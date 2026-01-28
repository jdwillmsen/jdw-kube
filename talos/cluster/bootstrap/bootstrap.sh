#!/bin/bash
set -euo pipefail

# ==================== DYNAMIC CONFIGURATION ====================
CONTROL_PLANE_IPS=""
WORKER_IPS=""

# Discovery Settings
PROXMOX_SSH_HOST="${PROXMOX_SSH_HOST:-pve1}"
DISCOVER_VM_IDS="${DISCOVER_VM_IDS:-200 300 301}"
USE_DISCOVERY="${USE_DISCOVERY:-false}"
ARP_WAIT_TIME="${ARP_WAIT_TIME:-5}"
POST_DEPLOY_WAIT="${POST_DEPLOY_WAIT:-60}"

# Cluster Settings
CLUSTER_NAME="proxmox-talos-test"
KUBERNETES_VERSION="v1.34.0"
TALOS_VERSION="v1.12.1"
HAPROXY_IP="192.168.1.237"
CONTROL_PLANE_ENDPOINT="$CLUSTER_NAME.jdwkube.com"

# Hardware Settings
DEFAULT_NETWORK_INTERFACE="eth0"
DEFAULT_DISK="sda"
declare -A NODE_INTERFACES=()
declare -A NODE_DISKS=()
declare -A NODE_VMIDS=()

# Talos Factory Image
INSTALLER_IMAGE="factory.talos.dev/nocloud-installer/b553b4a25d76e938fd7a9aaa7f887c06ea4ef75275e64f4630e6f8f739cf07df:${TALOS_VERSION}"

# Performance Settings
MAX_RETRIES=5
RETRY_DELAY=5
PARALLEL_WORKERS=true
NODE_RESTART_WAIT=90
BOOTSTRAP_TIMEOUT=1800
DEPLOY_JOBS=3

# State Management
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/.cluster-state"
STATE_FILE="$STATE_DIR/cluster-state.json"

cd "$SCRIPT_DIR"

# ==================== WINDOWS/GIT BASH COMPATIBILITY ====================
IS_WINDOWS=false
SSH_OPTS=""

if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]] || [[ "$MSYSTEM" == "MINGW"* ]] || [[ -n "${WINDIR:-}" ]]; then
    IS_WINDOWS=true
    SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    log_info() { echo -e "[$(date '+%H:%M:%S')] \033[0;32m[INFO]\033[0m $1"; }
    log_error() { echo -e "[$(date '+%H:%M:%S')] \033[0;31m[ERROR]\033[0m $1"; }
else
    SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPath=~/.ssh/proxmox_mux_%h_%p_%r -o ControlPersist=600"
    log_info() { echo -e "[$(date '+%H:%M:%S')] \033[0;32m[INFO]\033[0m $1"; }
    log_error() { echo -e "[$(date '+%H:%M:%S')] \033[0;31m[ERROR]\033[0m $1"; }
fi

log_step() { echo -e "\n[$(date '+%H:%M:%S')] \033[0;34m[STEP]\033[0m $1"; }
log_warn() { echo -e "[$(date '+%H:%M:%S')] \033[1;33m[WARN]\033[0m $1"; }
log_detail() { echo -e "[$(date '+%H:%M:%S')] \033[0;36m[DETAIL]\033[0m $1"; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && echo -e "[$(date '+%H:%M:%S')] \033[0;35m[DEBUG]\033[0m $1" || true; }

# OS-Specific commands
if [[ "$IS_WINDOWS" == "true" ]]; then
    PING_CMD="ping -n 1 -w 2000"
    HOSTS_FILE="/c/Windows/System32/drivers/etc/hosts"
else
    PING_CMD="ping -c 1 -W 2"
    HOSTS_FILE="/etc/hosts"
fi

# ==================== DATA STRUCTURES (DISCOVERY) ====================
declare -A DISC_VM_MACS=()
declare -A DISC_VM_NAMES=()
declare -A DISC_VM_IPS=()
declare -A DISC_MAC_TO_IP=()
declare -A DISC_VM_ROLES=()
DISC_CONTROL_PLANE_IPS=()
DISC_WORKER_IPS=()

# ==================== UTILITY FUNCTIONS ====================
test_port() {
    local ip=$1
    local port=$2
    timeout 2 bash -c "echo >/dev/tcp/$ip/$port" 2>/dev/null && echo "open" || echo "closed"
}

get_ssh_output() {
    local cmd="$1"
    local stderr_file=$(mktemp)
    local output

    output=$(ssh ${SSH_OPTS} "${PROXMOX_SSH_HOST}" "$cmd" 2>"$stderr_file") || {
        local exit_code=$?
        log_debug "SSH failed ($exit_code): $(cat "$stderr_file")"
        rm -f "$stderr_file"
        return $exit_code
    }
    rm -f "$stderr_file"
    echo "$output"
}

save_state() {
    mkdir -p "$STATE_DIR"
    local cp_ips=""
    local worker_ips=""

    local first=true
    for ip in "${CONTROL_PLANE_IPS_ARRAY[@]}"; do
        [[ "$first" == "true" ]] && first=false || cp_ips+=","
        local vmid="${NODE_VMIDS[$ip]:-unknown}"
        cp_ips+="{\"ip\":\"$ip\",\"vmid\":\"$vmid\"}"
    done

    first=true
    for ip in "${WORKER_IPS_ARRAY[@]}"; do
        [[ "$first" == "true" ]] && first=false || worker_ips+=","
        local vmid="${NODE_VMIDS[$ip]:-unknown}"
        worker_ips+="{\"ip\":\"$ip\",\"vmid\":\"$vmid\"}"
    done

    cat > "$STATE_FILE" <<EOF
{
  "cluster_name": "$CLUSTER_NAME",
  "timestamp": "$(date -Iseconds)",
  "control_planes": [$cp_ips],
  "workers": [$worker_ips]
}
EOF
    log_detail "State saved to $STATE_FILE"
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        log_info "Loading cluster state from $STATE_FILE"
        if command -v jq &>/dev/null; then
            local cp_count=$(jq '.control_planes | length' "$STATE_FILE")
            local worker_count=$(jq '.workers | length' "$STATE_FILE")
            log_info "Previous state: $cp_count control planes, $worker_count workers"
            return 0
        fi
    fi
    return 1
}

# ==================== HAPROXY INTEGRATION ====================
update_haproxy() {
    local ips=("$@")
    if [[ ${#ips[@]} -eq 0 ]]; then
        log_warn "No IPs provided to update_haproxy"
        return 1
    fi

    local haproxy_script="${SCRIPT_DIR}/update-haproxy.sh"

    if [[ -f "$haproxy_script" ]]; then
        log_step "Updating HAProxy configuration with IPs: ${ips[*]}"
        bash "$haproxy_script" "${ips[@]}" || {
            log_error "Failed to update HAProxy"
            log_info "You may need to run manually: ./update-haproxy.sh ${ips[*]}"
            return 1
        }
        log_info "HAProxy updated successfully"
        # Give HAProxy a moment to mark backends up
        sleep 3
    else
        log_warn "HAProxy update script not found at $haproxy_script"
        log_warn "Control plane IPs may have changed - remember to update HAProxy manually!"
        return 1
    fi
}

# ==================== DIAGNOSTIC FUNCTIONS ====================
collect_node_logs() {
    local ip=$1
    log_step "Collecting diagnostic logs from $ip"

    log_info "=== Kernel dmesg from $ip ==="
    talosctl --nodes "$ip" --insecure dmesg 2>/dev/null || log_warn "Failed to get dmesg from $ip"

    log_info "=== Service logs from $ip ==="
    talosctl --nodes "$ip" --insecure logs 2>/dev/null || log_warn "Failed to get logs from $ip"

    log_info "=== Disk usage ==="
    talosctl --nodes "$ip" --insecure df 2>/dev/null || true
}

check_haproxy_status() {
    log_step "Checking HAProxy backend status"

    # Test ports
    log_info "Testing HAProxy connectivity..."
    if timeout 3 bash -c "echo >/dev/tcp/${HAPROXY_IP}/6443" 2>/dev/null; then
        log_info "✓ HAProxy port 6443 (K8s API) is reachable"
    else
        log_warn "✗ HAProxy port 6443 is not reachable"
    fi

    if timeout 3 bash -c "echo >/dev/tcp/${HAPROXY_IP}/50000" 2>/dev/null; then
        log_info "✓ HAProxy port 50000 (Talos API) is reachable"
    else
        log_warn "✗ HAProxy port 50000 is not reachable"
    fi

    # Check HAProxy stats via SSH if possible
    ssh ${SSH_OPTS} "jake@${HAPROXY_IP}" "echo 'show stat' | sudo nc -U /run/haproxy/admin.sock | grep -E '(k8s-controlplane|talos-controlplane)'" 2>/dev/null || \
        log_warn "Could not retrieve HAProxy backend status"
}

# ==================== DISCOVERY ENGINE ====================
discover_proxmox_nodes() {
    local mode="${1:-initial}"
    log_step "Discovering nodes from Proxmox (VMs: $DISCOVER_VM_IDS) [mode: $mode]"

    local vmid_array=($DISCOVER_VM_IDS)
    local cp_vms=" 200 201 "
    local worker_vms=" 300 301 302 "

    # Clear previous discovery data if post-deploy
    if [[ "$mode" == "post-deploy" ]]; then
        DISC_VM_MACS=()
        DISC_VM_NAMES=()
        DISC_VM_IPS=()
        DISC_MAC_TO_IP=()
        DISC_VM_ROLES=()
        DISC_CONTROL_PLANE_IPS=()
        DISC_WORKER_IPS=()
    fi

    log_info "Fetching VM configurations from $PROXMOX_SSH_HOST..."
    for vmid in "${vmid_array[@]}"; do
        local config
        config=$(get_ssh_output "qm config $vmid") || {
            log_warn "VM $vmid not found or not accessible"
            continue
        }

        local name=$(echo "$config" | grep '^name:' | cut -d' ' -f2-)
        local macs=$(echo "$config" | grep -E '^net[0-9]+:' | grep -oE '[a-fA-F0-9]{2}:[a-fA-F0-9]{2}:[a-fA-F0-9]{2}:[a-fA-F0-9]{2}:[a-fA-F0-9]{2}:[a-fA-F0-9]{2}' | head -1 | tr '[:upper:]' '[:lower:]')

        if [[ -n "$macs" ]]; then
            DISC_VM_MACS[$vmid]="$macs"
            DISC_VM_NAMES[$vmid]="$name"

            if [[ "$cp_vms" == *" $vmid "* ]]; then
                DISC_VM_ROLES[$vmid]="control-plane"
            else
                DISC_VM_ROLES[$vmid]="worker"
            fi
            log_detail "VM $vmid ($name): MAC=$macs, Role=${DISC_VM_ROLES[$vmid]}"
        fi
    done

    if [[ ${#DISC_VM_MACS[@]} -eq 0 ]]; then
        log_error "No VMs discovered"
        return 1
    fi

    log_info "Populating ARP table..."
    local subnet="192.168.1"
    get_ssh_output "
        for i in {1..254}; do
            ping -c 1 -W 1 ${subnet}.\$i >/dev/null 2>&1 &
            if (( i % 30 == 0 )); then
                wait
            fi
        done
        wait
        echo 'ARP_DISCOVERY_COMPLETE'
    " || true

    log_detail "Waiting ${ARP_WAIT_TIME}s for ARP table to settle..."
    sleep "$ARP_WAIT_TIME"

    local arp_retries=3
    local arp_output=""

    while [[ $arp_retries -gt 0 ]]; do
        arp_output=$(get_ssh_output "cat /proc/net/arp") && break
        ((arp_retries--))
        sleep 2
    done

    if [[ -z "$arp_output" ]]; then
        log_error "Failed to get ARP table after retries"
        return 1
    fi

    DISC_MAC_TO_IP=()
    while read -r ip_addr _ _ mac_addr _ _; do
        [[ -z "$ip_addr" || "$ip_addr" == "IP" ]] && continue
        mac_addr=$(echo "$mac_addr" | tr '[:upper:]' '[:lower:]')
        [[ "$mac_addr" == "00:00:00:00:00:00" ]] && continue
        [[ -n "$mac_addr" ]] && DISC_MAC_TO_IP[$mac_addr]="$ip_addr"
    done <<< "$arp_output"

    log_info "ARP table has ${#DISC_MAC_TO_IP[@]} entries"

    local missing_vms=()

    for vmid in "${!DISC_VM_MACS[@]}"; do
        local mac="${DISC_VM_MACS[$vmid]}"
        local ip="${DISC_MAC_TO_IP[$mac]:-}"
        local role="${DISC_VM_ROLES[$vmid]}"
        local name="${DISC_VM_NAMES[$vmid]}"

        if [[ -n "$ip" ]]; then
            if [[ "$(test_port "$ip" 50000)" == "open" ]]; then
                DISC_VM_IPS[$vmid]="$ip"
                NODE_VMIDS[$ip]="$vmid"

                if [[ "$role" == "control-plane" ]]; then
                    DISC_CONTROL_PLANE_IPS+=("$ip")
                else
                    DISC_WORKER_IPS+=("$ip")
                fi
                log_info "Discovered $role: $name (VM $vmid) -> $ip"
            else
                log_warn "VM $vmid ($name) at $ip: Talos API (port 50000) not yet ready"
                missing_vms+=("$vmid")
            fi
        else
            log_warn "VM $vmid ($name): MAC $mac not in ARP table (VM/booting?)"
            missing_vms+=("$vmid")
        fi
    done

    # Retry for missing VMs
    if [[ ${#missing_vms[@]} -gt 0 ]]; then
        log_info "Retrying ARP discovery for ${#missing_vms[@]} missing VMs in 10 seconds..."
        sleep 10

        get_ssh_output "cat /proc/net/arp" > /tmp/arp_new.txt 2>/dev/null || true
        while read -r ip_addr _ _ mac_addr _ _; do
            [[ -z "$ip_addr" || "$ip_addr" == "IP" ]] && continue
            mac_addr=$(echo "$mac_addr" | tr '[:upper:]' '[:lower:]')
            [[ "$mac_addr" != "00:00:00:00:00:00" ]] && DISC_MAC_TO_IP[$mac_addr]="$ip_addr"
        done < /tmp/arp_new.txt
        rm -f /tmp/arp_new.txt

        for vmid in "${missing_vms[@]}"; do
            local mac="${DISC_VM_MACS[$vmid]}"
            local ip="${DISC_MAC_TO_IP[$mac]:-}"
            if [[ -n "$ip" && "$(test_port "$ip" 50000)" == "open" ]]; then
                local role="${DISC_VM_ROLES[$vmid]}"
                DISC_VM_IPS[$vmid]="$ip"
                NODE_VMIDS[$ip]="$vmid"
                if [[ "$role" == "control-plane" ]]; then
                    DISC_CONTROL_PLANE_IPS+=("$ip")
                else
                    DISC_WORKER_IPS+=("$ip")
                fi
                log_info "Discovered on retry $role: ${DISC_VM_NAMES[$vmid]} -> $ip"
            fi
        done
    fi

    if [[ "$mode" == "initial" ]]; then
        CONTROL_PLANE_IPS="${DISC_CONTROL_PLANE_IPS[*]:-}"
        WORKER_IPS="${DISC_WORKER_IPS[*]:-}"
    else
        WORKER_IPS="${DISC_WORKER_IPS[*]:-}"
        CONTROL_PLANE_IPS="${DISC_CONTROL_PLANE_IPS[*]:-}"
    fi

    log_info "Discovered ${#DISC_CONTROL_PLANE_IPS[@]} control plane nodes, ${#DISC_WORKER_IPS[@]} workers"

    if [[ ${#DISC_CONTROL_PLANE_IPS[@]} -eq 0 ]]; then
        log_error "Discovery found no responsive control plane nodes"
        return 1
    fi

    return 0
}

# ==================== DEPLOYMENT FUNCTIONS ====================
deploy_node() {
    local node_type=$1
    local ip=$2
    local config_file=$3
    local vmid="${NODE_VMIDS[$ip]:-}"
    local max_attempts=$MAX_RETRIES
    local attempt=1

    log_info "[$ip] Starting deployment (VM ${vmid:-unknown})..."

    while [[ $attempt -le $max_attempts ]]; do
        log_detail "[$ip] Attempt $attempt/$max_attempts"

        if talosctl apply-config --insecure --nodes "$ip" --file "$config_file" 2>&1; then
            log_info "[$ip] ✓ Configuration applied successfully"
            echo "SUCCESS:$ip:$(date +%s)" >> "$STATE_DIR/deploy-results.log"
            return 0
        else
            local delay=$((RETRY_DELAY * attempt))
            log_warn "[$ip] Attempt $attempt failed, waiting ${delay}s..."
            sleep $delay
        fi
        ((attempt++))
    done

    log_error "[$ip] ✗ Failed after $max_attempts attempts"
    echo "FAILED:$ip:$(date +%s)" >> "$STATE_DIR/deploy-results.log"
    return 1
}

deploy_control_planes() {
    local -n cp_ips=$1
    log_step "Deploying Control Planes (${#cp_ips[@]} nodes)"

    for ip in "${cp_ips[@]}"; do
        deploy_node "control-plane" "$ip" "node-cp-${ip}.yaml" || return 1
    done

    log_info "Control plane deployment complete"
}

deploy_workers_sequential() {
    local -n worker_ips=$1
    log_step "Deploying Workers (${#worker_ips[@]} nodes, sequential)"

    for ip in "${worker_ips[@]}"; do
        deploy_node "worker" "$ip" "node-worker-${ip}.yaml" || log_warn "Worker $ip failed deployment"
    done
}

deploy_workers_parallel() {
    local -n worker_ips=$1
    local total=${#worker_ips[@]}
    log_step "Deploying Workers ($total nodes, max $DEPLOY_JOBS parallel)"

    > "$STATE_DIR/deploy-results.log"
    mkdir -p "$STATE_DIR/pids"

    local pids=()

    for ip in "${worker_ips[@]}"; do
        deploy_node "worker" "$ip" "node-worker-${ip}.yaml" &
        local pid=$!
        pids+=("$pid")
        echo "$pid:$ip" >> "$STATE_DIR/pids/workers.pids"

        if [[ ${#pids[@]} -ge $DEPLOY_JOBS ]]; then
            wait -n ${pids[@]} 2>/dev/null || true
            local new_pids=()
            for p in "${pids[@]}"; do
                if kill -0 "$p" 2>/dev/null; then
                    new_pids+=("$p")
                fi
            done
            pids=("${new_pids[@]}")
        fi
    done

    if [[ ${#pids[@]} -gt 0 ]]; then
        wait ${pids[@]} 2>/dev/null || true
    fi

    log_info "Worker deployment jobs completed"

    local success_count=0
    local failed_count=0

    if [[ -f "$STATE_DIR/deploy-results.log" ]]; then
        success_count=$(grep "^SUCCESS:" "$STATE_DIR/deploy-results.log" 2>/dev/null | wc -l | tr -d ' ')
        failed_count=$(grep "^FAILED:" "$STATE_DIR/deploy-results.log" 2>/dev/null | wc -l | tr -d ' ')

        success_count=$(echo "$success_count" | tr -d '\n\r ')
        failed_count=$(echo "$failed_count" | tr -d '\n\r ')

        [[ -z "$success_count" ]] && success_count=0
        [[ -z "$failed_count" ]] && failed_count=0
    fi

    log_info "Results: $success_count succeeded, $failed_count failed (total: $total)"

    if [[ "$failed_count" -gt 0 ]]; then
        log_warn "Failed deployments detected."
        return 1
    fi

    return 0
}

wait_for_talos_api() {
    local ip=$1
    local timeout=${2:-300}
    local start_time=$(date +%s)

    log_info "[$ip] Waiting for Talos API to become available (timeout: ${timeout}s)..."

    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        if [[ $elapsed -gt $timeout ]]; then
            log_error "[$ip] Timeout waiting for Talos API ($elapsed seconds)"
            return 1
        fi

        if [[ "$(test_port "$ip" 50000)" == "open" ]]; then
            log_info "[$ip] ✓ Talos API is ready (${elapsed}s)"
            return 0
        fi

        log_detail "[$ip] Waiting for API... (${elapsed}s elapsed)"
        sleep 5
    done
}

# ==================== CONFIGURATION GENERATION ====================
generate_patches() {
    log_step "Generating Configuration Patches"

    for ip in "${CONTROL_PLANE_IPS_ARRAY[@]}"; do
        local vmid="${NODE_VMIDS[$ip]:-}"
        local nic="${NODE_INTERFACES[$ip]:-$DEFAULT_NETWORK_INTERFACE}"
        local disk="${NODE_DISKS[$ip]:-$DEFAULT_DISK}"

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
            --output "node-cp-${ip}.yaml"
        log_detail "Generated control plane config for $ip (VM $vmid)"
    done

    for ip in "${WORKER_IPS_ARRAY[@]}"; do
        local vmid="${NODE_VMIDS[$ip]:-}"
        local nic="${NODE_INTERFACES[$ip]:-$DEFAULT_NETWORK_INTERFACE}"
        local disk="${NODE_DISKS[$ip]:-$DEFAULT_DISK}"

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
            --output "node-worker-${ip}.yaml"
        log_detail "Generated worker config for $ip (VM $vmid)"
    done

    rm -f patch-*.yaml
}

# ==================== MAIN BOOTSTRAP ====================
run_bootstrap() {
    local SKIP_PREFLIGHT=false
    local DISCOVER_MODE=false
    local DRY_RUN=false

    for arg in "$@"; do
        case "$arg" in
            --skip-preflight) SKIP_PREFLIGHT=true ;;
            --discover) DISCOVER_MODE=true ;;
            --dry-run) DRY_RUN=true ;;
        esac
    done

    # Initial discovery
    if [[ "$DISCOVER_MODE" == "true" ]] || [[ "$USE_DISCOVERY" == "true" && -z "$CONTROL_PLANE_IPS" ]]; then
        log_step "Auto-Discovery Mode (Initial)"
        discover_proxmox_nodes "initial" || {
            log_error "Discovery failed. Try again in 30 seconds if VMs just started."
            exit 1
        }
    fi

    if [[ -z "$CONTROL_PLANE_IPS" ]]; then
        log_error "No control plane IPs defined (use --discover or set CONTROL_PLANE_IPS)"
        exit 1
    fi

    IFS=' ' read -r -a CONTROL_PLANE_IPS_ARRAY <<< "$CONTROL_PLANE_IPS"
    IFS=' ' read -r -a WORKER_IPS_ARRAY <<< "$WORKER_IPS"

    log_step "Bootstrap Configuration"
    log_info "Control Planes: ${CONTROL_PLANE_IPS_ARRAY[*]}"
    log_info "Workers: ${WORKER_IPS_ARRAY[*]}"
    log_info "HAProxy: $HAPROXY_IP"
    log_info "Platform: $([[ "$IS_WINDOWS" == "true" ]] && echo "Windows/Git Bash" || echo "Unix/Linux")"

    if [[ "$SKIP_PREFLIGHT" == "false" ]]; then
        log_step "Pre-flight Checks"
        for cmd in talosctl kubectl curl ssh; do
            command -v "$cmd" &>/dev/null || { log_error "$cmd not found"; exit 1; }
        done

        if ! curl -s -o /dev/null "http://${HAPROXY_IP}:9000"; then
            log_warn "HAProxy stats not responding (continuing anyway)"
        else
            log_info "HAProxy responsive"
        fi

        for ip in "${CONTROL_PLANE_IPS_ARRAY[@]}" "${WORKER_IPS_ARRAY[@]}"; do
            if $PING_CMD "$ip" >/dev/null 2>&1; then
                log_info "✓ $ip reachable"
            else
                log_error "✗ $ip unreachable"
                exit 1
            fi
        done
    fi

    log_step "Secrets Management"
    mkdir -p "$STATE_DIR"

    if [[ ! -f "secrets.yaml" ]]; then
        log_info "Generating new secrets..."
        talosctl gen secrets -o secrets.yaml
        chmod 600 secrets.yaml
        cp secrets.yaml "$STATE_DIR/secrets-$(date +%Y%m%d_%H%M%S).yaml"
    else
        log_info "Using existing secrets.yaml"
    fi

    log_step "Generating Talos Configurations"
    rm -f node-*.yaml controlplane.yaml worker.yaml talosconfig 2>/dev/null || true

    talosctl gen config \
        --with-secrets secrets.yaml \
        --kubernetes-version "$KUBERNETES_VERSION" \
        --talos-version "$TALOS_VERSION" \
        --install-image "$INSTALLER_IMAGE" \
        "$CLUSTER_NAME" "https://${CONTROL_PLANE_ENDPOINT}:6443" &>/dev/null

    generate_patches

    log_step "Applying Common Cluster Settings"
    cat > "cluster-patch.yaml" <<'EOF'
cluster:
  extraManifests:
    - https://raw.githubusercontent.com/alex1989hu/kubelet-serving-cert-approver/main/deploy/standalone-install.yaml
    - https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
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
            --output "node-cp-${ip}.yaml"
    done
    rm -f cluster-patch.yaml

    log_step "Preparing StaticHostConfig"
    cat > "statichost-config.yaml" <<EOF
apiVersion: v1alpha1
kind: StaticHostConfig
name: ${HAPROXY_IP}
hostnames:
  - ${CONTROL_PLANE_ENDPOINT}
EOF

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY-RUN: Configuration files generated:"
        ls -la node-*.yaml statichost-config.yaml
        save_state
        exit 0
    fi

    log_step "Ready to Deploy"
    echo
    echo "Summary:"
    echo "  Control Planes: ${#CONTROL_PLANE_IPS_ARRAY[@]} nodes (DHCP - will re-discover after reboot)"
    echo "  Workers: ${#WORKER_IPS_ARRAY[@]} nodes (DHCP - will re-discover after reboot)"
    echo "  Parallel Workers: $([[ "$PARALLEL_WORKERS" == "true" ]] && echo "Yes (max $DEPLOY_JOBS)" || echo "No")"
    echo
    read -p "Proceed with deployment? (y/N) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || { log_info "Cancelled"; exit 0; }

    > "$STATE_DIR/deploy-results.log"

    log_step "Applying StaticHostConfig (DNS resolution)"
    for ip in "${CONTROL_PLANE_IPS_ARRAY[@]}" "${WORKER_IPS_ARRAY[@]}"; do
        talosctl apply-config --insecure --nodes "$ip" --file "statichost-config.yaml" 2>/dev/null || \
            log_warn "Failed to apply StaticHostConfig to $ip (might already be configured)"
    done
    rm -f statichost-config.yaml

    deploy_control_planes CONTROL_PLANE_IPS_ARRAY || {
        log_error "Control plane deployment failed"
        exit 1
    }

    if [[ ${#WORKER_IPS_ARRAY[@]} -gt 0 ]]; then
        if [[ "$PARALLEL_WORKERS" == "true" ]]; then
            deploy_workers_parallel WORKER_IPS_ARRAY || log_warn "Some workers may have failed - check logs"
        else
            deploy_workers_sequential WORKER_IPS_ARRAY
        fi
    fi

    log_step "Waiting for nodes to restart (${POST_DEPLOY_WAIT}s)..."
    sleep "$POST_DEPLOY_WAIT"

    log_step "Re-discovering nodes after reboot (DHCP IPs may have changed)..."
    if ! discover_proxmox_nodes "post-deploy"; then
        log_warn "Re-discovery had issues, continuing with known IPs..."
    fi

    IFS=' ' read -r -a CONTROL_PLANE_IPS_ARRAY <<< "$CONTROL_PLANE_IPS"
    IFS=' ' read -r -a WORKER_IPS_ARRAY <<< "$WORKER_IPS"

    log_info "Post-reboot IPs:"
    log_info "  Control Planes: ${CONTROL_PLANE_IPS_ARRAY[*]}"
    log_info "  Workers: ${WORKER_IPS_ARRAY[*]:-<none>}"

    if [[ ${#CONTROL_PLANE_IPS_ARRAY[@]} -gt 0 ]]; then
        update_haproxy "${CONTROL_PLANE_IPS_ARRAY[@]}" || {
            log_warn "HAProxy update failed - cluster may not be accessible via VIP"
        }
    fi

    check_haproxy_status

    local bootstrap_node="${CONTROL_PLANE_IPS_ARRAY[0]}"
    log_info "Using control plane node $bootstrap_node for bootstrap..."

    if ! wait_for_talos_api "$bootstrap_node" 300; then
        log_error "Control plane API never became available at $bootstrap_node"
        collect_node_logs "$bootstrap_node"
        log_info "Troubleshooting steps:"
        log_info "  1. Check VM console in Proxmox for VM ${NODE_VMIDS[$bootstrap_node]:-unknown}"
        log_info "  2. Verify DHCP lease in router for MAC ${DISC_VM_MACS[${NODE_VMIDS[$bootstrap_node]}]:-unknown}"
        log_info "  3. Run: talosctl --nodes $bootstrap_node --insecure dashboard"
        exit 1
    fi

    log_step "Configuring Talos Client"
    talosctl config merge talosconfig
    talosctl config endpoint "$bootstrap_node"

    log_step "Bootstrapping Cluster (etcd)"
    talosctl bootstrap --nodes "$bootstrap_node"

    log_step "Waiting for Cluster Health"
    if ! talosctl --endpoints "$bootstrap_node" --nodes "$bootstrap_node" health --wait-timeout="${BOOTSTRAP_TIMEOUT}s"; then
        log_error "Cluster failed to become healthy within timeout"
        collect_node_logs "$bootstrap_node"
        check_haproxy_status
        exit 1
    fi

    log_step "Switching to HAProxy Endpoint"
    talosctl config endpoint "$HAPROXY_IP"

    if ! talosctl --endpoints "$HAPROXY_IP" --nodes "$HAPROXY_IP" health --wait-timeout=60s; then
        log_warn "Cluster healthy via direct IP but not via HAProxy - check backend configuration"
        check_haproxy_status
    else
        log_info "✓ Cluster accessible via HAProxy ($HAPROXY_IP)"
    fi

    KUBECONFIG_PATH="${HOME}/.kube/config-${CLUSTER_NAME}"
    mkdir -p "$(dirname "$KUBECONFIG_PATH")"
    talosctl kubeconfig "$KUBECONFIG_PATH" --nodes "$bootstrap_node"
    chmod 600 "$KUBECONFIG_PATH"

    save_state

    log_step "Bootstrap Complete"
    log_info "Kubeconfig: export KUBECONFIG=$KUBECONFIG_PATH"
    log_info "Talos Endpoint: talosctl --endpoints $HAPROXY_IP version"
    log_info "Dashboard: talosctl --endpoints $HAPROXY_IP dashboard"
}

# ==================== OTHER COMMANDS ====================
cmd_discover() {
    log_step "Running Discovery Only"
    discover_proxmox_nodes "initial"
    echo
    echo "Results:"
    echo "CONTROL_PLANE_IPS=\"${CONTROL_PLANE_IPS}\""
    echo "WORKER_IPS=\"${WORKER_IPS}\""
}

cmd_status() {
    load_state 2>/dev/null || {
        log_error "No state file found at $STATE_FILE"
        exit 1
    }

    if command -v jq &>/dev/null; then
        echo "State: $STATE_FILE"
        jq '.timestamp' "$STATE_FILE"
        echo "Control Planes:"
        jq -r '.control_planes[] | "  \(.ip) (VM \(.vmid))"' "$STATE_FILE"
        echo "Workers:"
        jq -r '.workers[] | "  \(.ip) (VM \(.vmid))"' "$STATE_FILE"
    else
        cat "$STATE_FILE"
    fi
}

cmd_logs() {
    if ! load_state 2>/dev/null; then
        log_error "No state file found. Run bootstrap first or provide IP argument."
        exit 1
    fi

    log_step "Collecting logs from all cluster nodes"

    local cp_ips=$(jq -r '.control_planes[].ip' "$STATE_FILE" 2>/dev/null)
    local worker_ips=$(jq -r '.workers[].ip' "$STATE_FILE" 2>/dev/null)

    for ip in $cp_ips $worker_ips; do
        collect_node_logs "$ip"
    done

    check_haproxy_status
}

MODE="${1:-help}"

case "$MODE" in
    bootstrap)
        shift
        run_bootstrap "$@"
        ;;
    discover)
        cmd_discover
        ;;
    status)
        cmd_status
        ;;
    logs)
        cmd_logs
        ;;
    cleanup)
        log_step "Cleaning up generated files"
        rm -frv node-*.yaml patch-*.yaml controlplane.yaml worker.yaml talosconfig statichost-config.yaml secrets.yaml .cluster-state
        log_info "Cleanup complete"
        ;;
    reset)
        log_step "Full reset"
        read -p "Delete all configs, state, and secrets? (yes/no): " confirm
        [[ "$confirm" == "yes" ]] || { log_info "Cancelled"; exit 0; }
        rm -rf .cluster-state/ backup/ secrets.yaml node-*.yaml *.yaml
        log_info "Reset complete"
        ;;
    help|--help|-h|*)
        echo "Usage: $0 {bootstrap|discover|status|logs|cleanup} [--discover|--dry-run|--skip-preflight]"
        echo ""
        echo "Commands:"
        echo "  bootstrap    Run the full bootstrap process"
        echo "  discover     Only run node discovery"
        echo "  status       Show saved cluster state"
        echo "  logs         Collect diagnostic logs from all nodes"
        echo "  cleanup      Remove generated configuration files"
        echo "  reset        Full reset (delete secrets and state)"
        ;;
esac