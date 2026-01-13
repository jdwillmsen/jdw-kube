#!/bin/bash
set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$PROJECT_DIR/backups"

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
        backup_file="$BACKUP_DIR/state-backup-$(date +%Y%m%d_%H%M%S).tfstate"
        cp "$PROJECT_DIR/terraform.tfstate" "$backup_file"
        log_success "State backed up to $backup_file"
    fi
}

backup_tfvars() {
    if [ -f "$PROJECT_DIR/terraform.tfvars" ]; then
        mkdir -p "$BACKUP_DIR"
        backup_file="$BACKUP_DIR/tfvars-backup-$(date +%Y%m%d_%H%M%S).tfvars"
        cp "$PROJECT_DIR/terraform.tfvars" "$backup_file"
        log_success "Config backed up to $backup_file"
    fi
}

extract_tfvar() {
    local var_name="$1"
    # Handles both quoted values: var = "value"
    # And unquoted: var = value
    grep -E "^${var_name}\s*=" "$PROJECT_DIR/terraform.tfvars" | sed -E 's/^[^=]*=\s*"([^"]*)".*$/\1/;t;s/^[^=]*=\s*([^#[:space:]]*).*$/\1/'
}

check_iso_exists() {
    local proxmox_endpoint="$1"
    local iso_name="$2"
    local token_id="$3"
    local token_secret="$4"

    # Extract just the hostname/IP from URL
    local proxmox_address=$(echo "$proxmox_endpoint" | sed -E 's|https?://([^/]+).*|\1|')

    log_info "Checking if ISO '$iso_name' exists in Proxmox..."

    # Use Proxmox API to check for ISO
    local response
    response=$(curl -s -k -H "Authorization: PVEAPIToken=$token_id=$token_secret" \
        "https://${proxmox_address}/api2/json/nodes/pve1/storage/local/content" 2>/dev/null)

    if echo "$response" | grep -q "$iso_name"; then
        log_success "ISO '$iso_name' found in Proxmox"
        return 0
    else
        log_warning "ISO '$iso_name' not found in Proxmox (but will continue)"
        return 1
    fi
}

# Header
echo -e "${GREEN}🔧 Talos Cluster Deployment Script${NC}"
echo -e "${GREEN}====================================${NC}"

# Pre-flight checks
echo -e "\n${YELLOW}→ Running pre-flight checks${NC}"

# Check terraform.tfvars
if [ ! -f "$PROJECT_DIR/terraform.tfvars" ]; then
    log_error "terraform.tfvars not found"
    echo "Please create it from the template"
    exit 1
fi
log_success "terraform.tfvars exists"

# Check for required variables
required_vars=("proxmox_endpoint" "proxmox_api_token_id" "proxmox_api_token_secret")
for var in "${required_vars[@]}"; do
    if ! grep -qE "^${var}\s*=" "$PROJECT_DIR/terraform.tfvars"; then
        log_error "Required variable '$var' not found in terraform.tfvars"
        exit 1
    fi
done
log_success "Required variables present"

# Extract variables for later use
PROXMOX_ENDPOINT=$(extract_tfvar "proxmox_endpoint")
PROXMOX_API_TOKEN_ID=$(extract_tfvar "proxmox_api_token_id")
PROXMOX_API_TOKEN_SECRET=$(extract_tfvar "proxmox_api_token_secret")
ISO_NAME=$(extract_tfvar "talos_iso")

# Check Terraform version
TF_VERSION=$(terraform version | head -n1 | cut -d' ' -f2 | sed 's/^v//')
MIN_TF_VERSION="1.4.0"
if ! printf '%s\n%s\n' "$MIN_TF_VERSION" "$TF_VERSION" | sort -V -C 2>/dev/null; then
    log_warning "Terraform version $TF_VERSION is below recommended $MIN_TF_VERSION"
fi

# Backup state and config
backup_state
backup_tfvars

# Step 1: Initialize Terraform
echo -e "\n${YELLOW}→ Step 1: Initializing Terraform${NC}"
if [ ! -d "$PROJECT_DIR/.terraform" ]; then
    terraform init
else
    log_info "Terraform already initialized"
fi

# Step 2: Format and Validate
echo -e "\n${YELLOW}→ Step 2: Formatting and validation${NC}"
terraform fmt
terraform validate

if [ $? -ne 0 ]; then
    log_error "Validation failed"
    exit 1
fi
log_success "Validation passed"

# Check if ISO exists before planning
if [ -n "$PROXMOX_ENDPOINT" ] && [ -n "$ISO_NAME" ] && [ -n "$PROXMOX_API_TOKEN_ID" ]; then
    check_iso_exists "$PROXMOX_ENDPOINT" "$ISO_NAME" "$PROXMOX_API_TOKEN_ID" "$PROXMOX_API_TOKEN_SECRET"
fi

# Step 3: Create deployment plan
echo -e "\n${YELLOW}→ Step 3: Creating deployment plan${NC}"
terraform plan -var-file="$PROJECT_DIR/terraform.tfvars" -out=tfplan

if [ ! -f tfplan ]; then
    log_error "Plan creation failed"
    exit 1
fi
log_success "Plan created"

# Check if there are any changes
changes=$(terraform show -json tfplan | jq '.resource_changes | length')
if [ "$changes" -eq 0 ]; then
    echo -e "\n${GREEN}✓ No changes needed - infrastructure is up to date${NC}"
    rm -f tfplan
    exit 0
fi

# Show change summary (counts by action and resource type)
echo -e "\n${YELLOW}→ Planned Changes:${NC}"
terraform show -json tfplan | jq -r '
  .resource_changes[] |
  "\(.change.actions[] | ascii_upcase)"' | sort | uniq -c | awk '{print "  " $0 " resources"}'

# Show details of changes
echo -e "\n${YELLOW}→ Details:${NC}"
terraform show -json tfplan | jq -r '
  .resource_changes[] |
  "  \(.change.actions[] | ascii_upcase) \(.type) \(.name)"' | sort

# Step 4: User confirmation
echo -e "\n${YELLOW}⚠️  Review the plan above carefully${NC}"
read -p "Do you want to apply these changes? (y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Deployment cancelled"
    rm -f tfplan
    exit 0
fi

# Step 5: Apply changes
echo -e "\n${YELLOW}→ Step 4: Applying Terraform plan${NC}"
terraform apply tfplan

# Step 6: Show results
echo -e "\n${GREEN}✅ Deployment complete!${NC}"
echo -e "\n${YELLOW}Resources:${NC}"
terraform state list

# Enhanced VM summary
echo -e "\n${YELLOW}VM Summary:${NC}"
echo -e "${BLUE}Control Plane Nodes:${NC}"
terraform show -json | jq -r '.values.root_module.resources[] | select(.address | contains("controlplane")) | "  - \(.values.name) (VMID: \(.values.vm_id), CPU: \(.values.cpu[0].cores), RAM: \(.values.memory[0].dedicated/1024|round)GB)"'

echo -e "${BLUE}Worker Nodes:${NC}"
terraform show -json | jq -r '.values.root_module.resources[] | select(.address | contains("worker")) | "  - \(.values.name) (VMID: \(.values.vm_id), CPU: \(.values.cpu[0].cores), RAM: \(.values.memory[0].dedicated/1024|round)GB)"'

# Talos-specific: Show how to get IPs instead of trying QEMU agent
echo -e "\n${YELLOW}→ To get VM IP addresses after Talos boots:${NC}"
echo -e "  ${BLUE}Method 1 - Proxmox UI:${NC}"
echo -e "    1. Open Proxmox web UI: https://$extracted_proxmox_host:8006"
echo -e "    2. Click each VM → Console → Wait for Talos to display IP"
echo -e "\n  ${BLUE}Method 2 - DHCP Server:${NC}"
echo -e "    Check your DHCP server leases for new MAC addresses"
echo -e "\n  ${BLUE}Method 3 - After Bootstrapping:${NC}"
echo -e "    talosctl --nodes <PROXMOX-IP> get members (once bootstrapped)"

# Step 7: Next steps
echo -e "\n${GREEN}→ Next Steps:${NC}"
echo -e "  1. Get VM IPs using one of the methods above"
echo -e "  2. Generate Talos configs: talosctl gen config my-cluster https://<CP-VIP>:6443 --output-dir ./config"
echo -e "  3. Apply configs: talosctl apply-config --insecure --nodes <CP-IP> --file ./config/controlplane.yaml"
echo -e "  4. Bootstrap cluster: talosctl --nodes <CP-IP> bootstrap"
echo -e "  5. Get kubeconfig: talosctl --nodes <CP-IP> kubeconfig ./kubeconfig"

# Cleanup
rm -f tfplan
log_success "Script complete"
