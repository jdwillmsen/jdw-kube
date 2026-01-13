#!/bin/bash
set -e

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

get_vm_names() {
    terraform state list 2>/dev/null | grep -E 'proxmox_virtual_environment_vm\.(controlplane|worker)' || echo ""
}

show_vm_details() {
    echo -e "\n${YELLOW}→ VMs that will be destroyed:${NC}"

    # Get all VMs
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
    local token_id="$2"
    local token_secret="$3"

    log_info "Stopping VMs gracefully..."

    # Extract hostname from URL
    local proxmox_address=$(echo "$proxmox_host" | sed -E 's|https?://([^/]+).*|\1|')

    # Get all VM IDs
    vmids=$(terraform show -json 2>/dev/null | jq -r '.values.root_module.resources[].values.vm_id' 2>/dev/null || true)

    for vmid in $vmids; do
        echo "  Stopping VM $vmid..."
        # Use qm stop command via SSH
        ssh -o ConnectTimeout=5 "root@$proxmox_address" "qm stop $vmid" 2>/dev/null || {
            log_warning "Failed to stop VM $vmid via SSH (will destroy anyway)"
        }
    done

    echo "  Waiting 10 seconds for VMs to stop..."
    sleep 10
}

# Header
echo -e "${RED}🚨 Talos Cluster DESTRUCTION Script${NC}"
echo -e "${RED}====================================${NC}"

# Check if Terraform state exists
if [ ! -f "$PROJECT_DIR/terraform.tfstate" ] || [ ! -s "$PROJECT_DIR/terraform.tfstate" ]; then
    log_warning "No Terraform state found. Nothing to destroy."
    exit 0
fi

# Show what will be destroyed
show_vm_details

# Check for Kubernetes cluster
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
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Destruction cancelled by user"
        exit 0
    fi
else
    log_info "No Kubernetes cluster detected in ./config/"
fi

# Backup state before destruction
echo -e "\n${YELLOW}→ Creating state backup...${NC}"
backup_state

# Show destruction plan
echo -e "\n${YELLOW}→ Terraform destruction plan:${NC}"
terraform plan -destroy -out=tfdestroy-plan -input=false -lock-timeout=0s

if [ ! -f tfdestroy-plan ]; then
    log_error "Failed to create destruction plan"
    exit 1
fi

# Get resource count
destroy_count=$(terraform show -json tfdestroy-plan | jq '.resource_changes | length')
echo -e "\n${RED}⚠️  Will destroy $destroy_count resources${NC}"

# Double confirmation
echo -e "\n${RED}⚠️  FINAL WARNING - THIS CANNOT BE UNDONE${NC}"
read -p $'\nType "DESTROY" (in all caps) to confirm: ' confirmation
if [ "$confirmation" != "DESTROY" ]; then
    log_info "Destruction cancelled"
    rm -f tfdestroy-plan
    exit 0
fi

# Option: Graceful shutdown or immediate destroy
echo -e "\n${YELLOW}→ Choose destruction method:${NC}"
echo "  1. Graceful shutdown (recommended - attempts safe shutdown)"
echo "  2. Immediate destroy (forces deletion, may leave orphaned disks)"
read -p "Enter choice (1 or 2): " -n 1 -r
echo ""

# Extract Proxmox details for graceful shutdown
PROXMOX_ENDPOINT=$(extract_tfvar "proxmox_endpoint")
PROXMOX_API_TOKEN_ID=$(extract_tfvar "proxmox_api_token_id")
PROXMOX_API_TOKEN_SECRET=$(extract_tfvar "proxmox_api_token_secret")

case $REPLY in
    1)
        log_info "Performing graceful shutdown..."

        # Stop VMs first via SSH
        if [ -n "$PROXMOX_ENDPOINT" ]; then
            graceful_shutdown "$PROXMOX_ENDPOINT" "$PROXMOX_API_TOKEN_ID" "$PROXMOX_API_TOKEN_SECRET"
        else
            log_warning "Could not extract Proxmox endpoint, skipping graceful shutdown"
        fi

        # Apply the destroy plan
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

# Verify destruction
echo -e "\n${YELLOW}→ Verifying destruction...${NC}"
if [ -f "$PROJECT_DIR/terraform.tfstate" ]; then
    remaining=$(terraform state list 2>/dev/null | wc -l)
    if [ "$remaining" -eq 0 ]; then
        log_success "All resources destroyed successfully"
    else
        log_warning "$remaining resources still exist"
        terraform state list
    fi
else
    log_success "State file removed - destruction complete"
fi

# Cleanup Proxmox leftovers (optional)
echo -e "\n${YELLOW}→ Cleanup (optional):${NC}"
read -p "Remove orphaned disks from Proxmox storage? (y/N): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log_info "You may want to manually check Proxmox Storage → 'Orphaned Disks'"
    echo "  Location: Datacenter → Storage → local-lvm → Content → Disks"
fi

# Final status
echo -e "\n${GREEN}✅ Cluster destruction complete!${NC}"
echo -e "\n${YELLOW}What was backed up:${NC}"
ls -lh "$BACKUP_DIR"/destroy-state-backup* 2>/dev/null || echo "  No backups found"
echo -e "\n${YELLOW}Next steps:${NC}"
echo "  - Verify in Proxmox UI that VMs are gone"
echo "  - Clean up any orphaned disks (if you chose to)"
echo "  - Remove or archive ./config/ directory if no longer needed"
echo "  - Keep backups for a few days in case of accidental destruction"

# Cleanup
rm -f tfdestroy-plan tfplan
log_success "Destroy script complete"
