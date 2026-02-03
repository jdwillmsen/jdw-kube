#!/bin/bash
set -euo pipefail

# ==================== IMPROVED DIRECTORY STRUCTURE ====================
# Directory layout:
# bootstrap/
# ├── bootstrap.sh
# ├── lib/                    # (optional future: modular functions)
# ├── clusters/
# │   └── proxmox-talos-test/ # $CLUSTER_NAME
# │       ├── nodes/          # Generated node configs (gitignored)
# │       ├── secrets/        # Sensitive files (gitignored)
# │       ├── state/          # Runtime state (gitignored)
# │       └── patches/        # Your custom patches (optional, tracked)
# └── logs/                   # Global logs (gitignored)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="proxmox-talos-test"

# Base directories - organized by cluster
CLUSTER_DIR="${SCRIPT_DIR}/clusters/${CLUSTER_NAME}"
NODES_DIR="${CLUSTER_DIR}/nodes"
SECRETS_DIR="${CLUSTER_DIR}/secrets"
STATE_DIR="${CLUSTER_DIR}/state"
PATCH_DIR="${CLUSTER_DIR}/patches"
LOG_DIR="${SCRIPT_DIR}/logs"

# Specific files
STATE_FILE="${STATE_DIR}/cluster-state.json"
SECRETS_FILE="${SECRETS_DIR}/secrets.yaml"
TALOSCONFIG="${SECRETS_DIR}/talosconfig"

# ==================== SCRIPT METADATA ====================
LOG_TIMESTAMP_FORMAT="+%Y-%m-%d %H:%M:%S"
LOG_FILE=""
VERSION="1.1.0"

# Discovery Settings
CONTROL_PLANE_IPS=""
WORKER_IPS=""
PROXMOX_SSH_HOST="${PROXMOX_SSH_HOST:-pve1}"
DISCOVER_VM_IDS="${DISCOVER_VM_IDS:-201 302}"
USE_DISCOVERY="${USE_DISCOVERY:-false}"
ARP_WAIT_TIME="${ARP_WAIT_TIME:-5}"
POST_DEPLOY_WAIT="${POST_DEPLOY_WAIT:-90}"

# Cluster Settings
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
NODE_RESTART_WAIT=120
BOOTSTRAP_TIMEOUT=1800
DEPLOY_JOBS=3
API_READY_WAIT=180

# State Management
declare -A DISC_VM_MACS=()
declare -A DISC_VM_NAMES=()
declare -A DISC_VM_IPS=()
declare -A DISC_MAC_TO_IP=()
declare -A DISC_VM_ROLES=()
DISC_CONTROL_PLANE_IPS=()
DISC_WORKER_IPS=()
ORIGINAL_CONTROL_PLANE_IPS=""
ORIGINAL_WORKER_IPS=""

# Color codes
C_RESET='\033[0m'
C_TIMESTAMP='\033[0;90m'     # Gray
C_INFO='\033[0;32m'          # Green
C_ERROR='\033[0;31m'         # Red
C_WARN='\033[1;33m'          # Yellow bold
C_STEP='\033[0;34m'          # Blue
C_DETAIL='\033[0;36m'        # Cyan
C_DEBUG='\033[0;35m'         # Magenta
C_WHITE='\033[0;97m'         # Bright white (for messages)
C_BOLD='\033[1m'             # Bold modifier

# platform detection
IS_WINDOWS=false
SSH_OPTS=""
PING_CMD=""
HOSTS_FILE=""

# ==================== BANNER ====================
print_banner() {
    local border="${C_STEP}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"

    echo -e "$border"
    echo -e "${C_WHITE}  ▄▄▄█████▓ ▄▄▄       ██▓      ▒█████    ██████ ${C_RESET}"
    echo -e "${C_WHITE}  ▓  ██▒ ▓▒▒████▄    ▓██▒     ▒██▓  ██▒▒██    ▒ ${C_RESET}"
    echo -e "${C_WHITE}  ▒ ▓██░ ▒░▒██  ▀█▄  ▒██░     ▒██▒  ██░░ ▓██▄   ${C_RESET}"
    echo -e "${C_WHITE}  ░ ▓██▓ ░ ░██▄▄▄▄██ ▒██░     ░██  █▀ ░  ▒   ██▒${C_RESET}"
    echo -e "${C_WHITE}    ▒██▒ ░  ▓█   ▓██▒░██████▒░▒███▒█▄ ▒██████▒▒${C_RESET}"
    echo -e "${C_WHITE}    ▒ ░░    ▒▒   ▓▒█░░ ▒░▓  ░░░ ▒▒░ ▒ ▒ ▒▓▒ ▒ ░${C_RESET}"
    echo -e "${C_DETAIL}         BOOTSTRAP UTILITY v${VERSION}${C_RESET}"
    echo -e "$border"
    echo ""

    if [[ -n "${LOG_FILE:-}" && -f "$LOG_FILE" ]]; then
        {
            echo "========================================================="
            echo "   TALOS BOOTSTRAP UTILITY v${VERSION}"
            echo "   Cluster: ${CLUSTER_NAME:-unknown}"
            echo "========================================================="
        } >> "$LOG_FILE"
    fi
}

# ==================== INITIALIZATION ====================
init_directories() {
    # Create all required directories
    mkdir -p "$NODES_DIR" "$SECRETS_DIR" "$STATE_DIR" "$PATCH_DIR" "$LOG_DIR"

    # Create .gitignore for sensitive directories
    if [[ ! -f "${CLUSTER_DIR}/.gitignore" ]]; then
        cat > "${CLUSTER_DIR}/.gitignore" <<'EOF'
# Generated configs - sensitive or ephemeral
/nodes/
/secrets/
/state/
/*.log
EOF
    fi

    _log_file "INIT" "Directories initialized: nodes=${NODES_DIR}, secrets=${SECRETS_DIR}, state=${STATE_DIR}"
}

# ==================== LOGGING CORE ====================
init_logging() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/bootstrap-$(date +%Y%m%d_%H%M%S).log"
    touch "$LOG_FILE"

    {
        echo "========================================"
        echo "Talos Bootstrap Log Started: $(date)"
        echo "Script: $0"
        echo "User: $(whoami)"
        echo "Working Directory: $SCRIPT_DIR"
        echo "Hostname: ${HOSTNAME:-$(hostname)}"
        echo "========================================"
    } >> "$LOG_FILE"

    print_banner

    log_info "Logging initialized: $LOG_FILE"
}

_log_file() {
    local level="$1"
    local message="$2"
    echo "[$(date "$LOG_TIMESTAMP_FORMAT")] [$level] $message" >> "$LOG_FILE"
}

_log() {
    local level="$1"
    local color="$2"
    local msg="$3"
    local time_str=$(date '+%H:%M:%S')

    echo -e "${C_TIMESTAMP}[${time_str}]${C_RESET} ${color}[${level}]${C_RESET} ${msg}${C_RESET}"

    echo "[$(date "$LOG_TIMESTAMP_FORMAT")] [$level] $msg" >> "$LOG_FILE"
}

log_info()  { _log "INFO"  "$C_INFO"  "$1"; }
log_error() { _log "ERROR" "$C_ERROR" "$1" >&2; }
log_warn()  { _log "WARN"  "$C_WARN"  "$1"; }
log_step()  { _log "STEP"  "$C_STEP"  "$1"; }
log_detail(){ _log "DETAIL" "$C_DETAIL" "$1"; }

log_debug() {
    local msg="$1"
    if [[ "${DEBUG:-0}" == "1" ]]; then
        _log "DEBUG" "$C_DEBUG" "$msg"
    else
        _log_file "DEBUG" "$msg"
    fi
}

run_cmd() {
    local description="$1"
    shift
    local cmd_display="$*"

    log_detail "Executing: $description"
    _log_file "EXEC" "$cmd_display"

    local stdout_file=$(mktemp)
    local stderr_file=$(mktemp)
    local exit_code=0

    if ! "$@" > "$stdout_file" 2> "$stderr_file"; then
        exit_code=$?
    fi

    if [[ -s "$stdout_file" ]]; then
        _log_file "STDOUT" "--- Output: $description ---"
        cat "$stdout_file" >> "$LOG_FILE"
    fi
    if [[ -s "$stderr_file" ]]; then
        _log_file "STDERR" "--- Errors: $description ---"
        cat "$stderr_file" >> "$LOG_FILE"
    fi

    rm -f "$stdout_file" "$stderr_file"

    if [[ $exit_code -eq 0 ]]; then
        _log_file "SUCCESS" "$description completed"
        return 0
    else
        _log_file "FAILED" "$description exited with code $exit_code"
        log_error "$description failed (exit $exit_code)"
        return $exit_code
    fi
}

# ==================== UTILITY FUNCTIONS ====================
test_port() {
    local ip=$1
    local port=$2
    local result="closed"
    if timeout 2 bash -c "echo >/dev/tcp/$ip/$port" 2>/dev/null; then
        result="open"
    fi
    _log_file "PORT-CHECK" "$ip:$port is $result"
    echo "$result"
}

get_ssh_output() {
    local cmd="$1"
    local output
    local exit_code=0

    _log_file "SSH" "Executing on ${PROXMOX_SSH_HOST}: $cmd"

    output=$(ssh ${SSH_OPTS} "${PROXMOX_SSH_HOST}" "$cmd" 2>> "$LOG_FILE") || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log_debug "SSH command failed with exit code $exit_code"
        return $exit_code
    fi

    _log_file "SSH-OUTPUT" "Received ${#output} bytes"
    echo "$output"
}

# ==================== IMPROVED STATE MANAGEMENT ====================
save_state() {
    mkdir -p "$STATE_DIR"

    # Use jq for proper JSON construction (handles escaping, valid JSON)
    local timestamp
    timestamp=$(date -Iseconds)

    # Build control planes array using jq
    local cp_json='[]'
    for ip in "${CONTROL_PLANE_IPS_ARRAY[@]}"; do
        local vmid="${NODE_VMIDS[$ip]:-unknown}"
        cp_json=$(echo "$cp_json" | jq \
            --arg ip "$ip" \
            --arg vmid "$vmid" \
            '. += [{"ip": $ip, "vmid": $vmid}]')
    done

    # Build workers array using jq
    local worker_json='[]'
    for ip in "${WORKER_IPS_ARRAY[@]}"; do
        local vmid="${NODE_VMIDS[$ip]:-unknown}"
        worker_json=$(echo "$worker_json" | jq \
            --arg ip "$ip" \
            --arg vmid "$vmid" \
            '. += [{"ip": $ip, "vmid": $vmid}]')
    done

    # Construct final JSON
    jq -n \
        --arg name "$CLUSTER_NAME" \
        --arg ts "$timestamp" \
        --argjson cp "$cp_json" \
        --argjson wk "$worker_json" \
        '{
            cluster_name: $name,
            timestamp: $ts,
            control_planes: $cp,
            workers: $wk
        }' > "$STATE_FILE"

    log_detail "State saved to $STATE_FILE ($(echo "$cp_json" | jq 'length') CPs, $(echo "$worker_json" | jq 'length') workers)"
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        log_info "Loading cluster state from $STATE_FILE"
        if command -v jq &>/dev/null; then
            local cp_count worker_count
            cp_count=$(jq '.control_planes | length' "$STATE_FILE")
            worker_count=$(jq '.workers | length' "$STATE_FILE")
            log_info "Previous state: $cp_count control planes, $worker_count workers"

            # Populate arrays from state
            readarray -t CONTROL_PLANE_IPS_ARRAY < <(jq -r '.control_planes[].ip' "$STATE_FILE")
            readarray -t WORKER_IPS_ARRAY < <(jq -r '.workers[].ip' "$STATE_FILE")
            return 0
        fi
    fi
    return 1
}

detect_environment() {
    if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]] || [[ "$MSYSTEM" == "MINGW"* ]] || [[ -n "${WINDIR:-}" ]]; then
        IS_WINDOWS=true
        SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        PING_CMD="ping -n 1 -w 2000"
        HOSTS_FILE="/c/Windows/System32/drivers/etc/hosts"
        log_info "Detected Windows/Git Bash environment"
    else
        IS_WINDOWS=false
        SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPath=~/.ssh/proxmox_mux_%h_%p_%r -o ControlPersist=600"
        PING_CMD="ping -c 1 -W 2"
        HOSTS_FILE="/etc/hosts"
        log_info "Detected Unix/Linux environment"
    fi
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
        log_step "Updating HAProxy configuration"
        log_detail "HAProxy IPs: ${ips[*]}"
        _log_file "HAPROXY" "Updating with IPs: ${ips[*]}"

        if bash "$haproxy_script" "${ips[@]}" >> "$LOG_FILE" 2>&1; then
            log_info "HAProxy updated successfully"
            sleep 3
        else
            log_error "Failed to update HAProxy"
            log_info "Manual fix: ./update-haproxy.sh ${ips[*]}"
            return 1
        fi
    else
        log_warn "HAProxy update script not found at $haproxy_script"
        return 1
    fi
}

# ==================== DIAGNOSTIC FUNCTIONS ====================
collect_node_logs() {
    local ip=$1
    log_step "Collecting diagnostic logs from $ip"
    _log_file "DIAGNOSTIC" "Node: $ip"

    talosctl dmesg --nodes "$ip" >> "$LOG_FILE" 2>&1 || log_warn "Failed to get dmesg from $ip"
    talosctl logs apid --nodes "$ip" >> "$LOG_FILE" 2>&1 || log_warn "Failed to get logs from $ip"
}

check_haproxy_status() {
    log_step "Checking HAProxy backend status"
    _log_file "HAPROXY-CHECK" "Testing $HAPROXY_IP"

    if timeout 3 bash -c "echo >/dev/tcp/${HAPROXY_IP}/6443" 2>>"$LOG_FILE"; then
        log_info "✓ HAProxy port 6443 (K8s API) reachable"
    else
        log_warn "✗ HAProxy port 6443 not reachable"
    fi

    if timeout 3 bash -c "echo >/dev/tcp/${HAPROXY_IP}/50000" 2>>"$LOG_FILE"; then
        log_info "✓ HAProxy port 50000 (Talos API) reachable"
    else
        log_warn "✗ HAProxy port 50000 not reachable"
    fi

    _log_file "HAPROXY" "Querying stats socket..."
    ssh ${SSH_OPTS} "jake@${HAPROXY_IP}" "echo 'show stat' | sudo nc -U /run/haproxy/admin.sock | grep -E '(k8s-controlplane|talos-controlplane)'" >> "$LOG_FILE" 2>&1 || \
        log_warn "Could not retrieve HAProxy stats"
}

# ==================== DISCOVERY ENGINE ====================
discover_proxmox_nodes() {
    local mode="${1:-initial}"
    log_step "Discovering nodes from Proxmox (VMs: $DISCOVER_VM_IDS) [mode: $mode]"
    _log_file "DISCOVERY" "Mode: $mode, VMs: $DISCOVER_VM_IDS"

    local vmid_array=($DISCOVER_VM_IDS)
    local cp_vms=" 200 201 "

    if [[ "$mode" == "post-deploy" ]]; then
        DISC_VM_MACS=()
        DISC_VM_NAMES=()
        DISC_VM_IPS=()
        DISC_MAC_TO_IP=()
        DISC_VM_ROLES=()
        DISC_CONTROL_PLANE_IPS=()
        DISC_WORKER_IPS=()
        _log_file "DISCOVERY" "Cleared previous data"
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
            _log_file "DISCOVERY" "VM $vmid: name=$name, mac=$macs, role=${DISC_VM_ROLES[$vmid]}"
        fi
    done

    if [[ ${#DISC_VM_MACS[@]} -eq 0 ]]; then
        log_error "No VMs discovered"
        return 1
    fi

    log_info "Populating ARP table..."
    _log_file "DISCOVERY" "Pinging subnet 192.168.1.0/24"

    get_ssh_output "
        for i in {1..254}; do
            ping -c 1 -W 1 192.168.1.\$i >/dev/null 2>&1 &
            if (( i % 30 == 0 )); then wait; fi
        done
        wait
    " >> "$LOG_FILE" 2>&1 || true

    log_detail "Waiting ${ARP_WAIT_TIME}s for ARP table to settle..."
    sleep "$ARP_WAIT_TIME"

    local arp_output=""
    local arp_retries=3
    while [[ $arp_retries -gt 0 ]]; do
        arp_output=$(get_ssh_output "cat /proc/net/arp") && break
        ((arp_retries--))
        sleep 2
    done

    if [[ -z "$arp_output" ]]; then
        log_error "Failed to get ARP table after retries"
        return 1
    fi

    _log_file "DISCOVERY" "ARP table: ${#arp_output} bytes"

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
                _log_file "DISCOVERY" "Ready: $role $name ($vmid) at $ip"
            else
                log_detail "$name ($vmid) at $ip: API not ready yet"
                missing_vms+=("$vmid")
                _log_file "DISCOVERY" "Not ready: $name ($vmid) at $ip"
            fi
        else
            log_detail "$name ($vmid): MAC not in ARP table yet"
            missing_vms+=("$vmid")
            _log_file "DISCOVERY" "Missing ARP: $name ($vmid), MAC $mac"
        fi
    done

    if [[ ${#missing_vms[@]} -gt 0 ]]; then
        log_info "Retrying discovery for ${#missing_vms[@]} missing VMs in 10s..."
        sleep 10

        get_ssh_output "cat /proc/net/arp" > /tmp/arp_new.txt 2>>"$LOG_FILE" || true
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
                [[ "$role" == "control-plane" ]] && DISC_CONTROL_PLANE_IPS+=("$ip") || DISC_WORKER_IPS+=("$ip")
                log_info "Discovered on retry: ${DISC_VM_NAMES[$vmid]} -> $ip"
                _log_file "DISCOVERY" "Retry success: $role at $ip"
            fi
        done
    fi

    if [[ "$mode" == "initial" ]]; then
        CONTROL_PLANE_IPS="${DISC_CONTROL_PLANE_IPS[*]}"
        WORKER_IPS="${DISC_WORKER_IPS[*]}"
    else
        WORKER_IPS="${DISC_WORKER_IPS[*]}"
        CONTROL_PLANE_IPS="${DISC_CONTROL_PLANE_IPS[*]}"
    fi

    log_info "Discovery complete: ${#DISC_CONTROL_PLANE_IPS[@]} control planes, ${#DISC_WORKER_IPS[@]} workers"

    if [[ ${#DISC_CONTROL_PLANE_IPS[@]} -eq 0 ]]; then
        log_error "No responsive control plane nodes found"
        return 1
    fi
    return 0
}

# ==================== USER INPUT ====================
prompt_user() {
    local question="$1"
    local var_name="$2"
    local default_value="${3:-}"
    local is_secret="${4:-false}"

    local prompt_text="${C_WARN}${question}${C_RESET}"
    [[ -n "$default_value" ]] && prompt_text+=" ${C_TIMESTAMP}[${default_value}]${C_RESET}"
    prompt_text+=" ${C_STEP}→${C_RESET} "

    echo -en "$prompt_text"

    if [[ "$is_secret" == "true" ]]; then
        local input
        read -rs input
        echo ""
        _log_file "PROMPT" "${var_name}=<redacted>"
    else
        local input
        read -r input
        _log_file "PROMPT" "${var_name}=${input:-$default_value}"
    fi

    if [[ -z "$input" && -n "$default_value" ]]; then
        printf -v "$var_name" '%s' "$default_value"
    else
        printf -v "$var_name" '%s' "$input"
    fi
}

confirm_proceed() {
    local msg="${1:-Proceed?}"
    local response

    echo -en "${C_WARN}${msg} ${C_DETAIL}(y/N)${C_RESET} ${C_WHITE}"
    read -n 1 -r response
    echo -e "${C_RESET}"

    _log_file "CONFIRM" "User responded: ${response}"

    [[ "$response" =~ ^[Yy]$ ]]
}

# ==================== IMPROVED DEPLOYMENT ====================
deploy_node() {
    local node_type=$1
    local ip=$2
    local config_file=$3
    local vmid="${NODE_VMIDS[$ip]:-}"
    local attempt=1

    log_info "[$ip] Starting deployment (VM ${vmid:-unknown})..."
    _log_file "DEPLOY" "$node_type $ip (VM ${vmid:-unknown}) file: $config_file"

    while [[ $attempt -le $MAX_RETRIES ]]; do
        log_detail "[$ip] Attempt $attempt/$MAX_RETRIES"

        if talosctl apply-config --insecure --nodes "$ip" --file "$config_file" >> "$LOG_FILE" 2>&1; then
            log_info "[$ip] Configuration applied successfully"
            _log_file "DEPLOY" "Success: $ip on attempt $attempt"

            # Use separate result files per node to avoid race conditions
            echo "SUCCESS:$ip:$(date +%s)" >> "$STATE_DIR/deploy-${ip}.result"
            return 0
        else
            local delay=$((RETRY_DELAY * attempt))
            log_warn "[$ip] Attempt $attempt failed, retrying in ${delay}s..."
            _log_file "DEPLOY" "Failed attempt $attempt for $ip"
            sleep $delay
        fi
        ((attempt++))
    done

    log_error "[$ip] Failed after $MAX_RETRIES attempts"
    _log_file "DEPLOY" "Final failure: $ip after $MAX_RETRIES attempts"
    echo "FAILED:$ip:$(date +%s)" >> "$STATE_DIR/deploy-${ip}.result"
    return 1
}

deploy_control_planes() {
    local -n cp_ips=$1
    log_step "Deploying Control Planes (${#cp_ips[@]} nodes)"

    for ip in "${cp_ips[@]}"; do
        deploy_node "control-plane" "$ip" "${NODES_DIR}/node-cp-${ip}.yaml" || return 1
    done

    log_info "Control plane deployment complete"
}

deploy_workers_parallel() {
    local -n worker_ips=$1
    local total=${#worker_ips[@]}
    log_step "Deploying Workers ($total nodes, max $DEPLOY_JOBS parallel)"

    mkdir -p "$STATE_DIR/pids"

    local pids=()
    for ip in "${worker_ips[@]}"; do
        deploy_node "worker" "$ip" "${NODES_DIR}/node-worker-${ip}.yaml" &
        local pid=$!
        pids+=("$pid")
        echo "$pid:$ip" >> "$STATE_DIR/pids/workers.pids"
        _log_file "DEPLOY" "Spawned $ip as PID $pid"

        if [[ ${#pids[@]} -ge $DEPLOY_JOBS ]]; then
            wait -n "${pids[@]}" 2>/dev/null || true
            local new_pids=()
            for p in "${pids[@]}"; do
                kill -0 "$p" 2>/dev/null && new_pids+=("$p")
            done
            pids=("${new_pids[@]}")
        fi
    done

    [[ ${#pids[@]} -gt 0 ]] && wait "${pids[@]}" 2>/dev/null || true

    # Aggregate results from individual result files
    local success_count=0
    local failed_count=0
    for f in "$STATE_DIR"/deploy-*.result; do
        [[ -f "$f" ]] || continue
        if grep -q "^SUCCESS:" "$f" 2>/dev/null; then
            ((success_count++))
        elif grep -q "^FAILED:" "$f" 2>/dev/null; then
            ((failed_count++))
        fi
    done

    log_info "Worker results: $success_count succeeded, $failed_count failed (total: $total)"
    [[ "$failed_count" -gt 0 ]] && return 1
    return 0
}

wait_for_talos_api() {
    local ip=$1
    local timeout=${2:-300}
    local start_time=$(date +%s)

    log_info "[$ip] Waiting for Talos API (timeout: ${timeout}s)..."
    _log_file "WAIT-API" "$ip timeout=${timeout}s"

    while true; do
        local elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -gt $timeout ]]; then
            log_error "[$ip] Timeout waiting for Talos API (${elapsed}s)"
            _log_file "WAIT-API" "$ip TIMEOUT after ${elapsed}s"
            return 1
        fi

        if [[ "$(test_port "$ip" 50000)" == "open" ]]; then
            log_info "[$ip] Talos API ready (${elapsed}s)"
            _log_file "WAIT-API" "$ip ready after ${elapsed}s"
            return 0
        fi

        [[ $((elapsed % 10)) -eq 0 ]] && log_detail "[$ip] Still waiting... (${elapsed}s)"
        sleep 2
    done
}

# ==================== IMPROVED CONFIG GENERATION ====================
generate_patches() {
    log_step "Generating Configuration Patches"

    for ip in "${CONTROL_PLANE_IPS_ARRAY[@]}"; do
        local vmid="${NODE_VMIDS[$ip]:-}"
        local nic="${NODE_INTERFACES[$ip]:-$DEFAULT_NETWORK_INTERFACE}"
        local disk="${NODE_DISKS[$ip]:-$DEFAULT_DISK}"

        # Patch file in nodes dir (temporary, cleaned up later)
        local patch_file="${NODES_DIR}/patch-cp-${ip}.yaml"
        local node_config="${NODES_DIR}/node-cp-${ip}.yaml"

        cat > "$patch_file" <<EOF
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
    extraHostEntries:
      - ip: ${HAPROXY_IP}
        aliases:
          - ${CONTROL_PLANE_ENDPOINT}
  sysctls:
    vm.nr_hugepages: "1024"
  kubelet:
    extraArgs:
      rotate-server-certificates: true
  kernel:
    modules:
      - name: nvme_tcp
      - name: vfio_pci
      - name: zfs
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
      - 127.0.0.1
EOF
        # Copy base config from script dir or generate location
        cp "${SCRIPT_DIR}/controlplane.yaml" "$node_config"

        run_cmd "Patch control plane config for $ip" \
            talosctl machineconfig patch "$node_config" \
            --patch "@$patch_file" \
            --output "$node_config"

        log_detail "Generated control plane config: $node_config"
    done

    for ip in "${WORKER_IPS_ARRAY[@]}"; do
        local vmid="${NODE_VMIDS[$ip]:-}"
        local nic="${NODE_INTERFACES[$ip]:-$DEFAULT_NETWORK_INTERFACE}"
        local disk="${NODE_DISKS[$ip]:-$DEFAULT_DISK}"

        local patch_file="${NODES_DIR}/patch-worker-${ip}.yaml"
        local node_config="${NODES_DIR}/node-worker-${ip}.yaml"

        cat > "$patch_file" <<EOF
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
    extraHostEntries:
      - ip: ${HAPROXY_IP}
        aliases:
          - ${CONTROL_PLANE_ENDPOINT}
  sysctls:
    vm.nr_hugepages: "1024"
  kernel:
    modules:
      - name: nvme_tcp
      - name: vfio_pci
      - name: zfs
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
      - 127.0.0.1
EOF
        cp "${SCRIPT_DIR}/worker.yaml" "$node_config"

        run_cmd "Patch worker config for $ip" \
            talosctl machineconfig patch "$node_config" \
            --patch "@$patch_file" \
            --output "$node_config"

        log_detail "Generated worker config: $node_config"
    done

    # Clean up patch files, keep only final node configs
    rm -f "${NODES_DIR}"/patch-*.yaml
    log_info "Node configurations generated in ${NODES_DIR}"
}

# ==================== IMPROVED MAIN BOOTSTRAP ====================
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

    # Initialize directory structure first
    init_directories

    if [[ "$DISCOVER_MODE" == "true" ]] || [[ "$USE_DISCOVERY" == "true" && -z "$CONTROL_PLANE_IPS" ]]; then
        log_step "Auto-Discovery Mode (Initial)"
        discover_proxmox_nodes "initial" || { log_error "Discovery failed"; exit 1; }
    fi

    if [[ -z "$CONTROL_PLANE_IPS" ]]; then
        log_error "No control plane IPs defined (use --discover or set CONTROL_PLANE_IPS)"
        exit 1
    fi

    IFS=' ' read -r -a CONTROL_PLANE_IPS_ARRAY <<< "$CONTROL_PLANE_IPS"
    IFS=' ' read -r -a WORKER_IPS_ARRAY <<< "$WORKER_IPS"
    ORIGINAL_CONTROL_PLANE_IPS="$CONTROL_PLANE_IPS"
    ORIGINAL_WORKER_IPS="$WORKER_IPS"

    log_step "Bootstrap Configuration"
    log_info "Control Planes: ${CONTROL_PLANE_IPS_ARRAY[*]}"
    log_info "Workers: ${WORKER_IPS_ARRAY[*]:-<none>}"
    log_info "HAProxy: $HAPROXY_IP"
    log_info "Platform: $([[ "$IS_WINDOWS" == "true" ]] && echo "Windows/Git Bash" || echo "Unix/Linux")"
    log_info "Cluster Dir: $CLUSTER_DIR"

    if [[ "$SKIP_PREFLIGHT" == "false" ]]; then
        log_step "Pre-flight Checks"

        for cmd in talosctl kubectl curl ssh jq; do  # Added jq check
            if ! command -v "$cmd" &>/dev/null; then
                log_error "$cmd not found in PATH (jq is required for state management)"
                exit 1
            fi
        done

        run_cmd "Check HAProxy stats endpoint" curl -s -o /dev/null "http://${HAPROXY_IP}:9000" || \
            log_warn "HAProxy stats not responding (continuing anyway)"

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

    # Use secrets directory
    if [[ ! -f "$SECRETS_FILE" ]]; then
        log_info "Generating new secrets..."
        run_cmd "Generate Talos secrets" talosctl gen secrets -o "$SECRETS_FILE" && \
            chmod 600 "$SECRETS_FILE" && \
            cp "$SECRETS_FILE" "${SECRETS_DIR}/secrets-$(date +%Y%m%d_%H%M%S).yaml"
    else
        log_info "Using existing secrets: $SECRETS_FILE"
    fi

    log_step "Generating Talos Configurations"
    # Clean only nodes dir, keep secrets
    rm -rf "${NODES_DIR:?}/"*
    rm -f "${SCRIPT_DIR}"/controlplane.yaml "${SCRIPT_DIR}"/worker.yaml 2>/dev/null || true

    # Generate configs to script dir first (talosctl limitation), then we'll copy if needed
    run_cmd "Generate Talos configurations" \
        talosctl gen config \
        --with-secrets "$SECRETS_FILE" \
        --kubernetes-version "$KUBERNETES_VERSION" \
        --talos-version "$TALOS_VERSION" \
        --install-image "$INSTALLER_IMAGE" \
        --additional-sans "${HAPROXY_IP},${CONTROL_PLANE_ENDPOINT}" \
        "$CLUSTER_NAME" "https://${CONTROL_PLANE_ENDPOINT}:6443"

    generate_patches

    log_step "Applying Common Cluster Settings"
    cat > "${NODES_DIR}/cluster-patch.yaml" <<'EOF'
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
        run_cmd "Apply cluster patch to $ip" \
            talosctl machineconfig patch "${NODES_DIR}/node-cp-${ip}.yaml" \
            --patch "@${NODES_DIR}/cluster-patch.yaml" \
            --output "${NODES_DIR}/node-cp-${ip}.yaml"
    done
    rm -f "${NODES_DIR}/cluster-patch.yaml"

    log_step "Preparing StaticHostConfig"
    cat > "${NODES_DIR}/statichost-config.yaml" <<EOF
apiVersion: v1alpha1
kind: StaticHostConfig
name: ${HAPROXY_IP}
hostnames:
  - ${CONTROL_PLANE_ENDPOINT}
EOF

    # Move talosconfig to secrets dir
    if [[ -f "${SCRIPT_DIR}/talosconfig" ]]; then
        mv "${SCRIPT_DIR}/talosconfig" "$TALOSCONFIG"
        chmod 600 "$TALOSCONFIG"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY-RUN: Configuration files generated in ${NODES_DIR}"
        ls -la "${NODES_DIR}/" | _log_file "DRY-RUN" "$(cat)"
        save_state
        exit 0
    fi

    log_step "Ready to Deploy"
    log_info "Summary:"
    log_info "  Control Planes: ${#CONTROL_PLANE_IPS_ARRAY[@]} nodes"
    log_info "  Workers: ${#WORKER_IPS_ARRAY[@]} nodes"
    log_info "  Parallel: $([[ "$PARALLEL_WORKERS" == "true" ]] && echo "Yes (max $DEPLOY_JOBS)" || echo "No")"

    if ! confirm_proceed "Deploy cluster with these settings?"; then
        log_info "Deployment cancelled by user"
        exit 0
    fi

    # Clean up old result files
    rm -f "$STATE_DIR"/deploy-*.result "$STATE_DIR"/pids/*.pids 2>/dev/null || true

    deploy_control_planes CONTROL_PLANE_IPS_ARRAY || { log_error "Control plane deployment failed"; exit 1; }

    if [[ ${#WORKER_IPS_ARRAY[@]} -gt 0 ]]; then
        if [[ "$PARALLEL_WORKERS" == "true" ]]; then
            deploy_workers_parallel WORKER_IPS_ARRAY || log_warn "Some workers may have failed"
        else
            for ip in "${WORKER_IPS_ARRAY[@]}"; do
                deploy_node "worker" "$ip" "${NODES_DIR}/node-worker-${ip}.yaml" || log_warn "Worker $ip failed"
            done
        fi
    fi

    log_step "Waiting for nodes to restart (${POST_DEPLOY_WAIT}s)..."
    sleep "$POST_DEPLOY_WAIT"

    log_step "Re-discovering nodes after reboot..."
    local rediscovery_attempts=3
    local rediscovery_success=false

    while [[ $rediscovery_attempts -gt 0 ]]; do
        if discover_proxmox_nodes "post-deploy"; then
            rediscovery_success=true
            break
        fi
        ((rediscovery_attempts--))
        [[ $rediscovery_attempts -gt 0 ]] && { log_warn "Re-discovery failed, retrying in 30s..."; sleep 30; }
    done

    IFS=' ' read -r -a CONTROL_PLANE_IPS_ARRAY <<< "$CONTROL_PLANE_IPS"
    IFS=' ' read -r -a WORKER_IPS_ARRAY <<< "$WORKER_IPS"

    if [[ "$rediscovery_success" == "false" ]]; then
        log_warn "Re-discovery failed, falling back to original IPs..."
        IFS=' ' read -r -a CONTROL_PLANE_IPS_ARRAY <<< "$ORIGINAL_CONTROL_PLANE_IPS"
        IFS=' ' read -r -a WORKER_IPS_ARRAY <<< "$ORIGINAL_WORKER_IPS"
    fi

    log_info "Post-reboot IPs:"
    log_info "  Control Planes: ${CONTROL_PLANE_IPS_ARRAY[*]:-<none>}"
    log_info "  Workers: ${WORKER_IPS_ARRAY[*]:-<none>}"

    if [[ ${#CONTROL_PLANE_IPS_ARRAY[@]} -eq 0 ]]; then
        log_error "No control plane nodes available after re-discovery"
        exit 1
    fi

    log_step "Waiting for Talos API on control plane nodes..."
    local api_ready_count=0
    for ip in "${CONTROL_PLANE_IPS_ARRAY[@]}"; do
        wait_for_talos_api "$ip" "$API_READY_WAIT" && ((api_ready_count++)) || log_warn "API not ready on $ip"
    done

    if [[ $api_ready_count -eq 0 ]]; then
        log_error "No control plane nodes have Talos API available"
        collect_node_logs "${CONTROL_PLANE_IPS_ARRAY[0]}"
        exit 1
    fi

    log_info "$api_ready_count/${#CONTROL_PLANE_IPS_ARRAY[@]} control plane nodes ready"

    if [[ ${#CONTROL_PLANE_IPS_ARRAY[@]} -gt 0 ]]; then
        update_haproxy "${CONTROL_PLANE_IPS_ARRAY[@]}" || log_warn "HAProxy update failed"
    fi

    check_haproxy_status

    local bootstrap_node="${CONTROL_PLANE_IPS_ARRAY[0]}"
    log_info "Using control plane node $bootstrap_node for bootstrap..."

    wait_for_talos_api "$bootstrap_node" 300 || {
        log_error "Control plane API never became available at $bootstrap_node"
        collect_node_logs "$bootstrap_node"
        exit 1
    }

    log_step "Configuring Talos Client"
    # Use talosconfig from secrets dir
    if [[ -f "$TALOSCONFIG" ]]; then
        run_cmd "Merge talosconfig" talosctl config merge "$TALOSCONFIG"
    else
        log_warn "talosconfig not found in $SECRETS_DIR, checking script dir..."
        run_cmd "Merge talosconfig" talosctl config merge talosconfig
    fi
    run_cmd "Set talosctl endpoint" talosctl config endpoint "$bootstrap_node"

    log_step "Applying StaticHostConfig"
    for ip in "${CONTROL_PLANE_IPS_ARRAY[@]}" "${WORKER_IPS_ARRAY[@]}"; do
        talosctl patch machineconfig --nodes "$ip" --patch-file "${NODES_DIR}/statichost-config.yaml" >> "$LOG_FILE" 2>&1 || \
            log_warn "StaticHostConfig failed for $ip (may already exist)"
    done
    rm -f "${NODES_DIR}/statichost-config.yaml"

    log_step "Bootstrapping Cluster (etcd)"
    run_cmd "Bootstrap etcd" talosctl bootstrap --nodes "$bootstrap_node"

    log_step "Waiting for Cluster Health"
    run_cmd "Wait for cluster health (${BOOTSTRAP_TIMEOUT}s)" \
        talosctl --endpoints "$bootstrap_node" --nodes "$bootstrap_node" health --wait-timeout="${BOOTSTRAP_TIMEOUT}s" || {
        log_error "Cluster failed to become healthy within timeout"
        collect_node_logs "$bootstrap_node"
        exit 1
    }

    log_step "Switching to HAProxy Endpoint"
    run_cmd "Switch endpoint to HAProxy" talosctl config endpoint "$HAPROXY_IP"

    if run_cmd "Verify health via HAProxy" \
        talosctl --endpoints "$HAPROXY_IP" --nodes "$HAPROXY_IP" health --wait-timeout=60s; then
        log_info "✓ Cluster accessible via HAProxy ($HAPROXY_IP)"
    else
        log_warn "Cluster healthy via direct IP but not via HAProxy"
    fi

    KUBECONFIG_PATH="${HOME}/.kube/config-${CLUSTER_NAME}"
    mkdir -p "$(dirname "$KUBECONFIG_PATH")"

    if run_cmd "Retrieve kubeconfig" talosctl kubeconfig "$KUBECONFIG_PATH" --nodes "$bootstrap_node"; then
        chmod 600 "$KUBECONFIG_PATH"
        _log_file "KUBECONFIG" "Saved to $KUBECONFIG_PATH"
    fi

    save_state

    log_step "Bootstrap Complete"
    log_info "Kubeconfig: export KUBECONFIG=$KUBECONFIG_PATH"
    log_info "Talos Dashboard: talosctl --endpoints $HAPROXY_IP dashboard"
    _log_file "COMPLETE" "Bootstrap finished successfully"
}

# ==================== OTHER COMMANDS ====================
cmd_discover() {
    log_step "Running Discovery Only"
    discover_proxmox_nodes "initial"
    echo
    echo "CONTROL_PLANE_IPS=\"${CONTROL_PLANE_IPS}\""
    echo "WORKER_IPS=\"${WORKER_IPS}\""
}

cmd_status() {
    load_state 2>/dev/null || { log_error "No state file"; exit 1; }

    if command -v jq &>/dev/null; then
        echo "State: $STATE_FILE"
        jq -r '"Timestamp: \(.timestamp)", "Control Planes:", (.control_planes[] | "  \(.ip) (VM \(.vmid))"), "Workers:", (.workers[] | "  \(.ip) (VM \(.vmid))")' "$STATE_FILE"
    else
        cat "$STATE_FILE"
    fi
}

cmd_logs() {
    load_state 2>/dev/null || { log_error "No state file"; exit 1; }

    log_step "Collecting logs from all cluster nodes"
    local cp_ips worker_ips
    cp_ips=$(jq -r '.control_planes[].ip' "$STATE_FILE" 2>/dev/null)
    worker_ips=$(jq -r '.workers[].ip' "$STATE_FILE" 2>/dev/null)

    for ip in $cp_ips $worker_ips; do
        collect_node_logs "$ip"
    done
    check_haproxy_status
}

# ==================== IMPROVED CLEANUP ====================
cmd_cleanup() {
    log_step "Cleaning up generated files"

    # Be more surgical - only remove generated node configs, keep secrets
    local removed_count=0
    if [[ -d "$NODES_DIR" ]]; then
        removed_count=$(find "$NODES_DIR" -type f 2>/dev/null | wc -l)
        rm -rf "${NODES_DIR:?}/"*
    fi

    # Remove base generated files from script dir (backward compat)
    rm -f "${SCRIPT_DIR}"/node-*.yaml \
          "${SCRIPT_DIR}"/patch-*.yaml \
          "${SCRIPT_DIR}"/controlplane.yaml \
          "${SCRIPT_DIR}"/worker.yaml \
          "${SCRIPT_DIR}"/talosconfig \
          "${SCRIPT_DIR}"/statichost-config.yaml \
          "${SCRIPT_DIR}"/cluster-patch.yaml 2>/dev/null || true

    log_info "Cleanup complete (removed ${removed_count} files from nodes/)"
}

cmd_reset() {
    log_step "Full reset"
    if ! confirm_proceed "Permanently delete all configs, state, and secrets for cluster ${CLUSTER_NAME}?"; then
        log_info "Reset cancelled"
        exit 0
    fi

    # Safer reset - remove entire cluster directory
    if [[ -d "$CLUSTER_DIR" ]]; then
        rm -rf "${CLUSTER_DIR:?}"
        log_info "Removed cluster directory: $CLUSTER_DIR"
    fi

    # Also clean script dir for backward compatibility
    rm -f "${SCRIPT_DIR}"/node-*.yaml \
          "${SCRIPT_DIR}"/patch-*.yaml \
          "${SCRIPT_DIR}"/controlplane.yaml \
          "${SCRIPT_DIR}"/worker.yaml \
          "${SCRIPT_DIR}"/talosconfig 2>/dev/null || true

    log_info "Reset complete for cluster ${CLUSTER_NAME}"
}

cd "$SCRIPT_DIR"
init_logging
detect_environment
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
        cmd_cleanup
        ;;
    reset)
        cmd_reset
        ;;
    help|--help|-h|*)
        echo "Usage: $0 {bootstrap|discover|status|logs|cleanup|reset} [--discover|--dry-run|--skip-preflight]"
        echo ""
        echo "Commands:"
        echo "  bootstrap    Run the full bootstrap process"
        echo "  discover     Only run node discovery"
        echo "  status       Show saved cluster state"
        echo "  logs         Collect diagnostic logs from all nodes"
        echo "  cleanup      Remove generated configuration files"
        echo "  reset        Full reset (delete secrets and state)"
        echo ""
        echo "Directory Structure:"
        echo "  clusters/${CLUSTER_NAME}/"
        echo "    ├── nodes/     # Generated node configs (ephemeral)"
        echo "    ├── secrets/   # Sensitive files (secrets.yaml, talosconfig)"
        echo "    ├── state/     # Runtime state and deployment results"
        echo "    └── patches/   # Custom patches (optional)"
        ;;
esac