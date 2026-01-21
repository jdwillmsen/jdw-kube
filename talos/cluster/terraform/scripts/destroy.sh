#!/bin/bash

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$PROJECT_DIR/backups"
TALOS_CONFIG_DIR="$PROJECT_DIR/../config"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse command line arguments
FORCE=false
while [[ $# -gt 0 ]]; do
  case $1 in
    -f|--force)
      FORCE=true
      shift
      ;;
    *)
      echo -e "${RED}[ERROR] Unknown option: $1${NC}"
      echo "Usage: $0 [-f|--force]"
      exit 1
      ;;
  esac
done

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Helper functions
backup_state() {
    if [ -f "$PROJECT_DIR/terraform.tfstate" ]; then
        mkdir -p "$BACKUP_DIR"
        backup_file="$BACKUP_DIR/destroy-state-backup-$(date +%Y%m%d_%H%M%S).tfstate"
        cp "$PROJECT_DIR/terraform.tfstate" "$backup_file"
        log_success "State backed up to $backup_file"
    fi
}

extract_tfvar() {
    local var_name="$1"
    grep -E "^${var_name}\s*=" "$PROJECT_DIR/terraform.tfvars" | sed -E 's/^[^=]*=\s*"([^"]*)".*$/\1/;t;s/^[^=]*=\s*([^#[:space:]]*).*$/\1/'
}

check_kubernetes_cluster() {
    if [ -f "$TALOS_CONFIG_DIR/talosconfig" ] && [ -f "$TALOS_CONFIG_DIR/kubeconfig" ]; then
        return 0
    fi
    return 1
}

show_vm_details() {
    echo -e "\n${YELLOW}→ VMs that will be destroyed:${NC}"
    vms_json=$(terraform show -json 2>/dev/null | jq -c '.values.root_module.resources[] | {name: .values.name, vmid: .values.vm_id, type: .address}' || echo "")

    if [ -n "$vms_json" ]; then
        echo -e "${BLUE}Control Plane Nodes:${NC}"
        echo "$vms_json" | jq -r 'select(.type | contains("controlplane")) | "  - \(.name) (VMID: \(.vmid))"' 2>/dev/null || true

        echo -e "${BLUE}Worker Nodes:${NC}"
        echo "$vms_json" | jq -r 'select(.type | contains("worker")) | "  - \(.name) (VMID: \(.vmid))"' 2>/dev/null || true
    else
        echo "  No VMs found in state"
    fi
}

graceful_shutdown() {
    local proxmox_host="$1"
    log_info "Stopping VMs gracefully..."

    local proxmox_address=$(echo "$proxmox_host" | sed -E 's|https?://([^/]+).*|\1|')
    vmids=$(terraform show -json 2>/dev/null | jq -r '.values.root_module.resources[].values.vm_id' 2>/dev/null || true)

    for vmid in $vmids; do
        echo "  Stopping VM $vmid..."
        ssh -o ConnectTimeout=5 "root@$proxmox_address" "qm stop $vmid" 2>/dev/null || {
            log_warning "Failed to stop VM $vmid via SSH (will destroy anyway)"
        }
    done

    if [ "$FORCE" = true ]; then
        echo "  Force mode: Waiting 2 seconds..."
        sleep 2
    else
        echo "  Waiting 10 seconds for VMs to stop..."
        sleep 10
    fi
}

# Header
if [ "$FORCE" = true ]; then
    echo -e "${RED}🚨 Talos Cluster DESTRUCTION Script [FORCED MODE]${NC}"
    # Disable strict error checking in force mode
    set +e
else
    echo -e "${RED}🚨 Talos Cluster DESTRUCTION Script${NC}"
    set -e
fi
echo -e "${RED}====================================${NC}"

# Check Terraform state
if [ ! -f "$PROJECT_DIR/terraform.tfstate" ] || [ ! -s "$PROJECT_DIR/terraform.tfstate" ]; then
    log_warning "No Terraform state found. Nothing to destroy."
    exit 0
fi

show_vm_details

# Skip Kubernetes checks in force mode
if [ "$FORCE" != true ]; then
    echo -e "\n${YELLOW}→ Checking for active Kubernetes cluster...${NC}"
    if check_kubernetes_cluster; then
        log_warning "Kubernetes cluster detected!"
        echo -e "\n${RED}⚠️  IMPORTANT - You should manually drain and remove nodes before destruction:${NC}"
        echo "   1. kubectl get nodes"
        echo "   2. kubectl drain <node> --ignore-daemonsets --delete-emptydir-data"
        echo "   3. kubectl delete node <node>"
        echo "   4. talosctl --nodes <CP-IP> etcd snapshot backup.yaml"
        echo -e "\n${YELLOW}Have you properly drained and backed up the cluster?${NC}"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo ""
        [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "Destruction cancelled by user"; exit 0; }
    else
        log_info "No Kubernetes cluster detected in ./config/"
    fi
else
    log_warning "Force mode: Skipping Kubernetes cluster check"
fi

# Backup state
echo -e "\n${YELLOW}→ Creating state backup...${NC}"
backup_state

# Show destruction plan
echo -e "\n${YELLOW}→ Terraform destruction plan:${NC}"

# CRITICAL: Add -refresh=false in force mode to skip provider refresh
if [ "$FORCE" = true ]; then
    log_warning "Force mode: Skipping Terraform provider refresh (may show stale data)"
    TERRAFORM_OPTS="-refresh=false -parallelism=1"
else
    TERRAFORM_OPTS=""
fi

# Wrap terraform commands with a timeout to prevent indefinite hanging
run_terraform_with_timeout() {
    local cmd="$1"
    local timeout_seconds=90

    if [ "$FORCE" = true ]; then
        # In force mode, use timeout to prevent hanging
        timeout $timeout_seconds bash -c "$cmd" 2>&1
        local exit_code=$?

        if [ $exit_code -eq 124 ]; then
            log_error "Terraform command timed out after ${timeout_seconds}s (provider unreachable)"
            log_info "Try: 1) Check Proxmox connectivity 2) Use -refresh=false 3) Manually remove from state"
            return 1
        elif [ $exit_code -ne 0 ]; then
            log_error "Terraform command failed with exit code $exit_code"
            return 1
        fi
    else
        # Normal mode: run without timeout
        bash -c "$cmd"
        return $?
    fi
}

# Create destruction plan
plan_cmd="terraform plan -destroy -out=tfdestroy-plan -input=false $TERRAFORM_OPTS"
run_terraform_with_timeout "$plan_cmd"

if [ ! -f tfdestroy-plan ] && [ "$FORCE" != true ]; then
    log_error "Failed to create destruction plan"
    exit 1
elif [ "$FORCE" = true ] && [ ! -f tfdestroy-plan ]; then
    log_warning "Force mode: Plan file not created, attempting direct destroy..."
fi

# Get resource count (only if plan exists)
if [ -f tfdestroy-plan ]; then
    destroy_count=$(terraform show -json tfdestroy-plan | jq '.resource_changes | length')
    echo -e "\n${RED}⚠️  Will destroy $destroy_count resources${NC}"
else
    log_warning "Force mode: Plan details unavailable (no refresh)"
fi

# Skip manual confirmation in force mode
if [ "$FORCE" != true ]; then
    echo -e "\n${RED}⚠️  FINAL WARNING - THIS CANNOT BE UNDONE${NC}"
    read -p $'\nType "DESTROY" (in all caps) to confirm: ' confirmation
    if [ "$confirmation" != "DESTROY" ]; then
        log_info "Destruction cancelled"
        rm -f tfdestroy-plan
        exit 0
    fi
else
    log_warning "Force mode: Skipping manual confirmation"
fi

# Extract Proxmox details
PROXMOX_ENDPOINT=$(extract_tfvar "proxmox_endpoint")

# Force mode: Always immediate destroy, skip graceful shutdown
if [ "$FORCE" = true ]; then
    log_warning "Force mode: Performing immediate DESTROY..."
    destroy_cmd="terraform apply -auto-approve $TERRAFORM_OPTS tfdestroy-plan"
    run_terraform_with_timeout "$destroy_cmd"

    # If plan file doesn't exist, try direct destroy without plan
    if [ ! -f tfdestroy-plan ]; then
        log_warning "Attempting direct destroy without plan..."
        destroy_cmd="terraform destroy -auto-approve $TERRAFORM_OPTS"
        run_terraform_with_timeout "$destroy_cmd"
    fi
else
    echo -e "\n${YELLOW}→ Choose destruction method:${NC}"
    echo "  1. Graceful shutdown (recommended)"
    echo "  2. Immediate destroy"
    read -p "Enter choice (1 or 2): " -n 1 -r
    echo ""

    case $REPLY in
        1)
            log_info "Performing graceful shutdown..."
            [ -n "$PROXMOX_ENDPOINT" ] && graceful_shutdown "$PROXMOX_ENDPOINT"
            terraform apply -auto-approve tfdestroy-plan
            ;;
        2)
            log_warning "Performing immediate DESTROY..."
            terraform apply -auto-approve tfdestroy-plan
            ;;
        *)
            log_error "Invalid choice"
            rm -f tfdestroy-plan
            exit 1
            ;;
    esac
fi

# Verify destruction
echo -e "\n${YELLOW}→ Verifying destruction...${NC}"
if [ -f "$PROJECT_DIR/terraform.tfstate" ]; then
    remaining=$(terraform state list 2>/dev/null | wc -l)
    [ "$remaining" -eq 0 ] && log_success "All resources destroyed successfully" || log_warning "$remaining resources still exist"
else
    log_success "State file removed - destruction complete"
fi

# Skip cleanup prompt in force mode
if [ "$FORCE" != true ]; then
    echo -e "\n${YELLOW}→ Cleanup (optional):${NC}"
    read -p "Remove orphaned disks from Proxmox storage? (y/N): " -n 1 -r
    echo ""
    [[ $REPLY =~ ^[Yy]$ ]] && log_info "Check: Datacenter → Storage → local-lvm → Content → Disks"
else
    log_warning "Force mode: Skipping optional cleanup prompt"
fi

# Final status
echo -e "\n${GREEN}✅ Cluster destruction complete!${NC}"
ls -lh "$BACKUP_DIR"/destroy-state-backup* 2>/dev/null || echo "  No backups found"

rm -f tfdestroy-plan tfplan
log_success "Destroy script complete"