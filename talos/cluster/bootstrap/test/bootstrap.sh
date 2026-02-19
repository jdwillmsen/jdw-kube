#!/usr/bin/env bash
set -euo pipefail

readonly VERSION="3.15.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-proxmox-talos-test}"
CLUSTER_DIR="${SCRIPT_DIR}/clusters/${CLUSTER_NAME}"
NODES_DIR="${CLUSTER_DIR}/nodes"
SECRETS_DIR="${CLUSTER_DIR}/secrets"
STATE_DIR="${CLUSTER_DIR}/state"
LOG_DIR="${SCRIPT_DIR}/logs"
CHECKSUM_DIR="${NODES_DIR}/.checksums"

TERRAFORM_TFVARS="${TERRAFORM_TFVARS:-${SCRIPT_DIR}/../terraform.tfvars}"
SECRETS_FILE="${SECRETS_FILE:-${SECRETS_DIR}/secrets.yaml}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/bootstrap-state.json}"
TALOSCONFIG="${TALOSCONFIG:-${SECRETS_DIR}/talosconfig}"
KUBECONFIG_PATH="${HOME}/.kube/config-${CLUSTER_NAME}"

CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-$CLUSTER_NAME.jdwkube.com}"
HAPROXY_IP="${HAPROXY_IP:-192.168.1.237}"
HAPROXY_LOGIN_USERNAME="${HAPROXY_LOGIN_USERNAME:-jake}"
HAPROXY_STATS_USERNAME="${HAPROXY_STATS_USERNAME:-admin}"
HAPROXY_STATS_PASSWORD="${HAPROXY_STATS_PASSWORD:-admin}"
REDISCOVERED_IP=""

KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.35.0}"
TALOS_VERSION="${TALOS_VERSION:-v1.12.3}"
INSTALLER_IMAGE="${INSTALLER_IMAGE:-factory.talos.dev/nocloud-installer/b553b4a25d76e938fd7a9aaa7f887c06ea4ef75275e64f4630e6f8f739cf07df:${TALOS_VERSION}}"

DEFAULT_NETWORK_INTERFACE="${DEFAULT_NETWORK_INTERFACE:-eth0}"
DEFAULT_DISK="${DEFAULT_DISK:-sda}"

readonly PREFLIGHT_MAX_RETRIES="${PREFLIGHT_MAX_RETRIES:-30}"
readonly PREFLIGHT_RETRY_DELAY="${PREFLIGHT_RETRY_DELAY:-2}"
readonly PREFLIGHT_CONNECT_TIMEOUT="${PREFLIGHT_CONNECT_TIMEOUT:-3}"

readonly MAX_PARALLEL_CONTROL_PLANES=3
readonly MAX_PARALLEL_WORKERS=3

readonly BOOTSTRAP_TIMEOUT=300
readonly REBOOT_WAIT_TIME=180
readonly API_READY_WAIT=180

declare -A DESIRED_CP_VMIDS=()
declare -A DESIRED_WORKER_VMIDS=()
declare -A DESIRED_ALL_VMIDS=()

declare -A DEPLOYED_CP_IPS=()
declare -A DEPLOYED_WORKER_IPS=()
declare -A DEPLOYED_CONFIG_HASH=()

declare -A LIVE_NODE_IPS=()
declare -A LIVE_NODE_STATUS=()
declare -A VMID_BY_MAC=()
declare -A MAC_BY_VMID=()

declare -a PLAN_ADD_CP=()
declare -a PLAN_ADD_WORKER=()
declare -a PLAN_REMOVE_CP=()
declare -a PLAN_REMOVE_WORKER=()
declare -a PLAN_UPDATE=()
declare -a PLAN_NOOP=()

declare -gA PROXMOX_NODE_IPS=(
    [pve1]="192.168.1.233"
    [pve2]="192.168.1.222"
    [pve3]="192.168.1.221"
    [pve4]="192.168.1.223"
)

declare -a PROCESSED_ARGS=()

BOOTSTRAP_COMPLETED=false
FIRST_CONTROL_PLANE_VMID=""
PLAN_NEED_BOOTSTRAP=false
APPLY_CONFIG_REBOOT_TRIGGERED="false"

TF_PROXMOX_ENDPOINT=""
TF_PROXMOX_NODE=""
TF_PROXMOX_SSH_USER="root"
TF_PROXMOX_SSH_HOST=""
TERRAFORM_HASH=""

IS_WINDOWS=false
SSH_OPTS=""
PING_CMD=""
HOSTS_FILE=""

AUTO_APPROVE="${AUTO_APPROVE:-false}"
DRY_RUN="${DRY_RUN:-false}"
PLAN_MODE="${PLAN_MODE:-false}"
SKIP_PREFLIGHT="${SKIP_PREFLIGHT:-false}"
FORCE_RECONFIGURE="${FORCE_RECONFIGURE:-false}"

LOG_LEVEL="${LOG_LEVEL:-INFO}"
LOG_DEPTH="${LOG_DEPTH:-4}"
LOG_TIMESTAMPS="${LOG_TIMESTAMPS:-1}"
LOG_ICONS="${LOG_ICONS:-0}"
LOG_FILE=""
LOG_SUMMARY="${LOG_SUMMARY:-true}"
LOG_HISTORY="${LOG_HISTORY:-true}"
CONSOLE_LOG_FILE=""
ALL_LOGS_FILE=""

LAST_COMMAND=""
LAST_COMMAND_OUTPUT=""
LAST_COMMAND_EXIT=0

declare -A SEV_LEVELS=([FATAL]=0 [ERROR]=1 [WARN]=2 [INFO]=3 [DEBUG]=4 [TRACE]=5)
declare -A SEV_LABELS=([FATAL]='FATAL' [ERROR]='ERROR' [WARN]='WARN' [INFO]='INFO' [DEBUG]='DEBUG' [TRACE]='TRACE')
declare -A SEV_COLORS=([FATAL]='\033[1;97;41m' [ERROR]='\033[0;91m' [WARN]='\033[0;93m' [INFO]='\033[0;97m' [DEBUG]='\033[0;94m' [TRACE]='\033[0;90m')

declare -A HIER_LABELS=([PLAN]='PLAN' [STAGE]='STAGE' [JOB]='JOB' [STEP]='STEP' [DETAIL]='DETAIL')
declare -A HIER_COLORS=([PLAN]='\033[1;95m' [STAGE]='\033[1;94m' [JOB]='\033[1;96m' [STEP]='\033[0;92m' [DETAIL]='\033[0;37m')

readonly C_RESET='\033[0m'
readonly C_TIMESTAMP='\033[0;90m'
readonly C_BORDER='\033[1;34m'
readonly C_HEADER='\033[1;96m'
readonly C_LABEL='\033[1;97m'
readonly C_VALUE='\033[0;97m'
readonly C_COUNT='\033[1;93m'
readonly C_NAME='\033[0;92m'
readonly C_IP='\033[0;93m'
readonly C_NODE='\033[0;96m'
readonly C_ROLE='\033[0;96m'
readonly C_WARN='\033[1;93m'
readonly C_ERROR='\033[1;91m'
readonly C_SUCCESS='\033[1;92m'
readonly C_PLAN='\033[1;95m'
readonly C_STAGE='\033[1;94m'
readonly C_JOB='\033[1;96m'
readonly C_STEP='\033[0;92m'
readonly C_DETAIL='\033[0;37m'
readonly C_TRUE='\033[1;92m'
readonly C_FALSE='\033[1;91m'

readonly LOG_TIMESTAMP_FORMAT="+%Y-%m-%d %H:%M:%S"

strip_colors() { echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g'; }

log_output() {
    local content="$1"
    local to_console="${2:-true}"
    local to_structured="${3:-true}"
    echo -e "$content" >&2
    [[ "$to_console" == "true" && -n "${CONSOLE_LOG_FILE:-}" ]] && echo -e "$content" >> "$CONSOLE_LOG_FILE"
    [[ "$to_structured" == "true" && -n "${LOG_FILE:-}" ]] && strip_colors "$content" >> "$LOG_FILE"
    return 0
}

print_box_line() {
    local content="$1"
    local color="${2:-$C_BORDER}"
    local plain_content=$(strip_colors "$content")
    local len=${#plain_content}
    local padding=$((61 - len))
    [[ $padding -lt 0 ]] && padding=0
    local line
    printf -v line "│%s%*s%s│%s" "$content" "$padding" "" "$C_BORDER" "$C_RESET"
    log_output "${color}${line}${C_RESET}"
}

print_border() {
    local type="$1"
    case "$type" in
        top) log_output "${C_BORDER}┌─────────────────────────────────────────────────────────────┐${C_RESET}" ;;
        header) log_output "${C_BORDER}├─────────────────────────────────────────────────────────────┤${C_RESET}" ;;
        divider) log_output "${C_BORDER}├─────────────────────────────────────────────────────────────┤${C_RESET}" ;;
        bottom) log_output "${C_BORDER}└─────────────────────────────────────────────────────────────┘${C_RESET}" ;;
    esac
}

print_box_header() {
    local title="$1"
    local title_color="${2:-$C_HEADER}"
    local title_len=${#title}
    local total_width=61
    local padding=$(( (total_width - title_len) / 2 ))
    local left_pad=$padding
    local right_pad=$((total_width - title_len - left_pad))
    print_border top
    printf -v header_line "%*s%s%*s" "$left_pad" "" "$title" "$right_pad" ""
    print_box_line "${title_color}${header_line}${C_RESET}"
    print_border divider
}

print_box_footer() { print_border bottom; }

print_box_pair() {
    local key="$1"
    local value="$2"
    local key_color="${3:-$C_LABEL}"
    local value_color="${4:-$C_VALUE}"
    print_box_line "  ${key_color}${key}:${C_RESET} ${value_color}${value}${C_RESET}"
}

print_box_item() {
    local bullet="$1"
    local content="$2"
    local content_color="${3:-$C_VALUE}"
    print_box_line "    ${C_VALUE}${bullet} ${content_color}${content}${C_RESET}"
}

print_box_section() { local label="$1"; print_box_line "  ${C_LABEL}${label}:${C_RESET}"; }

print_box_badge() {
    local badge="$1"
    local message="$2"
    local badge_color="${3:-$C_WARN}"
    print_box_line "  ${badge_color}[${badge}]${C_RESET} ${C_VALUE}${message}${C_RESET}"
}

print_box_wrapped() {
    local prefix="$1"
    local text="$2"
    local prefix_color="${3:-$C_LABEL}"
    local text_color="${4:-$C_VALUE}"
    local prefix_len=${#prefix}
    local max_content=61
    local available=$((max_content - prefix_len - 2))
    [[ $available -lt 10 ]] && available=10
    _print_wrapped_line() {
        local p="$1"
        local t="$2"
        print_box_line "  ${prefix_color}${p}${text_color}${t}${C_RESET}"
    }
    if [[ ${#text} -le $available ]]; then
        _print_wrapped_line "$prefix" "$text"
        return 0
    fi
    local current_pos=0
    local total_len=${#text}
    local is_first_line=true
    local indent_spaces=""
    for ((i=0; i<prefix_len; i++)); do indent_spaces+=" "; done
    while [[ $current_pos -lt $total_len ]]; do
        local remaining=$((total_len - current_pos))
        local chunk_len=$((available < remaining ? available : remaining))
        local chunk="${text:$current_pos:$chunk_len}"
        if [[ $((current_pos + chunk_len)) -lt $total_len ]]; then
            local next_char="${text:$((current_pos + chunk_len)):1}"
            if [[ "$next_char" != " " ]]; then
                local last_space=-1
                for ((i=chunk_len-1; i>=0; i--)); do
                    if [[ "${chunk:$i:1}" == " " ]]; then
                        last_space=$i
                        break
                    fi
                done
                if [[ $last_space -gt 0 ]]; then
                    chunk_len=$last_space
                    chunk="${text:$current_pos:$chunk_len}"
                fi
            fi
        fi
        chunk="${chunk% }"
        if [[ "$is_first_line" == true ]]; then
            _print_wrapped_line "$prefix" "$chunk"
            is_first_line=false
        else
            _print_wrapped_line "$indent_spaces" "$chunk"
        fi
        current_pos=$((current_pos + chunk_len))
        while [[ $current_pos -lt $total_len && "${text:$current_pos:1}" == " " ]]; do
            current_pos=$((current_pos + 1))
        done
    done
}

log() {
    local hierarchy="${1:-STEP}"
    local severity="${2:-INFO}"
    local message="$3"
    severity="${severity^^}"
    [[ -z "${SEV_LEVELS[$severity]:-}" ]] && severity="INFO"
    local normalized_log_level="${LOG_LEVEL^^}"
    [[ -z "${SEV_LEVELS[$normalized_log_level]:-}" ]] && normalized_log_level="INFO"
    local hier_num=0
    case "$hierarchy" in
        PLAN)   hier_num=0 ;;
        STAGE)  hier_num=1 ;;
        JOB)    hier_num=2 ;;
        STEP)   hier_num=3 ;;
        DETAIL) hier_num=4 ;;
    esac
    [[ ${SEV_LEVELS[$severity]} -gt ${SEV_LEVELS[$normalized_log_level]} ]] && return
    [[ $hier_num -gt $LOG_DEPTH ]] && return 0
    local output=""
    [[ "$LOG_TIMESTAMPS" == "1" ]] && output+="${C_TIMESTAMP}[$(date '+%H:%M:%S')]${C_RESET} "
    local sev_label="${SEV_LABELS[$severity]}"
    printf -v sev_padded "%-5s" "$sev_label"
    output+="${SEV_COLORS[$severity]}[${sev_padded}]${C_RESET} "
    local hier_label="${HIER_LABELS[$hierarchy]}"
    printf -v hier_padded "%-6s" "$hier_label"
    output+="${HIER_COLORS[$hierarchy]}[${hier_padded}]${C_RESET} "
    output+="${message}"
    log_output "$output"
    [[ "$severity" == "FATAL" ]] && exit 1
    return 0
}

log_plan_fatal() { log "PLAN" "FATAL" "$1"; }
log_plan_error() { log "PLAN" "ERROR" "$1"; }
log_plan_warn() { log "PLAN" "WARN" "$1"; }
log_plan_info() { log "PLAN" "INFO" "$1"; }
log_plan_debug() { log "PLAN" "DEBUG" "$1"; }
log_plan_trace() { log "PLAN" "TRACE" "$1"; }

log_stage_fatal() { log "STAGE" "FATAL" "$1"; }
log_stage_error() { log "STAGE" "ERROR" "$1"; }
log_stage_warn() { log "STAGE" "WARN" "$1"; }
log_stage_info() { log "STAGE" "INFO" "$1"; }
log_stage_debug() { log "STAGE" "DEBUG" "$1"; }
log_stage_trace() { log "STAGE" "TRACE" "$1"; }

log_job_fatal() { log "JOB" "FATAL" "$1"; }
log_job_error() { log "JOB" "ERROR" "$1"; }
log_job_warn() { log "JOB" "WARN" "$1"; }
log_job_info() { log "JOB" "INFO" "$1"; }
log_job_debug() { log "JOB" "DEBUG" "$1"; }
log_job_trace() { log "JOB" "TRACE" "$1"; }

log_step_fatal() { log "STEP" "FATAL" "$1"; }
log_step_error() { log "STEP" "ERROR" "$1"; }
log_step_warn() { log "STEP" "WARN" "$1"; }
log_step_info() { log "STEP" "INFO" "$1"; }
log_step_debug() { log "STEP" "DEBUG" "$1"; }
log_step_trace() { log "STEP" "TRACE" "$1"; }

log_detail_fatal() { log "DETAIL" "FATAL" "$1"; }
log_detail_error() { log "DETAIL" "ERROR" "$1"; }
log_detail_warn() { log "DETAIL" "WARN" "$1"; }
log_detail_info() { log "DETAIL" "INFO" "$1"; }
log_detail_debug() { log "DETAIL" "DEBUG" "$1"; }
log_detail_trace() { log "DETAIL" "TRACE" "$1"; }

log_file_only() {
    local entry="[$(date "$LOG_TIMESTAMP_FORMAT")] [$1] $2"
    [[ -n "${LOG_FILE:-}" ]] && echo "$entry" >> "$LOG_FILE"
    [[ -n "${ALL_LOGS_FILE:-}" ]] && echo "$entry" >> "$ALL_LOGS_FILE"
}

log_state_change() {
    local var_name="$1"
    local old_value="$2"
    local new_value="$3"
    [[ -n "${ALL_LOGS_FILE:-}" ]] && echo "[$(date "$LOG_TIMESTAMP_FORMAT")] [STATE-CHANGE] $var_name: [$old_value] -> [$new_value]" >> "$ALL_LOGS_FILE"
}

log_config_generated() {
    local file_path="$1"
    local file_hash
    if [[ -f "$file_path" ]]; then
        run_command sha256sum "$file_path"
        file_hash=$(echo "$LAST_COMMAND_OUTPUT" | cut -d' ' -f1)
        [[ -n "${ALL_LOGS_FILE:-}" ]] && {
            echo "[$(date "$LOG_TIMESTAMP_FORMAT")] [CONFIG-GENERATED] $file_path" >> "$ALL_LOGS_FILE"
            echo "[$(date "$LOG_TIMESTAMP_FORMAT")] [CONFIG-HASH] $file_hash" >> "$ALL_LOGS_FILE"
            echo "[$(date "$LOG_TIMESTAMP_FORMAT")] [CONFIG-PREVIEW] $(head -1 "$file_path")" >> "$ALL_LOGS_FILE"
        }
    fi
}

run_command() {
    LAST_COMMAND="$*"
    local output_file
    output_file=$(mktemp)
    local exit_code=0
    local output=""
    local start_time end_time duration_ms
    start_time=$(date +%s%N)
    if [[ -n "${ALL_LOGS_FILE:-}" ]]; then
        {
            echo ""
            echo "[$(date "$LOG_TIMESTAMP_FORMAT")] [CMD-START] $LAST_COMMAND"
            echo "[$(date "$LOG_TIMESTAMP_FORMAT")] [CMD-WD] $(pwd)"
        } >> "$ALL_LOGS_FILE"
    fi
    log_detail_trace "Executing: $LAST_COMMAND"
    if "$@" > "$output_file" 2>&1; then
        exit_code=0
    else
        exit_code=$?
    fi
    end_time=$(date +%s%N)
    duration_ms=$(((end_time - start_time) / 1000000))
    if [[ -f "$output_file" ]]; then
        output=$(cat "$output_file") || output="[ERROR: Failed to read output file]"
    else
        output="[ERROR: Output file missing]"
    fi
    LAST_COMMAND_EXIT=$exit_code
    LAST_COMMAND_OUTPUT="$output"
    if [[ -n "${ALL_LOGS_FILE:-}" ]]; then
        {
            [[ -n "$output" ]] && {
                echo "[$(date "$LOG_TIMESTAMP_FORMAT")] [CMD-OUTPUT]"
                echo "$output"
            }
            echo "[$(date "$LOG_TIMESTAMP_FORMAT")] [CMD-EXIT] $exit_code [DURATION: ${duration_ms}ms]"
        } >> "$ALL_LOGS_FILE"
    fi
    rm -f "$output_file"
    return $exit_code
}

write_file_audited() {
    local content="$1"
    local file="$2"
    local temp_f
    temp_f=$(mktemp)
    log_detail_trace "write_file_audited: Writing ${#content} bytes to $file"
    cat <<EOF > "$temp_f"
$content
EOF
    run_command mv "$temp_f" "$file"
    log_detail_debug "write_file_audited: Successfully wrote to $file"
}

init_logging() {
    log_detail_trace "init_logging: Starting with args: $*"
    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR"
    fi

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local date_prefix
    date_prefix=$(date +%Y-%m-%d)
    local iso_timestamp
    iso_timestamp=$(date -Iseconds)
    local run_dir="$LOG_DIR/$date_prefix/run-${timestamp}"

    run_command mkdir -p "$run_dir"
    RUN_DIR="$run_dir"
    RUN_TIMESTAMP="$timestamp"
    RUN_DATE_PREFIX="$date_prefix"
    CONSOLE_LOG_FILE="$run_dir/console.log"
    LOG_FILE="$run_dir/structured.log"
    ALL_LOGS_FILE="$run_dir/audit.log"

    touch "$CONSOLE_LOG_FILE" "$LOG_FILE" "$ALL_LOGS_FILE"
    chmod 600 "$CONSOLE_LOG_FILE" "$LOG_FILE" "$ALL_LOGS_FILE"

    local latest_file="$LOG_DIR/latest.txt"
    echo "$run_dir" > "$latest_file"
    chmod 600 "$latest_file" 2>/dev/null || true

    local args_str=""
    [[ $# -gt 0 ]] && args_str="Arguments: $*" || args_str="Arguments: (none)"

    local header_content="========================================
Talos Bootstrap Log Started: $(date)
Version: $VERSION
Script: $0
User: $(whoami)
Working Directory: $SCRIPT_DIR
Hostname: ${HOSTNAME:-$(hostname)}
Platform: $OSTYPE
Cluster: $CLUSTER_NAME
Control Plane Endpoint: $CONTROL_PLANE_ENDPOINT
HAProxy IP: $HAPROXY_IP
$args_str
Environment:
  KUBERNETES_VERSION=$KUBERNETES_VERSION
  TALOS_VERSION=$TALOS_VERSION
  AUTO_APPROVE=$AUTO_APPROVE
  DRY_RUN=$DRY_RUN
  PLAN_MODE=$PLAN_MODE
  SKIP_PREFLIGHT=$SKIP_PREFLIGHT
  FORCE_RECONFIGURE=$FORCE_RECONFIGURE
  LOG_LEVEL=$LOG_LEVEL
========================================"

    echo "$header_content" >> "$LOG_FILE"
    echo "$header_content" > "$CONSOLE_LOG_FILE"
    echo "$header_content" >> "$ALL_LOGS_FILE"

    {
        echo ""
        echo "[SYSTEM] Bash version: $BASH_VERSION"
        echo "[SYSTEM] PATH: $PATH"
        echo "[SYSTEM] Talosctl: $(command -v talosctl || echo 'NOT FOUND')"
        echo "[SYSTEM] SSH: $(command -v ssh || echo 'NOT FOUND')"
        echo "[SYSTEM] jq: $(command -v jq || echo 'NOT FOUND')"
        echo ""
        echo "=== COMPLETE COMMAND AUDIT TRAIL BELOW ==="
        echo ""
    } >> "$ALL_LOGS_FILE"

    if [[ "${LOG_HISTORY:-true}" == "true" ]]; then
        local runs_log="$LOG_DIR/runs.log"
        if [[ ! -f "$runs_log" ]]; then
            echo "timestamp|cluster|command|args|run_dir|status" > "$runs_log"
            chmod 600 "$runs_log"
        fi
        echo "${iso_timestamp}|${CLUSTER_NAME}|${1:-unknown}|${args_str// /_}|$run_dir|pending" >> "$runs_log"
        RUNS_LOG_LINE=$(wc -l < "$runs_log" 2>/dev/null) || RUNS_LOG_LINE=0
    fi

    print_banner
    trap 'cleanup_on_exit' EXIT INT TERM
    log_detail_trace "init_logging: Completed, RUN_DIR=$RUN_DIR"
}

save_state() {
    local timestamp=$(date -Iseconds)
    log_detail_trace "save_state: Starting state save with timestamp=$timestamp"

    run_command mkdir -p "$STATE_DIR" || {
        echo "ERROR: Failed to create state directory $STATE_DIR" >&2
        return 1
    }

    local cp_array="["
    local first=true
    for vmid in "${!DEPLOYED_CP_IPS[@]}"; do
        [[ "$first" == "true" ]] || cp_array+=","
        first=false
        local ip="${DEPLOYED_CP_IPS[$vmid]}"
        local hash="${DEPLOYED_CONFIG_HASH[$vmid]:-}"
        cp_array+="{\"vmid\":\"$vmid\",\"ip\":\"${ip:-}\",\"config_hash\":\"${hash:-}\"}"
    done
    cp_array+="]"

    local worker_array="["
    first=true
    for vmid in "${!DEPLOYED_WORKER_IPS[@]}"; do
        [[ "$first" == "true" ]] || worker_array+=","
        first=false
        local ip="${DEPLOYED_WORKER_IPS[$vmid]}"
        local hash="${DEPLOYED_CONFIG_HASH[$vmid]:-}"
        worker_array+="{\"vmid\":\"$vmid\",\"ip\":\"${ip:-}\",\"config_hash\":\"${hash:-}\"}"
    done
    worker_array+="]"

    local state_content
    state_content=$(cat <<EOF
{
  "timestamp": "$timestamp",
  "terraform_hash": "$TERRAFORM_HASH",
  "cluster_name": "$CLUSTER_NAME",
  "bootstrap_completed": ${BOOTSTRAP_COMPLETED:-false},
  "first_control_plane_vmid": "${FIRST_CONTROL_PLANE_VMID:-}",
  "deployed_state": {
    "control_planes": $cp_array,
    "workers": $worker_array
  },
  "haproxy_ip": "$HAPROXY_IP",
  "control_plane_endpoint": "$CONTROL_PLANE_ENDPOINT",
  "kubernetes_version": "$KUBERNETES_VERSION",
  "talos_version": "$TALOS_VERSION"
}
EOF
)
    log_detail_debug "save_state: Writing state with ${#DEPLOYED_CP_IPS[@]} CPs, ${#DEPLOYED_WORKER_IPS[@]} workers"
    if write_file_audited "$state_content" "$STATE_FILE"; then
        chmod 600 "$STATE_FILE"
        log_file_only "STATE" "Saved to $STATE_FILE"
        log_detail_trace "save_state: Successfully saved state"
    else
        log_job_error "Failed to write state file to $STATE_FILE"
        return 1
    fi
}

flush_arp_cache() {
    local host="$1"
    log_detail_debug "Flushing ARP cache on $host..."
    run_command ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no "${TF_PROXMOX_SSH_USER}@$host" "ip -s -s neigh flush all" || true
}

populate_arp_table() {
    local host="$1"
    local subnet=$(get_network_subnet "$host")
    log_step_debug "[ARP-SCAN] Populating ARP table from $host (subnet: $subnet.0/24)"
    run_command ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        "${TF_PROXMOX_SSH_USER}@$host" \
        "ip -s -s neigh flush all" || true
    log_step_debug "[ARP-SCAN] Pinging ${subnet}.0/24..."
    run_command bash -c "ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no ${TF_PROXMOX_SSH_USER}@$host \"seq 1 254 | xargs -P 100 -I{} ping -c 1 -W 1 ${subnet}.{} >/dev/null 2>&1 || true\"" || true
    sleep 3
    log_step_debug "[ARP-SCAN] Reading ARP table..."
    local arp_output
    if ! run_command ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            "${TF_PROXMOX_SSH_USER}@$host" \
            "cat /proc/net/arp"; then
        log_step_warn "[ARP-SCAN] Failed to read ARP table from $host"
        return 1
    fi
    arp_output="$LAST_COMMAND_OUTPUT"
    arp_output=$(echo "$arp_output" | tr -d '\r')
    log_step_debug "[ARP-SCAN] Looking for ${#VMID_BY_MAC[@]} MAC addresses:"
    for mac in "${!VMID_BY_MAC[@]}"; do
        local vmid="${VMID_BY_MAC[$mac]}"
        log_step_debug "[ARP-SCAN]   - VM $vmid -> MAC $mac"
    done
    local found_count=0
    local ip mac_upper vmid
    while IFS= read -r line; do
        [[ "$line" =~ ^IP[[:space:]]+HW ]] && continue
        ip=$(echo "$line" | awk '{print $1}')
        mac_upper=$(echo "$line" | awk '{print $4}' | tr '[:lower:]' '[:upper:]')
        [[ "$mac_upper" == "00:00:00:00:00:00" ]] && continue
        [[ -z "$mac_upper" || "$mac_upper" == "INCOMPLETE" ]] && continue
        vmid="${VMID_BY_MAC[$mac_upper]:-}"
        if [[ -n "$vmid" ]]; then
            LIVE_NODE_IPS["$vmid"]="$ip"
            log_step_debug "[ARP-SCAN] Found VM $vmid -> $ip ($mac_upper)"
            found_count=$((found_count + 1))
        else
            log_step_debug "[ARP-SCAN] Unmatched MAC: $mac_upper -> $ip"
        fi
    done <<< "$arp_output" || true
    log_step_debug "[ARP-SCAN] Complete: Found $found_count of ${#VMID_BY_MAC[@]} VMs"
    return 0
}

cleanup_on_exit() {
    local exit_code=$?
    log_detail_trace "cleanup_on_exit: Starting cleanup with exit_code=$exit_code"
    run_command rm -f /tmp/haproxy.cfg.* || true

    local footer_content="
========================================
Script Ended: $(date)
Exit Code: $exit_code
========================================"
    [[ -n "${LOG_FILE:-}" ]] && echo "$footer_content" >> "$LOG_FILE"
    [[ -n "${CONSOLE_LOG_FILE:-}" ]] && echo "$footer_content" >> "$CONSOLE_LOG_FILE"
    [[ -n "${ALL_LOGS_FILE:-}" ]] && echo "$footer_content" >> "$ALL_LOGS_FILE"

    [[ "${LOG_SUMMARY:-true}" == "true" && -n "${RUN_DIR:-}" ]] && {
        local summary_file="$RUN_DIR/SUMMARY.txt"
        local add_cp_count=${#PLAN_ADD_CP[@]}
        local add_worker_count=${#PLAN_ADD_WORKER[@]}
        local remove_cp_count=${#PLAN_REMOVE_CP[@]}
        local remove_worker_count=${#PLAN_REMOVE_WORKER[@]}
        local update_count=${#PLAN_UPDATE[@]}
        local noop_count=${#PLAN_NOOP[@]}
        local total_ops=$((add_cp_count + add_worker_count + remove_cp_count + remove_worker_count + update_count))
        local desired_cp_count=${#DESIRED_CP_VMIDS[@]}
        local desired_worker_count=${#DESIRED_WORKER_VMIDS[@]}
        local deployed_cp_count=${#DEPLOYED_CP_IPS[@]}
        local deployed_worker_count=${#DEPLOYED_WORKER_IPS[@]}

        {
            echo "TALOS BOOTSTRAP RUN SUMMARY"
            echo "==========================="
            echo ""
            echo "Run Information:"
            echo "  Timestamp:    ${RUN_TIMESTAMP:-unknown}"
            echo "  Date:         ${RUN_DATE_PREFIX:-unknown}"
            echo "  Cluster:      ${CLUSTER_NAME:-unknown}"
            echo "  Command:      ${0:-unknown}"
            echo "  Exit Code:    $exit_code"
            echo "  Status:       $([[ $exit_code -eq 0 ]] && echo "SUCCESS" || echo "FAILED")"
            echo ""
            echo "Configuration:"
            echo "  Terraform:    ${TERRAFORM_TFVARS:-unknown}"
            echo "  Hash:         ${TERRAFORM_HASH:-unknown}"
            echo "  K8s Version:  ${KUBERNETES_VERSION:-unknown}"
            echo "  Talos Version: ${TALOS_VERSION:-unknown}"
            echo ""
            echo "Operations Performed:"
            echo "  Add Control Planes:    $add_cp_count"
            echo "  Add Workers:           $add_worker_count"
            echo "  Remove Control Planes: $remove_cp_count"
            echo "  Remove Workers:        $remove_worker_count"
            echo "  Update Configs:        $update_count"
            echo "  Unchanged:             $noop_count"
            echo "  -------------------------"
            echo "  Total Operations:      $total_ops"
            echo ""
            echo "Node Counts:"
            echo "  Desired Control Planes:  $desired_cp_count"
            echo "  Desired Workers:         $desired_worker_count"
            echo "  Deployed Control Planes: $deployed_cp_count"
            echo "  Deployed Workers:        $deployed_worker_count"
            echo ""
            echo "Bootstrap Status:"
            echo "  Completed: ${BOOTSTRAP_COMPLETED:-false}"
            echo "  First CP:  ${FIRST_CONTROL_PLANE_VMID:-none}"
            echo ""
            echo "Files:"
            echo "  Console Log:   console.log"
            echo "  Structured:    structured.log"
            echo "  Audit Trail:   audit.log"
            echo "  Full Path:     ${RUN_DIR:-unknown}"
            echo ""
            echo "Quick Commands:"
            echo "  View console:  cat ${RUN_DIR:-.}/console.log"
            echo "  View audit:    tail -100 ${RUN_DIR:-.}/audit.log"
            echo "  Rerun:         $0"
        } > "$summary_file"

        chmod 600 "$summary_file"
        log_detail_debug "cleanup_on_exit: Summary written to $summary_file"
    }

    [[ "${LOG_HISTORY:-true}" == "true" && -n "${RUNS_LOG_LINE:-}" && -f "$LOG_DIR/runs.log" ]] && {
        local status="failed"
        [[ $exit_code -eq 0 ]] && status="success"
        sed -i "${RUNS_LOG_LINE}s/pending$/$status/" "$LOG_DIR/runs.log" 2>/dev/null || true
        log_detail_trace "cleanup_on_exit: Updated runs.log status to $status"
    }
    log_detail_trace "cleanup_on_exit: Cleanup completed"
}

print_banner() {
    log_output "${C_BORDER}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    log_output "${C_VALUE}  ▄▄▄█████▓ ▄▄▄       ██▓      ▒█████    ██████ ${C_RESET}"
    log_output "${C_VALUE}  ▓  ██▒ ▓▒▒████▄    ▓██▒     ▒██▓  ██▒▒██    ▒ ${C_RESET}"
    log_output "${C_VALUE}  ▒ ▓██░ ▒░▒██  ▀█▄  ▒██░     ▒██▒  ██░░ ▓██▄   ${C_RESET}"
    log_output "${C_VALUE}  ░ ▓██▓ ░ ░██▄▄▄▄██ ▒██░     ░██  █▀ ░  ▒   ██▒${C_RESET}"
    log_output "${C_VALUE}    ▒██▒ ░  ▓█   ▓██▒░██████▒░▒███▒█▄ ▒██████▒▒${C_RESET}"
    log_output "${C_VALUE}    ▒ ░░    ▒▒   ▓▒█░░ ▒░▓  ░░░ ▒▒░ ▒ ▒ ▒▓▒ ▒ ░${C_RESET}"
    log_output "${C_HEADER}            SMART RECONCILIATION v$VERSION${C_RESET}"
    log_output "${C_BORDER}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
}

fetch_proxmox_node_ips() {
    log_job_info "Fetching Proxmox cluster node IPs from API"
    log_job_trace "fetch_proxmox_node_ips: Starting with TF_PROXMOX_ENDPOINT=${TF_PROXMOX_ENDPOINT:-empty}"
    local api_url
    if [[ -n "${TF_PROXMOX_ENDPOINT:-}" ]]; then
        api_url="${TF_PROXMOX_ENDPOINT}/api2/json"
    else
        local first_node_ip=$(get_node_ip "pve1")
        api_url="https://${first_node_ip}:8006/api2/json"
    fi
    local token_id="${PROXMOX_TOKEN_ID:-}"
    local token_secret="${PROXMOX_TOKEN_SECRET:-}"
    local curl_cmd="curl -s -k --connect-timeout 10"
    if [[ -n "$token_id" && -n "$token_secret" ]]; then
        curl_cmd+=" -H 'Authorization: PVEAPIToken=${token_id}=${token_secret}'"
    else
        log_step_info "No API token configured, using SSH fallback for node discovery"
        fetch_node_ips_via_ssh
        return $?
    fi
    log_step_debug "Querying Proxmox API: ${api_url}/cluster/status"
    local response
    if run_command bash -c "eval \"$curl_cmd\" \"${api_url}/cluster/status\""; then
        response="$LAST_COMMAND_OUTPUT"
    else
        log_step_warn "Failed to query Proxmox API, falling back to SSH"
        fetch_node_ips_via_ssh
        return $?
    fi
    [[ -z "$response" ]] && {
        log_step_warn "Empty response from Proxmox API, falling back to SSH"
        fetch_node_ips_via_ssh
        return $?
    }
    if command -v jq &>/dev/null; then
        local nodes_json=$(echo "$response" | jq -r '.data[] | select(.type == "node") | "\(.name)|\(.ip)"' 2>/dev/null | tr -d '\r')
        while IFS='|' read -r node_name node_ip; do
            [[ -n "$node_name" && -n "$node_ip" ]] && {
                PROXMOX_NODE_IPS["$node_name"]="$node_ip"
                log_detail_debug "Resolved $node_name -> $node_ip"
            }
        done <<< "$nodes_json"
    else
        log_step_warn "jq not available, using basic parsing"
        local node_entries=$(echo "$response" | grep -o '"name":"[^"]*","id":"node/[^"]*","ip":"[^"]*"' 2>/dev/null)
        while IFS= read -r entry; do
            local node_name node_ip
            node_name=$(echo "$entry" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
            node_ip=$(echo "$entry" | grep -o '"ip":"[^"]*"' | cut -d'"' -f4)
            [[ -n "$node_name" && -n "$node_ip" ]] && {
                PROXMOX_NODE_IPS["$node_name"]="$node_ip"
                log_detail_debug "Resolved $node_name -> $node_ip"
            }
        done <<< "$node_entries"
    fi
    [[ ${#PROXMOX_NODE_IPS[@]} -eq 0 ]] && {
        log_step_warn "No node IPs resolved from API, falling back to SSH"
        fetch_node_ips_via_ssh
        return $?
    }
    log_step_debug "Resolved ${#PROXMOX_NODE_IPS[@]} Proxmox node IPs"
    log_job_trace "fetch_proxmox_node_ips: Resolved nodes: ${!PROXMOX_NODE_IPS[*]}"
    return 0
}

fetch_node_ips_via_ssh() {
    local main_node=$(get_node_ip "pve1")
    log_step_info "Fetching node IPs via SSH from $main_node"
    log_job_trace "fetch_node_ips_via_ssh: Connecting to $main_node as $TF_PROXMOX_SSH_USER"
    local cluster_status
    if run_command ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${TF_PROXMOX_SSH_USER}@$main_node" "pvesh get /cluster/status --output-format json"; then
        cluster_status="$LAST_COMMAND_OUTPUT"
    else
        log_step_warn "Failed to fetch cluster status via SSH"
        log_step_info "Using get_node_ip() fallbacks"
        return 0
    fi
    if command -v jq &>/dev/null; then
        local nodes_json=$(echo "$cluster_status" | jq -r '.[] | select(.type == "node") | "\(.name)|\(.ip)"' 2>/dev/null | tr -d '\r')
        while IFS='|' read -r node_name node_ip; do
            [[ -n "$node_name" && -n "$node_ip" ]] && {
                PROXMOX_NODE_IPS["$node_name"]="$node_ip"
                log_detail_debug "Resolved $node_name -> $node_ip (via SSH)"
            }
        done <<< "$nodes_json"
    fi
    log_job_trace "fetch_node_ips_via_ssh: Completed with ${#PROXMOX_NODE_IPS[@]} nodes"
    return 0
}

get_node_ip() {
    local node_name="$1"
    log_detail_trace "get_node_ip: Resolving $node_name"
    [[ ${#PROXMOX_NODE_IPS[@]} -gt 0 ]] && {
        echo "${PROXMOX_NODE_IPS[$node_name]:-$node_name}"
    } || {
        [[ "$node_name" == "pve1" ]] && echo "${TF_PROXMOX_SSH_HOST:-192.168.1.233}" || echo "$node_name"
    }
}

get_network_subnet() {
    local ip="$1"
    log_detail_trace "get_network_subnet: Extracting subnet from $ip"
    [[ "$ip" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+$ ]] && echo "${BASH_REMATCH[1]}" || echo "192.168.1"
}

load_desired_state() {
    log_job_info "Loading Desired State from Terraform"
    log_job_trace "load_desired_state: Resetting all desired state arrays"
    DESIRED_CP_VMIDS=()
    DESIRED_WORKER_VMIDS=()
    DESIRED_ALL_VMIDS=()
    if [[ ! -f "$TERRAFORM_TFVARS" ]]; then
        log_job_error "terraform.tfvars not found at $TERRAFORM_TFVARS"
        log_job_error "Terraform configuration is required as the single source of truth"
        return 1
    fi
    local tf_size
    tf_size=$(stat -f%z "$TERRAFORM_TFVARS" 2>/dev/null || stat -c%s "$TERRAFORM_TFVARS" 2>/dev/null || echo "unknown")
    local tf_lines
    tf_lines=$(wc -l < "$TERRAFORM_TFVARS" 2>/dev/null || echo "0")
    log_file_only "TERRAFORM" "File: $TERRAFORM_TFVARS, Size: $tf_size bytes, Lines: $tf_lines, Hash: ${TERRAFORM_HASH:0:16}..."
    log_step_debug "Found: $TERRAFORM_TFVARS"
    if run_command sha256sum "$TERRAFORM_TFVARS"; then
        TERRAFORM_HASH=$(echo "$LAST_COMMAND_OUTPUT" | cut -d' ' -f1)
    else
        log_job_error "Failed to compute hash of $TERRAFORM_TFVARS"
        return 1
    fi
    log_detail_debug "Terraform hash: ${TERRAFORM_HASH:0:16}..."
    TF_PROXMOX_ENDPOINT=$(grep -E '^proxmox_endpoint[[:space:]]*=' "$TERRAFORM_TFVARS" 2>/dev/null | head -1 | cut -d'"' -f2)
    if [[ -n "$TF_PROXMOX_ENDPOINT" ]]; then
        TF_PROXMOX_SSH_HOST=$(echo "$TF_PROXMOX_ENDPOINT" | sed -E 's|https?://||' | cut -d':' -f1)
        log_detail_debug "Proxmox endpoint: $TF_PROXMOX_ENDPOINT"
        log_detail_debug "SSH host: $TF_PROXMOX_SSH_HOST"
    fi
    parse_terraform_array "talos_control_configuration" "control-plane" || true
    parse_terraform_array "talos_worker_configuration" "worker" || true
    local cp_count=${#DESIRED_CP_VMIDS[@]}
    local worker_count=${#DESIRED_WORKER_VMIDS[@]}
    log_step_info "Parsed: $cp_count control planes, $worker_count workers"
    log_job_trace "load_desired_state: CPs=[${!DESIRED_CP_VMIDS[*]}], Workers=[${!DESIRED_WORKER_VMIDS[*]}]"
    if [[ -n "${ALL_LOGS_FILE:-}" ]]; then
        {
            echo "[$(date "$LOG_TIMESTAMP_FORMAT")] [TERRAFORM-PREVIEW]"
            grep -E '^(proxmox_|talos_iso|control_plane|cluster|endpoint)[[:space:]]*=' "$TERRAFORM_TFVARS" 2>/dev/null | head -20 || true
            echo ""
            echo "# Array configurations detected:"
            grep -E '^(talos_control_configuration|talos_worker_configuration)[[:space:]]*=' "$TERRAFORM_TFVARS" 2>/dev/null || true
            echo ""
            echo "# Parsed VM Summary:"
            echo "# Control Planes: ${#DESIRED_CP_VMIDS[@]}"
            echo "# Workers: ${#DESIRED_WORKER_VMIDS[@]}"
            local vm_preview_count=0
            for vmid in "${!DESIRED_ALL_VMIDS[@]}"; do
                [[ $vm_preview_count -ge 5 ]] && break
                echo "#   VMID $vmid: ${DESIRED_ALL_VMIDS[$vmid]}"
                vm_preview_count=$((vm_preview_count + 1))
            done
            [[ ${#DESIRED_ALL_VMIDS[@]} -gt 5 ]] && echo "#   ... and $(( ${#DESIRED_ALL_VMIDS[@]} - 5 )) more"
        } >> "$ALL_LOGS_FILE" 2>/dev/null || true
    fi
    if [[ $cp_count -eq 0 ]]; then
        log_job_warn "No control planes defined in terraform.tfvars"
        return 1
    fi
    if [[ $cp_count -gt 1 && $((cp_count % 2)) -eq 0 ]]; then
        log_job_warn "Even number of control planes ($cp_count) - etcd prefers odd numbers"
        log_job_warn "Consider adding or removing one control plane for optimal quorum"
    fi
    log_file_only "TERRAFORM" "Hash: $TERRAFORM_HASH, CP: $cp_count, Workers: $worker_count"
    return 0
}

load_proxmox_tokens_from_terraform() {
    log_job_trace "load_proxmox_tokens_from_terraform: Checking for tokens in $TERRAFORM_TFVARS"
    [[ ! -f "$TERRAFORM_TFVARS" ]] && {
        log_detail_debug "Terraform file not found, skipping token load"
        return 0
    }
    if [[ -z "${PROXMOX_TOKEN_ID:-}" ]]; then
        local token_id
        token_id=$(grep -E '^proxmox_api_token_id[[:space:]]*=' "$TERRAFORM_TFVARS" 2>/dev/null | head -1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')
        if [[ -n "$token_id" ]]; then
            export PROXMOX_TOKEN_ID="$token_id"
            log_detail_info "Loaded PROXMOX_TOKEN_ID from terraform.tfvars"
        fi
    else
        log_detail_debug "PROXMOX_TOKEN_ID already set in environment"
    fi
    if [[ -z "${PROXMOX_TOKEN_SECRET:-}" ]]; then
        local token_secret
        token_secret=$(grep -E '^proxmox_api_token_secret[[:space:]]*=' "$TERRAFORM_TFVARS" 2>/dev/null | head -1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')
        if [[ -n "$token_secret" ]]; then
            export PROXMOX_TOKEN_SECRET="$token_secret"
            log_detail_info "Loaded PROXMOX_TOKEN_SECRET from terraform.tfvars (masked)"
        fi
    else
        log_detail_debug "PROXMOX_TOKEN_SECRET already set in environment"
    fi
    if [[ -n "${PROXMOX_TOKEN_ID:-}" ]]; then
        log_job_debug "Proxmox API token configured: ${PROXMOX_TOKEN_ID}"
    else
        log_job_debug "No Proxmox API token found, will use SSH fallback"
    fi
}

parse_terraform_array() {
    local array_name="$1"
    local role="$2"
    local in_array=false
    local current_block=""
    local brace_count=0
    local parsed_count=0
    log_detail_debug "Parsing array: $array_name (role: $role)"
    log_detail_trace "parse_terraform_array: Starting parse of $array_name"
    if [[ ! -f "$TERRAFORM_TFVARS" ]]; then
        log_detail_warn "Terraform file not found, skipping parse"
        return 0
    fi
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ${array_name}[[:space:]]*=[[:space:]]*\[ ]]; then
            in_array=true
            log_detail_debug "Found array start: $array_name"
            continue
        fi
        [[ "$in_array" != true ]] && continue
        [[ "$line" =~ ^[[:space:]]*\][[:space:]]*$ ]] && break
        current_block+="$line"$'\n'
        [[ "$line" =~ \{ ]] && brace_count=$((brace_count + 1))
        if [[ "$line" =~ \} ]]; then
            brace_count=$((brace_count - 1))
            if [[ $brace_count -eq 0 ]]; then
                local vmid="" name="" node="" cpu="" memory="" disk=""
                local temp_file
                temp_file=$(mktemp)
                echo "$current_block" > "$temp_file"
                vmid=$(grep -E 'vmid[[:space:]]*=' "$temp_file" 2>/dev/null | head -1 | grep -oE '[0-9]+' 2>/dev/null) || vmid=""
                name=$(grep -E 'vm_name[[:space:]]*=' "$temp_file" 2>/dev/null | head -1 | cut -d'"' -f2 2>/dev/null) || name=""
                node=$(grep -E 'node_name[[:space:]]*=' "$temp_file" 2>/dev/null | head -1 | cut -d'"' -f2 2>/dev/null) || node=""
                cpu=$(grep -E 'cpu_cores[[:space:]]*=' "$temp_file" 2>/dev/null | head -1 | grep -oE '[0-9]+' 2>/dev/null) || cpu=""
                memory=$(grep -E 'memory[[:space:]]*=' "$temp_file" 2>/dev/null | head -1 | grep -oE '[0-9]+' 2>/dev/null) || memory=""
                disk=$(grep -E 'disk_size[[:space:]]*=' "$temp_file" 2>/dev/null | head -1 | grep -oE '[0-9]+' 2>/dev/null) || disk=""
                rm -f "$temp_file"
                if [[ -n "$vmid" && -n "$name" ]]; then
                    local value="${name}|${node:-pve1}|${cpu:-4}|${memory:-4096}|${disk:-100}"
                    if [[ "$role" == "control-plane" ]]; then
                        DESIRED_CP_VMIDS["$vmid"]="$value"
                    else
                        DESIRED_WORKER_VMIDS["$vmid"]="$value"
                    fi
                    DESIRED_ALL_VMIDS["$vmid"]="${role}|${name}|${node:-pve1}"
                    log_detail_debug "Parsed ${role}: $name (VMID: $vmid)"
                    parsed_count=$((parsed_count + 1))
                else
                    log_detail_warn "Skipped incomplete block (vmid: ${vmid:-none}, name: ${name:-none})"
                fi
                current_block=""
            fi
        fi
    done < "$TERRAFORM_TFVARS" || {
        log_detail_error "Failed to read from $TERRAFORM_TFVARS"
        return 0
    }
    log_detail_debug "Parsed $parsed_count $role nodes from $array_name"
    log_detail_trace "parse_terraform_array: Completed with $parsed_count nodes"
    return 0
}

load_deployed_state() {
    log_job_info "Loading Deployed State"
    log_job_trace "load_deployed_state: Resetting deployed state arrays"
    DEPLOYED_CP_IPS=()
    DEPLOYED_WORKER_IPS=()
    DEPLOYED_CONFIG_HASH=()
    [[ ! -f "$STATE_FILE" ]] && {
        log_step_debug "No existing state file found - starting fresh"
        BOOTSTRAP_COMPLETED=false
        FIRST_CONTROL_PLANE_VMID=""
        return 0
    }
    log_step_info "Loading: $STATE_FILE"
    run_command jq empty "$STATE_FILE" || {
        log_job_error "State file is corrupted: $STATE_FILE"
        log_job_error "Backup and remove this file to start fresh, or fix the JSON"
        return 1
    }
    BOOTSTRAP_COMPLETED=$(jq -r '.bootstrap_completed // false' "$STATE_FILE")
    FIRST_CONTROL_PLANE_VMID=$(jq -r '.first_control_plane_vmid // empty' "$STATE_FILE")
    [[ "$BOOTSTRAP_COMPLETED" == "true" ]] && log_step_info "Cluster was previously bootstrapped" || log_step_info "Cluster configs applied but bootstrap not completed"
    local stored_hash=$(jq -r '.terraform_hash // empty' "$STATE_FILE")
    [[ -n "$stored_hash" && "$stored_hash" != "$TERRAFORM_HASH" ]] && {
        log_step_info "Terraform configuration has changed since last run"
        log_detail_debug "Old hash: ${stored_hash:0:16}..."
        log_detail_debug "New hash: ${TERRAFORM_HASH:0:16}..."
    }
    local cp_data worker_data entry vmid ip hash
    cp_data=$(jq -c '.deployed_state.control_planes[]? // empty' "$STATE_FILE" 2>/dev/null)
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        vmid=$(echo "$entry" | jq -r '.vmid')
        ip=$(echo "$entry" | jq -r '.ip // empty')
        hash=$(echo "$entry" | jq -r '.config_hash // empty')
        [[ -n "$vmid" && "$vmid" != "null" ]] && {
            DEPLOYED_CP_IPS["$vmid"]="${ip:-}"
            DEPLOYED_CONFIG_HASH["$vmid"]="${hash:-}"
            log_detail_debug "Deployed CP: VMID $vmid -> IP ${ip:-unknown}"
        }
    done <<< "$cp_data"
    worker_data=$(jq -c '.deployed_state.workers[]? // empty' "$STATE_FILE" 2>/dev/null)
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        vmid=$(echo "$entry" | jq -r '.vmid')
        ip=$(echo "$entry" | jq -r '.ip // empty')
        hash=$(echo "$entry" | jq -r '.config_hash // empty')
        [[ -n "$vmid" && "$vmid" != "null" ]] && {
            DEPLOYED_WORKER_IPS["$vmid"]="${ip:-}"
            DEPLOYED_CONFIG_HASH["$vmid"]="${hash:-}"
            log_detail_debug "Deployed Worker: VMID $vmid -> IP ${ip:-unknown}"
        }
    done <<< "$worker_data"
    local cp_count=${#DEPLOYED_CP_IPS[@]}
    local worker_count=${#DEPLOYED_WORKER_IPS[@]}
    log_step_info "Loaded: $cp_count control planes, $worker_count workers"
    log_job_trace "load_deployed_state: CPs=[${!DEPLOYED_CP_IPS[*]}], Workers=[${!DEPLOYED_WORKER_IPS[*]}]"
}

reconcile_cluster() {
    log_stage_info "Reconciling Cluster State"
    log_stage_trace "reconcile_cluster: Starting reconciliation"
    discover_live_state
    build_reconcile_plan
    display_reconcile_plan
    [[ "$PLAN_MODE" == "true" ]] && {
        log_stage_info "Plan mode active - exiting without changes"
        return 0
    }
    local total_changes=$(( ${#PLAN_ADD_CP[@]} + ${#PLAN_ADD_WORKER[@]} + ${#PLAN_REMOVE_CP[@]} + ${#PLAN_REMOVE_WORKER[@]} + ${#PLAN_UPDATE[@]} ))
    [[ "$PLAN_NEED_BOOTSTRAP" == "true" ]] && total_changes=$((total_changes + 1))
    [[ $total_changes -eq 0 ]] && {
        log_stage_info "No changes required - cluster matches desired state"
        return 0
    }
    [[ "$AUTO_APPROVE" != "true" ]] && {
        confirm_proceed "Proceed with reconciliation?" || {
            log_stage_info "Reconciliation cancelled by user"
            exit 0
        }
    }
    log_stage_trace "reconcile_cluster: Completed successfully"
    return 0
}

discover_live_state() {
    log_job_info "Discovering Live Cluster State"
    log_job_trace "discover_live_state: Resetting live state arrays"
    LIVE_NODE_IPS=()
    LIVE_NODE_STATUS=()
    MAC_BY_VMID=()
    VMID_BY_MAC=()
    fetch_proxmox_node_ips
    log_step_debug "Querying Proxmox nodes for VM status"
    declare -A VMID_TO_NODE
    for vmid in "${!DESIRED_ALL_VMIDS[@]}"; do
        local info node
        info="${DESIRED_ALL_VMIDS[$vmid]}"
        node=$(echo "$info" | cut -d'|' -f3)
        VMID_TO_NODE["$vmid"]="$node"
    done
    for vmid in "${!DEPLOYED_CP_IPS[@]}"; do
        [[ -z "${VMID_TO_NODE[$vmid]:-}" ]] && VMID_TO_NODE["$vmid"]="${TF_PROXMOX_NODE:-pve1}"
    done
    for vmid in "${!DEPLOYED_WORKER_IPS[@]}"; do
        [[ -z "${VMID_TO_NODE[$vmid]:-}" ]] && VMID_TO_NODE["$vmid"]="${TF_PROXMOX_NODE:-pve1}"
    done
    [[ ${#VMID_TO_NODE[@]} -eq 0 ]] && {
        log_step_info "No VMs to discover"
        return 0
    }
    log_job_trace "discover_live_state: Checking ${#VMID_TO_NODE[@]} VMs across nodes"
    for vmid in "${!VMID_TO_NODE[@]}"; do
        local node node_ip qm_output ssh_exit_code current_vmid line
        node="${VMID_TO_NODE[$vmid]}"
        node_ip=$(get_node_ip "$node")
        log_step_debug "Querying node $node ($node_ip) for VM $vmid"
        if run_command ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${TF_PROXMOX_SSH_USER}@$node_ip" "echo '===VMID:$vmid==='; qm config $vmid 2>/dev/null || echo 'NOT_FOUND'"; then
            qm_output="$LAST_COMMAND_OUTPUT"
            ssh_exit_code=$LAST_COMMAND_EXIT
        else
            qm_output=""
            ssh_exit_code=$LAST_COMMAND_EXIT
        fi
        [[ $ssh_exit_code -ne 0 ]] && {
            log_step_warn "Failed to connect to Proxmox node $node ($node_ip) - exit code $ssh_exit_code"
            continue
        }
        current_vmid=""
        while IFS= read -r line; do
            [[ "$line" =~ ^===VMID:([0-9]+)===$ ]] && {
                current_vmid="${BASH_REMATCH[1]}"
                continue
            }
            [[ "$line" == "NOT_FOUND" ]] && {
                LIVE_NODE_STATUS["$current_vmid"]="not_found"
                current_vmid=""
                continue
            }
            [[ -n "$current_vmid" && "$line" =~ ^net[0-9]+:[[:space:]]*virtio=([0-9A-Fa-f:]+) ]] && {
                local mac="${BASH_REMATCH[1]}"
                mac=$(echo "$mac" | tr '[:lower:]' '[:upper:]')
                MAC_BY_VMID["$current_vmid"]="$mac"
                VMID_BY_MAC["$mac"]="$current_vmid"
                log_job_debug "MAC: VM $current_vmid -> $mac (on node $node)"
            }
        done <<< "$qm_output"
    done
    local main_node=$(get_node_ip "pve1")
    log_step_debug "Populating ARP table from main node ($main_node)"
    populate_arp_table "$main_node" || {
        log_step_warn "Failed to populate ARP from main node, trying fallback..."
        for vmid in "${!VMID_TO_NODE[@]}"; do
            local fallback_node fallback_ip
            fallback_node="${VMID_TO_NODE[$vmid]}"
            fallback_ip=$(get_node_ip "$fallback_node")
            [[ "$fallback_ip" != "$main_node" ]] && {
                log_step_info "Trying ARP from $fallback_node ($fallback_ip)"
                populate_arp_table "$fallback_ip" && break
            }
        done
    }
    log_step_debug "ARP discovery complete: ${#LIVE_NODE_IPS[@]} of ${#VMID_TO_NODE[@]} VMs found"
    [[ ${#LIVE_NODE_IPS[@]} -lt ${#VMID_TO_NODE[@]} ]] && {
        local missing_vms=""
        for vmid in "${!VMID_TO_NODE[@]}"; do
            [[ -z "${LIVE_NODE_IPS[$vmid]:-}" ]] && missing_vms+="$vmid "
        done
        log_step_warn "Missing IPs for VMs: $missing_vms"
    }
    log_step_debug "MAC to VMID mapping (${#VMID_BY_MAC[@]} entries):"
    for mac in "${!VMID_BY_MAC[@]}"; do
        local vmid="${VMID_BY_MAC[$mac]}"
        log_step_debug "  MAC $mac -> VM $vmid"
    done
    log_step_debug "VMID to IP mapping (${#LIVE_NODE_IPS[@]} entries):"
    for vmid in "${!LIVE_NODE_IPS[@]}"; do
        log_step_debug "  VM $vmid -> IP ${LIVE_NODE_IPS[$vmid]}"
    done
    log_step_debug "Checking Talos cluster membership"
    local first_cp_ip=""
    [[ -n "${FIRST_CONTROL_PLANE_VMID:-}" && -n "${DEPLOYED_CP_IPS[$FIRST_CONTROL_PLANE_VMID]:-}" ]] && {
        first_cp_ip="${DEPLOYED_CP_IPS[$FIRST_CONTROL_PLANE_VMID]}"
    } || {
        [[ ${#DEPLOYED_CP_IPS[@]} -gt 0 ]] && {
            for vmid in "${!DEPLOYED_CP_IPS[@]}"; do
                first_cp_ip="${DEPLOYED_CP_IPS[$vmid]}"
                break
            done
        }
    }
    [[ -n "$first_cp_ip" ]] && {
        local talos_members
        if run_command talosctl get members -o json --endpoints "$first_cp_ip" --insecure; then
            talos_members="$LAST_COMMAND_OUTPUT"
            echo "$talos_members" | jq -r '.[] | "\(.metadata.name)|\(.metadata.labels."node-role.kubernetes.io/control-plane" // "worker")"' 2>/dev/null | while IFS='|' read -r node_name role; do
                for vmid in "${!LIVE_NODE_IPS[@]}"; do
                    local ip="${LIVE_NODE_IPS[$vmid]}"
                    [[ "$node_name" == "$ip" || "$node_name" == *"$ip"* ]] && {
                        LIVE_NODE_STATUS["$vmid"]="joined"
                        log_detail_debug "VM $vmid is joined to cluster as $role"
                        break
                    }
                done
            done
        fi
    } || log_step_info "No control plane IP available for membership check"
    for vmid in "${!LIVE_NODE_IPS[@]}"; do
        [[ -z "${LIVE_NODE_STATUS[$vmid]:-}" ]] && LIVE_NODE_STATUS["$vmid"]="discovered"
    done
    log_step_debug "Discovery complete: ${#LIVE_NODE_IPS[@]} nodes found"
    log_job_trace "discover_live_state: Final state - ${#LIVE_NODE_IPS[@]} IPs, ${#LIVE_NODE_STATUS[@]} statuses"
}

build_reconcile_plan() {
    log_job_info "Building Reconciliation Plan"
    log_job_trace "build_reconcile_plan: Starting with ${#DESIRED_CP_VMIDS[@]} desired CPs, ${#DESIRED_WORKER_VMIDS[@]} desired workers"
    local old_plan_add_cp="${PLAN_ADD_CP[*]}"
    local old_plan_add_worker="${PLAN_ADD_WORKER[*]}"
    local old_deployed_cp="${!DEPLOYED_CP_IPS[*]}"
    PLAN_ADD_CP=()
    PLAN_ADD_WORKER=()
    PLAN_REMOVE_CP=()
    PLAN_REMOVE_WORKER=()
    PLAN_UPDATE=()
    PLAN_NOOP=()
    PLAN_NEED_BOOTSTRAP=false
    log_step_debug "Checking for new nodes to add"
    for vmid in "${!DESIRED_CP_VMIDS[@]}"; do
        [[ -z "${DEPLOYED_CP_IPS[$vmid]:-}" && -z "${DEPLOYED_WORKER_IPS[$vmid]:-}" ]] && {
            PLAN_ADD_CP+=("$vmid")
            log_file_only "RECONCILE" "ADD_CP: $vmid"
            log_detail_trace "build_reconcile_plan: Will add CP VM $vmid"
        }
    done
    for vmid in "${!DESIRED_WORKER_VMIDS[@]}"; do
        [[ -z "${DEPLOYED_CP_IPS[$vmid]:-}" && -z "${DEPLOYED_WORKER_IPS[$vmid]:-}" ]] && {
            PLAN_ADD_WORKER+=("$vmid")
            log_file_only "RECONCILE" "ADD_WORKER: $vmid"
            log_detail_trace "build_reconcile_plan: Will add Worker VM $vmid"
        }
    done
    log_step_debug "Checking for nodes to remove"
    for vmid in "${!DEPLOYED_CP_IPS[@]}"; do
        [[ -z "${DESIRED_CP_VMIDS[$vmid]:-}" ]] && {
            PLAN_REMOVE_CP+=("$vmid")
            log_file_only "RECONCILE" "REMOVE_CP: $vmid"
            log_detail_trace "build_reconcile_plan: Will remove CP VM $vmid"
        }
    done
    for vmid in "${!DEPLOYED_WORKER_IPS[@]}"; do
        [[ -z "${DESIRED_WORKER_VMIDS[$vmid]:-}" ]] && {
            PLAN_REMOVE_WORKER+=("$vmid")
            log_file_only "RECONCILE" "REMOVE_WORKER: $vmid"
            log_detail_trace "build_reconcile_plan: Will remove Worker VM $vmid"
        }
    done
    log_state_change "PLAN_ADD_CP" "$old_plan_add_cp" "${PLAN_ADD_CP[*]}"
    log_step_debug "Checking for configuration drift"
    for vmid in "${!DESIRED_CP_VMIDS[@]}"; do
        [[ -n "${DEPLOYED_CP_IPS[$vmid]:-}" ]] && {
            local current_hash new_hash config_file
            current_hash="${DEPLOYED_CONFIG_HASH[$vmid]:-}"
            config_file="$NODES_DIR/node-control-plane-${vmid}.yaml"
            [[ -f "$config_file" ]] && {
                run_command sha256sum "$config_file"
                new_hash=$(echo "$LAST_COMMAND_OUTPUT" | cut -d' ' -f1)
                if [[ "$current_hash" != "$new_hash" || "$FORCE_RECONFIGURE" == "true" ]]; then
                    PLAN_UPDATE+=("$vmid:control-plane")
                    log_file_only "RECONCILE" "UPDATE: $vmid (hash changed)"
                    log_detail_debug "Config drift detected for CP $vmid: ${current_hash:0:16} -> ${new_hash:0:16}"
                else
                    PLAN_NOOP+=("$vmid")
                    log_detail_trace "build_reconcile_plan: CP $vmid unchanged"
                fi
            }
        }
    done
    for vmid in "${!DESIRED_WORKER_VMIDS[@]}"; do
        [[ -n "${DEPLOYED_WORKER_IPS[$vmid]:-}" ]] && {
            local current_hash new_hash config_file
            current_hash="${DEPLOYED_CONFIG_HASH[$vmid]:-}"
            config_file="$NODES_DIR/node-worker-${vmid}.yaml"
            [[ -f "$config_file" ]] && {
                run_command sha256sum "$config_file"
                new_hash=$(echo "$LAST_COMMAND_OUTPUT" | cut -d' ' -f1)
                if [[ "$current_hash" != "$new_hash" || "$FORCE_RECONFIGURE" == "true" ]]; then
                    PLAN_UPDATE+=("$vmid:worker")
                    log_file_only "RECONCILE" "UPDATE: $vmid (hash changed)"
                    log_detail_debug "Config drift detected for Worker $vmid: ${current_hash:0:16} -> ${new_hash:0:16}"
                else
                    PLAN_NOOP+=("$vmid")
                    log_detail_trace "build_reconcile_plan: Worker $vmid unchanged"
                fi
            }
        }
    done

    [[ "$BOOTSTRAP_COMPLETED" != "true" && ${#DEPLOYED_CP_IPS[@]} -gt 0 ]] && {
        log_step_warn "Cluster has ${#DEPLOYED_CP_IPS[@]} control planes but bootstrap was never completed"
        log_step_warn "Will attempt to bootstrap before proceeding with other changes"
        PLAN_NEED_BOOTSTRAP=true
    }
    log_job_trace "build_reconcile_plan: Plan complete - Add CP: ${#PLAN_ADD_CP[@]} Add Worker: ${#PLAN_ADD_WORKER[@]} Remove CP: ${#PLAN_REMOVE_CP[@]} Remove Worker: ${#PLAN_REMOVE_WORKER[@]} Update: ${#PLAN_UPDATE[@]} Noop: ${#PLAN_NOOP[@]}"
    return 0
}

format_node_display() {
    local vmid="$1"
    local name="$2"
    local node="$3"
    local ip="${4:-}"
    [[ -n "$ip" ]] && echo "VMID ${C_COUNT}${vmid}${C_RESET}  ${C_NAME}${name}${C_RESET}  node: ${C_NODE}${node}${C_RESET}  IP: ${C_IP}${ip}${C_RESET}" || echo "VMID ${C_COUNT}${vmid}${C_RESET}  ${C_NAME}${name}${C_RESET}  node: ${C_NODE}${node}${C_RESET}"
}

display_reconcile_plan() {
    log_job_info "Reconciliation Plan Summary"
    print_box_header "RECONCILIATION PLAN"
    [[ "$PLAN_NEED_BOOTSTRAP" == "true" ]] && {
        print_box_badge "BOOTSTRAP" "Cluster needs bootstrap" "$C_WARN"
        print_box_wrapped "" "Cluster has configs applied but was never bootstrapped. Bootstrap will be attempted first." "$C_VALUE" "$C_VALUE"
        print_border divider
    }
    [[ ${#PLAN_ADD_CP[@]} -gt 0 ]] && {
        print_box_section "ADD CONTROL PLANES"
        for vmid in "${PLAN_ADD_CP[@]}"; do
            local info name node
            info="${DESIRED_CP_VMIDS[$vmid]}"
            name=$(echo "$info" | cut -d'|' -f1)
            node=$(echo "$info" | cut -d'|' -f2)
            print_box_item "" "$(format_node_display "$vmid" "$name" "$node")"
        done
        print_border divider
    }
    [[ ${#PLAN_ADD_WORKER[@]} -gt 0 ]] && {
        print_box_section "ADD WORKERS"
        for vmid in "${PLAN_ADD_WORKER[@]}"; do
            local info name node
            info="${DESIRED_WORKER_VMIDS[$vmid]}"
            name=$(echo "$info" | cut -d'|' -f1)
            node=$(echo "$info" | cut -d'|' -f2)
            print_box_item "" "$(format_node_display "$vmid" "$name" "$node")"
        done
        print_border divider
    }
    [[ ${#PLAN_REMOVE_CP[@]} -gt 0 ]] && {
        print_box_section "REMOVE CONTROL PLANES"
        for vmid in "${PLAN_REMOVE_CP[@]}"; do
            local ip="${DEPLOYED_CP_IPS[$vmid]:-unknown}"
            print_box_item "" "VMID ${C_COUNT}${vmid}${C_RESET}  IP: ${C_IP}${ip}${C_RESET}"
        done
        print_border divider
    }
    [[ ${#PLAN_REMOVE_WORKER[@]} -gt 0 ]] && {
        print_box_section "REMOVE WORKERS"
        for vmid in "${PLAN_REMOVE_WORKER[@]}"; do
            local ip="${DEPLOYED_WORKER_IPS[$vmid]:-unknown}"
            print_box_item "" "VMID ${C_COUNT}${vmid}${C_RESET}  IP: ${C_IP}${ip}${C_RESET}"
        done
        print_border divider
    }
    [[ ${#PLAN_UPDATE[@]} -gt 0 ]] && {
        print_box_section "UPDATE CONFIGURATIONS"
        for entry in "${PLAN_UPDATE[@]}"; do
            local vmid role info name node
            vmid=$(echo "$entry" | cut -d':' -f1)
            role=$(echo "$entry" | cut -d':' -f2)
            info="${DESIRED_ALL_VMIDS[$vmid]:-}"
            name=$(echo "$info" | cut -d'|' -f2)
            node=$(echo "$info" | cut -d'|' -f3)
            print_box_item "" "VMID ${C_COUNT}${vmid}${C_RESET}  ${C_NAME}${name}${C_RESET}  role: ${C_ROLE}${role}${C_RESET}  node: ${C_NODE}${node}${C_RESET}"
        done
        print_border divider
    }
    [[ ${#PLAN_NOOP[@]} -gt 0 ]] && {
        print_box_line "  ${C_LABEL}UNCHANGED:${C_RESET} ${C_COUNT}${#PLAN_NOOP[@]}${C_RESET} nodes up-to-date"
        print_border divider
    }
    local total_ops=$(( ${#PLAN_ADD_CP[@]} + ${#PLAN_ADD_WORKER[@]} + ${#PLAN_REMOVE_CP[@]} + ${#PLAN_REMOVE_WORKER[@]} + ${#PLAN_UPDATE[@]} ))
    [[ "$PLAN_NEED_BOOTSTRAP" == "true" ]] && total_ops=$((total_ops + 1))
    print_box_line "  ${C_LABEL}TOTAL OPERATIONS:${C_RESET} ${C_COUNT}${total_ops}${C_RESET}"
    [[ "$DRY_RUN" == "true" ]] && print_box_badge "DRY-RUN" "No changes will be made" "$C_WARN"
    [[ "$PLAN_MODE" == "true" ]] && print_box_badge "PLAN" "Review the plan above, then run without --plan to apply" "$C_WARN"
    print_box_footer
}

execute_reconcile_plan() {
    log_job_info "Executing Reconciliation Plan"
    log_job_trace "execute_reconcile_plan: Starting execution"
    [[ "$DRY_RUN" == "true" ]] && log_step_info "Dry run mode - simulating operations"
    [[ "$PLAN_NEED_BOOTSTRAP" == "true" ]] && {
        run_bootstrap || {
            log_stage_error "Bootstrap failed, but configs are applied"
            log_stage_error "You can retry with: ./bootstrap.sh bootstrap"
        }
    }
    [[ ${#PLAN_REMOVE_WORKER[@]} -gt 0 ]] && {
        log_stage_info "Phase 1a: Removing Workers"
        for vmid in "${PLAN_REMOVE_WORKER[@]}"; do remove_worker "$vmid"; done
    }
    [[ ${#PLAN_REMOVE_CP[@]} -gt 0 ]] && {
        log_stage_info "Phase 1b: Removing Control Planes"
        for vmid in "${PLAN_REMOVE_CP[@]}"; do remove_control_plane "$vmid"; done
    }
    [[ ${#PLAN_UPDATE[@]} -gt 0 ]] && {
        log_stage_info "Phase 2: Updating Node Configurations"
        for entry in "${PLAN_UPDATE[@]}"; do
            local vmid role
            vmid=$(echo "$entry" | cut -d':' -f1)
            role=$(echo "$entry" | cut -d':' -f2)
            update_node_config "$vmid" "$role"
        done
    }
    [[ ${#PLAN_ADD_CP[@]} -gt 0 ]] && {
        log_stage_info "Phase 3a: Adding Control Planes"
        for vmid in "${PLAN_ADD_CP[@]}"; do
            add_control_plane "$vmid" || log_step_warn "Failed to add control plane VM $vmid, continuing with others..."
        done
    }
    [[ ${#PLAN_ADD_WORKER[@]} -gt 0 ]] && {
        log_stage_info "Phase 3b: Adding Workers"
        for vmid in "${PLAN_ADD_WORKER[@]}"; do
            add_worker "$vmid" || log_step_warn "Failed to add worker VM $vmid, continuing with others..."
        done
    }
    [[ ${#PLAN_ADD_CP[@]} -gt 0 || ${#PLAN_REMOVE_CP[@]} -gt 0 || ${#PLAN_UPDATE[@]} -gt 0 ]] && {
        log_stage_info "Phase 4: Updating HAProxy Configuration"
        update_haproxy_from_state
    }
    [[ ${#PLAN_ADD_CP[@]} -gt 0 && "$BOOTSTRAP_COMPLETED" != "true" ]] && {
        run_bootstrap || {
            log_stage_error "Bootstrap failed after adding control planes"
            log_stage_error "You can retry with: ./bootstrap.sh bootstrap"
        }
    }
    save_state
    log_plan_info "Reconciliation complete"
    log_job_trace "execute_reconcile_plan: Execution completed"
}

add_control_plane() {
    local vmid=$1
    local info name ip config_file config_hash
    info="${DESIRED_CP_VMIDS[$vmid]}"
    name=$(echo "$info" | cut -d'|' -f1)
    log_step_info "Adding control plane VM $vmid ($name)"
    log_step_trace "add_control_plane: Starting for VM $vmid"
    [[ "$DRY_RUN" == "true" ]] && {
        log_step_info "[DRY-RUN] Would apply config to VM $vmid"
        return 0
    }
    ip=$(discover_ip_for_vmid "$vmid") || {
        log_step_error "Could not discover IP for VM $vmid"
        return 1
    }
    log_step_info "Discovered IP: $ip"
    config_file="$NODES_DIR/node-control-plane-${vmid}.yaml"
    [[ ! -f "$config_file" ]] && generate_node_config "$vmid" "control-plane"
    local apply_output result_ip reboot_triggered
    apply_output=$(apply_config_with_rediscovery "$vmid" "$ip" "$config_file" "control-plane")
    if [[ $? -ne 0 ]]; then
        log_step_error "Failed to apply config to VM $vmid"
        return 1
    fi
    result_ip=$(echo "$apply_output" | head -1)
    reboot_triggered=$(echo "$apply_output" | tail -1)
    [[ -n "$result_ip" ]] && ip="$result_ip"
    wait_for_node_with_rediscovery "$vmid" "$ip" 120 "control-plane" "false" "$reboot_triggered" || {
        log_step_error "Control plane $vmid did not become ready"
        return 1
    }
    [[ -n "$REDISCOVERED_IP" ]] && ip="$REDISCOVERED_IP"
    DEPLOYED_CP_IPS["$vmid"]="$ip"
    run_command sha256sum "$config_file"
    config_hash=$(echo "$LAST_COMMAND_OUTPUT" | cut -d' ' -f1)
    DEPLOYED_CONFIG_HASH["$vmid"]="$config_hash"
    run_command mkdir -p "$CHECKSUM_DIR"
    if write_file_audited "$config_hash" "$CHECKSUM_DIR/cp-${vmid}.sha256"; then
        log_step_info "Control plane VM $vmid added successfully (IP: $ip)"
        log_file_only "DEPLOY" "SUCCESS: CP $vmid at $ip"
    fi
    log_step_trace "add_control_plane: Completed for VM $vmid"
    return 0
}

add_worker() {
    local vmid=$1
    local info name ip config_file config_hash
    info="${DESIRED_WORKER_VMIDS[$vmid]}"
    name=$(echo "$info" | cut -d'|' -f1)
    log_step_info "Adding worker VM $vmid ($name)"
    log_step_trace "add_worker: Starting for VM $vmid"
    [[ "$DRY_RUN" == "true" ]] && {
        log_step_info "[DRY-RUN] Would apply config to VM $vmid"
        return 0
    }
    ip=$(discover_ip_for_vmid "$vmid") || {
        log_step_error "Could not discover IP for VM $vmid"
        return 1
    }
    log_step_info "Discovered IP: $ip"
    config_file="$NODES_DIR/node-worker-${vmid}.yaml"
    [[ ! -f "$config_file" ]] && generate_node_config "$vmid" "worker"
    local apply_output result_ip reboot_triggered
    apply_output=$(apply_config_with_rediscovery "$vmid" "$ip" "$config_file" "worker")
    if [[ $? -ne 0 ]]; then
        log_step_error "Failed to apply config to VM $vmid"
        return 1
    fi
    result_ip=$(echo "$apply_output" | head -1)
    reboot_triggered=$(echo "$apply_output" | tail -1)
    [[ -n "$result_ip" ]] && ip="$result_ip"
    wait_for_node_with_rediscovery "$vmid" "$ip" 120 "worker" "false" "$reboot_triggered" || {
        log_step_warn "Worker $vmid did not become ready in expected time, but may join cluster later"
    }
    [[ -n "$REDISCOVERED_IP" ]] && ip="$REDISCOVERED_IP"
    DEPLOYED_WORKER_IPS["$vmid"]="$ip"
    run_command sha256sum "$config_file"
    config_hash=$(echo "$LAST_COMMAND_OUTPUT" | cut -d' ' -f1)
    DEPLOYED_CONFIG_HASH["$vmid"]="$config_hash"
    run_command mkdir -p "$CHECKSUM_DIR"
    if write_file_audited "$config_hash" "$CHECKSUM_DIR/worker-${vmid}.sha256"; then
        log_step_info "Worker VM $vmid added successfully (IP: $ip)"
        log_file_only "DEPLOY" "SUCCESS: Worker $vmid at $ip"
    fi
    log_step_trace "add_worker: Completed for VM $vmid"
    return 0
}

remove_control_plane() {
    local vmid=$1
    local ip="${DEPLOYED_CP_IPS[$vmid]:-}"
    log_step_info "Removing control plane VM $vmid"
    log_step_trace "remove_control_plane: Starting for VM $vmid"
    [[ -z "$ip" ]] && {
        log_step_warn "No IP recorded for VM $vmid, attempting discovery"
        ip=$(discover_ip_for_vmid "$vmid" 2>/dev/null || echo "")
    }
    local current_cp_count=${#DEPLOYED_CP_IPS[@]}
    local desired_cp_count=${#DESIRED_CP_VMIDS[@]}
    local min_quorum=$(( (desired_cp_count / 2) + 1 ))
    local healthy_members=$(run_command talosctl etcd members 2>/dev/null | grep -c "Healthy" || echo "0")
    local after_removal=$((healthy_members - 1))
    [[ $after_removal -lt $min_quorum ]] && {
        log_step_error "Cannot remove VM $vmid: would violate etcd quorum"
        log_step_error "Current healthy: $healthy_members, after removal: $after_removal, required: $min_quorum"
        log_step_error "Add more control planes to terraform before removing this one"
        return 1
    }
    [[ "$AUTO_APPROVE" != "true" ]] && {
        echo -n "Confirm removal of control plane VM $vmid (IP: ${ip:-unknown})? [y/N] "
        read -r response
        [[ ! "$response" =~ ^[Yy]$ ]] && {
            log_step_info "Removal of VM $vmid cancelled"
            return 1
        }
    }
    [[ "$DRY_RUN" == "true" ]] && {
        log_step_info "[DRY-RUN] Would remove VM $vmid from cluster"
        return 0
    }
    local node_name=""
    [[ -n "$ip" && -f "$KUBECONFIG_PATH" ]] && node_name=$(run_command kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes -o wide 2>/dev/null | grep "$ip" | awk '{print $1}')
    [[ -n "$node_name" ]] && {
        log_step_info "Draining node $node_name..."
        run_command kubectl --kubeconfig "$KUBECONFIG_PATH" cordon "$node_name" || true
        run_command kubectl --kubeconfig "$KUBECONFIG_PATH" drain "$node_name" --ignore-daemonsets --delete-emptydir-data --timeout=300s || log_step_warn "Drain incomplete"
    }
    [[ -n "$ip" ]] && {
        log_step_info "Removing from etcd..."
        run_command talosctl etcd remove-member --nodes "$ip" 2>/dev/null || log_step_warn "etcd remove failed (may already be removed)"
    }
    [[ -n "$node_name" ]] && {
        log_step_info "Removing from Kubernetes..."
        run_command kubectl --kubeconfig "$KUBECONFIG_PATH" delete node "$node_name" --timeout=60s || true
    }
    unset DEPLOYED_CP_IPS["$vmid"]
    unset DEPLOYED_CONFIG_HASH["$vmid"]
    run_command rm -f "$CHECKSUM_DIR/cp-${vmid}.sha256"
    log_step_info "Control plane VM $vmid removed"
    log_file_only "DEPLOY" "REMOVED: CP $vmid"
    log_step_trace "remove_control_plane: Completed for VM $vmid"
}

remove_worker() {
    local vmid=$1
    local ip="${DEPLOYED_WORKER_IPS[$vmid]:-}"
    log_step_info "Removing worker VM $vmid"
    log_step_trace "remove_worker: Starting for VM $vmid"
    [[ -z "$ip" ]] && ip=$(discover_ip_for_vmid "$vmid" 2>/dev/null || echo "")
    [[ "$DRY_RUN" == "true" ]] && {
        log_step_info "[DRY-RUN] Would remove VM $vmid from cluster"
        return 0
    }
    local node_name=""
    [[ -n "$ip" && -f "$KUBECONFIG_PATH" ]] && node_name=$(run_command kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes -o wide 2>/dev/null | grep "$ip" | awk '{print $1}')
    [[ -n "$node_name" ]] && {
        log_step_info "Draining worker node $node_name..."
        run_command kubectl --kubeconfig "$KUBECONFIG_PATH" cordon "$node_name" || true
        run_command kubectl --kubeconfig "$KUBECONFIG_PATH" drain "$node_name" --ignore-daemonsets --delete-emptydir-data --timeout=180s || log_step_warn "Drain incomplete"
        run_command kubectl --kubeconfig "$KUBECONFIG_PATH" delete node "$node_name" || true
    }
    unset DEPLOYED_WORKER_IPS["$vmid"]
    unset DEPLOYED_CONFIG_HASH["$vmid"]
    run_command rm -f "$CHECKSUM_DIR/worker-${vmid}.sha256"
    log_step_info "Worker VM $vmid removed"
    log_file_only "DEPLOY" "REMOVED: Worker $vmid"
    log_step_trace "remove_worker: Completed for VM $vmid"
}

update_node_config() {
    local vmid=$1
    local role=$2
    local ip="" config_file new_hash
    log_step_info "Updating configuration for VM $vmid ($role)"
    log_step_trace "update_node_config: Starting for VM $vmid, role=$role"
    [[ "$role" == "control-plane" ]] && ip="${DEPLOYED_CP_IPS[$vmid]:-}" || ip="${DEPLOYED_WORKER_IPS[$vmid]:-}"
    [[ -z "$ip" ]] && ip=$(discover_ip_for_vmid "$vmid" 2>/dev/null || echo "")
    [[ -z "$ip" ]] && {
        log_step_error "Cannot find IP for VM $vmid"
        return 1
    }
    config_file="$NODES_DIR/node-${role}-${vmid}.yaml"
    [[ "$DRY_RUN" == "true" ]] && {
        log_step_info "[DRY-RUN] Would reapply config to VM $vmid"
        return 0
    }
    if run_command talosctl apply-config --nodes "$ip" --file "$config_file"; then
        log_step_info "Configuration updated for VM $vmid"
        run_command sha256sum "$config_file"
        new_hash=$(echo "$LAST_COMMAND_OUTPUT" | cut -d' ' -f1)
        DEPLOYED_CONFIG_HASH["$vmid"]="$new_hash"
        write_file_audited "$new_hash" "$CHECKSUM_DIR/${role}-${vmid}.sha256"
        log_file_only "DEPLOY" "UPDATED: $role $vmid"
    else
        log_step_error "Failed to update config for VM $vmid"
        return 1
    fi
    log_step_trace "update_node_config: Completed for VM $vmid"
}

generate_node_config() {
    local vmid=$1
    local role=$2
    local info name node cpu memory disk patch_file base_config output_file config_hash
    [[ "$role" == "control-plane" ]] && info="${DESIRED_CP_VMIDS[$vmid]}" || info="${DESIRED_WORKER_VMIDS[$vmid]}"
    name=$(echo "$info" | cut -d'|' -f1)
    node=$(echo "$info" | cut -d'|' -f2)
    cpu=$(echo "$info" | cut -d'|' -f3)
    memory=$(echo "$info" | cut -d'|' -f4)
    disk=$(echo "$info" | cut -d'|' -f5)
    log_step_info "Generating config for $name (VMID: $vmid)"
    log_step_trace "generate_node_config: role=$role, node=$node, cpu=$cpu, memory=$memory, disk=$disk"
    patch_file="${NODES_DIR}/.patches/${role}-${vmid}.yaml"
    run_command mkdir -p "${NODES_DIR}/.patches"
    local patch_content
    [[ "$role" == "control-plane" ]] && patch_content=$(generate_control_plane_patch "$vmid" "$name") || patch_content=$(generate_worker_patch "$vmid" "$name")
    write_file_audited "$patch_content" "$patch_file"
    base_config="$SECRETS_DIR/${role}.yaml"
    [[ ! -f "$base_config" ]] && generate_base_configs
    output_file="$NODES_DIR/node-${role}-${vmid}.yaml"
    run_command talosctl machineconfig patch "$base_config" --patch "@$patch_file" --output "$output_file" || {
        log_step_error "talosctl machineconfig patch failed for VM $vmid"
        log_step_error "Base config: $base_config"
        log_step_error "Patch file: $patch_file"
        log_step_error "Output file: $output_file"
        run_command rm -f "$patch_file" "$output_file"
        return 1
    }
    run_command rm -f "$patch_file"
    log_config_generated "$output_file"
    run_command sha256sum "$output_file"
    config_hash=$(echo "$LAST_COMMAND_OUTPUT" | cut -d' ' -f1)
    run_command mkdir -p "$CHECKSUM_DIR"

    write_file_audited "$config_hash" "$CHECKSUM_DIR/${role}-${vmid}.sha256"
    log_step_trace "generate_node_config: Completed for VM $vmid, hash=${config_hash:0:16}"
}

generate_base_configs() {
    log_step_info "Generating base Talos configurations"
    log_step_trace "generate_base_configs: Starting with secrets=$SECRETS_FILE"
    [[ ! -f "$SECRETS_FILE" ]] && {
        log_step_info "Generating secrets"
        run_command talosctl gen secrets -o "$SECRETS_FILE" && chmod 600 "$SECRETS_FILE" || log_job_fatal "Failed to generate secrets"
    }
    run_command talosctl gen config --with-secrets "$SECRETS_FILE" --kubernetes-version "$KUBERNETES_VERSION" --talos-version "$TALOS_VERSION" --install-image "$INSTALLER_IMAGE" --additional-sans "${HAPROXY_IP},${CONTROL_PLANE_ENDPOINT},127.0.0.1" "$CLUSTER_NAME" "https://${CONTROL_PLANE_ENDPOINT}:6443" || log_job_fatal "Failed to generate base configurations"
    [[ -f "controlplane.yaml" ]] && run_command mv controlplane.yaml "$SECRETS_DIR/control-plane.yaml" && chmod 600 "$SECRETS_DIR/control-plane.yaml"
    [[ -f "worker.yaml" ]] && run_command mv worker.yaml "$SECRETS_DIR/" && chmod 600 "$SECRETS_DIR/worker.yaml"
    [[ -f "talosconfig" ]] && run_command mv talosconfig "$TALOSCONFIG" && chmod 600 "$TALOSCONFIG"
    export TALOSCONFIG
    log_step_info "Talos config saved to $TALOSCONFIG"
    log_step_trace "generate_base_configs: Completed"
}

generate_control_plane_patch() {
    local vmid=$1
    local name=$2
    cat <<EOF
machine:
  install:
    disk: /dev/${DEFAULT_DISK}
    extraKernelArgs:
      - console=tty0
      - console=ttyS0
  network:
    interfaces:
      - interface: ${DEFAULT_NETWORK_INTERFACE}
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
}

generate_worker_patch() {
    local vmid=$1
    local name=$2
    cat <<EOF
machine:
  install:
    disk: /dev/${DEFAULT_DISK}
    extraKernelArgs:
      - console=tty0
      - console=ttyS0
  network:
    interfaces:
      - interface: ${DEFAULT_NETWORK_INTERFACE}
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

discover_ip_for_vmid() {
    local vmid=$1
    log_detail_trace "discover_ip_for_vmid: Starting for VM $vmid"
    if [[ -n "${LIVE_NODE_IPS[$vmid]:-}" ]]; then
        log_detail_debug "Using live discovered IP for VM $vmid: ${LIVE_NODE_IPS[$vmid]}"
        echo "${LIVE_NODE_IPS[$vmid]}"
        return 0
    fi
    local host
    if [[ -n "${DESIRED_ALL_VMIDS[$vmid]:-}" ]]; then
        local info node_name
        info="${DESIRED_ALL_VMIDS[$vmid]}"
        node_name=$(echo "$info" | cut -d'|' -f3)
        host=$(get_node_ip "$node_name")
    else
        host=$(get_node_ip "pve1")
    fi
    log_detail_trace "discover_ip_for_vmid: Checking host $host for VM $vmid"
    local mac="${MAC_BY_VMID[$vmid]:-}"
    if [[ -z "$mac" ]]; then
        log_detail_trace "discover_ip_for_vmid: No cached MAC, fetching from Proxmox"
        if run_command ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
                "${TF_PROXMOX_SSH_USER}@$host" \
                "qm config $vmid | grep -E '^net[0-9]+:' | head -1 | grep -oE 'virtio=[0-9A-Fa-f:]+' | cut -d= -f2"; then
            mac="$LAST_COMMAND_OUTPUT"
        fi
        if [[ -n "$mac" ]]; then
            MAC_BY_VMID["$vmid"]="$mac"
            log_detail_debug "Fetched MAC $mac for VM $vmid"
        fi
    fi
    if [[ -n "$mac" ]]; then
        local subnet
        subnet=$(get_network_subnet "$host")
        log_detail_trace "discover_ip_for_vmid: Pinging subnet $subnet for VM $vmid"
        run_command ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            "${TF_PROXMOX_SSH_USER}@$host" \
            "seq 1 254 | xargs -P 50 -I{} ping -c 1 -W 1 ${subnet}.{} >/dev/null 2>&1 || true" || true
        sleep 2
        local all_ips
        if run_command ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
                "${TF_PROXMOX_SSH_USER}@$host" \
                "cat /proc/net/arp | grep -i '$mac' | awk '{print \$1}'"; then
            all_ips="$LAST_COMMAND_OUTPUT"
        fi
        if [[ -n "$all_ips" ]]; then
            log_detail_debug "Found ARP entries for VM $vmid MAC $mac"
            local ip
            while IFS= read -r ip; do
                ip=$(echo "$ip" | tr -d '\r\n')
                [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
                if ping -c 1 -W 2 "$ip" &>/dev/null; then
                    LIVE_NODE_IPS["$vmid"]="$ip"
                    log_detail_debug "Discovered reachable IP via ARP for VM $vmid: $ip"
                    echo "$ip"
                    return 0
                else
                    log_detail_trace "discover_ip_for_vmid: IP $ip found in ARP but not reachable"
                fi
            done <<< "$all_ips" || true
            local first_valid_ip
            first_valid_ip=$(echo "$all_ips" | tr -d '\r' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
            if [[ -n "$first_valid_ip" ]]; then
                LIVE_NODE_IPS["$vmid"]="$first_valid_ip"
                log_detail_warn "No reachable IP found for VM $vmid, using first ARP entry: $first_valid_ip"
                echo "$first_valid_ip"
                return 0
            fi
        fi
    fi
    if [[ -n "${DEPLOYED_CP_IPS[$vmid]:-}" ]]; then
        log_detail_debug "Using cached control plane IP for VM $vmid: ${DEPLOYED_CP_IPS[$vmid]}"
        echo "${DEPLOYED_CP_IPS[$vmid]}"
        return 0
    fi
    if [[ -n "${DEPLOYED_WORKER_IPS[$vmid]:-}" ]]; then
        log_detail_debug "Using cached worker IP for VM $vmid: ${DEPLOYED_WORKER_IPS[$vmid]}"
        echo "${DEPLOYED_WORKER_IPS[$vmid]}"
        return 0
    fi
    log_detail_error "discover_ip_for_vmid: Could not find IP for VM $vmid"
    return 1
}

populate_arp_table() {
    local host="$1"
    local subnet=$(get_network_subnet "$host")
    log_step_debug "[ARP-SCAN] Populating ARP table from $host (subnet: $subnet.0/24)"
    run_command ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${TF_PROXMOX_SSH_USER}@$host" "ip -s -s neigh flush all" || true
    log_step_debug "[ARP-SCAN] Pinging ${subnet}.0/24..."
    run_command ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${TF_PROXMOX_SSH_USER}@$host" "seq 1 254 | xargs -P 100 -I{} ping -c 1 -W 1 ${subnet}.{} >/dev/null 2>&1 || true" || true
    sleep 3
    log_step_debug "[ARP-SCAN] Reading ARP table..."
    local arp_output
    run_command ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${TF_PROXMOX_SSH_USER}@$host" "cat /proc/net/arp" && arp_output="$LAST_COMMAND_OUTPUT" || {
        log_step_warn "[ARP-SCAN] Failed to read ARP table from $host"
        return 1
    }
    arp_output=$(echo "$arp_output" | tr -d '\r')
    log_step_debug "[ARP-SCAN] Looking for ${#VMID_BY_MAC[@]} MAC addresses:"
    for mac in "${!VMID_BY_MAC[@]}"; do
        local vmid="${VMID_BY_MAC[$mac]}"
        log_step_debug "[ARP-SCAN]   - VM $vmid -> MAC $mac"
    done
    local found_count=0
    local ip mac_upper vmid
    while IFS= read -r line; do
        [[ "$line" =~ ^IP[[:space:]]+HW ]] && continue
        ip=$(echo "$line" | awk '{print $1}')
        mac_upper=$(echo "$line" | awk '{print $4}' | tr '[:lower:]' '[:upper:]')
        [[ "$mac_upper" == "00:00:00:00:00:00" ]] && continue
        [[ -z "$mac_upper" || "$mac_upper" == "INCOMPLETE" ]] && continue
        vmid="${VMID_BY_MAC[$mac_upper]:-}"
        [[ -n "$vmid" ]] && {
            LIVE_NODE_IPS["$vmid"]="$ip"
            log_step_debug "[ARP-SCAN] Found VM $vmid -> $ip ($mac_upper)"
            found_count=$((found_count + 1))
        } || log_step_debug "[ARP-SCAN] Unmatched MAC: $mac_upper -> $ip"
    done <<< "$arp_output"
    log_step_debug "[ARP-SCAN] Complete: Found $found_count of ${#VMID_BY_MAC[@]} VMs"
    return 0
}

apply_config_to_node() {
    local vmid=$1
    local ip="$2"
    local config_file="$3"
    local role="$4"
    local max_attempts=5
    local attempt=1
    log_step_trace "apply_config_to_node: Starting for VM $vmid at $ip, role=$role"
    if [[ -f "$TALOSCONFIG" ]]; then
        export TALOSCONFIG
        log_step_debug "Using TALOSCONFIG: $TALOSCONFIG"
    else
        log_step_warn "TALOSCONFIG not found at $TALOSCONFIG, talosctl may fail"
    fi
    log_step_info "Applying config to $ip (VMID: $vmid)"
    check_node_configured "$ip" && {
        log_step_info "Node $ip (VMID: $vmid) is already configured and responsive (secure mode)"
        return 0
    }
    while [[ $attempt -le $max_attempts ]]; do
        log_detail_trace "apply_config_to_node: Attempt $attempt/$max_attempts (maintenance mode)"
        if run_command talosctl apply-config --nodes "$ip" --file "$config_file" --insecure; then
            log_step_info "Config applied successfully in maintenance mode (VMID: $vmid)"
            wait_for_node_ready "$ip" "$vmid"
            return 0
        fi
        local error_output="$LAST_COMMAND_OUTPUT"
        local cleaned_error=$(echo "$error_output" | tr -d '\r')
        echo "$cleaned_error" | grep -qi "certificate required" && {
            log_step_info "Node reports certificate required - already configured, trying secure mode"
            run_command talosctl apply-config --nodes "$ip" --endpoints "$ip" --file "$config_file" && {
                log_step_info "Config applied successfully in secure mode (VMID: $vmid)"
                return 0
            }
            check_node_configured "$ip" && {
                log_step_info "Node is responsive despite apply error - proceeding"
                return 0
            }
            log_step_error "Node has certificates but is not responsive - may need VM reset"
            return 1
        }
        echo "$cleaned_error" | grep -qi "already configured" && {
            log_step_info "Node reports already configured"
            check_node_configured "$ip" && return 0
            log_step_warn "Node claims configured but not responsive - waiting..."
            sleep 10
        }
        echo "$cleaned_error" | grep -qi "connection refused" && {
            log_step_warn "Connection refused, Talos still booting..."
            sleep 5
        } || {
            log_step_warn "Apply failed: $(echo "$cleaned_error" | head -1)"
            sleep 5
        }
        attempt=$((attempt + 1))
    done
    log_step_error "Failed to apply config after $max_attempts attempts"
    return 1
}

check_node_configured() {
    local ip="$1"
    log_detail_trace "check_node_configured: Checking $ip"
    if [[ -f "$TALOSCONFIG" ]]; then
        export TALOSCONFIG
        if timeout 5 talosctl version --nodes "$ip" --endpoints "$ip" &>/dev/null; then
            log_detail_trace "check_node_configured: $ip responsive to version check"
            return 0
        fi
        if timeout 5 talosctl version --endpoints "$ip" &>/dev/null; then
            log_detail_trace "check_node_configured: $ip responsive to endpoint version check"
            return 0
        fi
    fi
    if timeout 5 talosctl etcd members --endpoints "$ip" &>/dev/null; then
        log_detail_trace "check_node_configured: $ip has etcd members"
        return 0
    fi
    log_detail_trace "check_node_configured: $ip not configured"
    return 1
}

wait_for_node_with_rediscovery() {
    local vmid="$1"
    local initial_ip="$2"
    local max_wait="${3:-180}"
    local role="${4:-control-plane}"
    local is_bootstrap="${5:-false}"
    local config_triggered_reboot="${6:-false}"
    local subnet="${initial_ip%.*}"
    local waited=0
    local check_interval=3
    REDISCOVERED_IP=""
    log_step_info "Monitoring VM $vmid (IP: $initial_ip, role: $role, reboot_expected: $config_triggered_reboot)..."
    log_step_trace "wait_for_node_with_rediscovery: max_wait=$max_wait, check_interval=$check_interval"
    if [[ "$config_triggered_reboot" != "true" ]]; then
        log_step_debug "No reboot expected, verifying node readiness..."
        local ready_wait=0
        while [[ $ready_wait -lt 30 ]]; do
            if verify_talos_ready "$initial_ip" "$vmid" "$role"; then
                log_step_info "VM $vmid ready at $initial_ip (no reboot needed)"
                REDISCOVERED_IP="$initial_ip"
                return 0
            fi
            sleep 2
            ready_wait=$((ready_wait + 2))
        done
        log_step_warn "Node not ready after 30s check"
        return 1
    fi
    local state="monitoring"
    local last_seen_ip="$initial_ip"
    local candidate_ip=""
    local last_state_change=0
    local maintenance_stable_start=""
    while [[ $waited -lt $max_wait ]]; do
        log_detail_trace "wait_for_node_with_rediscovery: State=$state, waited=${waited}s, last_ip=$last_seen_ip"
        case "$state" in
            "monitoring")
                if ! ping -c 1 -W 2 "$initial_ip" &>/dev/null; then
                    local downtime_start=$waited
                    state="rebooting"
                    last_state_change=$waited
                    log_step_info "Node $initial_ip (VMID: $vmid) stopped responding (possible reboot starting)"
                    log_step_trace "wait_for_node_with_rediscovery: Transition monitoring->rebooting at ${waited}s"
                else
                    log_detail_debug "Node still responding, waiting for reboot..."
                fi
                ;;
            "rebooting")
                local downtime=$((waited - last_state_change))
                if [[ $((downtime % 15)) -eq 0 && $downtime -gt 0 ]]; then
                    log_step_debug "Re-populating ARP tables after ${downtime}s..."
                    for node_name in "${!PROXMOX_NODE_IPS[@]}"; do
                        local node_ip="${PROXMOX_NODE_IPS[$node_name]}"
                        run_command ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no "${TF_PROXMOX_SSH_USER}@$node_ip" "ip -s -s neigh flush all && seq 1 254 | xargs -P 100 -I{} ping -c 1 -W 1 ${subnet}.{} >/dev/null 2>&1 || true" || true
                    done
                    sleep 3
                fi
                local found_ip=""
                found_ip=$(rediscover_ip_by_mac "$vmid")
                if [[ -n "$found_ip" ]]; then
                    if [[ "$found_ip" != "$last_seen_ip" ]]; then
                        log_step_info "IP changed: $last_seen_ip -> $found_ip (reboot confirmed, VMID: $vmid)"
                        candidate_ip="$found_ip"
                        state="verifying"
                        last_state_change=$waited
                    elif ping -c 1 -W 2 "$found_ip" &>/dev/null && \
                         test_port "$found_ip" "50000" "3" "$vmid"; then
                        candidate_ip="$found_ip"
                        state="verifying"
                        last_state_change=$waited
                    fi
                fi
                if [[ $((downtime % 30)) -eq 0 && $downtime -gt 0 ]]; then
                    log_step_info "Still waiting for VM $vmid to reappear... (${downtime}s downtime)"
                fi
                ;;
            "verifying")
                local verify_time=$((waited - last_state_change))
                if test_port "$candidate_ip" "50000" "3" "$vmid" && \
                   verify_talos_ready "$candidate_ip" "$vmid" "$role"; then
                    log_step_info "VM $vmid ready at $candidate_ip (${verify_time}s)"
                    REDISCOVERED_IP="$candidate_ip"
                    return 0
                fi
                [[ $((verify_time % 15)) -eq 0 && $verify_time -gt 0 ]] && \
                    log_step_info "Verifying Talos ready... (${verify_time}s)"
                ;;
        esac
        sleep $check_interval
        waited=$((waited + check_interval))
    done
    log_step_error "Timeout waiting for VM $vmid after ${max_wait}s"
    log_step_error "Final state: $state, Last IP: ${candidate_ip:-$last_seen_ip} (VMID: $vmid, role: $role)"
    log_step_trace "wait_for_node_with_rediscovery: Timeout reached, state=$state"
    return 1
}

verify_talos_ready() {
    local ip="$1"
    local vmid="$2"
    local role="${3:-control-plane}"
    local maintenance_grace_period="${4:-45}"
    log_detail_trace "verify_talos_ready: Checking $ip (VM $vmid, role=$role)"
    [[ -f "$TALOSCONFIG" ]] && export TALOSCONFIG
    if run_command timeout 5 talosctl version --nodes "$ip" --endpoints "$ip" --insecure 2>/dev/null; then
        local version_output="$LAST_COMMAND_OUTPUT"
        if echo "$version_output" | grep -q "not implemented in maintenance mode"; then
            log_detail_debug "Node $ip (VMID: $vmid, role: $role) is in maintenance mode"
            if [[ "$role" == "worker" ]]; then
                log_detail_debug "Worker $ip (VMID: $vmid) in maintenance mode - this is expected before cluster bootstrap"
                local port_open_duration=0
                local check_interval=3
                local max_checks=$((maintenance_grace_period / check_interval))
                local check_count=0
                log_detail_debug "Checking maintenance mode stability for ${maintenance_grace_period}s..."
                while [[ $check_count -lt $max_checks ]]; do
                    if test_port "$ip" "50000" "2" "$vmid"; then
                        port_open_duration=$((port_open_duration + check_interval))
                        if [[ $((check_count % 5)) -eq 0 ]]; then
                            log_detail_debug "Port 50000 still open after ${port_open_duration}s (VMID: $vmid)"
                        fi
                        if [[ $port_open_duration -ge 30 ]]; then
                            log_step_info "Worker $ip (VMID: $vmid) maintenance mode stable after ${port_open_duration}s - considering ready"
                            return 0
                        fi
                    else
                        log_detail_warn "Port 50000 closed during grace period check - node may be rebooting"
                        return 1
                    fi
                    sleep $check_interval
                    check_count=$((check_count + 1))
                done
                log_step_info "Worker $ip (VMID: $vmid) completed ${maintenance_grace_period}s grace period in maintenance mode - ready"
                return 0
            fi
            log_detail_debug "Control plane $ip (VMID: $vmid) in maintenance mode - waiting for bootstrap"
            return 1
        fi
        log_detail_debug "Node $ip (VMID: $vmid) responding to insecure version check"
        return 0
    fi
    local error_output="$LAST_COMMAND_OUTPUT"
    if echo "$error_output" | grep -qi "certificate required"; then
        log_detail_debug "Node $ip (VMID: $vmid) has certificates, trying secure mode"
        if [[ -f "$TALOSCONFIG" ]]; then
            if run_command timeout 5 talosctl version --nodes "$ip" --endpoints "$ip" 2>/dev/null; then
                log_detail_debug "Node $ip (VMID: $vmid) responding to secure version check"
                return 0
            fi
            if run_command timeout 5 talosctl get machineconfig --nodes "$ip" --endpoints "$ip" 2>/dev/null; then
                log_detail_debug "Node $ip (VMID: $vmid) has machineconfig"
                return 0
            fi
        fi
    fi
    log_detail_debug "Node $ip (VMID: $vmid) not ready (role: $role)"
    return 1
}

rediscover_ip_by_mac() {
    local vmid="$1"
    log_detail_trace "rediscover_ip_by_mac: Starting for VM $vmid"
    local mac="${MAC_BY_VMID[$vmid]:-}"
    local host_ip="${PROXMOX_NODE_IPS[pve1]:-192.168.1.233}"
    local subnet=$(echo "$host_ip" | cut -d. -f1-3)
    if [[ -z "$mac" ]]; then
        log_detail_debug "No MAC cached for VM $vmid, attempting to fetch from Proxmox..."
        if run_command ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no "${TF_PROXMOX_SSH_USER}@$host_ip" "qm config $vmid | grep -E '^net[0-9]+:' | head -1 | grep -oE 'virtio=[0-9A-Fa-f:]+' | cut -d= -f2"; then
            mac=$(echo "$LAST_COMMAND_OUTPUT" | tr -d '\r' | tr '[:lower:]' '[:upper:]')
            if [[ -n "$mac" ]]; then
                MAC_BY_VMID["$vmid"]="$mac"
                VMID_BY_MAC["$mac"]="$vmid"
                log_detail_debug "Fetched MAC $mac for VM $vmid"
            fi
        fi
        if [[ -z "$mac" ]]; then
            log_detail_warn "Still no MAC for VM $vmid, cannot rediscover"
            return 1
        fi
    fi
    log_detail_debug "Looking for MAC $mac (VM $vmid) in ARP tables across all nodes..."
    local all_ips=()
    local nodes_to_check=()
    if [[ ${#PROXMOX_NODE_IPS[@]} -gt 0 ]]; then
        for node_name in "${!PROXMOX_NODE_IPS[@]}"; do
            nodes_to_check+=("${PROXMOX_NODE_IPS[$node_name]}")
        done
    else
        nodes_to_check+=("$(get_node_ip "pve1")")
    fi
    log_detail_trace "rediscover_ip_by_mac: Checking ${#nodes_to_check[@]} nodes for ARP entries"
    local unique_ips=""
    for node_ip in "${nodes_to_check[@]}"; do
        log_detail_trace "rediscover_ip_by_mac: Checking node $node_ip"
        run_command ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no "${TF_PROXMOX_SSH_USER}@$node_ip" "ping -c 2 -W 2 ${subnet}.254 >/dev/null 2>&1 || true" || true
        local arp_results=""
        if run_command ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no "${TF_PROXMOX_SSH_USER}@$node_ip" "cat /proc/net/arp | grep -i '$mac' | awk '{print \$1}'"; then
            arp_results="$LAST_COMMAND_OUTPUT"
        fi
        if [[ -n "$arp_results" ]]; then
            while IFS= read -r ip; do
                ip=$(echo "$ip" | tr -d '\r\n' | tr '[:lower:]' '[:upper:]')
                if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                    local valid_ip=true
                    IFS='.' read -ra octets <<< "$ip"
                    for octet in "${octets[@]}"; do
                        if [[ "$octet" -gt 255 || "$octet" -lt 0 ]]; then
                            valid_ip=false
                            break
                        fi
                    done
                    if [[ "$valid_ip" == true ]]; then
                        if [[ ! "$unique_ips" =~ (^|[[:space:]])"$ip"($|[[:space:]]) ]]; then
                            unique_ips+="$ip "
                            all_ips+=("$ip")
                            log_detail_debug "Found candidate IP $ip for VM $vmid on node $node_ip"
                        fi
                    fi
                fi
            done <<< "$arp_results"
        fi
    done
    if [[ ${#all_ips[@]} -eq 0 ]]; then
        log_detail_warn "No IPs found in ARP for MAC $mac (VM $vmid)"
        return 1
    fi
    log_detail_debug "Found ${#all_ips[@]} unique IP(s) for VM $vmid MAC $mac: ${all_ips[*]}"
    local responsive_ips=()
    local unresponsive_ips=()
    for candidate_ip in "${all_ips[@]}"; do
        log_detail_trace "rediscover_ip_by_mac: Testing responsiveness of $candidate_ip..."
        if ping -c 1 -W 2 "$candidate_ip" &>/dev/null; then
            responsive_ips+=("$candidate_ip")
        else
            unresponsive_ips+=("$candidate_ip")
        fi
    done
    local ordered_ips=("${responsive_ips[@]}" "${unresponsive_ips[@]}")
    for candidate_ip in "${ordered_ips[@]}"; do
        [[ -z "$candidate_ip" ]] && continue
        log_detail_debug "Testing candidate IP $candidate_ip for VM $vmid..."
        if test_port "$candidate_ip" "50000" "3" "$vmid"; then
            log_detail_debug "Found responsive Talos API at $candidate_ip for VM $vmid"
            echo "$candidate_ip"
            return 0
        else
            log_detail_trace "rediscover_ip_by_mac: IP $candidate_ip not responding on port 50000, trying next..."
        fi
    done
    for candidate_ip in "${ordered_ips[@]}"; do
        [[ -z "$candidate_ip" ]] && continue
        log_detail_debug "Checking $candidate_ip for Kubernetes API (port 6443)..."
        if test_port "$candidate_ip" "6443" "2" "$vmid"; then
            log_detail_warn "VM $vmid at $candidate_ip has k8s API but no Talos API - may need secure mode"
            echo "$candidate_ip"
            return 0
        fi
    done
    if [[ ${#responsive_ips[@]} -gt 0 ]]; then
        log_detail_warn "No APIs responding for VM $vmid, returning first responsive IP: ${responsive_ips[0]}"
        echo "${responsive_ips[0]}"
        return 0
    fi
    log_detail_warn "No responsive IP found for VM $vmid, returning first ARP entry: ${all_ips[0]}"
    echo "${all_ips[0]}"
    return 0
}

wait_for_talos_ready_at_ip() {
    local ip="$1"
    local vmid="$2"
    local role="${3:-control-plane}"
    local max_wait="${4:-60}"
    local waited=0
    local check_interval=3
    [[ -f "$TALOSCONFIG" ]] && export TALOSCONFIG
    log_step_debug "Waiting for Talos ready at $ip (VMID: $vmid, role: $role, max: ${max_wait}s)"
    while [[ $waited -lt $max_wait ]]; do
        log_detail_trace "wait_for_talos_ready_at_ip: Check at ${waited}s for $ip"
        if verify_talos_ready "$ip" "$vmid" "$role"; then
            log_step_info "Node $vmid at $ip is ready (role: $role)"
            return 0
        fi
        sleep $check_interval
        waited=$((waited + check_interval))
        [[ $((waited % 15)) -eq 0 ]] && log_step_debug "Still waiting for $ip... (${waited}s)"
    done
    log_step_debug "Timeout waiting for Talos ready at $ip (role: $role)"
    return 1
}

attempt_bootstrap_node() {
    local vmid="$1"
    local initial_ip="$2"
    local config_file="$3"
    local current_ip="$initial_ip"
    log_step_info "Bootstrapping VM $vmid (IP: $initial_ip)"
    local apply_output result_ip reboot_triggered
    apply_output=$(apply_config_with_rediscovery "$vmid" "$current_ip" "$config_file" "control-plane")
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    result_ip=$(echo "$apply_output" | head -1)
    reboot_triggered=$(echo "$apply_output" | tail -1)
    [[ -n "$result_ip" ]] && current_ip="$result_ip"
    wait_for_node_with_rediscovery "$vmid" "$current_ip" 120 "control-plane" "true" "$reboot_triggered" || {
        log_step_error "Node $vmid failed to become ready"
        return 1
    }
    [[ -n "$REDISCOVERED_IP" ]] && current_ip="$REDISCOVERED_IP"
    DEPLOYED_CP_IPS["$vmid"]="$current_ip"
    save_state
    bootstrap_etcd_at_ip "$current_ip" "$vmid" || return 1
    log_step_info "Successfully bootstrapped VM $vmid at $current_ip"
    return 0
}

apply_config_with_rediscovery() {
    local vmid="$1"
    local initial_ip="$2"
    local config_file="$3"
    local role="${4:-control-plane}"
    local max_attempts=5
    local attempt=1
    local current_ip="$initial_ip"
    local subnet="${initial_ip%.*}"
    APPLY_CONFIG_REBOOT_TRIGGERED="false"
    log_step_info "Applying config to $current_ip (VMID: $vmid, role: $role, attempt $attempt/$max_attempts)..."
    log_step_trace "apply_config_with_rediscovery: Starting with max_attempts=$max_attempts"
    while [[ $attempt -le $max_attempts ]]; do
        log_detail_trace "apply_config_with_rediscovery: Attempt $attempt/$max_attempts"
        if [[ $attempt -gt 1 ]]; then
            log_step_debug "Rediscovering IP for VM $vmid before attempt $attempt..."
            local fresh_ip=""
            for node_name in "${!PROXMOX_NODE_IPS[@]}"; do
                local node_ip="${PROXMOX_NODE_IPS[$node_name]}"
                run_command ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no "${TF_PROXMOX_SSH_USER}@$node_ip" "ip -s -s neigh flush all && seq 1 254 | xargs -P 100 -I{} ping -c 1 -W 1 ${subnet}.{} >/dev/null 2>&1 || true" || true
            done
            sleep 2
            fresh_ip=$(rediscover_ip_by_mac "$vmid")
            if [[ -n "$fresh_ip" && "$fresh_ip" != "$current_ip" ]]; then
                log_step_info "IP changed during retry: $current_ip -> $fresh_ip"
                current_ip="$fresh_ip"
                if [[ "$role" == "control-plane" ]]; then
                    DEPLOYED_CP_IPS["$vmid"]="$current_ip"
                else
                    DEPLOYED_WORKER_IPS["$vmid"]="$current_ip"
                fi
            fi
        fi
        if run_command talosctl apply-config --nodes "$current_ip" --file "$config_file" --insecure; then
            log_step_info "Configuration applied successfully, node will reboot (VMID: $vmid)"
            APPLY_CONFIG_REBOOT_TRIGGERED="true"
            echo "$current_ip"
            echo "true"
            return 0
        fi
        local error_output="$LAST_COMMAND_OUTPUT"
        local cleaned_error=$(echo "$error_output" | tr -d '\r')
        if echo "$cleaned_error" | grep -qi "connection refused\; connection timed out\; no route to host"; then
            log_step_warn "Connection issue detected, IP may have changed. Triggering immediate rediscovery..."
            for node_name in "${!PROXMOX_NODE_IPS[@]}"; do
                local node_ip="${PROXMOX_NODE_IPS[$node_name]}"
                run_command ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no "${TF_PROXMOX_SSH_USER}@$node_ip" "ip -s -s neigh flush all" || true
            done
            sleep 3
            local emergency_ip=$(rediscover_ip_by_mac "$vmid")
            if [[ -n "$emergency_ip" && "$emergency_ip" != "$current_ip" ]]; then
                log_step_debug "Emergency rediscovery found new IP: $emergency_ip"
                current_ip="$emergency_ip"
                if [[ "$role" == "control-plane" ]]; then
                    DEPLOYED_CP_IPS["$vmid"]="$current_ip"
                else
                    DEPLOYED_WORKER_IPS["$vmid"]="$current_ip"
                fi
                attempt=$((attempt - 1))
            fi
        elif echo "$cleaned_error" | grep -qi "already configured\|certificate required"; then
            log_step_info "Node $current_ip (VMID: $vmid) reports already configured, checking state..."
            if wait_for_talos_ready_at_ip "$current_ip" "$vmid" "$role" 30; then
                echo "$current_ip"
                echo "false"
                return 0
            fi
            log_step_warn "Node $current_ip (VMID: $vmid) partially configured, attempting recovery..."
            if attempt_recovery_reapply "$current_ip" "$config_file" "$role"; then
                echo "$current_ip"
                echo "false"
                return 0
            fi
        fi
        attempt=$((attempt + 1))
        [[ $attempt -le $max_attempts ]] && {
            log_step_warn "Retrying in 5 seconds... (attempt $attempt/$max_attempts)"
            sleep 5
        }
    done
    log_step_error "Failed to apply config after $max_attempts attempts"
    return 1
}

bootstrap_etcd_at_ip() {
    local ip="$1"
    local vmid="$2"
    local max_attempts=3
    local attempt=1
    [[ -f "$TALOSCONFIG" ]] && export TALOSCONFIG
    log_step_trace "bootstrap_etcd_at_ip: Starting for VM $vmid at $ip"
    while [[ $attempt -le $max_attempts ]]; do
        log_step_debug "Attempting etcd bootstrap (attempt $attempt/$max_attempts)..."
        local bootstrap_flags=""
        local endpoint_flag="--endpoints $ip"
        run_command talosctl version --nodes "$ip" --endpoints "$ip" --insecure 2>/dev/null && {
            echo "$LAST_COMMAND_OUTPUT" | grep -q "not implemented in maintenance mode" || bootstrap_flags="--insecure"
        }
        run_command talosctl bootstrap --nodes "$ip" --endpoints "$ip" $bootstrap_flags && {
            log_step_info "Bootstrap command succeeded"
            wait_for_etcd_healthy "$ip" "$vmid" && return 0
        } || {
            echo "$LAST_COMMAND_OUTPUT" | grep -qi "already bootstrapped\|etcd already initialized" && {
                log_step_info "Node reports already bootstrapped"
                wait_for_etcd_healthy "$ip" "$vmid" && return 0
            }
        }
        log_step_warn "Bootstrap attempt $attempt failed, retrying..."
        attempt=$((attempt + 1))
        sleep 10
    done
    log_step_error "Failed to bootstrap etcd after $max_attempts attempts"
    return 1
}

wait_for_etcd_healthy() {
    local ip="$1"
    local vmid="$2"
    local max_attempts=30
    local attempt=1
    [[ -f "$TALOSCONFIG" ]] && export TALOSCONFIG
    log_step_info "Waiting for etcd to become healthy..."
    while [[ $attempt -le $max_attempts ]]; do
        log_detail_trace "wait_for_etcd_healthy: Check $attempt/$max_attempts"
        if run_command timeout 10 talosctl etcd members --nodes "$ip" --endpoints "$ip" 2>/dev/null; then
            if echo "$LAST_COMMAND_OUTPUT" | grep -qE '[0-9a-f]{16}'; then
                local member_count=$(echo "$LAST_COMMAND_OUTPUT" | grep -cE '[0-9a-f]{16}' || echo "0")
                log_step_info "etcd has $member_count member(s) on VM $vmid (healthy)"
                return 0
            fi
        fi
        if [[ $((attempt % 5)) -eq 0 ]]; then
            log_step_debug "Waiting for etcd... ($attempt/$max_attempts)"
        fi
        sleep 5
        attempt=$((attempt + 1))
    done
    log_step_warn "etcd not healthy after $max_attempts attempts"
    return 1
}

wait_for_node_ready() {
    local ip="$1"
    local vmid="$2"
    wait_for_node_with_rediscovery "$vmid" "$ip" 120
}

update_haproxy_from_state() {
    log_job_info "Updating HAProxy from current state"
    log_job_trace "update_haproxy_from_state: Starting with ${#DEPLOYED_CP_IPS[@]} control planes"
    local cp_entries=()
    for vmid in "${!DEPLOYED_CP_IPS[@]}"; do
        local ip="${DEPLOYED_CP_IPS[$vmid]}"
        [[ -n "$ip" ]] && cp_entries+=("${vmid}:${ip}")
    done
    [[ ${#cp_entries[@]} -eq 0 ]] && {
        log_job_warn "No control plane IPs to configure in HAProxy"
        return 1
    }
    log_step_info "Configuring HAProxy with ${#cp_entries[@]} backends"
    log_step_trace "update_haproxy_from_state: Backends: ${cp_entries[*]}"
    update_haproxy "${cp_entries[@]}"
}

update_haproxy() {
    local entries=("$@")
    log_step_trace "update_haproxy: Starting with ${#entries[@]} entries"
    [[ ${#entries[@]} -eq 0 ]] && {
        log_step_warn "No entries provided to update_haproxy"
        return 1
    }
    for entry in "${entries[@]}"; do
        local ip="${entry#*:}"
        [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && {
            log_step_error "Invalid IP address in entry: $entry"
            return 1
        }
    done
    log_step_info "Generate HAProxy configuration"
    local haproxy_cfg
    haproxy_cfg=$(mktemp /tmp/haproxy.cfg.XXXXXX) || {
        log_step_error "Failed to create temporary file"
        return 1
    }
    local haproxy_content
    haproxy_content=$(cat <<EOFCFG
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
)
    for entry in "${entries[@]}"; do
        local vmid="${entry%%:*}"
        local ip="${entry#*:}"
        local server_name="talos-cp-${vmid}"
        haproxy_content+=$(printf '\n    server %s %s:6443 check' "$server_name" "$ip")
        log_detail_trace "update_haproxy: Added k8s backend $server_name -> $ip"
    done
    haproxy_content+=$(cat <<EOFCFG


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
)
    for entry in "${entries[@]}"; do
        local vmid="${entry%%:*}"
        local ip="${entry#*:}"
        local server_name="talos-cp-${vmid}"
        haproxy_content+=$(printf '\n    server %s %s:50000 check' "$server_name" "$ip")
        log_detail_trace "update_haproxy: Added talos backend $server_name -> $ip"
    done
    write_file_audited "$haproxy_content" "$haproxy_cfg"

    log_step_info "Copy configuration to HAProxy server"
    run_command scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$haproxy_cfg" "${HAPROXY_LOGIN_USERNAME}@${HAPROXY_IP}:/tmp/haproxy.cfg.new" || {
        log_step_error "Failed to copy config to HAProxy server"
        run_command rm -f "$haproxy_cfg"
        return 1
    }
    local timestamp=$(date +%Y%m%d_%H%M%S)
    run_command ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${HAPROXY_LOGIN_USERNAME}@${HAPROXY_IP}" "sudo cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.backup.${timestamp} && sudo mv /tmp/haproxy.cfg.new /etc/haproxy/haproxy.cfg" || {
        log_step_error "Failed to install new configuration"
        run_command rm -f "$haproxy_cfg"
        return 1
    }
    run_command ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${HAPROXY_LOGIN_USERNAME}@${HAPROXY_IP}" "sudo haproxy -c -f /etc/haproxy/haproxy.cfg" || {
        log_step_error "HAProxy configuration validation failed"
        run_command ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${HAPROXY_LOGIN_USERNAME}@${HAPROXY_IP}" "sudo cp /etc/haproxy/haproxy.cfg.backup.${timestamp} /etc/haproxy/haproxy.cfg" || true
        run_command ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${HAPROXY_LOGIN_USERNAME}@${HAPROXY_IP}" "sudo systemctl reload haproxy" || true
        run_command rm -f "$haproxy_cfg"
        return 1
    }
    run_command ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${HAPROXY_LOGIN_USERNAME}@${HAPROXY_IP}" "sudo systemctl reload haproxy || sudo systemctl start haproxy" || {
        log_step_error "Failed to reload HAProxy"
        run_command rm -f "$haproxy_cfg"
        return 1
    }
    run_command rm -f "$haproxy_cfg"
    log_step_info "HAProxy updated successfully"
    log_file_only "DEPLOY" "HAPROXY: Updated with ${#entries[@]} backends"
    log_step_trace "update_haproxy: Completed successfully"
}

setup_environment() {
    log_stage_info "Environment Setup"
    log_stage_trace "setup_environment: Starting environment setup"
    init_directories
    detect_environment
    check_prerequisites
    load_proxmox_tokens_from_terraform
    load_desired_state || true
    load_deployed_state
    log_stage_trace "setup_environment: Completed"
}

run_discovery() {
    log_stage_info "Node Discovery"
    log_stage_trace "run_discovery: Starting discovery phase"
    [[ "$SKIP_PREFLIGHT" != "true" ]] && run_preflight_checks
    sync_deployed_ips_with_live_discovery
    log_stage_trace "run_discovery: Discovery completed"
}

run_configuration() {
    log_stage_info "Configuration Generation"
    log_stage_trace "run_configuration: Starting configuration generation"
    [[ ! -f "$SECRETS_DIR/control-plane.yaml" || ! -f "$SECRETS_DIR/worker.yaml" ]] && generate_base_configs
    log_step_info "Generating control plane configurations"
    for vmid in "${!DESIRED_CP_VMIDS[@]}"; do
        local config_file="$NODES_DIR/node-control-plane-${vmid}.yaml"
        [[ ! -f "$config_file" || "$FORCE_RECONFIGURE" == "true" ]] && generate_node_config "$vmid" "control-plane" || log_detail_debug "Config exists for CP VMID $vmid, skipping generation"
    done
    log_step_info "Generating worker configurations"
    for vmid in "${!DESIRED_WORKER_VMIDS[@]}"; do
        local config_file="$NODES_DIR/node-worker-${vmid}.yaml"
        [[ ! -f "$config_file" || "$FORCE_RECONFIGURE" == "true" ]] && generate_node_config "$vmid" "worker" || log_detail_debug "Config exists for Worker VMID $vmid, skipping generation"
    done
    log_step_info "Verifying configuration files"
    local missing_configs=()
    for vmid in "${!DESIRED_CP_VMIDS[@]}"; do
        [[ ! -f "$NODES_DIR/node-control-plane-${vmid}.yaml" ]] && missing_configs+=("node-control-plane-${vmid}.yaml")
    done
    for vmid in "${!DESIRED_WORKER_VMIDS[@]}"; do
        [[ ! -f "$NODES_DIR/node-worker-${vmid}.yaml" ]] && missing_configs+=("node-worker-${vmid}.yaml")
    done
    [[ ${#missing_configs[@]} -gt 0 ]] && {
        log_step_error "Missing configuration files:"
        for cfg in "${missing_configs[@]}"; do log_step_error "  - $cfg"; done
        return 1
    }
    log_step_info "Configuration files ready in $NODES_DIR (${#DESIRED_CP_VMIDS[@]} CPs, ${#DESIRED_WORKER_VMIDS[@]} Workers)"
    log_stage_trace "run_configuration: Configuration generation completed"
}

run_execution() {
    log_stage_info "Executing Changes"
    log_stage_trace "run_execution: Starting execution phase"
    execute_reconcile_plan
    log_stage_trace "run_execution: Execution completed"
}

run_finalization() {
    log_stage_info "Finalizing"
    log_stage_trace "run_finalization: Starting finalization"
    [[ ${#PLAN_ADD_CP[@]} -gt 0 || ${#PLAN_REMOVE_CP[@]} -gt 0 || "$PLAN_NEED_BOOTSTRAP" == "true" ]] && update_kubeconfig
    verify_cluster
    log_stage_trace "run_finalization: Finalization completed"
}

run_bootstrap() {
    [[ "${BOOTSTRAP_COMPLETED:-false}" == "true" ]] && {
        log_stage_info "Bootstrap already completed, skipping"
        return 0
    }
    [[ ${#DEPLOYED_CP_IPS[@]} -eq 0 ]] && {
        log_stage_error "No control planes available to bootstrap"
        return 1
    }
    log_stage_info "Starting cluster bootstrap with IP rediscovery support"
    log_stage_trace "run_bootstrap: Starting bootstrap with ${#DEPLOYED_CP_IPS[@]} control planes"
    log_step_info "Forcing complete IP rediscovery before bootstrap..."
    MAC_BY_VMID=()
    VMID_BY_MAC=()
    LIVE_NODE_IPS=()
    for vmid in "${!DEPLOYED_CP_IPS[@]}"; do
        log_step_info "Rediscovering IP for control plane VM $vmid..."
        local fresh_ip=$(rediscover_ip_by_mac "$vmid")
        if [[ -n "$fresh_ip" ]]; then
            if [[ "$fresh_ip" != "${DEPLOYED_CP_IPS[$vmid]}" ]]; then
                log_step_info "Updated CP VMID $vmid IP: ${DEPLOYED_CP_IPS[$vmid]} -> $fresh_ip"
                DEPLOYED_CP_IPS["$vmid"]="$fresh_ip"
            fi
        fi
    done
    save_state
    sync_deployed_ips_with_live_discovery
    local bootstrap_vmid=""
    local bootstrap_ip=""
    [[ -n "${FIRST_CONTROL_PLANE_VMID:-}" && -n "${DEPLOYED_CP_IPS[$FIRST_CONTROL_PLANE_VMID]:-}" ]] && {
        bootstrap_vmid="$FIRST_CONTROL_PLANE_VMID"
        bootstrap_ip="${DEPLOYED_CP_IPS[$bootstrap_vmid]}"
    } || {
        for vmid in "${!DEPLOYED_CP_IPS[@]}"; do
            bootstrap_vmid="$vmid"
            bootstrap_ip="${DEPLOYED_CP_IPS[$vmid]}"
            break
        done
    }
    [[ -z "$bootstrap_ip" ]] && {
        log_stage_error "Could not find a control plane IP to bootstrap"
        return 1
    }
    log_step_info "Selected bootstrap node: VMID $bootstrap_vmid at $bootstrap_ip"
    log_step_trace "run_bootstrap: Bootstrap node selected - VMID $bootstrap_vmid at $bootstrap_ip"
    [[ -z "${MAC_BY_VMID[$bootstrap_vmid]:-}" ]] && {
        log_step_info "Discovering MAC address for VM $bootstrap_vmid..."
        local node_name info
        info="${DESIRED_CP_VMIDS[$bootstrap_vmid]:-}"
        node_name=$(echo "$info" | cut -d'|' -f2)
        [[ -z "$node_name" ]] && node_name="pve1"
        local node_ip=$(get_node_ip "$node_name")
        run_command ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${TF_PROXMOX_SSH_USER}@$node_ip" "qm config $bootstrap_vmid | grep -E '^net[0-9]+:' | head -1 | grep -oE 'virtio=[0-9A-Fa-f:]+' | cut -d= -f2" && {
            local mac="$LAST_COMMAND_OUTPUT"
            [[ -n "$mac" ]] && {
                MAC_BY_VMID["$bootstrap_vmid"]="$mac"
                VMID_BY_MAC["$mac"]="$bootstrap_vmid"
                log_step_info "Cached MAC $mac for VM $bootstrap_vmid"
            }
        }
    }
    local config_file="$NODES_DIR/node-control-plane-${bootstrap_vmid}.yaml"
    [[ ! -f "$config_file" ]] && {
        log_stage_error "Configuration file not found: $config_file"
        return 1
    }
    attempt_bootstrap_node "$bootstrap_vmid" "$bootstrap_ip" "$config_file" && {
        BOOTSTRAP_COMPLETED=true
        FIRST_CONTROL_PLANE_VMID="$bootstrap_vmid"
        [[ -n "$REDISCOVERED_IP" ]] && DEPLOYED_CP_IPS["$bootstrap_vmid"]="$REDISCOVERED_IP"
        save_state
        log_stage_info "Bootstrap completed successfully"
        log_stage_trace "run_bootstrap: Bootstrap completed successfully"
        return 0
    } || {
        log_stage_error "Bootstrap failed for VM $bootstrap_vmid"
        return 1
    }
}

init_directories() {
    log_job_info "Initialize Directories"
    log_job_trace "init_directories: Creating directories"
    run_command mkdir -p "$NODES_DIR" "$SECRETS_DIR" "$STATE_DIR" "$LOG_DIR" "$CHECKSUM_DIR"
    [[ ! -f "${CLUSTER_DIR}/.gitignore" ]] && {
        local gitignore_content=$(cat <<'EOF'
/nodes/
/secrets/
/state/
/*.log
EOF
)
        write_file_audited "$gitignore_content" "${CLUSTER_DIR}/.gitignore"
        log_detail_debug "Created .gitignore"
    }
    log_file_only "INIT" "Directories initialized"
    log_job_trace "init_directories: Directories created"
}

detect_environment() {
    log_job_info "Detect Platform"
    log_job_trace "detect_environment: Detecting platform"
    if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]] || [[ "$MSYSTEM" == "MINGW"* ]] || [[ -n "${WINDIR:-}" ]] || [[ -n "${MINGW_PREFIX:-}" ]] || [[ "$TERM" == "xterm-256color" && -n "${MSYSTEM:-}" ]]; then
        IS_WINDOWS=true
        SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        PING_CMD="ping -n 1 -w 2000"
        HOSTS_FILE="/c/Windows/System32/drivers/etc/hosts"
        log_step_info "Detected Windows/Git Bash environment"
    else
        IS_WINDOWS=false
        SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPath=~/.ssh/proxmox_mux_%h_%p_%r -o ControlPersist=600"
        PING_CMD="ping -c 1 -W 2"
        HOSTS_FILE="/etc/hosts"
        log_step_info "Detected Unix/Linux environment"
    fi
    log_job_trace "detect_environment: IS_WINDOWS=$IS_WINDOWS"
}

run_preflight_checks() {
    log_job_info "Pre-flight Checks - Verifying VM readiness"
    log_job_trace "run_preflight_checks: Starting preflight with max_retries=$PREFLIGHT_MAX_RETRIES"
    log_job_trace "DESIRED_ALL_VMIDS count: ${#DESIRED_ALL_VMIDS[@]}"
    log_job_trace "DESIRED_ALL_VMIDS keys: ${!DESIRED_ALL_VMIDS[*]}"
    local total_vms=${#DESIRED_ALL_VMIDS[@]}
    local ready_vms=0
    local pending_vms=()
    local failed_vms=()
    [[ $total_vms -eq 0 ]] && {
        log_job_warn "No VMs defined in desired state, skipping preflight"
        return 0
    }
    log_step_info "Checking $total_vms VMs for Talos API readiness (timeout: $((PREFLIGHT_MAX_RETRIES * PREFLIGHT_RETRY_DELAY))s)"
    for vmid in "${!DESIRED_ALL_VMIDS[@]}"; do
        local info name node
        info="${DESIRED_ALL_VMIDS[$vmid]}"
        name=$(echo "$info" | cut -d'|' -f2)
        node=$(echo "$info" | cut -d'|' -f3)
        log_job_trace "Checking VMID $vmid (name=$name, node=$node)"
        local ip=""
        ip=$(discover_ip_for_vmid "$vmid" 2>/dev/null) || {
            log_detail_debug "VMID $vmid ($name): IP not yet discoverable (VM may still be booting)"
            pending_vms+=("$vmid:$name:$node")
            continue
        }
        test_port "$ip" "50000" "$PREFLIGHT_CONNECT_TIMEOUT" "$vmid" && {
            log_detail_debug "VMID $vmid ($name at $ip): Talos API ready"
            ready_vms=$((ready_vms + 1))
            LIVE_NODE_IPS["$vmid"]="$ip"
        } || {
            log_detail_debug "VMID $vmid ($name at $ip): Talos API not responding yet"
            pending_vms+=("$vmid:$name:$node:$ip")
        }
    done
    [[ $ready_vms -eq $total_vms ]] && {
        log_step_info "All $total_vms VMs are ready"
        log_job_trace "run_preflight_checks: All VMs ready"
        return 0
    }
    log_step_info "Waiting for ${#pending_vms[@]} VMs to become ready..."
    local attempt=1
    local still_pending=()
    while [[ $attempt -le $PREFLIGHT_MAX_RETRIES && ${#pending_vms[@]} -gt 0 ]]; do
        still_pending=()
        local newly_ready=0
        local rediscovered_count=0
        if [[ $((attempt % 5)) -eq 0 ]]; then
            log_step_debug "Refreshing ARP tables (attempt $attempt)..."
            for node_name in "${!PROXMOX_NODE_IPS[@]}"; do
                local node_ip="${PROXMOX_NODE_IPS[$node_name]}"
                populate_arp_table "$node_ip" || true
            done
        fi
        for entry in "${pending_vms[@]}"; do
            local vmid name node old_ip new_ip
            vmid=$(echo "$entry" | cut -d':' -f1)
            name=$(echo "$entry" | cut -d':' -f2)
            node=$(echo "$entry" | cut -d':' -f3)
            old_ip=$(echo "$entry" | cut -d':' -f4)
            new_ip=$(discover_ip_for_vmid "$vmid" 2>/dev/null || echo "")
            [[ -n "$old_ip" && -n "$new_ip" && "$old_ip" != "$new_ip" ]] && {
                log_step_info "VMID $vmid IP changed: $old_ip -> $new_ip (rediscovered)"
                rediscovered_count=$((rediscovered_count + 1))
            }
            [[ -z "$new_ip" ]] && {
                log_detail_debug "Attempt $attempt: VMID $vmid ($name) still no IP discovered"
                still_pending+=("$vmid:$name:$node:")
                continue
            }
            test_port "$new_ip" "50000" "$PREFLIGHT_CONNECT_TIMEOUT" "$vmid" && {
                log_detail_debug "Attempt $attempt: VMID $vmid ($name) now ready at $new_ip"
                LIVE_NODE_IPS["$vmid"]="$new_ip"
                ready_vms=$((ready_vms + 1))
                newly_ready=$((newly_ready + 1))
            } || {
                still_pending+=("$vmid:$name:$node:$new_ip")
            }
        done
        pending_vms=("${still_pending[@]}")
        [[ $newly_ready -gt 0 ]] && log_step_debug "Attempt $attempt: $newly_ready VM(s) became ready (${#pending_vms[@]} still pending)"
        [[ $rediscovered_count -gt 0 ]] && log_step_debug "Attempt $attempt: $rediscovered_count VM(s) had IP changes"
        [[ $((attempt % 10)) -eq 0 && ${#pending_vms[@]} -gt 0 ]] && log_step_debug "Attempt $attempt/$PREFLIGHT_MAX_RETRIES: ${#pending_vms[@]} VMs still pending..."
        [[ ${#pending_vms[@]} -eq 0 ]] && break
        sleep "$PREFLIGHT_RETRY_DELAY"
        attempt=$((attempt + 1))
    done
    log_step_info "Pre-flight complete: $ready_vms/$total_vms VMs ready"
    [[ ${#pending_vms[@]} -gt 0 ]] && {
        log_step_warn "${#pending_vms[@]} VM(s) did not become ready within timeout:"
        for entry in "${pending_vms[@]}"; do
            local vmid name node ip
            vmid=$(echo "$entry" | cut -d':' -f1)
            name=$(echo "$entry" | cut -d':' -f2)
            node=$(echo "$entry" | cut -d':' -f3)
            ip=$(echo "$entry" | cut -d':' -f4)
            local final_ip=$(discover_ip_for_vmid "$vmid" 2>/dev/null || echo "")
            [[ -n "$final_ip" && "$final_ip" != "$ip" ]] && {
                log_step_warn "  - VMID $vmid ($name): IP changed during check ($ip -> $final_ip)"
                ip="$final_ip"
            }
            [[ -n "$ip" ]] && {
                log_step_warn "  - VMID $vmid ($name at $ip): Talos API not responding"
                ping -c 1 -W 2 "$ip" &>/dev/null || log_step_warn "  - VMID $vmid ($name at $ip): Host is unreachable (check network/VM status)"
                ping -c 1 -W 2 "$ip" &>/dev/null && log_step_warn "  - VMID $vmid ($name at $ip): Host is pingable but port 50000 closed (Talos still booting?)"
            } || log_step_warn "  - VMID $vmid ($name): No IP discovered (check Proxmox VM status)"
        done
        [[ "$SKIP_PREFLIGHT" != "true" ]] && {
            log_step_warn "Some VMs are not ready. Options:"
            log_step_warn "  1. Wait and retry (VMs may still be booting)"
            log_step_warn "  2. Use --skip-preflight to bypass this check"
            log_step_warn "  3. Check VM status in Proxmox: qm status <vmid>"
            [[ "$AUTO_APPROVE" != "true" ]] && {
                echo -n "Continue anyway? [y/N] "
                local response
                read -r response
                [[ ! "$response" =~ ^[Yy]$ ]] && {
                    log_step_info "Cancelled by user"
                    exit 1
                }
            } || log_step_warn "Auto-approve enabled, continuing despite unready VMs"
        }
    }
    log_job_trace "run_preflight_checks: Completed with $ready_vms/$total_vms ready"
    return 0
}

update_kubeconfig() {
    log_job_info "Update Kubeconfig"
    log_job_trace "update_kubeconfig: Starting kubeconfig update"
    [[ -f "$TALOSCONFIG" ]] && export TALOSCONFIG
    local updated=0
    for vmid in "${!DEPLOYED_CP_IPS[@]}"; do
        local live_ip="${LIVE_NODE_IPS[$vmid]:-}"
        [[ -n "$live_ip" && "$live_ip" != "${DEPLOYED_CP_IPS[$vmid]}" ]] && {
            log_step_info "Updating CP VMID $vmid IP: ${DEPLOYED_CP_IPS[$vmid]} -> $live_ip"
            DEPLOYED_CP_IPS["$vmid"]="$live_ip"
            updated=$((updated + 1))
        }
    done
    [[ $updated -gt 0 ]] && save_state
    local bootstrap_node=""
    local max_attempts=30
    local attempt=1
    log_step_info "Waiting for control planes to be ready (this may take 60-90 seconds)..."
    while [[ $attempt -le $max_attempts ]]; do
        log_detail_trace "update_kubeconfig: Checking control plane readiness (attempt $attempt/$max_attempts)"
        for vmid in "${!DEPLOYED_CP_IPS[@]}"; do
            local ip="${DEPLOYED_CP_IPS[$vmid]}"
            log_step_debug "Checking VMID $vmid at $ip..."
            run_command talosctl version --nodes "$ip" --endpoints "$ip" && {
                run_command timeout 10 talosctl etcd members --nodes "$ip" --endpoints "$ip" && {
                    bootstrap_node="$ip"
                    log_step_info "Control plane $ip (VMID $vmid) is ready with healthy etcd (attempt $attempt)"
                    break 2
                } || log_step_debug "VMID $vmid API up but etcd not yet healthy"
            }
        done
        [[ $((attempt % 5)) -eq 0 ]] && log_step_debug "Still waiting for control planes... ($attempt/$max_attempts)"
        sleep 3
        attempt=$((attempt + 1))
    done
    [[ -z "$bootstrap_node" ]] && {
        log_step_error "No healthy control plane found after $max_attempts attempts"
        return 1
    }
    log_step_info "Retrieving kubeconfig from $bootstrap_node"
    run_command mkdir -p "$(dirname "$KUBECONFIG_PATH")"
    local temp_kubeconfig
    temp_kubeconfig=$(mktemp)
    run_command talosctl kubeconfig "$temp_kubeconfig" --nodes "$bootstrap_node" --endpoints "$bootstrap_node" && {
        chmod 600 "$temp_kubeconfig"
        local correct_server="https://${CONTROL_PLANE_ENDPOINT}:6443"
        log_step_info "Setting kubeconfig server to $correct_server (via HAProxy/control plane endpoint)"
        local actual_cluster_name=$(KUBECONFIG="$temp_kubeconfig" kubectl config view -o jsonpath='{.clusters[0].name}' 2>/dev/null || echo "")
        if [[ -z "$actual_cluster_name" ]]; then
            log_step_warn "Could not detect cluster name from kubeconfig, falling back to $CLUSTER_NAME"
            actual_cluster_name="$CLUSTER_NAME"
        fi
        log_step_debug "Detected cluster name in kubeconfig: $actual_cluster_name"
        if ! KUBECONFIG="$temp_kubeconfig" kubectl config set-cluster "$actual_cluster_name" --server="$correct_server" 2>/dev/null; then
          sed -i "s|server: https://[^[:space:]]*|server: $correct_server|g" "$temp_kubeconfig"
          log_step_debug "Used sed fallback to update server URL in kubeconfig"
        fi
        local actual_context_name=$(KUBECONFIG="$temp_kubeconfig" kubectl config view -o jsonpath='{.contexts[0].name}' 2>/dev/null || echo "")
        local context_name="${CLUSTER_NAME}"
        if [[ -n "$actual_context_name" && "$actual_context_name" != "$context_name" ]]; then
            log_step_debug "Renaming kubeconfig context from $actual_context_name to $context_name"
            KUBECONFIG="$temp_kubeconfig" kubectl config rename-context "$actual_context_name" "$context_name" 2>/dev/null || true
        fi
        if [[ "$actual_cluster_name" != "$CLUSTER_NAME" ]]; then
            log_step_debug "Renaming kubeconfig cluster from $actual_cluster_name to $CLUSTER_NAME"
            sed -i "s|cluster: $actual_cluster_name|cluster: $CLUSTER_NAME|g; s|name: $actual_cluster_name|name: $CLUSTER_NAME|g" "$temp_kubeconfig"
        fi
        if [[ -f "${HOME}/.kube/config" ]]; then
            log_step_info "Merging with existing kubeconfig at ${HOME}/.kube/config"
            local merged_config
            merged_config=$(mktemp)
            KUBECONFIG="${HOME}/.kube/config:${temp_kubeconfig}" kubectl config view --flatten > "$merged_config"
            if [[ -s "$merged_config" ]]; then
                local backup_name="${HOME}/.kube/config.backup.$(date +%Y%m%d_%H%M%S)"
                cp "${HOME}/.kube/config" "$backup_name"
                log_step_info "Backed up existing kubeconfig to $backup_name"
                mv "$merged_config" "${HOME}/.kube/config"
                chmod 600 "${HOME}/.kube/config"
                cp "${HOME}/.kube/config" "$KUBECONFIG_PATH"
            else
                log_step_warn "Merge failed, using cluster-specific config only"
                mv "$temp_kubeconfig" "$KUBECONFIG_PATH"
            fi
            rm -f "$merged_config"
        else
            mv "$temp_kubeconfig" "${HOME}/.kube/config"
            chmod 600 "${HOME}/.kube/config"
            cp "${HOME}/.kube/config" "$KUBECONFIG_PATH"
        fi
        rm -f "$temp_kubeconfig"
        log_step_info "Kubeconfig saved and merged successfully"
        log_step_info "Available contexts:"
        run_command kubectl --kubeconfig "$KUBECONFIG_PATH" config get-contexts 2>/dev/null || true
        local current_context=$(run_command kubectl --kubeconfig "$KUBECONFIG_PATH" config current-context 2>/dev/null || echo "")
        if [[ -z "$current_context" || "$current_context" != "$context_name" ]]; then
            run_command kubectl --kubeconfig "$KUBECONFIG_PATH" config use-context "$context_name" 2>/dev/null || true
            run_command kubectl config use-context "$context_name" 2>/dev/null || true
            log_step_info "Set current context to: $context_name"
        fi
        configure_talosctl_endpoints "$bootstrap_node"
        verify_kubernetes_access
    } || {
        log_step_error "Failed to retrieve kubeconfig from $bootstrap_node"
        rm -f "$temp_kubeconfig"
        return 1
    }
    log_job_trace "update_kubeconfig: Kubeconfig update completed"
}

configure_talosctl_endpoints() {
    local bootstrap_node="$1"
    log_step_info "Configuring talosctl endpoints"
    log_step_trace "configure_talosctl_endpoints: Setting endpoints to $HAPROXY_IP, node to $bootstrap_node"
    if run_command talosctl config endpoint "$HAPROXY_IP"; then
        log_step_info "Set talosctl endpoint to HAProxy ($HAPROXY_IP)"
        log_file_only "TALOSCONFIG" "Endpoint set to $HAPROXY_IP"
    else
        log_step_warn "Failed to set talosctl endpoint to HAProxy, using bootstrap node"
        if run_command talosctl config endpoint "$bootstrap_node"; then
            log_step_info "Set talosctl endpoint to bootstrap node ($bootstrap_node)"
            log_file_only "TALOSCONFIG" "Endpoint set to $bootstrap_node"
        fi
    fi
    if run_command talosctl config node "$bootstrap_node"; then
        log_step_info "Set talosctl node to $bootstrap_node"
        log_file_only "TALOSCONFIG" "Node set to $bootstrap_node"
    fi
    export TALOSCONFIG
}

verify_kubernetes_access() {
    log_step_info "Verifying Kubernetes API access..."
    log_step_trace "verify_kubernetes_access: Testing API connectivity"
    local kube_args=()
    [[ -f "$KUBECONFIG_PATH" ]] && kube_args+=(--kubeconfig "$KUBECONFIG_PATH")
    if kubectl "${kube_args[@]}" cluster-info &>/dev/null; then
        log_step_info "Kubernetes API is accessible"
        log_step_info "Cluster info:"
        run_command kubectl "${kube_args[@]}" cluster-info 2>/dev/null | head -5 || true
        log_step_info "Node status:"
        run_command kubectl "${kube_args[@]}" get nodes -o wide 2>/dev/null || log_step_warn "Could not retrieve node list (may still be joining)"
    else
        log_step_warn "Kubernetes API not yet ready (nodes may still be joining)"
        log_step_info "Try: kubectl --kubeconfig $KUBECONFIG_PATH cluster-info"
    fi
}

verify_cluster() {
    log_job_info "Verify Cluster"
    log_job_trace "verify_cluster: Starting cluster verification"
    [[ ! -f "$KUBECONFIG_PATH" ]] && {
        log_step_warn "No kubeconfig found, skipping verification"
        return 0
    }
    log_step_info "Checking Kubernetes API"
    run_command kubectl --kubeconfig "$KUBECONFIG_PATH" cluster-info &>/dev/null && log_step_info "Kubernetes API is ready" || {
        log_step_warn "Kubernetes API not yet ready"
        return 0
    }
    log_step_info "Node status:"
    run_command kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes -o wide 2>/dev/null || true
    log_step_info "etcd members:"
    run_command talosctl etcd members 2>/dev/null || true
    log_job_trace "verify_cluster: Verification completed"
}

sync_deployed_ips_with_live_discovery() {
    log_job_info "Synchronizing deployed IPs with live discovery"
    log_job_trace "sync_deployed_ips_with_live_discovery: Starting sync"
    local updated_count=0
    [[ ${#LIVE_NODE_IPS[@]} -eq 0 ]] && {
        log_step_warn "Live discovery empty, skipping IP sync (will use stored IPs)"
    } || {
        for vmid in "${!DEPLOYED_CP_IPS[@]}"; do
            local live_ip="${LIVE_NODE_IPS[$vmid]:-}"
            local stored_ip="${DEPLOYED_CP_IPS[$vmid]}"
            [[ -n "$live_ip" && "$live_ip" != "$stored_ip" ]] && {
                log_step_info "Updating CP VMID $vmid IP: $stored_ip -> $live_ip"
                DEPLOYED_CP_IPS["$vmid"]="$live_ip"
                updated_count=$((updated_count + 1))
            }
            [[ -z "$live_ip" && -n "$stored_ip" ]] && log_step_warn "CP VMID $vmid has stored IP $stored_ip but not discovered live (keeping stored)"
        done
        for vmid in "${!DEPLOYED_WORKER_IPS[@]}"; do
            local live_ip="${LIVE_NODE_IPS[$vmid]:-}"
            local stored_ip="${DEPLOYED_WORKER_IPS[$vmid]}"
            [[ -n "$live_ip" && "$live_ip" != "$stored_ip" ]] && {
                log_step_info "Updating Worker VMID $vmid IP: $stored_ip -> $live_ip"
                DEPLOYED_WORKER_IPS["$vmid"]="$live_ip"
                updated_count=$((updated_count + 1))
            }
            [[ -z "$live_ip" && -n "$stored_ip" ]] && log_step_warn "Worker VMID $vmid has stored IP $stored_ip but not discovered live (keeping stored)"
        done
    }
    [[ $updated_count -gt 0 ]] && {
        log_step_info "Updated $updated_count IPs from live discovery"
        save_state
    } || log_step_info "All IPs are current (no changes needed)"
    log_job_trace "sync_deployed_ips_with_live_discovery: Sync completed, updated=$updated_count"
}

test_port() {
    local ip="$1"
    local port="${2:-50000}"
    local timeout="${3:-2}"
    local vmid="${4:-}"
    local context=""
    [[ -n "$vmid" ]] && context="[VMID:${vmid}] "
    log_detail_trace "${context}Testing $ip:$port"
    if run_command timeout "$timeout" bash -c "echo >/dev/tcp/$ip/$port" 2>/dev/null; then
        log_detail_trace "${context}$ip:$port is open"
        return 0
    else
        log_detail_debug "${context}$ip:$port is closed/unreachable"
        return 1
    fi
}

run_bootstrap_plan() {
    log_plan_info "Bootstrap Execution"
    log_plan_trace "run_bootstrap_plan: Starting bootstrap plan execution"
    setup_environment
    run_discovery
    run_configuration
    reconcile_cluster
    [[ "$PLAN_MODE" == "true" ]] && return 0
    run_execution
    run_finalization
    log_plan_info "Bootstrap Complete"
    log_step_info "Kubeconfig: export KUBECONFIG=$KUBECONFIG_PATH"
    log_step_info "Talos Dashboard: talosctl dashboard --endpoints $HAPROXY_IP"
    log_file_only "COMPLETE" "Bootstrap finished successfully"
    log_plan_trace "run_bootstrap_plan: Bootstrap plan completed"
}

run_reconcile_plan() {
    log_plan_info "Reconcile Only"
    log_plan_trace "run_reconcile_plan: Starting reconcile plan execution"
    setup_environment
    run_discovery
    run_configuration
    reconcile_cluster
    [[ "$PLAN_MODE" == "true" ]] && return 0
    run_execution
    run_finalization
    log_plan_info "Reconciliation Complete"
    log_step_info "Kubeconfig: export KUBECONFIG=$KUBECONFIG_PATH"
    log_step_info "Talos Dashboard: talosctl dashboard --endpoints $HAPROXY_IP"
    log_file_only "COMPLETE" "Reconcile finished successfully"
    log_plan_trace "run_reconcile_plan: Reconcile plan completed"
}

run_status_plan() {
    log_plan_info "Show Status"
    log_plan_trace "run_status_plan: Displaying cluster status"
    load_desired_state 2>/dev/null || {
        log_step_warn "Could not load desired state from terraform.tfvars"
        log_step_warn "Status will show deployed state only"
    }
    load_deployed_state
    print_box_header "CLUSTER STATUS"
    print_box_pair "Cluster" "$CLUSTER_NAME"
    print_box_wrapped "Terraform" "$TERRAFORM_TFVARS"
    print_box_pair "Hash" "${TERRAFORM_HASH:0:16}..."
    print_border divider
    print_box_section "DESIRED STATE (Terraform)"
    print_box_line "  ${C_LABEL}Control Planes:${C_RESET} ${C_COUNT}${#DESIRED_CP_VMIDS[@]}${C_RESET}"
    for vmid in "${!DESIRED_CP_VMIDS[@]}"; do
        local info name node
        info="${DESIRED_CP_VMIDS[$vmid]}"
        name=$(echo "$info" | cut -d'|' -f1)
        node=$(echo "$info" | cut -d'|' -f2)
        print_box_item "" "$(format_node_display "$vmid" "$name" "$node")"
    done
    print_box_line "  ${C_LABEL}Workers:${C_RESET} ${C_COUNT}${#DESIRED_WORKER_VMIDS[@]}${C_RESET}"
    for vmid in "${!DESIRED_WORKER_VMIDS[@]}"; do
        local info name node
        info="${DESIRED_WORKER_VMIDS[$vmid]}"
        name=$(echo "$info" | cut -d'|' -f1)
        node=$(echo "$info" | cut -d'|' -f2)
        print_box_item "" "$(format_node_display "$vmid" "$name" "$node")"
    done
    print_border divider
    print_box_section "DEPLOYED STATE"
    print_box_line "  ${C_LABEL}Control Planes:${C_RESET} ${C_COUNT}${#DEPLOYED_CP_IPS[@]}${C_RESET}"
    for vmid in "${!DEPLOYED_CP_IPS[@]}"; do
        local ip info name node
        ip="${DEPLOYED_CP_IPS[$vmid]}"
        info="${DESIRED_CP_VMIDS[$vmid]:-}"
        name=$(echo "$info" | cut -d'|' -f1)
        node=$(echo "$info" | cut -d'|' -f2)
        print_box_item "" "$(format_node_display "$vmid" "$name" "$node" "$ip")"
    done
    print_box_line "  ${C_LABEL}Workers:${C_RESET} ${C_COUNT}${#DEPLOYED_WORKER_IPS[@]}${C_RESET}"
    for vmid in "${!DEPLOYED_WORKER_IPS[@]}"; do
        local ip info name node
        ip="${DEPLOYED_WORKER_IPS[$vmid]}"
        info="${DESIRED_WORKER_VMIDS[$vmid]:-}"
        name=$(echo "$info" | cut -d'|' -f1)
        node=$(echo "$info" | cut -d'|' -f2)
        print_box_item "" "$(format_node_display "$vmid" "$name" "$node" "$ip")"
    done
    local bootstrap_display
    [[ "$BOOTSTRAP_COMPLETED" == "true" ]] && bootstrap_display="${C_TRUE}true${C_RESET}" || bootstrap_display="${C_FALSE}false${C_RESET}"
    print_box_pair "Bootstrap Completed" "$bootstrap_display" "$C_LABEL" ""
    print_box_footer
    log_plan_trace "run_status_plan: Status display completed"
}

run_reset_plan() {
    log_plan_info "Full Reset"
    log_plan_trace "run_reset_plan: Starting full reset"
    log_stage_info "Reset Cluster"
    if [[ "$AUTO_APPROVE" != "true" ]]; then
        confirm_proceed "Permanently delete all configs, state, and secrets for cluster ${CLUSTER_NAME}?" || {
            log_step_info "Reset cancelled"
            exit 0
        }
    else
        log_step_warn "Auto-approve enabled, skipping confirmation for reset"
    fi
    [[ -d "$CLUSTER_DIR" ]] && {
        run_command rm -rf "${CLUSTER_DIR:?}"
        log_step_info "Removed cluster directory: $CLUSTER_DIR"
    }
    log_step_info "Reset complete for cluster ${CLUSTER_NAME}"
    log_plan_trace "run_reset_plan: Reset completed"
}

apply_config_maintenance() {
    local ip="$1"
    local config_file="$2"
    local max_attempts=5
    local attempt=1
    log_step_trace "apply_config_maintenance: Starting for $ip with $max_attempts attempts"
    while [[ $attempt -le $max_attempts ]]; do
        log_step_debug "Applying config (attempt $attempt/$max_attempts)..."
        if run_command talosctl apply-config --nodes "$ip" --file "$config_file" --insecure; then
            log_step_info "Configuration applied successfully"
            return 0
        fi
        local error_output="$LAST_COMMAND_OUTPUT"
        echo "$error_output" | grep -qi "already configured\|certificate required" && {
            log_step_info "Node reports already configured, proceeding..."
            return 0
        }
        log_step_warn "Apply failed, waiting before retry..."
        sleep 5
        attempt=$((attempt + 1))
    done
    log_step_error "apply_config_maintenance: Failed after $max_attempts attempts"
    return 1
}

attempt_recovery_reapply() {
    local ip="$1"
    local config_file="$2"
    local role="${3:-control-plane}"
    log_step_debug "Attempting recovery re-apply to $ip (role: $role) with insecure mode..."
    log_step_trace "attempt_recovery_reapply: Starting recovery for $ip"
    if run_command talosctl apply-config --nodes "$ip" --file "$config_file" --insecure; then
        log_step_info "Recovery re-apply succeeded"
        return 0
    fi
    local error_output="$LAST_COMMAND_OUTPUT"
    if echo "$error_output" | grep -qi "already configured"; then
        log_step_info "Node reports already configured"
        return 0
    fi
    if echo "$error_output" | grep -qi "certificate required"; then
        log_step_warn "Node requires certificates - cannot use insecure mode (this is expected for configured nodes)"
        if [[ "$role" == "worker" ]]; then
            log_step_debug "Worker node requiring certificates - may be attempting to join cluster"
            return 0
        fi
        return 1
    fi
    log_step_error "attempt_recovery_reapply: Recovery failed"
    return 1
}

wait_for_node_after_reboot() {
    local ip="$1"
    local vmid="$2"
    log_step_trace "wait_for_node_after_reboot: Waiting for VM $vmid at $ip"
    wait_for_node_with_rediscovery "$vmid" "$ip" 120
}

check_prerequisites() {
    log_job_info "Check Prerequisites"
    log_job_trace "check_prerequisites: Checking required tools"
    local missing=()
    for cmd in talosctl ssh scp jq; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -gt 0 ]] && log_job_fatal "Missing required tools: ${missing[*]}"
    command -v talosctl &>/dev/null && {
        if run_command talosctl version --client; then
            local talos_version=$(echo "$LAST_COMMAND_OUTPUT" | grep -oP 'Tag:\s*\K[^[:space:]]+' | head -1 || echo "unknown")
            log_detail_debug "talosctl version: $talos_version"
        fi
    }
    log_step_info "Prerequisites satisfied"
    log_job_trace "check_prerequisites: All prerequisites met"
}

confirm_proceed() {
    local msg="${1:-Proceed?}"
    local response
    local prompt_output="${C_TIMESTAMP}[$(date '+%H:%M:%S')]${C_RESET} ${SEV_COLORS[WARN]}[INPUT]${C_RESET} ${msg} (y/N) "
    echo -en "$prompt_output"
    read -r response
    [[ -n "${ALL_LOGS_FILE:-}" ]] && {
        echo "[$(date "$LOG_TIMESTAMP_FORMAT")] [USER-INPUT] Prompt: '$msg' Response: '$response'" >> "$ALL_LOGS_FILE"
        echo "[$(date "$LOG_TIMESTAMP_FORMAT")] [DECISION] Auto-approve=$AUTO_APPROVE, User-response=$response" >> "$ALL_LOGS_FILE"
    }
    log_file_only "INPUT" "Prompt: '$msg' Response: '$response'"
    [[ "$response" =~ ^[Yy]$ ]]
}

show_help() {
    local help_text
    read -r -d '' help_text <<'EOF' || true
Usage: $0 {bootstrap|reconcile|status|reset|help} [options]

Commands:
  bootstrap    Full bootstrap with reconciliation (initial deployment)
  reconcile    Reconcile existing cluster with terraform.tfvars changes
  status       Show current cluster status and state comparison
  reset        Full reset (delete all configs, state, and secrets)
  help         Show this help message

Options:
  Long Form:           Short Form:        Description:
  --plan               -p                 Show what would change without applying
  --auto-approve       -a                 Skip interactive confirmations (for CI/CD)
  --dry-run            -d                 Simulate operations without making changes
  --skip-preflight     -s                 Skip pre-flight connectivity checks
  --force-reconfigure  -f                 Regenerate all configs even if unchanged
  --log-level          -l <level>         Set log level (FATAL, ERROR, WARN, INFO, DEBUG, TRACE)
  --help               -h                 Show this help message

  Combined short flags are supported: -pas is equivalent to -p -a -s
  Note: -l requires an argument, so place it last in combined flags: -pasl DEBUG

Environment Variables:
  CLUSTER_NAME              Cluster name (default: proxmox-talos-test)
  TERRAFORM_TFVARS          Path to terraform.tfvars (required)
  CONTROL_PLANE_ENDPOINT    DNS endpoint (default: $CLUSTER_NAME.jdwkube.com)
  HAPROXY_IP                HAProxy IP (default: 192.168.1.237)
  KUBERNETES_VERSION        K8s version (default: v1.35.0)
  TALOS_VERSION             Talos version (default: v1.12.3)
  LOG_LEVEL                 Log level: FATAL, ERROR, WARN, INFO, DEBUG, TRACE

Examples:
  $0 bootstrap                    # Initial deployment
  $0 reconcile --plan             # Preview changes from terraform.tfvars
  $0 reconcile -p                 # Same as above using short flag
  $0 reconcile -pas               # Combined: plan + auto-approve + skip-preflight
  $0 reconcile -p -a -s           # Same as above, separate flags
  $0 reconcile --auto-approve     # Apply changes without prompting
  $0 status                       # Show current cluster state
  $0 status -l DEBUG              # Show status with debug logging
  LOG_LEVEL=TRACE $0 status       # Show detailed trace logging

Directory Structure:
  clusters/${CLUSTER_NAME}/
    ├── nodes/          # Generated node configs (VMID-based naming)
    │   └── .checksums/ # Config hashes for drift detection
    ├── secrets/        # Sensitive files (persistent)
    └── state/          # Deployment state (persistent)

Log Files:
  logs/YYYY-MM-DD/run-YYYYMMDD_HHMMSS/
    ├── console.log     # Colored output (same as terminal)
    ├── structured.log  # Clean text output (no colors)
    ├── audit.log       # Complete command audit trail
    └── SUMMARY.txt     # Run summary and statistics
EOF
    log_output "$help_text" "false" "false"
}

parse_arguments() {
    local args
    args=$(getopt -o "hpadsfl:" --long "plan,auto-approve,dry-run,skip-preflight,force-reconfigure,help,log-level:" -n "$(basename "$0")" -- "$@") || {
        echo "Try '$(basename "$0") --help' for more information." >&2
        exit 1
    }
    eval set -- "$args"
    while true; do
        case "$1" in
            -p|--plan) PLAN_MODE="true"; DRY_RUN="true"; shift ;;
            -a|--auto-approve) AUTO_APPROVE="true"; shift ;;
            -d|--dry-run) DRY_RUN="true"; shift ;;
            -s|--skip-preflight) SKIP_PREFLIGHT="true"; shift ;;
            -f|--force-reconfigure) FORCE_RECONFIGURE="true"; shift ;;
            -l|--log-level)
                [[ -z "${2:-}" ]] && {
                    echo "ERROR: --log-level requires an argument" >&2
                    exit 1
                }
                LOG_LEVEL="$2"
                shift 2
                ;;
            -h|--help) show_help; exit 0 ;;
            --) shift; break ;;
            *) echo "ERROR: Unhandled option: $1" >&2; exit 1 ;;
        esac
    done
    REMAINING_ARGS=("$@")
}

main() {
    parse_arguments "$@"
    [[ ${#REMAINING_ARGS[@]} -eq 0 ]] && {
        show_help
        exit 1
    }
    local command="${REMAINING_ARGS[0]}"
    local extra_args=("${REMAINING_ARGS[@]:1}")
    case "$command" in
        bootstrap|reconcile|status|reset|help) : ;;
        *) echo "ERROR: Unknown command: $command" >&2; show_help; exit 1 ;;
    esac
    case "$command" in
        bootstrap)
            init_logging "$command" "${extra_args[@]}"
            run_bootstrap_plan
            ;;
        reconcile)
            init_logging "$command" "${extra_args[@]}"
            run_reconcile_plan
            ;;
        status)
            init_logging "$command"
            run_status_plan
            ;;
        reset)
            init_logging "$command"
            run_reset_plan
            ;;
        help) show_help ;;
    esac
}

main "$@"