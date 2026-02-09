#!/usr/bin/env bash
# Talos Bootstrap Script - Hierarchical Logging Refactor
# Hierarchy: PLAN > STAGE > JOB > STEP > DETAIL

set -euo pipefail

# ==================== CONFIGURATION ====================
VERSION="2.5.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

CLUSTER_NAME="${CLUSTER_NAME:-proxmox-talos-test}"
CLUSTER_DIR="${SCRIPT_DIR}/clusters/${CLUSTER_NAME}"
NODES_DIR="${CLUSTER_DIR}/nodes"
SECRETS_DIR="${CLUSTER_DIR}/secrets"
STATE_DIR="${CLUSTER_DIR}/state"
PATCH_DIR="${CLUSTER_DIR}/patches"
LOG_DIR="${SCRIPT_DIR}/logs"

TERRAFORM_TFVARS="${TERRAFORM_TFVARS:-${SCRIPT_DIR}/../terraform.tfvars}"
SECRETS_FILE="${SECRETS_FILE:-${SECRETS_DIR}/secrets.yaml}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/bootstrap-state.json}"
TALOSCONFIG="${TALOSCONFIG:-${SECRETS_DIR}/talosconfig}"
KUBECONFIG_PATH="${HOME}/.kube/config-${CLUSTER_NAME}"

# Node Configuration
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-$CLUSTER_NAME.jdwkube.com}"
HAPROXY_IP="${HAPROXY_IP:-192.168.1.237}"
HAPROXY_LOGIN_USERNAME="${HAPROXY_LOGIN_USERNAME:-jake}"
HAPROXY_STATS_USERNAME="${HAPROXY_STATS_USERNAME:-admin}"
HAPROXY_STATS_PASSWORD="${HAPROXY_STATS_PASSWORD:-admin}"
CONTROL_PLANE_IPS="${CONTROL_PLANE_IPS:-}"
WORKER_IPS="${WORKER_IPS:-}"
ORIGINAL_CONTROL_PLANE_IPS=""
ORIGINAL_WORKER_IPS=""

# Kubernetes/Talos Versions
KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.35.0}"
TALOS_VERSION="${TALOS_VERSION:-v1.12.3}"
INSTALLER_IMAGE="${INSTALLER_IMAGE:-factory.talos.dev/nocloud-installer/b553b4a25d76e938fd7a9aaa7f887c06ea4ef75275e64f4630e6f8f739cf07df:${TALOS_VERSION}}"

# Hardware Defaults
DEFAULT_NETWORK_INTERFACE="${DEFAULT_NETWORK_INTERFACE:-eth0}"
DEFAULT_DISK="${DEFAULT_DISK:-sda}"

# Parallelism
MAX_PARALLEL_CONTROL_PLANES=3
MAX_PARALLEL_WORKERS=3

# Timeouts
BOOTSTRAP_TIMEOUT=300
REBOOT_WAIT_TIME=180
API_READY_WAIT=180

# State
declare -A NODE_DISKS
declare -A NODE_INTERFACES
declare -A VMID_BY_IP
declare -A IP_BY_MAC
declare -A MAC_BY_VMDATA
declare -A NODE_ROLES

# Terraform parsed values
TF_PROXMOX_ENDPOINT=""
TF_PROXMOX_NODE=""
TF_PROXMOX_SSH_USER="root"
TF_PROXMOX_SSH_HOST=""
TF_CONTROL_PLANE_VMIDS=()
TF_CONTROL_PLANE_NAMES=()
TF_WORKER_VMIDS=()
TF_WORKER_NAMES=()
DISCOVER_VM_IDS=""
CONTROL_PLANE_VM_IDS=""

# Platform detection
IS_WINDOWS=false
SSH_OPTS=""
PING_CMD=""
HOSTS_FILE=""

# ==================== HIERARCHICAL LOGGING SYSTEM ====================

# Configuration
LOG_LEVEL="${LOG_LEVEL:-INFO}"
LOG_DEPTH="${LOG_DEPTH:-4}"
LOG_TIMESTAMPS="${LOG_TIMESTAMPS:-1}"
LOG_ICONS="${LOG_ICONS:-0}"
LOG_FILE=""
CONSOLE_LOG_FILE=""

# Severity Levels
declare -A SEV_LEVELS=([FATAL]=0 [ERROR]=1 [WARN]=2 [INFO]=3 [DEBUG]=4 [TRACE]=5)

# Severity Icons (inside brackets)
declare -A SEV_ICONS=(
    [FATAL]='🚫'
    [ERROR]='❌'
    [WARN]='⚠️'
    [INFO]='ℹ️'
    [DEBUG]='🔧'
    [TRACE]='🔬'
)

# Severity Labels (text mode - default)
declare -A SEV_LABELS=(
    [FATAL]='FATAL'
    [ERROR]='ERROR'
    [WARN]='WARN'
    [INFO]='INFO'
    [DEBUG]='DEBUG'
    [TRACE]='TRACE'
)

# Severity Colors (for severity bracket)
declare -A SEV_COLORS=(
    [FATAL]='\033[1;97;41m'  # White on red background
    [ERROR]='\033[0;91m'     # Bright red
    [WARN]='\033[0;93m'      # Bright yellow
    [INFO]='\033[0;97m'      # White
    [DEBUG]='\033[0;94m'     # Bright blue
    [TRACE]='\033[0;90m'     # Gray
)

# Hierarchy Icons (inside brackets)
declare -A HIER_ICONS=(
    [PLAN]='▶'
    [STAGE]='◆'
    [JOB]='▸'
    [STEP]='→'
    [DETAIL]='·'
)

# Hierarchy Labels (text mode - default)
declare -A HIER_LABELS=(
    [PLAN]='PLAN'
    [STAGE]='STAGE'
    [JOB]='JOB'
    [STEP]='STEP'
    [DETAIL]='DETAIL'
)

# Hierarchy Colors (for hierarchy bracket)
declare -A HIER_COLORS=(
    [PLAN]='\033[1;95m'      # Bright magenta
    [STAGE]='\033[1;94m'     # Bright blue
    [JOB]='\033[1;96m'       # Bright cyan
    [STEP]='\033[0;92m'      # Green
    [DETAIL]='\033[0;37m'    # Light gray
)

C_RESET='\033[0m'
C_TIMESTAMP='\033[0;90m'

# Timestamp format
LOG_TIMESTAMP_FORMAT="+%Y-%m-%d %H:%M:%S"

# ==================== CORE LOGGING FUNCTION ====================

log() {
    local hierarchy="${1:-STEP}"
    local severity="${2:-INFO}"
    local message="$3"

    [[ -z "${SEV_LEVELS[$severity]:-}" ]] && severity="INFO"

    local hier_num=0
    case "$hierarchy" in
        PLAN) hier_num=0 ;;
        STAGE) hier_num=1 ;;
        JOB) hier_num=2 ;;
        STEP) hier_num=3 ;;
        DETAIL) hier_num=4 ;;
    esac

    [[ ${SEV_LEVELS[$severity]} -gt ${SEV_LEVELS[$LOG_LEVEL]} ]] && return
    [[ $hier_num -gt $LOG_DEPTH ]] && return

    # Build output
    local output=""

    # Timestamp: [14:32:10]
    if [[ "$LOG_TIMESTAMPS" == "1" ]]; then
        output+="${C_TIMESTAMP}[$(date '+%H:%M:%S')]${C_RESET} "
    fi

    # Severity: [INFO] or [ℹ️] depending on LOG_ICONS setting
    if [[ "$LOG_ICONS" == "1" ]]; then
        # Icon mode
        local sev_display="${SEV_ICONS[$severity]}"
        output+="${SEV_COLORS[$severity]}[${sev_display}]${C_RESET} "
    else
        # Text mode (default) - padded to 5 chars for alignment
        local sev_label="${SEV_LABELS[$severity]}"
        printf -v sev_padded "%-5s" "$sev_label"
        output+="${SEV_COLORS[$severity]}[${sev_padded}]${C_RESET} "
    fi

    # Hierarchy: [STEP] or [▶] depending on LOG_ICONS setting
    if [[ "$LOG_ICONS" == "1" ]]; then
        # Icon mode
        local hier_display="${HIER_ICONS[$hierarchy]}"
        output+="${HIER_COLORS[$hierarchy]}[${hier_display}]${C_RESET} "
    else
        # Text mode (default) - padded to 6 chars for alignment
        local hier_label="${HIER_LABELS[$hierarchy]}"
        printf -v hier_padded "%-6s" "$hier_label"
        output+="${HIER_COLORS[$hierarchy]}[${hier_padded}]${C_RESET} "
    fi

    # Message (no indentation - clean alignment)
    output+="${message}"

    # Print to console
    echo -e "$output"

    # Write to console log file (with ANSI codes)
    if [[ -n "${CONSOLE_LOG_FILE:-}" ]]; then
        echo -e "$output" >> "$CONSOLE_LOG_FILE"
    fi

    [[ "$severity" == "FATAL" ]] && exit 1

    # Write to regular log file (text labels for grep-ability)
    if [[ -n "${LOG_FILE:-}" ]]; then
        local timestamp=$(date "$LOG_TIMESTAMP_FORMAT")
        echo "[$timestamp] [$severity] [$hierarchy] $message" >> "$LOG_FILE"
    fi
}

# ==================== HIERARCHY LOGGING WRAPPERS ====================

plan_fatal_log() { log "PLAN" "FATAL" "$1"; }
plan_error_log() { log "PLAN" "ERROR" "$1"; }
plan_warn_log()  { log "PLAN" "WARN" "$1"; }
plan_info_log()  { log "PLAN" "INFO" "$1"; }
plan_debug_log() { log "PLAN" "DEBUG" "$1"; }

stage_fatal_log() { log "STAGE" "FATAL" "$1"; }
stage_error_log() { log "STAGE" "ERROR" "$1"; }
stage_warn_log()  { log "STAGE" "WARN" "$1"; }
stage_info_log()  { log "STAGE" "INFO" "$1"; }
stage_debug_log() { log "STAGE" "DEBUG" "$1"; }

job_fatal_log() { log "JOB" "FATAL" "$1"; }
job_error_log() { log "JOB" "ERROR" "$1"; }
job_warn_log()  { log "JOB" "WARN" "$1"; }
job_info_log()  { log "JOB" "INFO" "$1"; }
job_debug_log() { log "JOB" "DEBUG" "$1"; }

step_fatal_log() { log "STEP" "FATAL" "$1"; }
step_error_log() { log "STEP" "ERROR" "$1"; }
step_warn_log()  { log "STEP" "WARN" "$1"; }
step_info_log()  { log "STEP" "INFO" "$1"; }
step_debug_log() { log "STEP" "DEBUG" "$1"; }

detail_fatal_log() { log "DETAIL" "FATAL" "$1"; }
detail_error_log() { log "DETAIL" "ERROR" "$1"; }
detail_warn_log()  { log "DETAIL" "WARN" "$1"; }
detail_info_log()  { log "DETAIL" "INFO" "$1"; }
detail_debug_log() { log "DETAIL" "DEBUG" "$1"; }
detail_trace_log() { log "DETAIL" "TRACE" "$1"; }

# ==================== UTILITY LOGGERS ====================

log_file_only() {
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "[$(date "$LOG_TIMESTAMP_FORMAT")] [$1] $2" >> "$LOG_FILE"
    fi
}

init_logging() {
    mkdir -p "$LOG_DIR"

    # Timestamped log file (keeps history)
    LOG_FILE="$LOG_DIR/bootstrap-$(date +%Y%m%d_%H%M%S).log"
    touch "$LOG_FILE"

    local args_str=""
    if [[ $# -gt 0 ]]; then
        args_str="Arguments: $*"
    else
        args_str="Arguments: (none)"
    fi

    # Console log file (overwritten each run, keeps colors/formatting)
    CONSOLE_LOG_FILE="$LOG_DIR/console-logs.log"
    # Clear previous console log and add header
    {
        echo "========================================"
        echo "Console Log Started: $(date)"
        echo "Version: $VERSION"
        echo "Script: $0"
        echo "User: $(whoami)"
        echo "Working Directory: $SCRIPT_DIR"
        echo "Hostname: ${HOSTNAME:-$(hostname)}"
        echo "Platform: $OSTYPE"
        echo "Cluster: $CLUSTER_NAME"
        echo "Control Plane Endpoint: $CONTROL_PLANE_ENDPOINT"
        echo "HAProxy IP: $HAPROXY_IP"
        echo "$args_str"
        echo "Environment:"
        echo "  KUBERNETES_VERSION=$KUBERNETES_VERSION"
        echo "  TALOS_VERSION=$TALOS_VERSION"
        echo "  INSTALLER_IMAGE=$INSTALLER_IMAGE"
        echo "  DEFAULT_NETWORK_INTERFACE=$DEFAULT_NETWORK_INTERFACE"
        echo "  DEFAULT_DISK=$DEFAULT_DISK"
        echo "========================================"
    } > "$CONSOLE_LOG_FILE"

    {
        echo "========================================"
        echo "Talos Bootstrap Log Started: $(date)"
        echo "Version: $VERSION"
        echo "Script: $0"
        echo "User: $(whoami)"
        echo "Working Directory: $SCRIPT_DIR"
        echo "Hostname: ${HOSTNAME:-$(hostname)}"
        echo "Platform: $OSTYPE"
        echo "Cluster: $CLUSTER_NAME"
        echo "Control Plane Endpoint: $CONTROL_PLANE_ENDPOINT"
        echo "HAProxy IP: $HAPROXY_IP"
        echo "$args_str"
        echo "Environment:"
        echo "  KUBERNETES_VERSION=$KUBERNETES_VERSION"
        echo "  TALOS_VERSION=$TALOS_VERSION"
        echo "  INSTALLER_IMAGE=$INSTALLER_IMAGE"
        echo "  DEFAULT_NETWORK_INTERFACE=$DEFAULT_NETWORK_INTERFACE"
        echo "  DEFAULT_DISK=$DEFAULT_DISK"
        echo "========================================"
    } >> "$LOG_FILE"

    print_banner

    trap 'cleanup_on_exit' EXIT INT TERM
}

cleanup_on_exit() {
    local exit_code=$?

    rm -f /tmp/haproxy.cfg.* 2>/dev/null || true

    if [[ $exit_code -ne 0 && -n "${LOG_FILE:-}" ]]; then
        log_file_only "EXIT" "Script exited with code $exit_code"
    fi

    # Add footer to console log
    if [[ -n "${CONSOLE_LOG_FILE:-}" ]]; then
        {
            echo ""
            echo "========================================"
            echo "Console Log Ended: $(date)"
            echo "Exit Code: $exit_code"
            echo "========================================"
        } >> "$CONSOLE_LOG_FILE"
    fi

    exit $exit_code
}

print_banner() {
    local color_reset='\033[0m'
    local color_blue='\033[1;34m'
    local color_cyan='\033[1;36m'
    local color_white='\033[1;37m'
    echo -e "$color_blue━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$color_reset"
    echo -e "$color_white  ▄▄▄█████▓ ▄▄▄       ██▓      ▒█████    ██████ $color_reset"
    echo -e "$color_white  ▓  ██▒ ▓▒▒████▄    ▓██▒     ▒██▓  ██▒▒██    ▒ $color_reset"
    echo -e "$color_white  ▒ ▓██░ ▒░▒██  ▀█▄  ▒██░     ▒██▒  ██░░ ▓██▄   $color_reset"
    echo -e "$color_white  ░ ▓██▓ ░ ░██▄▄▄▄██ ▒██░     ░██  █▀ ░  ▒   ██▒$color_reset"
    echo -e "$color_white    ▒██▒ ░  ▓█   ▓██▒░██████▒░▒███▒█▄ ▒██████▒▒$color_reset"
    echo -e "$color_white    ▒ ░░    ▒▒   ▓▒█░░ ▒░▓  ░░░ ▒▒░ ▒ ▒ ▒▓▒ ▒ ░$color_reset"
    echo -e "$color_cyan             BOOTSTRAP UTILITY v$VERSION$color_reset"
    echo -e "$color_blue━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$color_reset"
    echo
}

# ==================== STEP LEVEL FUNCTIONS ====================

step_run_command() {
    local description="$1"
    local verbose="${VERBOSE:-false}"
    shift
    local cmd=("$@")

    step_info_log "$description"
    log_file_only "EXEC" "${cmd[*]}"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        step_info_log "[DRY RUN] Would execute: ${cmd[*]}"
        return 0
    fi

    local output
    local exit_code=0

    if output=$("${cmd[@]}" 2>&1); then
        log_file_only "OUTPUT" "$output"
        [[ "$verbose" == "true" && -n "$output" ]] && detail_info_log "$output"
        log_file_only "SUCCESS" "$description"
        return 0
    else
        exit_code=$?
        step_error_log "$description failed (exit $exit_code)"
        log_file_only "FAIL" "$output"
        if [[ -n "$output" ]]; then
            local truncated="${output:0:500}"
            if [[ ${#output} -gt 500 ]]; then
                truncated="${truncated}... [truncated, see log file for full output]"
            fi
            step_error_log "Command output: $truncated"
        fi
        return $exit_code
    fi
}

step_test_port() {
    local ip="$1"
    local port="${2:-50000}"
    local timeout="${3:-2}"

    step_info_log "Testing $ip:$port"

    if timeout "$timeout" bash -c "echo >/dev/tcp/$ip/$port" 2>/dev/null; then
        detail_info_log "$ip:$port is OPEN"
        return 0
    else
        detail_warn_log "$ip:$port is CLOSED"
        return 1
    fi
}

step_apply_config() {
    local ip="$1"
    local config_file="$2"
    local vmid="$3"
    local max_attempts="${4:-5}"

    step_info_log "Apply config to $ip (VM $vmid)"

    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        detail_info_log "Attempt $attempt/$max_attempts"

        if talosctl apply-config --nodes "$ip" --file "$config_file" --insecure 2>>"$LOG_FILE"; then
            step_info_log "Configuration applied successfully"
            return 0
        fi

        attempt=$(($attempt + 1))
        [[ $attempt -le $max_attempts ]] && sleep 5
    done

    step_error_log "Failed to apply config after $max_attempts attempts"
    return 1
}

step_wait_for_api() {
    local ip="$1"
    local timeout="${2:-180}"
    local mode="${3:-secure}"  # 'insecure' for initial, 'secure' for post-reboot

    step_info_log "Wait for Talos API on $ip (mode: $mode)"
    detail_info_log "Timeout: ${timeout}s"

    local -i start_time
    start_time=$(date +%s)
    local -i elapsed=0

    export TALOSCONFIG="$TALOSCONFIG"

    while (( elapsed < timeout )); do
        elapsed=$(($(date +%s) - start_time))

        if [[ "$mode" == "insecure" ]]; then
            if talosctl version --nodes "$ip" --insecure &>/dev/null; then
                step_info_log "API ready (insecure) (${elapsed}s)"
                return 0
            fi
        else
            if talosctl version --nodes "$ip" --endpoints "$ip" &>/dev/null; then
                step_info_log "API ready (secure) (${elapsed}s)"
                return 0
            fi
        fi

        detail_info_log "Waiting... (${elapsed}s elapsed)"
        sleep 5
        elapsed=$(($(date +%s) - start_time))
    done

    step_error_log "Timeout waiting for API on $ip (${timeout}s)"
    return 1
}

# ==================== JOB LEVEL FUNCTIONS ====================

job_init_directories() {
    job_info_log "Initialize Directories"

    step_info_log "Create directory structure"
    mkdir -p "$NODES_DIR" "$SECRETS_DIR" "$STATE_DIR" "$PATCH_DIR" "$LOG_DIR"

    step_info_log "Setup .gitignore"
    if [[ ! -f "${CLUSTER_DIR}/.gitignore" ]]; then
        cat > "${CLUSTER_DIR}/.gitignore" <<'EOF'
/nodes/
/secrets/
/state/
/*.log
EOF
        detail_info_log "Created .gitignore"
    else
        detail_info_log ".gitignore already exists"
    fi

    log_file_only "INIT" "Directories: nodes=${NODES_DIR}, secrets=${SECRETS_DIR}, state=${STATE_DIR}"
}

job_detect_environment() {
    job_info_log "Detect Platform"

    step_info_log "Check operating system"
    if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]] || [[ "$MSYSTEM" == "MINGW"* ]] \
    || [[ -n "${WINDIR:-}" ]] || [[ -n "${MINGW_PREFIX:-}" ]] || [[ "$TERM" == "xterm-256color" \
    && -n "${MSYSTEM:-}" ]]; then
        IS_WINDOWS=true
        SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        PING_CMD="ping -n 1 -w 2000"
        HOSTS_FILE="/c/Windows/System32/drivers/etc/hosts"
        step_info_log "Detected Windows/Git Bash environment"
    else
        IS_WINDOWS=false
        SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPath=~/.ssh/proxmox_mux_%h_%p_%r -o ControlPersist=600"
        PING_CMD="ping -c 1 -W 2"
        HOSTS_FILE="/etc/hosts"
        step_info_log "Detected Unix/Linux environment"
    fi

    detail_info_log "SSH options configured"
}

job_parse_terraform() {
    local tfvars_file="${1:-$TERRAFORM_TFVARS}"

    job_info_log "Parse Terraform Configuration"

    step_info_log "Locate terraform.tfvars"
    if [[ ! -f "$tfvars_file" ]]; then
        step_warn_log "File not found: $tfvars_file"
        step_info_log "Falling back to environment variables / defaults"
        return 1
    fi
    step_info_log "Found: $tfvars_file"

    step_info_log "Parse Proxmox endpoint"
    TF_PROXMOX_ENDPOINT=$(grep -E '^proxmox_endpoint[[:space:]]*=' "$tfvars_file" | head -1 | cut -d'"' -f2)
    if [[ -n "$TF_PROXMOX_ENDPOINT" ]]; then
        local proxmox_host
        proxmox_host=$(echo "$TF_PROXMOX_ENDPOINT" | sed -E 's|https?://||' | cut -d':' -f1)
        if [[ -n "$proxmox_host" ]]; then
            PROXMOX_SSH_HOST="$proxmox_host"
            detail_info_log "Endpoint: $TF_PROXMOX_ENDPOINT"
            detail_info_log "SSH host: $PROXMOX_SSH_HOST"
        fi
    fi

    step_info_log "Parse control plane VMs"
    local in_cp_config=false
    local current_name=""
    local current_vmid=""
    local cp_count=0

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" =~ talos_control_configuration[[:space:]]*=[[:space:]]*\[ ]]; then
            in_cp_config=true
            continue
        fi

        if [[ "$in_cp_config" == true && "$line" =~ ^\][[:space:]]*$ ]]; then
            in_cp_config=false
            if [[ -n "$current_vmid" ]]; then
                TF_CONTROL_PLANE_VMIDS+=("$current_vmid")
                TF_CONTROL_PLANE_NAMES+=("${current_name:-unnamed}")
                cp_count=$(($cp_count + 1))
                detail_info_log "Control plane: ${current_name:-unnamed} (VM $current_vmid)"
            fi
            current_name=""
            current_vmid=""
            continue
        fi

        if [[ "$in_cp_config" == true ]]; then
            if [[ "$line" =~ \{ ]]; then
                current_name=""
                current_vmid=""
            fi
            if [[ "$line" =~ vmid[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
                current_vmid="${BASH_REMATCH[1]}"
            fi
            if [[ "$line" =~ vm_name[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
                current_name="${BASH_REMATCH[1]}"
            fi
            if [[ "$line" =~ node_name[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
                local node="${BASH_REMATCH[1]}"
                [[ -z "$TF_PROXMOX_NODE" ]] && TF_PROXMOX_NODE="$node"
            fi
            if [[ "$line" =~ \} ]]; then
                if [[ -n "$current_vmid" ]]; then
                    TF_CONTROL_PLANE_VMIDS+=("$current_vmid")
                    TF_CONTROL_PLANE_NAMES+=("${current_name:-unnamed}")
                    cp_count=$(($cp_count + 1))
                    detail_info_log "Control plane: ${current_name:-unnamed} (VM $current_vmid)"
                fi
                current_name=""
                current_vmid=""
            fi
        fi
    done < "$tfvars_file"

    step_info_log "Parse worker VMs"
    local in_worker_config=false
    current_name=""
    current_vmid=""
    local worker_count=0

    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" =~ talos_worker_configuration[[:space:]]*=[[:space:]]*\[ ]]; then
            in_worker_config=true
            continue
        fi

        if [[ "$in_worker_config" == true && "$line" =~ ^\][[:space:]]*$ ]]; then
            in_worker_config=false
            if [[ -n "$current_vmid" ]]; then
                TF_WORKER_VMIDS+=("$current_vmid")
                TF_WORKER_NAMES+=("${current_name:-unnamed}")
                worker_count=$(($worker_count + 1))
                detail_info_log "Worker: ${current_name:-unnamed} (VM $current_vmid)"
            fi
            current_name=""
            current_vmid=""
            continue
        fi

        if [[ "$in_worker_config" == true ]]; then
            if [[ "$line" =~ \{ ]]; then
                current_name=""
                current_vmid=""
            fi
            if [[ "$line" =~ vmid[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
                current_vmid="${BASH_REMATCH[1]}"
            fi
            if [[ "$line" =~ vm_name[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
                current_name="${BASH_REMATCH[1]}"
            fi
            if [[ "$line" =~ \} ]]; then
                if [[ -n "$current_vmid" ]]; then
                    TF_WORKER_VMIDS+=("$current_vmid")
                    TF_WORKER_NAMES+=("${current_name:-unnamed}")
                    worker_count=$(($worker_count + 1))
                    detail_info_log "Worker: ${current_name:-unnamed} (VM $current_vmid)"
                fi
                current_name=""
                current_vmid=""
            fi
        fi
    done < "$tfvars_file"

    if [[ ${#TF_CONTROL_PLANE_VMIDS[@]} -gt 0 || ${#TF_WORKER_VMIDS[@]} -gt 0 ]]; then
        local all_vmids=()
        [[ ${#TF_CONTROL_PLANE_VMIDS[@]} -gt 0 ]] && all_vmids+=("${TF_CONTROL_PLANE_VMIDS[@]}")
        [[ ${#TF_WORKER_VMIDS[@]} -gt 0 ]] && all_vmids+=("${TF_WORKER_VMIDS[@]}")

        DISCOVER_VM_IDS=$(IFS=' '; echo "${all_vmids[*]}")
        CONTROL_PLANE_VM_IDS=$(IFS=' '; echo "${TF_CONTROL_PLANE_VMIDS[*]}")

        step_info_log "Results: $cp_count control planes, $worker_count workers"
        detail_info_log "DISCOVER_VM_IDS: $DISCOVER_VM_IDS"
        detail_info_log "CONTROL_PLANE_VM_IDS: $CONTROL_PLANE_VM_IDS"

        if [[ -n "$DISCOVER_VM_IDS" ]]; then
            USE_DISCOVERY="true"
            step_info_log "Auto-enabled discovery mode"
        fi

        return 0
    else
        step_warn_log "No VM IDs found in terraform.tfvars"
        return 1
    fi
}

job_display_config() {
    job_info_log "Display Configuration"

    step_info_log "Proxmox Endpoint: $TF_PROXMOX_ENDPOINT"
    step_info_log "Proxmox Node: $TF_PROXMOX_NODE"
    step_info_log "SSH User: $TF_PROXMOX_SSH_USER@${TF_PROXMOX_SSH_HOST:-pve1}"

    step_info_log "Control Plane VMs:"
    for i in "${!TF_CONTROL_PLANE_NAMES[@]}"; do
        detail_info_log "${TF_CONTROL_PLANE_NAMES[$i]} (VM ${TF_CONTROL_PLANE_VMIDS[$i]})"
    done

    step_info_log "Worker VMs:"
    for i in "${!TF_WORKER_NAMES[@]}"; do
        detail_info_log "${TF_WORKER_NAMES[$i]} (VM ${TF_WORKER_VMIDS[$i]})"
    done
}

job_discover_vms() {
    local mode="${1:-initial}"

    job_info_log "Discover Proxmox VMs"

    local discovered_count=0
    local discovered_host=""

    # Validate we have VM IDs to discover
    if [[ -z "${DISCOVER_VM_IDS:-}" ]]; then
        job_error_log "No VM IDs configured for discovery"
        return 1
    fi

    for host in "${TF_PROXMOX_NODE:-pve1}"; do
        local qm_output
        qm_output=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
            "${TF_PROXMOX_SSH_USER}@$host" \
            "for vmid in $DISCOVER_VM_IDS; do echo \"===VMID:\$vmid===\"; qm config \$vmid 2>/dev/null || echo 'NOT_FOUND'; done" 2>/dev/null) || {
            job_warn_log "Failed to connect to $host"
            continue
        }

        local current_vmid=""
        while IFS= read -r line; do
            if [[ "$line" =~ ^===VMID:([0-9]+)===$ ]]; then
                current_vmid="${BASH_REMATCH[1]}"
            elif [[ "$line" == "NOT_FOUND" ]]; then
                job_warn_log "VM $current_vmid not found on $host"
                current_vmid=""
            elif [[ -n "$current_vmid" && "$line" =~ ^name:[[:space:]]*(.+)$ ]]; then
                local vmname="${BASH_REMATCH[1]}"
                local role="worker"
                [[ " ${TF_CONTROL_PLANE_VMIDS[*]:-} " =~ " $current_vmid " ]] && role="control-plane"

                NODE_ROLES["$current_vmid"]="$role"
                job_debug_log "VM $current_vmid ($vmname): Role=$role, Host=$host"
                discovered_count=$(($discovered_count + 1))
            elif [[ -n "$current_vmid" && "$line" =~ ^net[0-9]+:[[:space:]]*virtio=([0-9A-Fa-f:]+) ]]; then
                local mac="${BASH_REMATCH[1]}"
                MAC_BY_VMDATA["$current_vmid"]="$mac"
                job_debug_log "MAC: $mac"
            fi
        done <<< "$qm_output"

        if [[ $discovered_count -gt 0 ]]; then
            discovered_host="$host"
            break
        fi
    done

    if [[ $discovered_count -eq 0 ]]; then
        job_error_log "No VMs discovered"
        return 1
    fi

    job_info_log "Found $discovered_count VMs on host $discovered_host"

    if ! populate_arp_table "$discovered_host"; then
        job_error_log "ARP population failed - cannot determine IP addresses"
        return 1
    fi

    # Validate we found IPs for all VMs
    local missing_ips=()
    for vmid in "${!MAC_BY_VMDATA[@]}"; do
        if [[ -z "${IP_BY_MAC[$vmid]:-}" ]]; then
            missing_ips+=("$vmid")
        fi
    done

    if [[ ${#missing_ips[@]} -gt 0 ]]; then
        job_error_log "Could not find IPs for VMs: ${missing_ips[*]}"
        return 1
    fi

    local cp_ips=()
    local worker_ips=()

    # Sort VMIDs to ensure consistent ordering
    local sorted_vmids
    sorted_vmids=$(echo "${!IP_BY_MAC[@]}" | tr ' ' '\n' | sort -n)

    for vmid in $sorted_vmids; do
        local ip="${IP_BY_MAC[$vmid]}"
        if [[ "${NODE_ROLES[$vmid]}" == "control-plane" ]]; then
            cp_ips+=("$ip")
            step_info_log "Control plane VM $vmid -> $ip"
        else
            worker_ips+=("$ip")
            step_info_log "Worker VM $vmid -> $ip"
        fi
    done

    CONTROL_PLANE_IPS=$(IFS=' '; echo "${cp_ips[*]}")
    WORKER_IPS=$(IFS=' '; echo "${worker_ips[*]}")

    job_info_log "Discovery complete: ${#cp_ips[@]} control planes, ${#worker_ips[@]} workers"
    job_info_log "Control plane IPs: $CONTROL_PLANE_IPS"
    job_info_log "Worker IPs: $WORKER_IPS"

    [[ ${#cp_ips[@]} -gt 0 ]]
}

job_preflight_checks() {
    job_info_log "Pre-flight Checks"

    local all_passed=true

    for ip in "${CONTROL_PLANE_IPS_ARRAY[@]}" "${WORKER_IPS_ARRAY[@]}"; do
        if step_test_port "$ip" "50000" "2"; then
            step_info_log "$ip: reachable"
        else
            step_warn_log "$ip: not reachable"
            all_passed=false
        fi
    done

    $all_passed
}

job_manage_secrets() {
    job_info_log "Manage Secrets"

    if [[ -f "$SECRETS_FILE" ]]; then
        step_info_log "Using existing secrets: $SECRETS_FILE"
        return 0
    fi

    step_info_log "Generate new secrets"
    step_run_command "Generate Talos secrets" \
        talosctl gen secrets -o "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
    step_info_log "Secrets generated"
}

job_generate_configs() {
    job_info_log "Generate Node Configs"

    step_run_command "Generate base configurations" \
        talosctl gen config \
            --with-secrets "$SECRETS_FILE" \
            --kubernetes-version "$KUBERNETES_VERSION" \
            --talos-version "$TALOS_VERSION" \
            --install-image "$INSTALLER_IMAGE" \
            --additional-sans "${HAPROXY_IP},${CONTROL_PLANE_ENDPOINT},127.0.0.1" \
            "$CLUSTER_NAME" \
            "https://${CONTROL_PLANE_ENDPOINT}:6443"

    if [[ -f "${SCRIPT_DIR}/controlplane.yaml" ]]; then
        mv "${SCRIPT_DIR}/controlplane.yaml" "$SECRETS_DIR/"
        chmod 600 "$SECRETS_DIR/controlplane.yaml"
    fi
    if [[ -f "${SCRIPT_DIR}/worker.yaml" ]]; then
        mv "${SCRIPT_DIR}/worker.yaml" "$SECRETS_DIR/"
        chmod 600 "$SECRETS_DIR/worker.yaml"
    fi
    if [[ -f "${SCRIPT_DIR}/talosconfig" ]]; then
        mv "${SCRIPT_DIR}/talosconfig" "$TALOSCONFIG"
        chmod 600 "$TALOSCONFIG"
    fi

    detail_info_log "Base configs secured in $SECRETS_DIR"

    # Create temporary directory for patches
    local patch_dir="${NODES_DIR}/.patches"
    mkdir -p "$patch_dir"

    for ip in "${CONTROL_PLANE_IPS_ARRAY[@]}"; do
        local vmid=${VMID_BY_IP[$ip]}
        local patch_file="${patch_dir}/cp-${ip}.yaml"

        # Write patch to file instead of using here-string
        generate_cp_patch "$ip" "$vmid" > "$patch_file"

        step_run_command "Generate config for control plane $ip" \
            talosctl machineconfig patch \
                "$SECRETS_DIR/controlplane.yaml" \
                --patch "@${patch_file}" \
                --output "$NODES_DIR/node-cp-$ip.yaml"
    done

    for ip in "${WORKER_IPS_ARRAY[@]}"; do
        local vmid=${VMID_BY_IP[$ip]}
        local patch_file="${patch_dir}/worker-${ip}.yaml"

        # Write patch to file instead of using here-string
        generate_worker_patch "$ip" "$vmid" > "$patch_file"

        step_run_command "Generate config for worker $ip" \
            talosctl machineconfig patch \
                "$SECRETS_DIR/worker.yaml" \
                --patch "@${patch_file}" \
                --output "$NODES_DIR/node-worker-$ip.yaml"
    done

    # Clean up patch files
    rm -rf "$patch_dir"

    step_info_log "Node configs generated in $NODES_DIR"
}

job_apply_cluster_patches() {
    job_info_log "Apply Cluster Patches"

    step_info_log "Create cluster patch"
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
        step_run_command "Apply cluster patch to $ip" \
            talosctl machineconfig patch "${NODES_DIR}/node-cp-${ip}.yaml" \
            --patch "@${NODES_DIR}/cluster-patch.yaml" \
            --output "${NODES_DIR}/node-cp-${ip}.yaml"
    done

    rm -f "${NODES_DIR}/cluster-patch.yaml"

    step_info_log "Prepare StaticHostConfig"
    cat > "${NODES_DIR}/statichost-config.yaml" <<EOF
apiVersion: v1alpha1
kind: StaticHostConfig
name: ${HAPROXY_IP}
hostnames:
  - ${CONTROL_PLANE_ENDPOINT}
EOF

    if [[ -f "${SCRIPT_DIR}/talosconfig" ]]; then
        mv "${SCRIPT_DIR}/talosconfig" "$TALOSCONFIG"
        chmod 600 "$TALOSCONFIG"
    fi
}

job_deploy_control_planes() {
    job_info_log "Deploy Control Planes"

    local pids=()
    local -a failed_ips=()
    local -a all_ips=("${CONTROL_PLANE_IPS_ARRAY[@]}")
    local total=${#all_ips[@]}
    local running=0
    local i=0

    step_info_log "Deploying $total nodes sequentially"

    for ip in "${all_ips[@]}"; do
        local vmid=${VMID_BY_IP[$ip]}
        local config="$NODES_DIR/node-cp-$ip.yaml"

        step_info_log "Deploying control plane $ip (VM $vmid)"

        if step_apply_config "$ip" "$config" "$vmid" 5; then
            log_file_only "DEPLOY" "SUCCESS:$ip"
        else
            log_file_only "DEPLOY" "FAILED:$ip"
            failed_ips+=("$ip")
        fi
    done

    if [[ ${#failed_ips[@]} -gt 0 ]]; then
        step_error_log "Failed control planes: ${failed_ips[*]}"
        return 1
    fi

    step_info_log "Control plane deployment complete ($total/${#all_ips[@]} successful)"
}

job_deploy_workers() {
    job_info_log "Deploy Workers"

    local -a failed_ips=()
    local total=${#WORKER_IPS_ARRAY[@]}

    step_info_log "Deploying $total workers sequentially"

    for ip in "${WORKER_IPS_ARRAY[@]}"; do
        local vmid=${VMID_BY_IP[$ip]}
        local config="$NODES_DIR/node-worker-$ip.yaml"

        step_info_log "Deploying worker $ip (VM $vmid)"

        if step_apply_config "$ip" "$config" "$vmid" 5; then
            log_file_only "DEPLOY" "SUCCESS:$ip"
        else
            log_file_only "DEPLOY" "FAILED:$ip"
            failed_ips+=("$ip")
        fi
    done

    local success_count=$((total - ${#failed_ips[@]}))
    step_info_log "Worker deployment: $success_count/$total successful"

    if [[ ${#failed_ips[@]} -gt 0 ]]; then
        step_warn_log "Failed workers: ${failed_ips[*]}"
    fi

    step_info_log "Worker deployment complete"
}

job_wait_for_restart() {
    job_info_log "Wait for Node Restart"

    local timeout="${REBOOT_WAIT_TIME:-180}"
    local all_ready=false
    local -i start_time elapsed

    # STEP 1: Immediately rediscover nodes after reboot (IPs likely changed)
    step_info_log "Re-discovering nodes after reboot (IPs may have changed)..."

    if ! job_discover_vms "post-deploy"; then
        step_warn_log "Post-deploy rediscovery failed, using original IPs"
        # Restore original IPs from initial discovery
        CONTROL_PLANE_IPS="$ORIGINAL_CONTROL_PLANE_IPS"
        WORKER_IPS="$ORIGINAL_WORKER_IPS"
    fi

    # Update arrays with potentially new IPs
    IFS=' ' read -r -a CONTROL_PLANE_IPS_ARRAY <<< "$CONTROL_PLANE_IPS"
    IFS=' ' read -r -a WORKER_IPS_ARRAY <<< "$WORKER_IPS"

    step_info_log "Control plane IPs after rediscovery: ${CONTROL_PLANE_IPS_ARRAY[*]}"
    step_info_log "Worker IPs after rediscovery: ${WORKER_IPS_ARRAY[*]}"

    # STEP 2: Now test ports with the correct (potentially new) IPs
    local -a all_nodes=("${CONTROL_PLANE_IPS_ARRAY[@]}" "${WORKER_IPS_ARRAY[@]}")
    local total_nodes=${#all_nodes[@]}

    step_info_log "Polling $total_nodes nodes for Talos API readiness (timeout: ${timeout}s)"

    start_time=$(date +%s)
    while true; do
        elapsed=$(($(date +%s) - start_time))

        if [[ $elapsed -ge $timeout ]]; then
            step_warn_log "Timeout waiting for nodes to restart (${timeout}s)"
            break
        fi

        all_ready=true
        local ready_count=0

        for ip in "${all_nodes[@]}"; do
            if step_test_port "$ip" "50000" "2"; then
                ready_count=$((ready_count + 1))
            else
                all_ready=false
            fi
        done

        if $all_ready; then
            step_info_log "All $total_nodes nodes ready after ${elapsed}s"
            break
        fi

        detail_info_log "Waiting... $ready_count/$total_nodes nodes ready (${elapsed}s elapsed)"
        sleep 5
    done
}

job_bootstrap_cluster() {
    job_info_log "Bootstrap Cluster"

    job_diagnose_nodes

    local bootstrap_node="${CONTROL_PLANE_IPS_ARRAY[0]}"
    step_info_log "Using control plane node $bootstrap_node for bootstrap (first in array: ${CONTROL_PLANE_IPS_ARRAY[*]})"

    step_wait_for_api "$bootstrap_node" 300 "secure" || {
        step_error_log "Control plane API never became available at $bootstrap_node"
        return 1
    }

    step_info_log "Configure Talos Client"
    if [[ -f "$TALOSCONFIG" ]]; then
        step_run_command "Merge talosconfig" talosctl config merge "$TALOSCONFIG"
    else
        step_warn_log "talosconfig not found in $SECRETS_DIR, checking script dir..."
        step_run_command "Merge talosconfig" talosctl config merge talosconfig
    fi
    step_run_command "Set talosctl endpoint" talosctl config endpoint "$bootstrap_node"

    step_info_log "Apply StaticHostConfig"
    for ip in "${CONTROL_PLANE_IPS_ARRAY[@]}" "${WORKER_IPS_ARRAY[@]}"; do
        talosctl patch machineconfig --nodes "$ip" --patch-file "${NODES_DIR}/statichost-config.yaml" >> "$LOG_FILE" 2>&1 || \
            step_warn_log "StaticHostConfig failed for $ip (may already exist)"
    done
    rm -f "${NODES_DIR}/statichost-config.yaml"

    step_info_log "Bootstrap etcd"

    local etcd_members
    step_info_log "Checking existing etcd members (10s timeout)..."
    if etcd_members=$(timeout 10 talosctl etcd members --nodes "$bootstrap_node" 2>&1); then
        step_warn_log "etcd appears to already have members - may need manual reset"
        log_file_only "ETCD-MEMBERS" "$etcd_members"
    else
        # Log the failure but don't fail - this is just a check
        log_file_only "ETCD-CHECK" "etcd members check failed or timed out: $?"
    fi
    step_run_command "Bootstrap etcd" talosctl bootstrap --nodes "$bootstrap_node"

    # Stage 1: Wait for etcd to be healthy (this is critical)
    local etcd_timeout=60
    local etcd_start=$(date +%s)
    local etcd_healthy=false
    step_info_log "Stage 1: Wait for etcd health ($etcd_timeout)s"

    while true; do
        local etcd_elapsed=$(($(date +%s) - etcd_start))

        # Capture output to a temp file so we can both log it and check it
        local health_output
        health_output=$(talosctl health --endpoints "$bootstrap_node" \
            --nodes "${CONTROL_PLANE_IPS_ARRAY[*]}" \
            --wait-timeout=10s 2>&1) || true

        # Log the output for debugging
        if [[ -n "$health_output" ]]; then
            log_file_only "HEALTH-CHECK" "$health_output"
        fi

        if echo "$health_output" | grep -q "waiting for etcd to be healthy: OK"; then
            etcd_healthy=true
            step_info_log "etcd is healthy (${etcd_elapsed}s)"
            break
        fi

        if [[ $etcd_elapsed -ge $etcd_timeout ]]; then
            step_warn_log "etcd health check timeout, continuing anyway..."
            break
        fi

        detail_info_log "Waiting for etcd... (${etcd_elapsed}s)"
        sleep 5
    done

    # Stage 2: Wait for kubelet on all nodes
    step_info_log "Stage 2: Wait for kubelet health (120s)"
    local kubelet_timeout=120
    local kubelet_start=$(date +%s)

    while true; do
        local kubelet_elapsed=$(($(date +%s) - kubelet_start))

        # Check if all nodes report kubelet ready
        local all_kubelets_ready=true
        local health_output=""

        for ip in "${CONTROL_PLANE_IPS_ARRAY[@]}"; do
            local node_health
            node_health=$(talosctl health --endpoints "$bootstrap_node" --nodes "$ip" --wait-timeout=5s 2>&1) || true
            health_output+="$node_health"$'\n'

            if ! echo "$node_health" | grep -q "waiting for kubelet to be healthy: OK"; then
                all_kubelets_ready=false
            fi
        done

        # Log accumulated health output
        if [[ -n "$health_output" ]]; then
            log_file_only "HEALTH-CHECK-KUBELET" "$health_output"
        fi

        if $all_kubelets_ready; then
            step_info_log "All kubelets healthy (${kubelet_elapsed}s)"
            break
        fi

        if [[ $kubelet_elapsed -ge $kubelet_timeout ]]; then
            step_warn_log "Kubelet health check timeout, continuing..."
            break
        fi

        detail_info_log "Waiting for kubelets... (${kubelet_elapsed}s)"
        sleep 5
    done

    # Stage 3: Check Kubernetes API (quick check only, don't block)
    step_info_log "Stage 3: Quick Kubernetes API check (30s)"
    local k8s_timeout=30  # Reduced from 180
    local k8s_start=$(date +%s)
    local k8s_ready=false

    while true; do
        local k8s_elapsed=$(($(date +%s) - k8s_start))

        # Try via endpoint if DNS is working
        if curl -sk "https://${CONTROL_PLANE_ENDPOINT}:6443/healthz" &>/dev/null; then
            k8s_ready=true
            step_info_log "Kubernetes API ready via endpoint (${k8s_elapsed}s)"
            break
        fi

        if [[ $k8s_elapsed -ge $k8s_timeout ]]; then
            step_info_log "K8s API not ready yet (expected), will verify via HAProxy"
            break
        fi

        detail_info_log "Waiting for K8s API... (${k8s_elapsed}s)"
        sleep 5
    done

    # Stage 4: Full health check (best effort - failure doesn't affect exit code)
    step_info_log "Stage 4: Full cluster health check (optional)"
    # Run directly without step_run_command to prevent exit code propagation
    local health_output
    if health_output=$(talosctl health --endpoints "$bootstrap_node" --nodes "$bootstrap_node" --wait-timeout=60s 2>&1); then
        log_file_only "HEALTH-CHECK-FINAL" "$health_output"
        step_info_log "Full health check passed"
    else
        log_file_only "HEALTH-CHECK-FINAL" "$health_output"
        step_warn_log "Full health check failed (see log), but core services are up"
    fi

    step_info_log "Switch to HAProxy endpoint"
    step_run_command "Switch endpoint to HAProxy" talosctl config endpoint "$HAPROXY_IP"

    step_info_log "Update HAProxy with current control plane IPs"
    update_haproxy "${CONTROL_PLANE_IPS_ARRAY[@]}" || step_warn_log "HAProxy update failed"

    # Verify via HAProxy with shorter timeout
    if step_run_command "Verify health via HAProxy" \
        talosctl health --endpoints "$HAPROXY_IP" --nodes "$HAPROXY_IP" --wait-timeout=30s; then
        step_info_log "Cluster accessible via HAProxy ($HAPROXY_IP)"
    else
        step_warn_log "Cluster healthy via direct IP but not via HAProxy (DNS may need time)"
    fi

    KUBECONFIG_PATH="${HOME}/.kube/config-${CLUSTER_NAME}"
    mkdir -p "$(dirname "$KUBECONFIG_PATH")"

    if step_run_command "Retrieve kubeconfig" talosctl kubeconfig "$KUBECONFIG_PATH" --nodes "$bootstrap_node"; then
        chmod 600 "$KUBECONFIG_PATH"
        log_file_only "KUBECONFIG" "Saved to $KUBECONFIG_PATH"
    fi

    save_state

    # Final status
    if $k8s_ready; then
        step_info_log "Cluster bootstrap completed successfully"
    else
        step_warn_log "Cluster bootstrap completed with warnings - K8s API may need more time"
        step_info_log "You can check status later with: kubectl --kubeconfig $KUBECONFIG_PATH get nodes"
    fi
}

job_verify_cluster() {
    job_info_log "Verify Cluster"

    step_info_log "Check Kubernetes API"
    if kubectl --kubeconfig "$KUBECONFIG_PATH" cluster-info &>/dev/null; then
        step_info_log "Kubernetes API is ready"
    else
        step_warn_log "Kubernetes API not yet ready"
    fi

    step_info_log "Check node status"
    kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes -o wide || true
}

job_diagnose_nodes() {
    job_info_log "Pre-Bootstrap Diagnostics"

    for ip in "${CONTROL_PLANE_IPS_ARRAY[@]}"; do
        step_info_log "Diagnosing $ip"

        # Test port with verbose output
        if timeout 5 bash -c "echo >/dev/tcp/$ip/50000" 2>/dev/null; then
            step_info_log "  Port 50000: OPEN"
        else
            step_error_log "  Port 50000: CLOSED"
        fi

        # Try talosctl version (insecure)
        local version_output
        version_output=$(talosctl version --nodes "$ip" --insecure 2>&1) || true
        if [[ -n "$version_output" ]]; then
            step_info_log "  Talos version (insecure): $(echo "$version_output" | head -1)"
        else
            step_warn_log "  Talos version (insecure): No response"
        fi

        # Try secure API
        local secure_output
        secure_output=$(talosctl version --nodes "$ip" --endpoints "$ip" 2>&1) || true
        if [[ -n "$secure_output" ]]; then
            step_info_log "  Talos API (secure): RESPONDING"
        else
            step_warn_log "  Talos API (secure): No response"
        fi
    done
}

# ==================== STAGE LEVEL FUNCTIONS ====================

stage_environment() {
    stage_info_log "Environment Setup"

    job_init_directories
    job_detect_environment
    check_prerequisites
    job_parse_terraform || {
        step_warn_log "Using defaults (terraform.tfvars not found)"
    }
    job_display_config
}

stage_discovery() {
    stage_info_log "Node Discovery"

    if [[ "${NO_DISCOVER:-false}" != "true" ]]; then
        if ! job_discover_vms "initial"; then
            stage_fatal_log "Discovery failed - cannot proceed"
        fi
    fi

    if [[ -z "$CONTROL_PLANE_IPS" ]]; then
        stage_fatal_log "No control plane IPs found. Set CONTROL_PLANE_IPS or ensure discovery works."
    fi

    IFS=' ' read -r -a CONTROL_PLANE_IPS_ARRAY <<< "$CONTROL_PLANE_IPS"
    IFS=' ' read -r -a WORKER_IPS_ARRAY <<< "$WORKER_IPS"
    ORIGINAL_CONTROL_PLANE_IPS="$CONTROL_PLANE_IPS"
    ORIGINAL_WORKER_IPS="$WORKER_IPS"

    if ! validate_environment; then
        stage_fatal_log "Environment validation failed"
    fi

    if ! job_preflight_checks; then
        stage_warn_log "Some pre-flight checks failed"
    fi
}

stage_configuration() {
    stage_info_log "Configuration Generation"

    job_manage_secrets
    job_generate_configs
    job_apply_cluster_patches

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        step_info_log "DRY-RUN: Configuration files generated in ${NODES_DIR}"
        save_state
        exit 0
    fi
}

stage_deployment() {
    stage_info_log "Deployment"

    step_info_log "Summary:"
    detail_info_log "Control Planes: ${#CONTROL_PLANE_IPS_ARRAY[@]} nodes"
    detail_info_log "Workers: ${#WORKER_IPS_ARRAY[@]} nodes"
    detail_info_log "Parallel: Yes (CP: $MAX_PARALLEL_CONTROL_PLANES, Worker: $MAX_PARALLEL_WORKERS)"

    if ! confirm_proceed "Deploy cluster with these settings?"; then
        step_info_log "Deployment cancelled by user"
        exit 0
    fi

    job_deploy_control_planes || {
        stage_fatal_log "Control plane deployment failed"
    }

    job_deploy_workers

    update_haproxy "${CONTROL_PLANE_IPS_ARRAY[@]}" || step_warn_log "HAProxy update failed"
    check_haproxy_status
}

stage_post_deploy() {
    stage_info_log "Post-Deployment"

    job_wait_for_restart

    job_info_log "Using rediscovered IPs for bootstrap:"
    step_info_log "Control planes: ${CONTROL_PLANE_IPS_ARRAY[*]}"
    step_info_log "Workers: ${WORKER_IPS_ARRAY[*]}"

    job_bootstrap_cluster
    job_verify_cluster
}

# ==================== PLAN LEVEL FUNCTIONS ====================

plan_bootstrap() {
    plan_info_log "Bootstrap Execution"

    stage_environment
    stage_discovery
    stage_configuration
    stage_deployment
    stage_post_deploy

    plan_info_log "Bootstrap Complete"
    step_info_log "Kubeconfig: export KUBECONFIG=$KUBECONFIG_PATH"
    step_info_log "Talos Dashboard: talosctl dashboard --endpoints $HAPROXY_IP "
    log_file_only "COMPLETE" "Bootstrap finished successfully"
}

plan_discover() {
    plan_info_log "Discovery Only"

    stage_info_log "Node Discovery"

    job_init_directories
    job_detect_environment
    job_parse_terraform || {
        stage_error_log "Failed to parse terraform configuration"
        exit 1
    }
    job_display_config

    if ! job_discover_vms "initial"; then
        stage_error_log "Discovery failed"
        exit 1
    fi

    echo
    echo "CONTROL_PLANE_IPS=\"${CONTROL_PLANE_IPS}\""
    echo "WORKER_IPS=\"${WORKER_IPS}\""
}

plan_status() {
    plan_info_log "Show Status"
    load_state 2>/dev/null || {
        plan_error_log "No state file"
        exit 1
    }

    if command -v jq &>/dev/null; then
        echo "State: $STATE_FILE"
        jq -r '"Timestamp: \(.timestamp)", "Control Planes:", (.control_planes[] | "  \(.ip) (VM \(.vmid))"), "Workers:", (.workers[] | "  \(.ip) (VM \(.vmid))")' "$STATE_FILE"
    else
        cat "$STATE_FILE"
    fi
}

plan_logs() {
    plan_info_log "Collect Logs"
    load_state 2>/dev/null || {
        plan_error_log "No state file"
        exit 1
    }

    local cp_ips worker_ips
    cp_ips=$(jq -r '.control_planes[].ip' "$STATE_FILE" 2>/dev/null)
    worker_ips=$(jq -r '.workers[].ip' "$STATE_FILE" 2>/dev/null)

    for ip in $cp_ips $worker_ips; do
        collect_node_logs "$ip"
    done
    check_haproxy_status
}

plan_cleanup() {
    plan_info_log "Cleanup"

    stage_info_log "Remove Generated Files"

    job_info_log "Clean node configurations"

    local removed_count=0
    if [[ -d "$NODES_DIR" ]]; then
        removed_count=$(find "$NODES_DIR" -type f 2>/dev/null | wc -l)
        rm -rf "${NODES_DIR:?}/"*
    fi

    rm -f "${SCRIPT_DIR}"/node-*.yaml \
          "${SCRIPT_DIR}"/patch-*.yaml \
          "${SCRIPT_DIR}"/controlplane.yaml \
          "${SCRIPT_DIR}"/worker.yaml \
          "${SCRIPT_DIR}"/talosconfig \
          "${SCRIPT_DIR}"/statichost-config.yaml \
          "${SCRIPT_DIR}"/cluster-patch.yaml 2>/dev/null || true

    step_info_log "Cleanup complete (removed ${removed_count} files from nodes/)"
    step_info_log "Secrets preserved in ${SECRETS_DIR}"
}

plan_reset() {
    plan_info_log "Full Reset"

    stage_info_log "Reset Cluster"

    job_info_log "Confirm reset"

    if ! confirm_proceed "Permanently delete all configs, state, and secrets for cluster ${CLUSTER_NAME}?"; then
        step_info_log "Reset cancelled"
        exit 0
    fi

    job_info_log "Remove cluster data"

    if [[ -d "$CLUSTER_DIR" ]]; then
        rm -rf "${CLUSTER_DIR:?}"
        step_info_log "Removed cluster directory: $CLUSTER_DIR"
    fi

    rm -f "${SCRIPT_DIR}"/node-*.yaml \
          "${SCRIPT_DIR}"/patch-*.yaml \
          "${SCRIPT_DIR}"/controlplane.yaml \
          "${SCRIPT_DIR}"/worker.yaml \
          "${SCRIPT_DIR}"/talosconfig 2>/dev/null || true

    step_info_log "Reset complete for cluster ${CLUSTER_NAME}"
}

plan_haproxy() {
    plan_info_log "Update HAProxy Configuration"

    stage_info_log "Configure HAProxy"

    job_info_log "Update backend servers"

    update_haproxy "$@"
}

# ==================== HELPER FUNCTIONS ====================

check_prerequisites() {
    job_info_log "Check Prerequisites"

    local missing=()
    local version_issues=()

    # Required binaries
    for cmd in talosctl ssh scp; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    # Optional but recommended
    if ! command -v jq &>/dev/null; then
        step_warn_log "jq not found - state management will be limited"
    fi

    # Check talosctl version compatibility
    if command -v talosctl &>/dev/null; then
        local talos_version
        talos_version=$(talosctl version --client 2>/dev/null | grep -oP 'Tag:\s*\K[^[:space:]]+' | head -1 || echo "unknown")
        detail_info_log "talosctl version: $talos_version"

        # Warn if major version mismatch
        if [[ "$talos_version" != "unknown" && ! "$talos_version" =~ ^${TALOS_VERSION%%.*} ]]; then
            step_warn_log "talosctl version ($talos_version) may not match target ($TALOS_VERSION)"
        fi
    fi

    # Check SSH key is available
    if ! ssh-add -l &>/dev/null; then
        step_warn_log "No SSH keys loaded in ssh-agent"
        # Check for default key files
        if [[ ! -f "$HOME/.ssh/id_rsa" && ! -f "$HOME/.ssh/id_ed25519" ]]; then
            step_warn_log "No default SSH key found"
        fi
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        step_fatal_log "Missing required tools: ${missing[*]}"
    fi

    step_info_log "Prerequisites satisfied"
}

collect_node_logs() {
    local ip="$1"
    local log_file="${LOG_DIR}/node-${ip}-$(date +%Y%m%d_%H%M%S).log"

    step_info_log "Collect logs from $ip"
    talosctl logs kubelet --nodes "$ip" 2>/dev/null | head -100 > "$log_file" || true
    talosctl dmesg --nodes "$ip" 2>/dev/null | tail -100 >> "$log_file" || true

    log_file_only "NODE-LOGS" "Saved to $log_file"
}

populate_arp_table() {
    local host="$1"

    step_info_log "Populating ARP table"

    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "${TF_PROXMOX_SSH_USER}@$host" \
        "ip -s -s neigh flush all" >/dev/null 2>&1 || true

    local arp_populated=false
    local arp_attempts=0
    local max_arp_attempts=5
    local parallel_pings=255

    while [[ $arp_attempts -lt $max_arp_attempts && "$arp_populated" == "false" ]]; do
        arp_attempts=$(($arp_attempts + 1))
        detail_info_log "ARP population attempt $arp_attempts/$max_arp_attempts"

        # Clear associative arrays to start fresh each attempt
        IP_BY_MAC=()
        VMID_BY_IP=()

        # Rate-limited ping sweep
        ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
            "${TF_PROXMOX_SSH_USER}@$host" \
            "seq 1 254 | xargs -P $parallel_pings -I{} ping -c 1 -W 1 192.168.1.{} >/dev/null 2>&1 || true" \
            2>/dev/null || true

        sleep 3

        local arp_output
        arp_output=$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
            "${TF_PROXMOX_SSH_USER}@$host" \
            "cat /proc/net/arp" 2>/dev/null) || continue

        local found_macs=0
        while IFS= read -r line; do
            [[ "$line" =~ ^IP[[:space:]]+HW ]] && continue
            local ip mac
            ip=$(echo "$line" | awk '{print $1}')
            mac=$(echo "$line" | awk '{print $4}' | tr '[:lower:]' '[:upper:]')
            [[ "$mac" == "00:00:00:00:00:00" ]] && continue
            [[ -z "$mac" || "$mac" == "INCOMPLETE" ]] && continue

            for vmid in "${!MAC_BY_VMDATA[@]}"; do
                local vm_mac="${MAC_BY_VMDATA[$vmid]}"
                if [[ "$mac" == "$vm_mac" && -n "$ip" ]]; then
                    IP_BY_MAC["$vmid"]="$ip"
                    VMID_BY_IP["$ip"]="$vmid"
                    found_macs=$(($found_macs + 1))
                    step_info_log "Discovered ${NODE_ROLES[$vmid]}: $vmid -> $ip"
                    break
                fi
            done
        done <<< "$arp_output"

        if [[ $found_macs -ge ${#MAC_BY_VMDATA[@]} ]]; then
            arp_populated=true
        else
            detail_info_log "Found $found_macs/${#MAC_BY_VMDATA[@]} VMs in ARP, retrying..."
            sleep 5
        fi
    done

    [[ "$arp_populated" == "true" ]]
}

generate_cp_patch() {
    local ip="$1"
    local vmid="$2"
    local nic="${NODE_INTERFACES[$ip]:-$DEFAULT_NETWORK_INTERFACE}"
    local disk="${NODE_DISKS[$ip]:-$DEFAULT_DISK}"

    cat <<EOF
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
EOF
}

generate_worker_patch() {
    local ip="$1"
    local vmid="$2"
    local nic="${NODE_INTERFACES[$ip]:-$DEFAULT_NETWORK_INTERFACE}"
    local disk="${NODE_DISKS[$ip]:-$DEFAULT_DISK}"

    cat <<EOF
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
EOF
}

validate_environment() {
    local valid=true

    if [[ ${#CONTROL_PLANE_IPS_ARRAY[@]} -eq 0 ]]; then
        step_error_log "No control plane IPs"
        valid=false
    fi

    if [[ ${#CONTROL_PLANE_IPS_ARRAY[@]} -lt 1 ]]; then
        step_error_log "At least 1 control plane required"
        valid=false
    fi

    if [[ ${#CONTROL_PLANE_IPS_ARRAY[@]} -gt 1 && $((${#CONTROL_PLANE_IPS_ARRAY[@]} % 2)) -eq 0 ]]; then
        step_warn_log "Even number of control planes (${#CONTROL_PLANE_IPS_ARRAY[@]}) - etcd prefers odd numbers"
    fi

    for ip in "${CONTROL_PLANE_IPS_ARRAY[@]}"; do
        if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            step_error_log "Invalid control plane IP: $ip"
            valid=false
        fi
    done

    for ip in "${WORKER_IPS_ARRAY[@]}"; do
        if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            step_error_log "Invalid worker IP: $ip"
            valid=false
        fi
    done

    # Check for required files
    if [[ ! -f "$SECRETS_FILE" && "${DRY_RUN:-false}" != "true" ]]; then
        step_info_log "Secrets will be generated: $SECRETS_FILE"
    fi

    $valid
}

save_state() {
    local timestamp
    timestamp=$(date -Iseconds)

    # Check if jq is available
    if ! command -v jq &>/dev/null; then
        step_warn_log "jq not available, using fallback state format"
        # Fallback to simple format
        cat > "$STATE_FILE" <<EOF
{
  "timestamp": "$timestamp",
  "cluster_name": "$CLUSTER_NAME",
  "control_planes": $(printf '%s\n' "${CONTROL_PLANE_IPS_ARRAY[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]"),
  "workers": $(printf '%s\n' "${WORKER_IPS_ARRAY[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]"),
  "haproxy_ip": "$HAPROXY_IP",
  "control_plane_endpoint": "$CONTROL_PLANE_ENDPOINT"
}
EOF
        return
    fi

    # Build control planes array - match IPs to VMIDs properly
    local cp_array="[]"
    if [[ ${#CONTROL_PLANE_IPS_ARRAY[@]} -gt 0 ]]; then
        # Create array of ip:vmid pairs for control planes
        local cp_pairs=()
        for ip in "${CONTROL_PLANE_IPS_ARRAY[@]}"; do
            local vmid="${VMID_BY_IP[$ip]:-unknown}"
            cp_pairs+=("$ip:$vmid")
        done
        cp_array=$(jq -n --arg pairs "${cp_pairs[*]}" '
            ($pairs | split(" ")) as $pair_list |
            [range($pair_list | length) |
                ($pair_list[.] | split(":")) as $parts |
                {ip: $parts[0], vmid: $parts[1]}
            ]
        ')
    fi

    # Build workers array - match IPs to VMIDs properly
    local worker_array="[]"
    if [[ ${#WORKER_IPS_ARRAY[@]} -gt 0 ]]; then
        # Create array of ip:vmid pairs for workers
        local worker_pairs=()
        for ip in "${WORKER_IPS_ARRAY[@]}"; do
            local vmid="${VMID_BY_IP[$ip]:-unknown}"
            worker_pairs+=("$ip:$vmid")
        done
        worker_array=$(jq -n --arg pairs "${worker_pairs[*]}" '
            ($pairs | split(" ")) as $pair_list |
            [range($pair_list | length) |
                ($pair_list[.] | split(":")) as $parts |
                {ip: $parts[0], vmid: $parts[1]}
            ]
        ')
    fi

    # Construct final JSON
    jq -n \
        --arg timestamp "$timestamp" \
        --arg cluster_name "$CLUSTER_NAME" \
        --argjson control_planes "$cp_array" \
        --argjson workers "$worker_array" \
        --arg haproxy_ip "$HAPROXY_IP" \
        --arg control_plane_endpoint "$CONTROL_PLANE_ENDPOINT" \
        '{
            timestamp: $timestamp,
            cluster_name: $cluster_name,
            control_planes: $control_planes,
            workers: $workers,
            haproxy_ip: $haproxy_ip,
            control_plane_endpoint: $control_plane_endpoint
        }' > "$STATE_FILE"

    chmod 600 "$STATE_FILE"
}

load_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        step_error_log "jq required for state loading"
        return 1
    fi

    # Validate JSON
    if ! jq empty "$STATE_FILE" 2>/dev/null; then
        step_error_log "State file is corrupted: $STATE_FILE"
        return 1
    fi

    CLUSTER_NAME=$(jq -r '.cluster_name // empty' "$STATE_FILE")
    CONTROL_PLANE_IPS=$(jq -r '[.control_planes[].ip] | join(" ")' "$STATE_FILE" 2>/dev/null || echo "")
    WORKER_IPS=$(jq -r '[.workers[].ip] | join(" ")' "$STATE_FILE" 2>/dev/null || echo "")
    HAPROXY_IP=$(jq -r '.haproxy_ip // empty' "$STATE_FILE")
    CONTROL_PLANE_ENDPOINT=$(jq -r '.control_plane_endpoint // empty' "$STATE_FILE")

    # Rebuild arrays
    IFS=' ' read -r -a CONTROL_PLANE_IPS_ARRAY <<< "$CONTROL_PLANE_IPS"
    IFS=' ' read -r -a WORKER_IPS_ARRAY <<< "$WORKER_IPS"

    # Rebuild VMID mappings if available
    if [[ -f "$STATE_FILE" ]]; then
        local cp_vmids
        cp_vmids=$(jq -r '.control_planes[] | "\(.ip):\(.vmid)"' "$STATE_FILE" 2>/dev/null)
        while IFS=: read -r ip vmid; do
            [[ -n "$ip" && -n "$vmid" ]] && VMID_BY_IP["$ip"]="$vmid"
        done <<< "$cp_vmids"

        local worker_vmids
        worker_vmids=$(jq -r '.workers[] | "\(.ip):\(.vmid)"' "$STATE_FILE" 2>/dev/null)
        while IFS=: read -r ip vmid; do
            [[ -n "$ip" && -n "$vmid" ]] && VMID_BY_IP["$ip"]="$vmid"
        done <<< "$worker_vmids"
    fi

    [[ -n "$CLUSTER_NAME" ]]
}

check_haproxy_status() {
    job_info_log "Check HAProxy Status"

    if curl -s -u "${HAPROXY_STATS_USERNAME}:${HAPROXY_STATS_PASSWORD}" "http://${HAPROXY_IP}:9000/stats" > /dev/null 2>&1; then
        step_info_log "HAProxy stats accessible at http://${HAPROXY_IP}:9000/stats"
    else
        step_warn_log "HAProxy stats not accessible"
    fi
}

update_haproxy() {
    local ips=()

    # Handle both: update_haproxy "ip1 ip2 ip3" AND update_haproxy ip1 ip2 ip3
    if [[ $# -eq 1 && "$1" =~ [[:space:]] ]]; then
        read -ra ips <<< "$1"
    else
        ips=("$@")
    fi

    if [[ ${#ips[@]} -eq 0 ]]; then
        step_warn_log "No IPs provided to update_haproxy"
        return 1
    fi

    for ip in "${ips[@]}"; do
        if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            step_error_log "Invalid IP address: $ip"
            return 1
        fi
    done

    step_info_log "Generate HAProxy configuration"
    step_info_log "Backend servers: ${ips[*]}"

    local haproxy_cfg
    haproxy_cfg=$(mktemp /tmp/haproxy.cfg.XXXXXX) || {
        step_error_log "Failed to create temporary file"
        return 1
    }

    # Use double quotes for the heredoc delimiter to allow variable expansion
    cat > "$haproxy_cfg" <<EOFCFG
# ==================== GLOBAL ====================
global
    log /dev/log local0 info
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn 32000
    ulimit-n 65535
    nbthread 4
    cpu-map auto:1/1-4 0-3
    tune.ssl.default-dh-param 2048

# ==================== DEFAULTS ====================
defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    option tcp-smart-connect
    option redispatch
    option tcp-check
    retries 3
    timeout connect 5s
    timeout client 30s
    timeout server 30s
    timeout check 5s
    maxconn 32000

# ==================== STATS PAGE ====================
listen stats
    bind ${HAPROXY_IP}:9000
    mode http
    stats enable
    stats uri /
    stats refresh 5s
    stats show-legends
    stats admin if TRUE
    stats auth ${HAPROXY_STATS_USERNAME}:${HAPROXY_STATS_PASSWORD}

# ==================== KUBERNETES API ====================
frontend k8s-apiserver
    bind ${HAPROXY_IP}:6443
    mode tcp
    option tcplog
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    default_backend k8s-controlplane

backend k8s-controlplane
    mode tcp
    balance leastconn
    option tcp-check
    tcp-check connect port 6443
    default-server inter 5s fall 3 rise 2
EOFCFG

    for ip in "${ips[@]}"; do
        local server_name="talos-cp-${ip##*.}"
        printf '    server %s %s:6443 check\n' "$server_name" "$ip" >> "$haproxy_cfg"
    done

    # Continue with double-quoted heredoc
    cat >> "$haproxy_cfg" <<EOFCFG

# ==================== TALOS API ====================
frontend talos-apiserver
    bind ${HAPROXY_IP}:50000
    mode tcp
    option tcplog
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    default_backend talos-controlplane

backend talos-controlplane
    mode tcp
    balance leastconn
    option tcp-check
    tcp-check connect port 50000
    timeout connect 10s
    timeout server 60s
    default-server inter 5s fall 3 rise 2
EOFCFG

    for ip in "${ips[@]}"; do
        local server_name="talos-cp-${ip##*.}"
        printf '    server %s %s:50000 check\n' "$server_name" "$ip" >> "$haproxy_cfg"
    done

    step_info_log "Copy configuration to HAProxy server"
    detail_info_log "Target: ${HAPROXY_LOGIN_USERNAME}@${HAPROXY_IP}"

    if ! scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
         "$haproxy_cfg" "${HAPROXY_LOGIN_USERNAME}@${HAPROXY_IP}:/tmp/haproxy.cfg.new" >> "$LOG_FILE" 2>&1; then
        step_error_log "Failed to copy config to HAProxy server"
        rm -f "$haproxy_cfg"
        return 1
    fi

    step_info_log "Install and validate configuration"

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)

    # Backup and install with atomic operation
    if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
         "${HAPROXY_LOGIN_USERNAME}@${HAPROXY_IP}" "
        set -e
        sudo cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.backup.${timestamp}
        sudo mv /tmp/haproxy.cfg.new /etc/haproxy/haproxy.cfg
    " >> "$LOG_FILE" 2>&1; then
        step_error_log "Failed to install new configuration"
        rm -f "$haproxy_cfg"
        return 1
    fi

    # Validate config
    if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
         "${HAPROXY_LOGIN_USERNAME}@${HAPROXY_IP}" "sudo haproxy -c -f /etc/haproxy/haproxy.cfg" >> "$LOG_FILE" 2>&1; then
        step_error_log "HAProxy configuration validation failed"
        step_info_log "Restoring backup configuration..."

        ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
            "${HAPROXY_LOGIN_USERNAME}@${HAPROXY_IP}" "sudo cp /etc/haproxy/haproxy.cfg.backup.${timestamp} /etc/haproxy/haproxy.cfg" >> "$LOG_FILE" 2>&1 || true

        # Attempt to reload old config
        ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
            "${HAPROXY_LOGIN_USERNAME}@${HAPROXY_IP}" "sudo systemctl reload haproxy" >> "$LOG_FILE" 2>&1 || true

        rm -f "$haproxy_cfg"
        return 1
    fi

    # Reload HAProxy
    if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
         "${HAPROXY_LOGIN_USERNAME}@${HAPROXY_IP}" "sudo systemctl reload haproxy || sudo systemctl start haproxy" >> "$LOG_FILE" 2>&1; then
        step_error_log "Failed to reload HAProxy"
        rm -f "$haproxy_cfg"
        return 1
    fi

    # Explicit cleanup
    rm -f "$haproxy_cfg"

    step_info_log "HAProxy updated successfully"
    detail_info_log "Backup: /etc/haproxy/haproxy.cfg.backup.${timestamp}"
    detail_info_log "Stats: http://${HAPROXY_IP}:9000"

    return 0
}

confirm_proceed() {
    local msg="${1:-Proceed?}"
    local response

    echo -en "${C_TIMESTAMP}[$(date '+%H:%M:%S')]${C_RESET} ${SEV_COLORS[WARN]}[INPUT]${C_RESET} ${msg} (y/N) "
    read -n 1 -r response
    echo ""

    log_file_only "INPUT" "Prompt: '$msg' Response: '$response'"

    [[ "$response" =~ ^[Yy]$ ]]
}

show_help() {
    echo "Usage: $0 {bootstrap|discover|status|logs|cleanup|reset|haproxy} [options]"
    echo ""
    echo "Commands:"
    echo "  bootstrap    Run the full bootstrap process"
    echo "  discover     Only run node discovery and output IPs"
    echo "  status       Show saved cluster state"
    echo "  logs         Collect diagnostic logs from all nodes"
    echo "  cleanup      Remove generated configuration files (keep secrets)"
    echo "  reset        Full reset (delete all configs, state, and secrets)"
    echo "  haproxy      Update HAProxy configuration"
    echo ""
    echo "Bootstrap Options:"
    echo "  --no-discover      Skip auto-discovery (use CONTROL_PLANE_IPS env var)"
    echo "  --dry-run          Generate configs but don't deploy"
    echo "  --skip-preflight   Skip pre-flight connectivity checks"
    echo ""
    echo "Environment Variables:"
    echo "  CLUSTER_NAME                  Cluster name (default: proxmox-talos-test)"
    echo "  CONTROL_PLANE_ENDPOINT        DNS endpoint (default: \$CLUSTER_NAME.jdwkube.com)"
    echo "  HAPROXY_IP                    HAProxy IP (default: 192.168.1.237)"
    echo "  CONTROL_PLANE_IPS             Space-separated list of CP IPs (auto-discovered if not set)"
    echo "  WORKER_IPS                    Space-separated list of worker IPs (auto-discovered if not set)"
    echo "  KUBERNETES_VERSION            K8s version (default: v1.34.0)"
    echo "  TALOS_VERSION                 Talos version (default: v1.12.1)"
    echo "  INSTALLER_IMAGE               Talos installer image"
    echo "  DEFAULT_NETWORK_INTERFACE     NIC for nodes (default: eth0)"
    echo "  DEFAULT_DISK                  Disk for install (default: sda)"
    echo "  VERBOSE=true                  Show all command output (default: false)"
    echo ""
    echo "Directory Structure:"
    echo "  clusters/\${CLUSTER_NAME}/"
    echo "    ├── nodes/     # Generated node configs (ephemeral, excluded from git)"
    echo "    ├── secrets/   # Sensitive files (secrets.yaml, talosconfig)"
    echo "    ├── state/     # Runtime state and deployment results"
    echo "    └── patches/   # Custom Talos patches (optional)"
    echo ""
    echo "Examples:"
    echo "  $0 bootstrap                    # Full bootstrap with auto-discovery"
    echo "  $0 bootstrap --no-discover      # Use CONTROL_PLANE_IPS from environment"
    echo "  $0 bootstrap --dry-run          # Generate configs only"
    echo "  $0 discover                     # Just discover and show IPs"
    echo "  $0 cleanup                      # Clean up generated files"
}

# ==================== MAIN ENTRY ====================

main() {
    cd "$SCRIPT_DIR"

    local command="${1:-help}"
    shift || true

    case "$command" in
        bootstrap)
            shift || true
            local args=()
            # Parse arguments
            for arg in "$@"; do
                case "$arg" in
                    --skip-preflight) export SKIP_PREFLIGHT=true; args+=("$arg") ;;
                    --no-discover) export NO_DISCOVER=true; args+=("$arg") ;;
                    --dry-run) export DRY_RUN=true; args+=("$arg") ;;
                esac
            done
            init_logging "$command" "${args[@]}"
            plan_bootstrap
            ;;
        discover)
            init_logging "$command"
            plan_discover
            ;;
        status)
            init_logging "$command"
            plan_status
            ;;
        logs)
            init_logging "$command"
            plan_logs
            ;;
        cleanup)
            init_logging "$command"
            plan_cleanup
            ;;
        reset)
            init_logging "$command"
            plan_reset
            ;;
        haproxy|update-haproxy)
            init_logging "$command" "$@"
            plan_haproxy "$@"
            ;;
        help|--help|-h|*)
            show_help
            ;;
    esac
}

main "$@"