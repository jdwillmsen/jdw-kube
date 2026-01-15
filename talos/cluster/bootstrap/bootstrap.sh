#!/bin/bash
set -euo pipefail

# ==================== DYNAMIC CONFIGURATION ====================
# Define nodes as space-separated lists
CONTROL_PLANE_IPS="192.168.1.106"
WORKER_IPS="192.168.1.108 192.168.1.105"

# Cluster Settings
CLUSTER_NAME="proxmox-talos-prod"
KUBERNETES_VERSION="v1.34.0"
TALOS_VERSION="v1.12.0"
HAPROXY_IP="192.168.1.237"
CONTROL_PLANE_ENDPOINT="kube.$CLUSTER_NAME.jdwkube.com"

# Hardware Settings
DEFAULT_NETWORK_INTERFACE="eth0"
DEFAULT_DISK="sda"

# Per-node overrides (optional - add as needed)
declare -A NODE_INTERFACES=()  # e.g., (["192.168.1.250"]="eth1")
declare -A NODE_DISKS=()       # e.g., (["192.168.1.250"]="nvme0n1")

# Talos Factory Image
INSTALLER_IMAGE="factory.talos.dev/installer/9d7d65b2bfb510587239ba5645d4a995726767cf0b149b2ec8a51ede5f05f76c:${TALOS_VERSION}"

# Deployment Settings
MAX_RETRIES=3
RETRY_DELAY=5
NODE_RESTART_WAIT=120    # Wait for node to restart after config apply
BOOTSTRAP_TIMEOUT=900    # Max time to wait for control plane to be ready

# Secrets Vault
SECRETS_VAULT_DIR="${SCRIPT_DIR:-.}/.talos-secrets-vault"

# ==================== SCRIPT SETUP ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_step() { echo -e "\n${BLUE}[STEP]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ==================== OS-SPECIFIC SETTINGS ====================
# Detect OS type for ping compatibility
if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "win32" ]]; then
  # Windows Git Bash
  PING_CMD="ping -n 1 -w 1000"  # 1 packet, 1000ms timeout
  HOSTS_FILE="/c/Windows/System32/drivers/etc/hosts"
else
  # Linux/macOS
  PING_CMD="ping -c 1 -W 1"     # 1 packet, 1s timeout
  HOSTS_FILE="/etc/hosts"
fi

# ==================== NODE MANAGEMENT FUNCTIONS ====================

add_control_plane_node() {
  local new_ip="$1"
  log_step "Adding new control plane node: $new_ip"

  if [ ! -f "secrets.yaml" ]; then
    log_error "secrets.yaml not found! Use secrets from initial bootstrap."
    log_error "Place the original secrets.yaml in this directory or run in bootstrap mode first."
    exit 1
  fi

  nic="${NODE_INTERFACES[$new_ip]:-$DEFAULT_NETWORK_INTERFACE}"
  disk="${NODE_DISKS[$new_ip]:-$DEFAULT_DISK}"

  log_info "Generating configuration for new control plane node..."
  talosctl gen config \
    --with-secrets secrets.yaml \
    --kubernetes-version "${KUBERNETES_VERSION}" \
    --talos-version "${TALOS_VERSION}" \
    --install-image "${INSTALLER_IMAGE}" \
    --output-types controlplane \
    "${CLUSTER_NAME}" "https://${CONTROL_PLANE_ENDPOINT}:6443" >/dev/null

  cat > "patch-cp-${new_ip}.yaml" <<EOF
machine:
  install:
    disk: /dev/${disk}
    extraKernelArgs:
      - console=tty0
      - console=ttyS0
  network:
    interfaces:
      - interface: ${nic}
        dhcp: true
  sysctls:
    vm.nr_hugepages: "1024"
  kubelet:
    extraArgs:
      rotate-server-certificates: true
  kernel:
    modules:
      - name: nvme_tcp
      - name: vfio_pci
  certSANs:
    - ${$new_ip}
    - ${HAPROXY_IP}
    - ${CONTROL_PLANE_ENDPOINT}
cluster:
  apiServer:
    certSANs:
      - ${$new_ip}
      - ${HAPROXY_IP}
      - ${CONTROL_PLANE_ENDPOINT}
EOF

  cp controlplane.yaml "node-cp-${new_ip}.yaml"
  talosctl machineconfig patch "node-cp-${new_ip}.yaml" \
    --patch "@patch-cp-${new_ip}.yaml" \
    --output "node-cp-${new_ip}.yaml"

  log_info "Applying configuration to node $new_ip..."
  talosctl apply-config --insecure --nodes "$new_ip" --file "node-cp-${new_ip}.yaml"

  log_info "Waiting 45 seconds for node to initialize..."
  sleep 45

  if [ "${#CONTROL_PLANE_IPS_ARRAY[@]}" -gt 0 ]; then
    talosctl --endpoints "${CONTROL_PLANE_IPS_ARRAY[0]}" health --nodes "$new_ip" || {
      log_warn "Health check failed for new node $new_ip"
    }
  fi

  log_info "✓ Control plane node $new_ip added"
  rm -f "patch-cp-${new_ip}.yaml"
}

add_worker_node() {
  local new_ip="$1"
  log_step "Adding new worker node: $new_ip"

  if [ ! -f "secrets.yaml" ]; then
    log_error "secrets.yaml not found! Use secrets from initial bootstrap."
    exit 1
  fi

  nic="${NODE_INTERFACES[$new_ip]:-$DEFAULT_NETWORK_INTERFACE}"
  disk="${NODE_DISKS[$new_ip]:-$DEFAULT_DISK}"

  log_info "Generating configuration for new worker node..."
  talosctl gen config \
    --with-secrets secrets.yaml \
    --kubernetes-version "${KUBERNETES_VERSION}" \
    --talos-version "${TALOS_VERSION}" \
    --install-image "${INSTALLER_IMAGE}" \
    --output-types worker \
    "${CLUSTER_NAME}" "https://${CONTROL_PLANE_ENDPOINT}:6443" >/dev/null

  cat > "patch-worker-${new_ip}.yaml" <<EOF
machine:
  install:
    disk: /dev/${disk}
    extraKernelArgs:
      - console=tty0
      - console=ttyS0
  network:
    interfaces:
      - interface: ${nic}
        dhcp: true
  sysctls:
    vm.nr_hugepages: "1024"
  kernel:
    modules:
      - name: nvme_tcp
      - name: vfio_pci
  kubelet:
    extraArgs:
      rotate-server-certificates: true
    extraMounts:
      - destination: /var/local
        type: bind
        source: /var/local
        options:
          - bind
          - rshared
          - rw
  certSANs:
    - ${$new_ip}
    - ${HAPROXY_IP}
    - ${CONTROL_PLANE_ENDPOINT}
cluster:
  apiServer:
    certSANs:
      - ${$new_ip}
      - ${HAPROXY_IP}
      - ${CONTROL_PLANE_ENDPOINT}
EOF

  cp worker.yaml "node-worker-${new_ip}.yaml"
  talosctl machineconfig patch "node-worker-${new_ip}.yaml" \
    --patch "@patch-worker-${new_ip}.yaml" \
    --output "node-worker-${new_ip}.yaml"

  log_info "Applying configuration to node $new_ip..."
  talosctl apply-config --insecure --nodes "$new_ip" --file "node-worker-${new_ip}.yaml"

  log_info "✓ Worker node $new_ip added"
  rm -f "patch-worker-${new_ip}.yaml"
}

# ==================== BOOTSTRAP FUNCTION ====================
run_bootstrap() {
  # Parse flags
  SKIP_PREFLIGHT=false
  DRY_RUN=false
  for arg in "$@"; do
    [[ "$arg" == "--skip-preflight" ]] && SKIP_PREFLIGHT=true
    [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
  done

  if [ "$DRY_RUN" = true ]; then
    log_warn "Running in DRY-RUN mode - no configurations will be applied to nodes"
  fi

  # Convert to arrays
  IFS=' ' read -r -a CONTROL_PLANE_IPS_ARRAY <<< "$CONTROL_PLANE_IPS"
  IFS=' ' read -r -a WORKER_IPS_ARRAY <<< "$WORKER_IPS"

  if [ "${#CONTROL_PLANE_IPS_ARRAY[@]}" -eq 0 ]; then
    log_error "No control plane IPs defined"
    exit 1
  fi

  # Dependency check
  log_step "Dependency Check"
  for cmd in talosctl kubectl curl; do
    if ! command -v "$cmd" &> /dev/null; then
      log_error "Required command '$cmd' not found in PATH"
      exit 1
    fi
    log_info "✓ $cmd found"
  done

  # Configuration validation
  log_step "Configuration Validation"
  log_info "Control Plane: ${CONTROL_PLANE_IPS_ARRAY[*]}"
  log_info "Workers: ${WORKER_IPS_ARRAY[*]}"
  log_info "HAProxy: $HAPROXY_IP"
  log_info "Endpoint: $CONTROL_PLANE_ENDPOINT"
  log_info "Default NIC: $DEFAULT_NETWORK_INTERFACE"
  log_info "Default Disk: $DEFAULT_DISK"

  # Pre-flight validation
  log_step "Pre-Flight Validation"
  if [ "$SKIP_PREFLIGHT" = false ]; then
    log_info "Testing HAProxy connectivity..."
    timeout 3 bash -c "curl -su admin:talos-lb-admin http://${HAPROXY_IP}:9000" || { log_error "HAProxy unreachable"; exit 1; }
    log_info "✓ HAProxy reachable"

    log_info "Testing node reachability..."
    for ip in "${CONTROL_PLANE_IPS_ARRAY[@]}" "${WORKER_IPS_ARRAY[@]}"; do
      if timeout 3 $PING_CMD "$ip" >/dev/null 2>&1; then
        log_info "✓ $ip reachable"
      else
        log_error "$ip not reachable (use --skip-preflight to skip)"; exit 1;
      fi
    done
  else
    log_warn "Skipping connectivity checks"
  fi

  # Hosts file configuration
  log_step "Configure Hosts File"
  if [ -f "$HOSTS_FILE" ]; then
    if ! grep -q "$CONTROL_PLANE_ENDPOINT" "$HOSTS_FILE" 2>/dev/null; then
      log_info "Adding $CONTROL_PLANE_ENDPOINT to $HOSTS_FILE..."
      echo "${HAPROXY_IP} ${CONTROL_PLANE_ENDPOINT}" | sudo tee -a "$HOSTS_FILE" >/dev/null ||
        log_warn "Could not write to hosts file (permission denied)"
    else
      log_info "$CONTROL_PLANE_ENDPOINT already in hosts file"
    fi
  else
    log_warn "Hosts file not found at $HOSTS_FILE"
  fi

  # Secrets management
  log_step "Secrets Management"
  mkdir -p "$SECRETS_VAULT_DIR"

  if [ -f "secrets.yaml" ]; then
    log_info "Found secrets.yaml in working directory"
    cp secrets.yaml "$SECRETS_VAULT_DIR/secrets-$(date +%Y%m%d_%H%M%S).yaml"
  elif [ -f "$SECRETS_VAULT_DIR/secrets-latest.yaml" ]; then
    log_info "Using secrets from vault..."
    cp "$SECRETS_VAULT_DIR/secrets-latest.yaml" secrets.yaml
  else
    log_info "Generating new secrets.yaml..."
    talosctl gen secrets -o secrets.yaml
    cp secrets.yaml "$SECRETS_VAULT_DIR/secrets-latest.yaml"
    chmod 600 "$SECRETS_VAULT_DIR/secrets-latest.yaml"
  fi

  if [ ! -f "secrets.yaml" ]; then
    log_error "Failed to obtain secrets.yaml"; exit 1
  fi
  log_info "✓ secrets.yaml ready"

  # Backup existing configs
  if [ -f "controlplane.yaml" ]; then
    BACKUP_DIR="talos-backup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp secrets.yaml controlplane.yaml worker.yaml talosconfig "$BACKUP_DIR/" 2>/dev/null || true
    log_info "Backed up existing configs to $BACKUP_DIR"
  fi
  log_info "Cleaning up old configuration files..."
  rm -f controlplane.yaml worker.yaml talosconfig node-*.yaml patch-*.yaml

  # Generate configurations
  log_step "Generate Talos Configurations"
  talosctl gen config \
    --with-secrets secrets.yaml \
    --kubernetes-version "${KUBERNETES_VERSION}" \
    --talos-version "${TALOS_VERSION}" \
    --install-image "${INSTALLER_IMAGE}" \
    "${CLUSTER_NAME}" "https://${CONTROL_PLANE_ENDPOINT}:6443" || {
      log_error "Config generation failed"; exit 1; }

  for file in controlplane.yaml worker.yaml talosconfig; do
    [ -f "$file" ] && log_info "✓ $file" || { log_error "$file missing"; exit 1; }
  done

  # Create per-node configurations
  log_step "Create Per-Node Configurations"

  for ip in "${CONTROL_PLANE_IPS_ARRAY[@]}"; do
    nic="${NODE_INTERFACES[$ip]:-$DEFAULT_NETWORK_INTERFACE}"
    disk="${NODE_DISKS[$ip]:-$DEFAULT_DISK}"

    cat > "patch-cp-${ip}.yaml" <<EOF
machine:
  install:
    disk: /dev/${disk}
    extraKernelArgs:
      - console=tty0
      - console=ttyS0
  network:
    interfaces:
      - interface: ${nic}
        dhcp: true
  sysctls:
    vm.nr_hugepages: "1024"
  kubelet:
    extraArgs:
      rotate-server-certificates: true
  kernel:
    modules:
      - name: nvme_tcp
      - name: vfio_pci
  certSANs:
    - ${ip}
    - ${HAPROXY_IP}
    - ${CONTROL_PLANE_ENDPOINT}
cluster:
  apiServer:
    certSANs:
      - ${ip}
      - ${HAPROXY_IP}
      - ${CONTROL_PLANE_ENDPOINT}
EOF

    cp controlplane.yaml "node-cp-${ip}.yaml"
    talosctl machineconfig patch "node-cp-${ip}.yaml" \
      --patch "@patch-cp-${ip}.yaml" \
      --output "node-cp-${ip}.yaml" || exit 1
  done

  for ip in "${WORKER_IPS_ARRAY[@]}"; do
    nic="${NODE_INTERFACES[$ip]:-$DEFAULT_NETWORK_INTERFACE}"
    disk="${NODE_DISKS[$ip]:-$DEFAULT_DISK}"

    cat > "patch-worker-${ip}.yaml" <<EOF
machine:
  install:
    disk: /dev/${disk}
    extraKernelArgs:
      - console=tty0
      - console=ttyS0
  network:
    interfaces:
      - interface: ${nic}
        dhcp: true
  sysctls:
    vm.nr_hugepages: "1024"
  kernel:
    modules:
      - name: nvme_tcp
      - name: vfio_pci
  kubelet:
    extraArgs:
      rotate-server-certificates: true
    extraMounts:
      - destination: /var/local
        type: bind
        source: /var/local
        options:
          - bind
          - rshared
          - rw
  certSANs:
    - ${ip}
    - ${HAPROXY_IP}
    - ${CONTROL_PLANE_ENDPOINT}
cluster:
  apiServer:
    certSANs:
      - ${ip}
      - ${HAPROXY_IP}
      - ${CONTROL_PLANE_ENDPOINT}
EOF

    cp worker.yaml "node-worker-${ip}.yaml"
    talosctl machineconfig patch "node-worker-${ip}.yaml" \
      --patch "@patch-worker-${ip}.yaml" \
      --output "node-worker-${ip}.yaml" || exit 1
  done

  # Apply cluster patch
  log_step "Apply Cluster Configuration"
  cat > "cluster-patch.yaml" <<'EOF'
cluster:
  allowSchedulingOnControlPlanes: false
  apiServer:
    admissionControl:
      - name: PodSecurity
        configuration:
          apiVersion: pod-security.admission.config.k8s.io/v1
          kind: PodSecurityConfiguration
          exemptions:
            namespaces:
              - longhorn-system
EOF

  for ip in "${CONTROL_PLANE_IPS_ARRAY[@]}"; do
    talosctl machineconfig patch "node-cp-${ip}.yaml" \
      --patch "@cluster-patch.yaml" \
      --output "node-cp-${ip}.yaml" || exit 1
  done

  rm -f cluster-patch.yaml patch-*.yaml

  # Verify configurations
  log_step "Verify Generated Configuration Files"
  for ip in "${CONTROL_PLANE_IPS_ARRAY[@]}"; do
    [ -f "node-cp-${ip}.yaml" ] && log_info "✓ node-cp-${ip}.yaml" || log_warn "Missing node-cp-${ip}.yaml"
  done
  for ip in "${WORKER_IPS_ARRAY[@]}"; do
    [ -f "node-worker-${ip}.yaml" ] && log_info "✓ node-worker-${ip}.yaml" || log_warn "Missing node-worker-${ip}.yaml"
  done

  if [ "$DRY_RUN" = true ]; then
    log_info "DRY-RUN complete - Configuration files generated"
    exit 0
  fi

  # Deployment confirmation
  log_step "Ready to Deploy"
  echo
  echo "Configuration Summary:"
  echo "  Control Plane: ${CONTROL_PLANE_IPS_ARRAY[*]}"
  echo "  Workers: ${WORKER_IPS_ARRAY[*]}"
  echo "  Endpoint: https://${CONTROL_PLANE_ENDPOINT}:6443"
  echo "  HAProxy: ${HAPROXY_IP}"
  echo "  Network: ${DEFAULT_NETWORK_INTERFACE}"
  echo "  Disk: ${DEFAULT_DISK}"
  echo

  read -p "Deploy now? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Cancelled"
    exit 0
  fi

  # Deploy to nodes
  log_step "Deploy to Nodes"

  deploy_config() {
    local node_type="$1"
    local ip="$2"
    local config_file="$3"
    local attempt=0

    while [ $attempt -lt $MAX_RETRIES ]; do
      attempt=$((attempt + 1))
      log_info "Deploy attempt $attempt/$MAX_RETRIES to $node_type $ip..."

      if talosctl apply-config --insecure --nodes "$ip" --file "$config_file"; then
        log_info "✓ $node_type $ip deployed successfully"
        return 0
      fi

      if [ $attempt -lt $MAX_RETRIES ]; then
        log_warn "Attempt $attempt failed, retrying in ${RETRY_DELAY}s..."
        sleep $RETRY_DELAY
      fi
    done

    log_error "Failed to deploy to $node_type $ip after $MAX_RETRIES attempts"
    return 1
  }

  for ip in "${CONTROL_PLANE_IPS_ARRAY[@]}"; do
    deploy_config "control plane" "$ip" "node-cp-${ip}.yaml" || exit 1
  done

  for ip in "${WORKER_IPS_ARRAY[@]}"; do
    deploy_config "worker" "$ip" "node-worker-${ip}.yaml" || exit 1
  done

  # Wait for nodes to restart
  log_step "Wait & Bootstrap"
  log_info "Waiting $NODE_RESTART_WAIT seconds for nodes to restart..."
  sleep $NODE_RESTART_WAIT

  # Configure client access BEFORE bootstrap
  log_step "Configure Client Access"
  log_info "Merging talosconfig..."
  talosctl config merge talosconfig

  # For bootstrap, use the first control plane node directly (not HAProxy)
  log_info "Setting endpoint to first control plane node..."
  talosctl config endpoint "${CONTROL_PLANE_IPS_ARRAY[0]}"

  # Bootstrap the cluster
  if [ "${#CONTROL_PLANE_IPS_ARRAY[@]}" -gt 0 ]; then
    log_info "Bootstrapping cluster using ${CONTROL_PLANE_IPS_ARRAY[0]}..."
    talosctl bootstrap --nodes "${CONTROL_PLANE_IPS_ARRAY[0]}"  || {
      log_error "Bootstrap failed";
      exit 1;
    }
    log_info "✓ Bootstrap command sent successfully"
  fi

  # NOW set the endpoint to HAProxy for ongoing operations
  log_info "Reconfiguring endpoint to HAProxy ($HAPROXY_IP) for client access..."
  talosctl config endpoint "$HAPROXY_IP"

  # Wait for control plane using secure connection (with proper timeout)
  log_info "Waiting for control plane to initialize (this may take several minutes)..."
  if ! talosctl --nodes "${CONTROL_PLANE_IPS_ARRAY[0]}" health --wait-timeout="${BOOTSTRAP_TIMEOUT}s"; then
    log_error "Control plane failed to become ready within $BOOTSTRAP_TIMEOUT seconds"
    exit 1
  fi
  log_info "✓ Control plane is ready"

  # Retrieve kubeconfig
  KUBECONFIG_PATH="$HOME/.kube/config-${CLUSTER_NAME}"
  log_info "Retrieving kubeconfig to $KUBECONFIG_PATH..."
  talosctl kubeconfig "$KUBECONFIG_PATH" --nodes "${CONTROL_PLANE_IPS_ARRAY[0]}"
  chmod 600 "$KUBECONFIG_PATH"
  log_info "✓ Kubeconfig saved and secured"

  # Final verification
  log_step "Final Cluster Verification"
  echo
  echo "To verify your cluster:"
  echo "  export KUBECONFIG=$KUBECONFIG_PATH"
  echo "  kubectl get nodes -o wide"
  echo "  talosctl --endpoints $HAPROXY_IP version"
  echo
  log_info "✓ Bootstrap completed successfully!"
}

# ==================== MODE SELECTOR ====================
MODE="${1:-help}"

case "$MODE" in
  bootstrap)
    shift
    run_bootstrap "$@"
    ;;
  add-cp)
    if [ -z "${2:-}" ]; then
      log_error "Usage: $0 add-cp <NEW_CONTROL_PLANE_IP>"
      exit 1
    fi
    add_control_plane_node "$2"
    ;;
  add-worker)
    if [ -z "${2:-}" ]; then
      log_error "Usage: $0 add-worker <NEW_WORKER_IP>"
      exit 1
    fi
    add_worker_node "$2"
    ;;
  cleanup)
    log_step "Cleanup"
    rm -f node-*.yaml patch-*.yaml controlplane.yaml worker.yaml talosconfig
    log_info "Temporary files removed"
    ;;
  help|--help|-h)
    echo "Usage: $0 [MODE] [OPTIONS]"
    echo
    echo "Modes:"
    echo "  bootstrap    - Full cluster bootstrap"
    echo "  add-cp IP    - Add control plane node to existing cluster"
    echo "  add-worker IP - Add worker node to existing cluster"
    echo "  cleanup      - Remove generated config files"
    echo "  help         - Show this help"
    echo
    echo "Bootstrap Options:"
    echo "  --skip-preflight  - Skip connectivity checks"
    echo "  --dry-run         - Generate configs without deploying"
    echo
    echo "Examples:"
    echo "  $0 bootstrap"
    echo "  $0 bootstrap --dry-run"
    echo "  $0 add-cp 192.168.1.253"
    echo "  $0 add-worker 192.168.1.254"
    ;;
  *)
    log_error "Unknown mode: $MODE"
    echo "Run '$0 help' for usage information"
    exit 1
    ;;
esac