#!/bin/bash
set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TALOS_CONFIG_DIR="$PROJECT_DIR/../config"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
ERRORS=0
WARNINGS=0

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[⚠]${NC} $1"; ((WARNINGS++)); }
log_error() { echo -e "${RED}[✗]${NC} $1"; ((ERRORS++)); }

# Test result tracking
print_summary() {
    echo -e "\n${YELLOW}═══════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Validation Complete${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"
    echo "Errors: $ERRORS"
    echo "Warnings: $WARNINGS"

    if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
        echo -e "\n${GREEN}✅ All checks passed! Ready to deploy.${NC}"
        exit 0
    elif [ $ERRORS -eq 0 ]; then
        echo -e "\n${YELLOW}⚠️  Checks passed with warnings. Review before deploying.${NC}"
        exit 0
    else
        echo -e "\n${RED}❌ Checks failed. Please fix errors before deploying.${NC}"
        exit 1
    fi
}

extract_tfvar() {
    local var_name="$1"
    grep -E "^${var_name}\s*=" "$PROJECT_DIR/terraform.tfvars" | sed -E 's/^[^=]*=\s*"([^"]*)".*$/\1/;t;s/^[^=]*=\s*([^#[:space:]]*).*$/\1/'
}

check_command() {
    local cmd="$1"
    local name="$2"
    if command -v "$cmd" &> /dev/null; then
        log_success "$name is installed"
        return 0
    else
        log_error "$name is not installed"
        return 1
    fi
}

check_file() {
    local file="$1"
    local desc="$2"
    if [ -f "$file" ]; then
        log_success "$desc exists"
        return 0
    else
        log_error "$desc not found at $file"
        return 1
    fi
}

check_proxmox_api() {
    local endpoint="$1"
    local token_id="$2"
    local token_secret="$3"

    local proxmox_address=$(echo "$endpoint" | sed -E 's|https?://([^/]+).*|\1|')

    log_info "Testing Proxmox API connectivity..."

    response=$(curl -s -k -H "Authorization: PVEAPIToken=$token_id=$token_secret" \
        "https://${proxmox_address}/api2/json/access/users" 2>/dev/null)

    if echo "$response" | grep -q "data"; then
        log_success "Proxmox API authentication successful"
        return 0
    else
        log_error "Proxmox API authentication failed"
        echo "  Response: $response"
        return 1
    fi
}

check_iso_in_proxmox() {
    local endpoint="$1"
    local iso_name="$2"
    local token_id="$3"
    local token_secret="$4"

    local proxmox_address=$(echo "$endpoint" | sed -E 's|https?://([^/]+).*|\1|')

    log_info "Checking for ISO: $iso_name"

    response=$(curl -s -k -H "Authorization: PVEAPIToken=$token_id=$token_secret" \
        "https://${proxmox_address}/api2/json/nodes/pve1/storage/local/content" 2>/dev/null)

    if echo "$response" | grep -q "$iso_name"; then
        log_success "ISO '$iso_name' found in Proxmox storage"
        return 0
    else
        log_error "ISO '$iso_name' NOT found in Proxmox storage"
        echo "  Available ISOs:"
        echo "$response" | jq -r '.data[] | select(.content == "iso") | "    - \(.volid)"' 2>/dev/null || echo "    Could not list ISOs"
        return 1
    fi
}

check_terraform_version() {
    local min_version="$1"
    local current_version

    current_version=$(terraform version | head -n1 | cut -d' ' -f2 | sed 's/^v//')

    if printf '%s\n%s\n' "$min_version" "$current_version" | sort -V -C 2>/dev/null; then
        log_success "Terraform version $current_version meets minimum $min_version"
        return 0
    else
        log_warning "Terraform version $current_version is below minimum $min_version"
        return 1
    fi
}

check_variable() {
    local var_name="$1"
    local value="$2"

    if [ -z "$value" ]; then
        log_error "Variable '$var_name' is empty or not set"
        return 1
    else
        log_success "Variable '$var_name' is set"
        return 0
    fi
}

check_vm_ids() {
    local tfvars_file="$1"

    log_info "Checking for duplicate VM IDs..."

    # Extract VM IDs from terraform.tfvars
    vm_ids=$(grep -E "vmid\s*=" "$tfvars_file" | sed -E 's/.*vmid\s*=\s*([0-9]+).*/\1/')

    if [ -z "$vm_ids" ]; then
        log_warning "Could not extract VM IDs from terraform.tfvars"
        return 1
    fi

    # Check for duplicates
    duplicates=$(echo "$vm_ids" | sort | uniq -d)

    if [ -n "$duplicates" ]; then
        log_error "Duplicate VM IDs found: $duplicates"
        return 1
    else
        log_success "All VM IDs are unique"
        return 0
    fi
}

# Header
echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
echo -e "${GREEN}Talos Cluster Pre-flight Validation${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════${NC}"

# Phase 1: System Dependencies
echo -e "\n${YELLOW}📦 Phase 1: System Dependencies${NC}"
check_command "terraform" "Terraform"
check_command "jq" "JQ (JSON processor)"
check_command "curl" "cURL"

# Phase 2: File Structure
echo -e "\n${YELLOW}📁 Phase 2: File Structure${NC}"
check_file "$PROJECT_DIR/terraform.tfvars" "terraform.tfvars"
check_file "$PROJECT_DIR/00-providers.tf" "Terraform providers file"
check_file "$PROJECT_DIR/01-variables.tf" "Terraform variables file"

# Phase 3: Required Variables
echo -e "\n${YELLOW}🔧 Phase 3: Required Variables${NC}"
PROXMOX_ENDPOINT=$(extract_tfvar "proxmox_endpoint")
PROXMOX_API_TOKEN_ID=$(extract_tfvar "proxmox_api_token_id")
PROXMOX_API_TOKEN_SECRET=$(extract_tfvar "proxmox_api_token_secret")
ISO_NAME=$(extract_tfvar "talos_iso")
STORAGE_POOL=$(extract_tfvar "storage_pool")

check_variable "proxmox_endpoint" "$PROXMOX_ENDPOINT"
check_variable "proxmox_api_token_id" "$PROXMOX_API_TOKEN_ID"
check_variable "proxmox_api_token_secret" "$PROXMOX_API_TOKEN_SECRET"
check_variable "talos_iso" "$ISO_NAME"
check_variable "storage_pool" "$STORAGE_POOL"

# Phase 4: Validations with API Calls
echo -e "\n${YELLOW}🌐 Phase 4: Proxmox Connectivity${NC}"
if [ -n "$PROXMOX_ENDPOINT" ] && [ -n "$PROXMOX_API_TOKEN_ID" ] && [ -n "$PROXMOX_API_TOKEN_SECRET" ]; then
    check_proxmox_api "$PROXMOX_ENDPOINT" "$PROXMOX_API_TOKEN_ID" "$PROXMOX_API_TOKEN_SECRET"

    if [ -n "$ISO_NAME" ]; then
        check_iso_in_proxmox "$PROXMOX_ENDPOINT" "$ISO_NAME" "$PROXMOX_API_TOKEN_ID" "$PROXMOX_API_TOKEN_SECRET"
    fi
else
    log_warning "Skipping API checks - missing credentials"
fi

# Phase 5: Configuration Validation
echo -e "\n${YELLOW}⚙️  Phase 5: Configuration Validation${NC}"
check_terraform_version "1.4.0"
check_vm_ids "$PROJECT_DIR/terraform.tfvars"

# Phase 6: Kubernetes Files (if they exist)
echo -e "\n${YELLOW}☸️  Phase 6: Kubernetes Configuration${NC}"
if [ -d "$TALOS_CONFIG_DIR" ]; then
    log_info "Found ./config/ directory"
    check_file "$TALOS_CONFIG_DIR/talosconfig" "Talos configuration"
    check_file "$TALOS_CONFIG_DIR/kubeconfig" "Kubernetes kubeconfig"
    check_file "$TALOS_CONFIG_DIR/controlplane.yaml" "Control plane config"
    check_file "$TALOS_CONFIG_DIR/worker.yaml" "Worker config"
else
    log_info "No ./config/ directory found (expected before deployment)"
fi

# Phase 7: Terraform State Check
echo -e "\n${YELLOW}📊 Phase 7: Terraform State${NC}"
if [ -f "$PROJECT_DIR/terraform.tfstate" ]; then
    log_info "Existing state file found"

    # Check if state is empty
    resource_count=$(terraform state list 2>/dev/null | wc -l)

    if [ "$resource_count" -eq 0 ]; then
        log_success "State file exists but contains no resources"
    else
        log_warning "State file contains $resource_count resources"
        echo "  Run 'terraform state list' to see them"
    fi
else
    log_success "No existing state file (clean deployment)"
fi

# Print final summary
print_summary
