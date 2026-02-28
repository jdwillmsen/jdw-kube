#!/bin/bash
set -euo pipefail

# ==================== CONFIGURATION ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
BACKUP_DIR="$PROJECT_DIR/backups"
STATE_DIR="$PROJECT_DIR/.tf-deploy-state"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Settings
AUTO_APPROVE="${AUTO_APPROVE:-false}"
SKIP_BACKUP="${SKIP_BACKUP:-false}"
PARALLEL_WORKERS="${PARALLEL_WORKERS:-true}"
MAX_RETRIES=3
RETRY_DELAY=5

# ==================== LOGGING ====================
log_info() { echo -e "[$(date '+%H:%M:%S')] ${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "[$(date '+%H:%M:%S')] ${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "[$(date '+%H:%M:%S')] ${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "[$(date '+%H:%M:%S')] ${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${CYAN}▶ $1${NC}"; }
log_detail() { echo -e "[$(date '+%H:%M:%S')] ${BLUE}  →${NC} $1"; }

# ==================== UTILITY FUNCTIONS ====================
check_command() {
    command -v "$1" &>/dev/null || { log_error "$1 is required but not installed"; exit 1; }
}

ensure_dir() {
    [[ -d "$1" ]] || mkdir -p "$1"
}

backup_file() {
    local src="$1"
    local prefix="${2:-backup}"

    if [[ "$SKIP_BACKUP" == "true" ]] || [[ ! -f "$src" ]]; then
        return 0
    fi

    ensure_dir "$BACKUP_DIR"
    local backup_file="$BACKUP_DIR/${prefix}-$(date +%Y%m%d_%H%M%S).$(basename "$src")"
    cp "$src" "$backup_file"
    log_detail "Backed up to $backup_file"
}

extract_tfvar() {
    local var_name="$1"
    grep -E "^${var_name}\s*=" "$PROJECT_DIR/terraform.tfvars" 2>/dev/null | \
        sed -E 's/^[^=]*=\s*"([^"]*)".*$/\1/;t;s/^[^=]*=\s*([^#[:space:]]*).*$/\1/' || \
        echo ""
}

save_state() {
    ensure_dir "$STATE_DIR"
    local tf_version=$(terraform version -json 2>/dev/null | jq -r '.terraform_version' || terraform version | head -n1 | cut -d' ' -f2)

    cat > "$STATE_DIR/deploy-state.json" <<EOF
{
  "timestamp": "$(date -Iseconds)",
  "project_dir": "$PROJECT_DIR",
  "terraform_version": "$tf_version",
  "auto_approved": $([[ "$AUTO_APPROVE" == "true" ]] && echo "true" || echo "false"),
  "last_deployment": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
}

load_state() {
    if [[ -f "$STATE_DIR/deploy-state.json" ]]; then
        log_detail "Previous deployment: $(jq -r '.last_deployment' "$STATE_DIR/deploy-state.json" 2>/dev/null || cat "$STATE_DIR/deploy-state.json")"
        return 0
    fi
    return 1
}

# ==================== TERRAFORM FUNCTIONS ====================
check_prerequisites() {
    log_step "Pre-flight Checks"

    # Check files
    if [[ ! -f "$PROJECT_DIR/terraform.tfvars" ]]; then
        log_error "terraform.tfvars not found in $PROJECT_DIR"
        log_info "Please create it from the template first"
        exit 1
    fi
    log_detail "terraform.tfvars exists"

    # Check required vars
    local required_vars=("proxmox_endpoint" "proxmox_api_token_id" "proxmox_api_token_secret")
    for var in "${required_vars[@]}"; do
        if ! grep -qE "^${var}\s*=" "$PROJECT_DIR/terraform.tfvars"; then
            log_error "Required variable '$var' not found in terraform.tfvars"
            exit 1
        fi
    done
    log_detail "Required variables present"

    # Check Terraform version
    local tf_version=$(terraform version | head -n1 | cut -d' ' -f2 | sed 's/^v//')
    local min_version="1.4.0"

    if ! printf '%s\n%s\n' "$min_version" "$tf_version" | sort -V -C 2>/dev/null; then
        log_warning "Terraform v$tf_version < recommended v$min_version"
    else
        log_detail "Terraform v$tf_version"
    fi

    # Check tools
    check_command terraform
    check_command jq
}

check_iso_exists() {
    local proxmox_endpoint="$1"
    local iso_name="$2"
    local token_id="$3"
    local token_secret="$4"

    [[ -z "$iso_name" ]] && return 0

    local proxmox_address=$(echo "$proxmox_endpoint" | sed -E 's|https?://([^/]+).*|\1|')

    log_detail "Checking ISO '$iso_name' in Proxmox..."

    local response
    response=$(curl -s -k -H "Authorization: PVEAPIToken=$token_id=$token_secret" \
        "https://${proxmox_address}/api2/json/nodes/pve1/storage/local/content" 2>/dev/null || echo "")

    if echo "$response" | grep -q "$iso_name"; then
        log_success "ISO '$iso_name' found"
        return 0
    else
        log_warning "ISO '$iso_name' not found (will continue anyway)"
        return 1
    fi
}

init_terraform() {
    log_step "Initializing Terraform"

    if [[ ! -d "$PROJECT_DIR/.terraform" ]]; then
        terraform init
    else
        log_detail "Already initialized"
    fi
}

validate_terraform() {
    log_step "Formatting & Validation"

    terraform fmt
    if ! terraform validate; then
        log_error "Validation failed"
        exit 1
    fi
    log_success "Validation passed"
}

show_plan_summary() {
    local plan_file="$1"

    log_step "Plan Summary"

    local changes=$(terraform show -json "$plan_file" | jq '.resource_changes | length')

    if [[ "$changes" -eq 0 ]]; then
        echo -e "\n${GREEN}✓ No changes needed - infrastructure is up to date${NC}"
        rm -f "$plan_file"
        return 1
    fi

    # Fixed: Properly aggregate action counts
    echo -e "\n${YELLOW}Changes:${NC}"
    terraform show -json "$plan_file" | jq -r '
        [.resource_changes[].change.actions[]] |
        group_by(.) |
        map({action: .[0], count: length}) |
        .[] |
        "  \(.action | ascii_upcase): \(.count)"
    '

    # Show details
    echo -e "\n${YELLOW}Details:${NC}"
    terraform show -json "$plan_file" | jq -r '
        .resource_changes[] |
        "  \(.change.actions[] | ascii_upcase) \(.type) \(.name)"' | sort

    return 0
}

apply_with_retry() {
    local plan_file="$1"
    local attempt=1

    while [[ $attempt -le $MAX_RETRIES ]]; do
        log_detail "Apply attempt $attempt/$MAX_RETRIES"

        if terraform apply "$plan_file"; then
            return 0
        fi

        if [[ $attempt -lt $MAX_RETRIES ]]; then
            local delay=$((RETRY_DELAY * attempt))
            log_warning "Apply failed, waiting ${delay}s before retry..."
            sleep $delay
        fi
        ((attempt++))
    done

    return 1
}

show_deployment_summary() {
    log_step "Deployment Summary"

    # State list
    echo -e "${BLUE}Resources:${NC}"
    terraform state list | while read -r resource; do
        echo "  • $resource"
    done

    # VM Details if Proxmox
    if terraform state list | grep -q "proxmox_vm"; then
        echo -e "\n${BLUE}Virtual Machines:${NC}"

        # Control planes
        local cp_vms=$(terraform show -json | jq -r '
            .values.root_module.resources[] |
            select(.type == "proxmox_virtual_environment_vm" and (.name | contains("control") or .name | contains("cp"))) |
            "  \(.values.name) | VMID: \(.values.vm_id) | CPU: \(.values.cpu[0].cores) cores | RAM: \(.values.memory[0].dedicated/1024)GB | IP: \(.values.ipv4_addresses[0][0] // "DHCP")"
        ' 2>/dev/null || echo "")

        if [[ -n "$cp_vms" ]]; then
            echo -e "  ${CYAN}Control Planes:${NC}"
            echo "$cp_vms"
        fi

        # Workers
        local worker_vms=$(terraform show -json | jq -r '
            .values.root_module.resources[] |
            select(.type == "proxmox_virtual_environment_vm" and (.name | contains("worker") or .name | contains("node"))) |
            "  \(.values.name) | VMID: \(.values.vm_id) | CPU: \(.values.cpu[0].cores) cores | RAM: \(.values.memory[0].dedicated/1024)GB | IP: \(.values.ipv4_addresses[0][0] // "DHCP")"
        ' 2>/dev/null || echo "")

        if [[ -n "$worker_vms" ]]; then
            echo -e "  ${CYAN}Workers:${NC}"
            echo "$worker_vms"
        fi
    fi
}

# ==================== COMMANDS ====================
cmd_deploy() {
    local skip_plan=false
    local dry_run=false
    local auto_approve_flag=false

    # Parse args
    for arg in "$@"; do
        # Handle combined short flags (e.g., -as, -da)
        if [[ "$arg" =~ ^-[^-].* ]]; then
            local flags="${arg:1}"
            for (( i=0; i<${#flags}; i++ )); do
                case "${flags:$i:1}" in
                    a) auto_approve_flag=true ;;
                    s) skip_plan=true ;;
                    d) dry_run=true ;;
                esac
            done
        else
            case "$arg" in
                --auto-approve) auto_approve_flag=true ;;
                --skip-plan) skip_plan=true ;;
                --dry-run) dry_run=true ;;
            esac
        fi
    done

    # Override env var if flag passed
    [[ "$auto_approve_flag" == "true" ]] && AUTO_APPROVE=true

    cd "$PROJECT_DIR"

    # Header
    echo -e "${GREEN}🔧 Talos Cluster Deployment${NC}"
    log_detail "Project: $PROJECT_DIR"
    log_detail "Mode: $([[ "$dry_run" == "true" ]] && echo "DRY RUN" || echo "DEPLOY")"

    # Pre-flight
    check_prerequisites

    # Extract vars early for ISO check
    local proxmox_endpoint=$(extract_tfvar "proxmox_endpoint")
    local proxmox_token_id=$(extract_tfvar "proxmox_api_token_id")
    local proxmox_token_secret=$(extract_tfvar "proxmox_api_token_secret")
    local iso_name=$(extract_tfvar "talos_iso")

    # Backup
    if [[ "$SKIP_BACKUP" != "true" ]]; then
        backup_file "$PROJECT_DIR/terraform.tfstate" "tfstate"
        backup_file "$PROJECT_DIR/terraform.tfvars" "tfvars"
    fi

    # Init & Validate
    init_terraform
    validate_terraform

    # ISO Check
    if [[ -n "$proxmox_endpoint" && -n "$iso_name" ]]; then
        check_iso_exists "$proxmox_endpoint" "$iso_name" "$proxmox_token_id" "$proxmox_token_secret" || true
    fi

    # Plan
    log_step "Creating Plan"
    local plan_file="$PROJECT_DIR/tfplan-$(date +%s)"

    if [[ "$skip_plan" == "true" ]]; then
        log_detail "Skipping detailed plan (--skip-plan)"
        terraform plan -var-file="$PROJECT_DIR/terraform.tfvars" -out="$plan_file"
    else
        terraform plan -var-file="$PROJECT_DIR/terraform.tfvars" -out="$plan_file"

        if ! show_plan_summary "$plan_file"; then
            log_info "No changes to apply"
            rm -f "$plan_file"
            return 0
        fi
    fi

    # Dry run exit
    if [[ "$dry_run" == "true" ]]; then
        log_info "Dry run complete - plan saved to $plan_file"
        return 0
    fi

    # Confirmation
    if [[ "$AUTO_APPROVE" != "true" ]]; then
        echo ""
        read -p "Proceed with deployment? [y/N]: " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Cancelled"
            rm -f "$plan_file"
            return 0
        fi
    else
        log_detail "Auto-approving (--auto-approve)"
    fi

    # Apply
    log_step "Applying Changes"
    if apply_with_retry "$plan_file"; then
        save_state
        show_deployment_summary

        # Next steps
        echo -e "\n${GREEN}✅ Deployment Complete${NC}"
        echo -e "\n${YELLOW}Next Steps:${NC}"
        echo "  1. Verify VMs: terraform show"
        echo "  2. Get kubeconfig: talosctl kubeconfig"
        echo "  3. Check nodes: kubectl get nodes"
        echo "  4. View state: $0 status"
    else
        log_error "Deployment failed after $MAX_RETRIES attempts"
        return 1
    fi

    rm -f "$plan_file"
}

cmd_destroy() {
 local force_mode=false
    local skip_confirm=false

    # Parse destroy-specific args
    for arg in "$@"; do
        # Handle combined short flags (e.g., -fa, -af)
        if [[ "$arg" =~ ^-[^-].* ]]; then
            local flags="${arg:1}"
            for (( i=0; i<${#flags}; i++ )); do
                case "${flags:$i:1}" in
                    f) force_mode=true ;;
                    a) skip_confirm=true ;;
                esac
            done
        else
            case "$arg" in
                --force) force_mode=true ;;
                --auto-approve) skip_confirm=true ;;
            esac
        fi
    done

    # Auto-approve env var also works
    [[ "$AUTO_APPROVE" == "true" ]] && skip_confirm=true

    cd "$PROJECT_DIR"

    # Initialize terraform first (required for state list to work)
    init_terraform

    local talos_config_dir="$PROJECT_DIR/../config"

    # Header
    if [[ "$force_mode" == "true" ]]; then
        echo -e "${RED}🚨 DESTROY [FORCE MODE]${NC}"
        log_warning "Force mode: Bypassing safety checks and confirmations"
        set +e  # Disable exit on error for force mode
    else
        echo -e "${RED}🚨 Cluster Destruction${NC}"
        set -e
    fi

    # Check state
    if [[ ! -f "$PROJECT_DIR/terraform.tfstate" ]] || [[ ! -s "$PROJECT_DIR/terraform.tfstate" ]]; then
        log_warning "No state file found. Nothing to destroy."
        return 0
    fi

    # Show what's being destroyed
    log_step "Resources to Destroy"
    local vm_count=$(terraform state list 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$vm_count" -gt 0 ]]; then
        terraform state list | while read -r resource; do
            echo "  • $resource"
        done
    else
        log_info "No resources in state"
        return 0
    fi

    # Check for active Kubernetes cluster (unless force mode)
    if [[ "$force_mode" != "true" ]]; then
        if [[ -f "$talos_config_dir/talosconfig" ]] && [[ -f "$talos_config_dir/kubeconfig" ]]; then
            log_warning "Active Kubernetes cluster detected in $talos_config_dir"
            echo -e "\n${YELLOW}Pre-destruction checklist:${NC}"
            echo "  1. kubectl drain <node> --ignore-daemonsets --delete-emptydir-data"
            echo "  2. kubectl delete node <node>"
            echo "  3. talosctl etcd snapshot backup.yaml"
            echo ""

            if [[ "$skip_confirm" != "true" ]]; then
                read -p "Have you drained nodes and taken backups? (y/N): " -n 1 -r
                echo ""
                [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "Cancelled"; return 0; }
            fi
        fi
    fi

    # Backup state
    if [[ "$SKIP_BACKUP" != "true" ]]; then
        backup_file "$PROJECT_DIR/terraform.tfstate" "pre-destroy"
    fi

    # Prepare terraform options
    local tf_opts=""
    [[ "$force_mode" == "true" ]] && tf_opts="-refresh=false"

    log_step "Creating Destruction Plan"

    # Function to run terraform with timeout (for force mode)
    run_with_timeout() {
        local cmd="$1"
        local timeout_sec=120

        if [[ "$force_mode" == "true" ]]; then
            timeout $timeout_sec bash -c "$cmd" 2>&1
            local exit_code=$?
            if [[ $exit_code -eq 124 ]]; then
                log_error "Command timed out after ${timeout_sec}s (Proxmox unreachable?)"
                log_info "Tip: Use --force to skip provider refresh"
                return 1
            fi
            return $exit_code
        else
            eval "$cmd"
            return $?
        fi
    }

    # Create plan
    if ! run_with_timeout "terraform plan -destroy -out=tfdestroy-plan $tf_opts"; then
        [[ "$force_mode" != "true" ]] && return 1
    fi

    # Show count
    if [[ -f tfdestroy-plan ]]; then
        local destroy_count=$(terraform show -json tfdestroy-plan | jq '.resource_changes | length')
        log_warning "Will destroy $destroy_count resources"
    fi

    # Confirmation
    if [[ "$skip_confirm" != "true" ]] && [[ "$force_mode" != "true" ]]; then
        echo -e "\n${RED}⚠️  FINAL WARNING - THIS CANNOT BE UNDONE${NC}"
        read -p $'\nType "DESTROY" (all caps) to confirm: ' confirmation
        if [[ "$confirmation" != "DESTROY" ]]; then
            log_info "Cancelled"
            rm -f tfdestroy-plan
            return 0
        fi
    elif [[ "$force_mode" == "true" ]]; then
        log_warning "Force mode: Skipping confirmation"
    fi

    # Destruction logic
    log_step "Destroying Resources"

    if [[ "$force_mode" == "true" ]]; then
        # Force mode: Try plan first, then direct if needed
        if [[ -f tfdestroy-plan ]]; then
            terraform apply -auto-approve $tf_opts tfdestroy-plan || {
                log_warning "Plan apply failed, trying direct destroy..."
                terraform destroy -auto-approve $tf_opts
            }
        else
            terraform destroy -auto-approve $tf_opts
        fi
    else
        # Normal mode: Offer graceful shutdown
        echo -e "\n${YELLOW}Destruction method:${NC}"
        echo "  1. Graceful shutdown (stop VMs first, recommended)"
        echo "  2. Immediate destroy (faster, may leave disks)"
        read -p "Choice (1/2): " -n 1 -r
        echo ""

        case $REPLY in
            1)
                # Graceful shutdown via SSH
                local proxmox_endpoint=$(extract_tfvar "proxmox_endpoint")
                if [[ -n "$proxmox_endpoint" ]]; then
                    log_info "Stopping VMs gracefully..."
                    local proxmox_host=$(echo "$proxmox_endpoint" | sed -E 's|https?://([^/]+).*|\1|')

                    terraform state list | grep "proxmox_virtual_environment_vm" | while read -r resource; do
                        local vmid=$(terraform state show "$resource" 2>/dev/null | grep "vm_id" | head -1 | awk -F'=' '{print $2}' | tr -d ' ')
                        if [[ -n "$vmid" ]]; then
                            log_detail "Stopping VM $vmid..."
                            ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "root@$proxmox_host" "qm stop $vmid" 2>/dev/null || \
                                log_warning "Failed to stop VM $vmid via SSH"
                        fi
                    done

                    log_info "Waiting 10s for VMs to stop..."
                    sleep 10
                fi
                terraform apply -auto-approve tfdestroy-plan
                ;;
            2)
                terraform apply -auto-approve tfdestroy-plan
                ;;
            *)
                log_error "Invalid choice"
                rm -f tfdestroy-plan
                return 1
                ;;
        esac
    fi

    # Cleanup
    rm -f tfdestroy-plan

    log_step "Destruction Complete"

    # Optional cleanup
    if [[ "$force_mode" != "true" ]] && [[ "$skip_confirm" != "true" ]]; then
        read -p "Check Proxmox for orphaned disks? (opens web UI hint) (y/N): " -n 1 -r
        echo ""
        [[ $REPLY =~ ^[Yy]$ ]] && log_info "Check: Datacenter → Storage → local-lvm → Content → Disks"
    fi

    # Remove state file if empty
    if [[ -f "$PROJECT_DIR/terraform.tfstate" ]]; then
        local remaining=$(terraform state list 2>/dev/null | wc -l)
        if [[ "$remaining" -eq 0 ]]; then
            rm -f "$PROJECT_DIR/terraform.tfstate"
            rm -f "$STATE_DIR/deploy-state.json"  # Clear deployment tracking
            log_success "All resources destroyed"
        else
            log_warning "$remaining resources may remain (check state)"
        fi
    fi
}

cmd_status() {
    log_step "Deployment Status"
    cd "$PROJECT_DIR"

    # Deployment tracking metadata
    if [[ -f "$STATE_DIR/deploy-state.json" ]]; then
        echo -e "${BLUE}Last Deployment:${NC}"
        jq -r 'to_entries[] | "  \(.key): \(.value)"' "$STATE_DIR/deploy-state.json"
    else
        log_warning "No deployment state found"
    fi

    # Read state file directly with jq (faster than terraform init + state list)
    if [[ -f "$PROJECT_DIR/terraform.tfstate" ]]; then
        local count=$(jq -r '.resources | length' "$PROJECT_DIR/terraform.tfstate" 2>/dev/null || echo "0")
        echo -e "\n${BLUE}Resources:${NC}"
        echo "  Managed resources: $count"

        if [[ "$count" -gt 0 ]]; then
            echo -e "\n${CYAN}State List:${NC}"
            jq -r '.resources[].module // empty' "$PROJECT_DIR/terraform.tfstate" 2>/dev/null | head -10 | while read -r resource; do
                echo "  • $resource"
            done
            jq -r '.resources[] | "\(.type).\(.name)"' "$PROJECT_DIR/terraform.tfstate" 2>/dev/null | head -10 | while read -r resource; do
                echo "  • $resource"
            done
            [[ "$count" -gt 10 ]] && echo "  ... and $((count - 10)) more"
        fi
    else
        log_warning "No terraform.tfstate found"
        echo "  Run: ./cluster.sh deploy"
    fi
}

cmd_plan() {
    log_step "View Plan Only"
    cd "$PROJECT_DIR"

    init_terraform
    validate_terraform

    local plan_file="$PROJECT_DIR/tfplan-view"
    terraform plan -var-file="$PROJECT_DIR/terraform.tfvars" -out="$plan_file"
    show_plan_summary "$plan_file" || true
    rm -f "$plan_file"
}

cmd_cleanup() {
    log_step "Cleanup Generated Files"

    local to_remove=(
        "$PROJECT_DIR/tfplan*"
        "$PROJECT_DIR/.terraform.lock.hcl"
        "$PROJECT_DIR/crash.log"
    )

    for pattern in "${to_remove[@]}"; do
        if ls $pattern 1> /dev/null 2>&1; then
            rm -f $pattern
            log_detail "Removed $pattern"
        fi
    done

    # Ask about state
    read -p "Remove Terraform state & backups too? [y/N]: " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$PROJECT_DIR/.terraform" "$BACKUP_DIR" "$STATE_DIR"
        log_detail "Removed .terraform, backups, and state"
    fi

    log_success "Cleanup complete"
}

cmd_help() {
    echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}        ${GREEN}🔧 Talos Cluster Infrastructure Manager${NC}            ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Usage:${NC}"
    echo -e "  $0 ${GREEN}<command>${NC} [options]"
    echo ""
    echo -e "${YELLOW}Commands:${NC}"
    echo -e "  ${GREEN}deploy${NC}          Deploy or update cluster infrastructure"
    echo -e "  ${GREEN}destroy${NC}         Destroy cluster (with safety checks)"
    echo -e "  ${GREEN}plan${NC}            Preview changes without applying"
    echo -e "  ${GREEN}status${NC}          Show current deployment state"
    echo -e "  ${GREEN}cleanup${NC}         Remove generated files and backups"
    echo ""
    echo -e "${YELLOW}Deploy Options:${NC}"
    echo -e "  ${BLUE}-a, --auto-approve${NC}  Skip confirmation prompt"
    echo -e "  ${BLUE}-s, --skip-plan${NC}     Skip detailed plan summary (faster)"
    echo -e "  ${BLUE}-d, --dry-run${NC}       Create plan but don't apply"
    echo ""
    echo -e "${YELLOW}Destroy Options:${NC}"
    echo -e "  ${BLUE}-a, --auto-approve${NC}  Skip confirmation prompt"
    echo -e "  ${BLUE}-f, --force${NC}         Force mode (bypass K8s check, no refresh)"
    echo ""
    echo -e "${YELLOW}Global Options:${NC}"
    echo -e "  ${BLUE}-h, --help${NC}          Show this help message"
    echo ""
    echo -e "${YELLOW}Environment Variables:${NC}"
    echo -e "  ${CYAN}AUTO_APPROVE${NC}      Set to 'true' to skip all confirmations"
    echo -e "  ${CYAN}SKIP_BACKUP${NC}       Set to 'true' to skip backup creation"
    echo -e "  ${CYAN}PARALLEL_WORKERS${NC}  Enable parallel operations (default: true)"
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo -e "  $0 ${GREEN}deploy${NC} ${BLUE}-a${NC}                     # Quick deploy"
    echo -e "  $0 ${GREEN}deploy${NC} ${BLUE}-d${NC}                     # Dry run"
    echo -e "  $0 ${GREEN}destroy${NC} ${BLUE}-f${NC}                    # Emergency destroy"
    echo -e "  $0 ${GREEN}destroy${NC} ${BLUE}-a${NC}                    # Automated destroy"
    echo -e "  $0 ${GREEN}plan${NC}"
    echo ""
    echo -e "${YELLOW}Quick Start:${NC}"
    echo -e "  1. Configure: Edit ${CYAN}terraform.tfvars${NC}"
    echo -e "  2. Preview:    $0 ${GREEN}plan${NC}"
    echo -e "  3. Deploy:     $0 ${GREEN}deploy${NC} ${BLUE}-a${NC}"
    echo -e "  4. Cleanup:    $0 ${GREEN}destroy${NC}"
    echo ""
}

# ==================== MAIN ====================
main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        deploy)
            cmd_deploy "$@"
            ;;
        destroy)
            cmd_destroy "$@"
            ;;
        plan)
            cmd_plan "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        cleanup)
            cmd_cleanup "$@"
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            log_error "Unknown command: $cmd"
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"