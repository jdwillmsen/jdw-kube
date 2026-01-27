#!/bin/bash
set -eo pipefail

# ==================== CONFIGURATION ====================
HAPROXY_IP="192.168.1.237"
PROXMOX_SSH_HOST="pve1"

PROXMOX_NODE="pve"
CLUSTER_NAME="proxmox-talos-test"

CONTROL_PLANE_VM_IDS=(200 201)
WORKER_VM_IDS=(300 301 302)

# ==================== WINDOWS/GIT BASH DETECTION ====================
# SSH Multiplexing (ControlMaster) uses Unix sockets that don't work in Git Bash
IS_WINDOWS=false
SSH_OPTS=""

if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]] || [[ "$MSYSTEM" == "MINGW"* ]] || [[ -n "$WINDIR" && "$OSTYPE" == "linux-gnu" ]]; then
    IS_WINDOWS=true
    # Simple SSH opts for Windows - no multiplexing
    SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no"
else
    # Linux/Mac - use multiplexing for performance
    SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPath=~/.ssh/proxmox_mux_%h_%p_%r -o ControlPersist=600"
fi

# ==================== LOGGING ====================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; ORANGE='\033[0;33m'; NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_step() { echo -e "\n${BLUE}[STEP]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_detail() { echo -e "${CYAN}[DETAIL]${NC} $1"; }
log_method() { echo -e "${ORANGE}[METHOD]${NC} $1"; }
log_debug() {
    if [ "${DEBUG:-0}" == "1" ]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

# ==================== DATA STRUCTURES ====================
declare -A VM_MACS=()
declare -A VM_NAMES=()
declare -A VM_IPS=()
declare -A MAC_TO_IP=()
declare -A VM_ROLES=()
declare -A FOUND_BY_AGENT=()
declare -A FOUND_BY_ARP=()

# ==================== SSH SETUP ====================

setup_ssh_mux() {
    log_step "Testing SSH connection to ${PROXMOX_SSH_HOST}"

    if [ "$IS_WINDOWS" == "true" ]; then
        log_info "Windows/Git Bash detected - using standard SSH (multiplexing disabled)"
    fi

    # Debug output to stderr if DEBUG=1
    if [ "${DEBUG:-0}" == "1" ]; then
        log_detail "Running: ssh ${SSH_OPTS} ${PROXMOX_SSH_HOST} \"echo SSH ready\""
        if ! ssh ${SSH_OPTS} "${PROXMOX_SSH_HOST}" "echo 'SSH ready'"; then
            log_error "SSH connection failed"
            return 1
        fi
    else
        if ! ssh ${SSH_OPTS} "${PROXMOX_SSH_HOST}" "echo 'SSH ready'" &>/dev/null; then
            log_error "SSH connection failed to ${PROXMOX_SSH_HOST}"
            log_detail "Tip: Run with DEBUG=1 to see detailed error"
            log_detail "Check: ssh ${PROXMOX_SSH_HOST} \"echo test\" works from your CLI"
            return 1
        fi
    fi
    log_info "SSH connection successful"
    return 0
}

cleanup_ssh_mux() {
    # Only try to close multiplexing socket if not on Windows and we actually used it
    if [ "$IS_WINDOWS" != "true" ] && [ -n "$SSH_OPTS" ]; then
        ssh -O exit -o ControlPath=~/.ssh/proxmox_mux_%h_%p_%r "${PROXMOX_SSH_HOST}" &>/dev/null || true
    fi
}

# ==================== UTILITY FUNCTIONS ====================

test_port() {
    local ip=$1
    local port=$2
    timeout 2 bash -c "echo >/dev/tcp/$ip/$port" 2>/dev/null || echo "failed"
}

get_ssh_output() {
    local cmd="$1"
    local output=""
    local stderr_file=$(mktemp)

    output=$(ssh ${SSH_OPTS} "${PROXMOX_SSH_HOST}" "$cmd" 2>"$stderr_file") || {
        local exit_code=$?
        if [ "${DEBUG:-0}" == "1" ]; then
            log_error "SSH command failed with exit $exit_code"
            log_detail "Command: $cmd"
            log_detail "Stderr: $(cat "$stderr_file")"
        fi
        rm -f "$stderr_file"
        return $exit_code
    }
    rm -f "$stderr_file"
    echo "$output"
}

get_vm_role() {
    local vmid=$1
    # Use case statement for better compatibility than array regex
    case " ${CONTROL_PLANE_VM_IDS[*]} " in
        *" $vmid "*) echo "control-plane" ;;
        *)
            case " ${WORKER_VM_IDS[*]} " in
                *" $vmid "*) echo "worker" ;;
                *) echo "unknown" ;;
            esac
        ;;
    esac
}

# ==================== VM CONFIG & MAC DISCOVERY ====================

get_proxmox_vm_config() {
    log_step "Fetching VM Configurations from Proxmox (VMs: ${CONTROL_PLANE_VM_IDS[*]} ${WORKER_VM_IDS[*]})"
    local all_vm_ids=("${CONTROL_PLANE_VM_IDS[@]}" "${WORKER_VM_IDS[@]}")
    local found_count=0

    for vmid in "${all_vm_ids[@]}"; do
        log_debug "Fetching config for VM $vmid"
        local config
        config=$(get_ssh_output "qm config $vmid") || {
            log_warn "Failed to get config for VM $vmid (VM might not exist or be stopped)"
            continue
        }

        local name=$(echo "$config" | grep '^name:' | cut -d' ' -f2-)
        VM_NAMES[$vmid]="$name"
        VM_ROLES[$vmid]=$(get_vm_role "$vmid")

        # Extract MAC addresses from network interfaces
        local macs=$(echo "$config" | grep -E '^net[0-9]+:' | grep -oE '[a-fA-F0-9]{2}:[a-fA-F0-9]{2}:[a-fA-F0-9]{2}:[a-fA-F0-9]{2}:[a-fA-F0-9]{2}:[a-fA-F0-9]{2}')

        if [ -n "$macs" ]; then
            macs=$(echo "$macs" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')
            VM_MACS[$vmid]="$macs"
            log_detail "VM $vmid ($name): MACs=$macs"
            found_count=$((found_count + 1))
        else
            log_warn "VM $vmid has no MAC addresses found"
        fi
    done

    log_info "Discovered $found_count VMs with MAC addresses"
    if [ $found_count -eq 0 ]; then
        log_error "No VMs found! Check if VMs exist and SSH access is working"
        return 1
    fi
    return 0
}

# ==================== METHOD 1: GUEST AGENT ====================

discover_guest_agent() {
    log_method "Guest Agent Method"
    local found_count=0

    for vmid in "${!VM_MACS[@]}"; do
        log_debug "Querying guest agent for VM $vmid"
        local json_data
        json_data=$(get_ssh_output "qm guest cmd $vmid network-get-interfaces") || {
            log_debug "Guest agent not available for VM $vmid"
            continue
        }

        local ip
        ip=$(echo "$json_data" | jq -r '.[0]."ip-addresses"[]? | select(."ip-address-type"=="ipv4" and ."ip-address" != "127.0.0.1") | ."ip-address"' 2>/dev/null | head -1)

        if [ -n "$ip" ] && [ "$(test_port "$ip" 50000)" != "failed" ]; then
            FOUND_BY_AGENT[$vmid]="$ip"
            VM_IPS[$vmid]="$ip"
            log_detail "VM $vmid (${VM_NAMES[$vmid]}): $ip (guest agent)"
            found_count=$((found_count + 1))
        elif [ -n "$ip" ]; then
            log_detail "VM $vmid: guest agent reports $ip but port 50000 not open"
        fi
    done

    log_info "Guest Agent found $found_count VMs"
    return 0
}

test_guest_agent_only() {
    log_step "Testing Guest Agent Method Only"
    get_proxmox_vm_config || return 1
    discover_guest_agent

    echo -e "\n${CYAN}Results from Guest Agent:${NC}"
    printf "%-6s %-20s %-15s %-15s\n" "VMID" "NAME" "IP" "STATUS"
    echo "------------------------------------------------"

    for vmid in "${!VM_MACS[@]}"; do
        local ip="${FOUND_BY_AGENT[$vmid]:-}"
        local status="✗ Not found"
        [ -n "$ip" ] && status="✓ Found"
        printf "%-6s %-20s %-15s %-15s\n" "$vmid" "${VM_NAMES[$vmid]}" "${ip:--}" "$status"
    done

    VM_IPS=()
    FOUND_BY_AGENT=()
}

# ==================== METHOD 2: ARP/MAC ====================

get_arp_table() {
    log_method "ARP Table Collection"
    local arp_output
    arp_output=$(get_ssh_output "cat /proc/net/arp | grep -v '00:00:00:00:00:00'") || {
        log_warn "Failed to get ARP table"
        return 1
    }

    MAC_TO_IP=()
    while read -r ip_addr _ _ mac_addr _ _; do
        [ -z "$ip_addr" ] || [ "$ip_addr" == "IP" ] && continue
        mac_addr=$(echo "$mac_addr" | tr '[:upper:]' '[:lower:]')
        if [ -n "$mac_addr" ] && [ "$mac_addr" != "00:00:00:00:00:00" ]; then
            MAC_TO_IP[$mac_addr]="$ip_addr"
            log_debug "ARP: $mac_addr -> $ip_addr"
        fi
    done <<< "$arp_output"

    log_info "ARP table contains ${#MAC_TO_IP[@]} entries"
}

trigger_arp_discovery() {
    log_method "Triggering ARP Discovery (background ping sweep)"
    local subnet="192.168.1"

    log_info "Sending ping sweep from Proxmox to populate ARP table..."
    # Run in background on Proxmox so we don't wait for completion
    get_ssh_output "
        for i in \$(seq 1 254); do
            ping -c 1 -W 1 ${subnet}.\${i} &>/dev/null &
            if (( i % 50 == 0 )); then wait; fi
        done
        wait
        echo 'Scan complete'
    " || {
        log_warn "ARP discovery trigger may have had issues, continuing anyway"
    }

    sleep 2
}

discover_arp_method() {
    log_method "MAC/ARP Association"
    get_arp_table || return 1

    local found_count=0
    for vmid in "${!VM_MACS[@]}"; do
        local vm_name="${VM_NAMES[$vmid]}"
        local found_ip=""

        for mac in ${VM_MACS[$vmid]}; do
            if [ -n "${MAC_TO_IP[$mac]:-}" ]; then
                local ip="${MAC_TO_IP[$mac]}"
                if [ "$(test_port "$ip" 50000)" != "failed" ]; then
                    FOUND_BY_ARP[$vmid]="$ip"
                    VM_IPS[$vmid]="$ip"
                    log_detail "VM $vmid ($vm_name): $ip (MAC: $mac)"
                    found_ip="$ip"
                    found_count=$((found_count + 1))
                    break
                else
                    log_detail "VM $vmid: $ip in ARP but port 50000 closed"
                fi
            fi
        done
    done

    log_info "ARP method found $found_count VMs"
}

test_arp_method_only() {
    log_step "Testing ARP/MAC Method Only"
    get_proxmox_vm_config || return 1
    trigger_arp_discovery
    discover_arp_method

    echo -e "\n${CYAN}Results from ARP/MAC:${NC}"
    printf "%-6s %-20s %-15s %-20s\n" "VMID" "NAME" "IP" "MAC(s)"
    echo "--------------------------------------------------------"

    for vmid in "${!VM_MACS[@]}"; do
        local ip="${FOUND_BY_ARP[$vmid]:-}"
        local macs="${VM_MACS[$vmid]}"
        printf "%-6s %-20s %-15s %-20s\n" "$vmid" "${VM_NAMES[$vmid]}" "${ip:--}" "$macs"
    done

    VM_IPS=()
    FOUND_BY_ARP=()
}

# ==================== METHOD 3: NETWORK SCAN ====================

discover_network_scan() {
    log_method "Network Port Scan (50000)"
    local subnet="192.168.1"
    local port=50000

    # Git Bash has issues with background processes in loops sometimes, so use temp files differently
    local scan_results=$(mktemp)
    local pids=()

    log_info "Scanning ${subnet}.0/24 for port $port (this takes ~10 seconds)..."
    log_detail "Note: Network scan cannot associate IPs with VMIDs without MAC correlation"

    for i in {1..254}; do
        (
            ip="${subnet}.${i}"
            if [ "$(test_port "$ip" "$port")" != "failed" ]; then
                echo "$ip" >> "$scan_results"
                log_debug "Found $ip:$port open"
            fi
        ) &
        pids+=($!)

        # Limit concurrency to avoid overwhelming Windows/Git Bash
        if (( i % 30 == 0 )); then
            wait ${pids[@]} 2>/dev/null || true
            pids=()
        fi
    done

    # Wait for remaining
    wait 2>/dev/null || true

    if [ -s "$scan_results" ]; then
        mapfile -t found_ips < <(sort -t. -k4 -n -u "$scan_results")
        rm -f "$scan_results"
        log_info "Network scan found ${#found_ips[@]} IPs with port 50000 open"
        echo "${found_ips[@]}"
        return 0
    else
        rm -f "$scan_results"
        log_warn "No IPs found via network scan"
        return 1
    fi
}

test_network_scan_only() {
    log_step "Testing Network Scan Method Only"
    local ips=$(discover_network_scan)

    if [ -n "$ips" ]; then
        echo -e "\n${CYAN}Results from Network Scan:${NC}"
        for ip in $ips; do
            local role="potential node"
            [[ "$ip" == "$HAPROXY_IP" ]] && role="HAProxy (exclude)"
            log_info "Found: $ip ($role)"
        done
    fi
}

# ==================== COMPARISON & VALIDATION ====================

compare_discovery_methods() {
    log_step "Comparing All Discovery Methods"
    get_proxmox_vm_config || return 1

    log_info "Running Guest Agent discovery..."
    discover_guest_agent

    log_info "Running ARP discovery..."
    trigger_arp_discovery
    discover_arp_method

    log_info "Running Network Scan..."
    local scan_ips=$(discover_network_scan)

    echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           METHOD COMPARISON REPORT                             ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"

    printf "${CYAN}%-6s %-20s %-15s %-15s %-12s${NC}\n" "VMID" "NAME" "Guest Agent" "ARP/MAC" "Consensus"
    echo "----------------------------------------------------------------------------"

    for vmid in "${!VM_MACS[@]}"; do
        local agent_ip="${FOUND_BY_AGENT[$vmid]:--}"
        local arp_ip="${FOUND_BY_ARP[$vmid]:--}"
        local consensus="✗ Missing"

        if [ "$agent_ip" == "$arp_ip" ] && [ "$agent_ip" != "-" ]; then
            consensus="✓ Agreement"
        elif [ "$agent_ip" != "-" ] && [ "$arp_ip" != "-" ]; then
            consensus="⚠ CONFLICT!"
        elif [ "$agent_ip" != "-" ] || [ "$arp_ip" != "-" ]; then
            consensus="Partial"
        fi

        printf "%-6s %-20s %-15s %-15s %-12s\n" \
            "$vmid" "${VM_NAMES[$vmid]:0:20}" "$agent_ip" "$arp_ip" "$consensus"
    done

    echo -e "\n${CYAN}Raw Network Scan results:${NC} $scan_ips"
    echo -e "${YELLOW}Note:${NC} If Guest Agent and ARP disagree, check if VM has multiple IPs or was recently migrated"

    FOUND_BY_AGENT=()
    FOUND_BY_ARP=()
    VM_IPS=()
}

validate_vm_ip_association() {
    log_step "Validating VM→MAC→IP Association Chain"
    get_proxmox_vm_config || return 1
    trigger_arp_discovery
    get_arp_table || return 1

    echo -e "\n${CYAN}VM → MAC → IP Association Map:${NC}"
    printf "${CYAN}%-6s %-18s %-15s %-15s %-12s${NC}\n" "VMID" "MAC Address" "IP Address" "Role" "Talos API"
    echo "--------------------------------------------------------------------------------"

    for vmid in "${!VM_MACS[@]}"; do
        local role="${VM_ROLES[$vmid]}"
        local name="${VM_NAMES[$vmid]}"
        local mac_list=(${VM_MACS[$vmid]})

        for mac in "${mac_list[@]}"; do
            local ip="${MAC_TO_IP[$mac]:-}"
            local status="Not in ARP"

            if [ -n "$ip" ]; then
                if [ "$(test_port "$ip" 50000)" != "failed" ]; then
                    status="✓ Port 50000"
                else
                    status="✗ Port closed"
                fi
                printf "%-6s %-18s %-15s %-15s %-12s\n" "$vmid" "$mac" "$ip" "$role" "$status"
            else
                printf "%-6s %-18s %-15s %-15s %-12s\n" "$vmid" "$mac" "(unknown)" "$role" "$status"
            fi
        done
    done
}

# ==================== COMPREHENSIVE DISCOVERY ====================

discover_proxmox_vms() {
    log_step "Comprehensive Proxmox VM Discovery"

    if ! get_proxmox_vm_config; then
        return 1
    fi

    # Step 1: Guest agent
    discover_guest_agent

    # Step 2: Fill gaps with ARP
    local missing_vms=()
    for vmid in "${!VM_MACS[@]}"; do
        [ -z "${FOUND_BY_AGENT[$vmid]:-}" ] && missing_vms+=("$vmid")
    done

    if [ ${#missing_vms[@]} -gt 0 ]; then
        log_info "${#missing_vms[@]} VMs not found by Guest Agent, trying ARP..."
        trigger_arp_discovery
        discover_arp_method

        for vmid in "${missing_vms[@]}"; do
            [ -n "${FOUND_BY_ARP[$vmid]:-}" ] && VM_IPS[$vmid]="${FOUND_BY_ARP[$vmid]}"
        done
    fi

    # Summary Table
    FILTERED_CP_IPS=()
    FILTERED_WORKER_IPS=()

    echo -e "\n${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           FINAL DISCOVERY RESULTS                      ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"

    printf "${CYAN}%-6s %-20s %-15s %-15s %-12s${NC}\n" "VMID" "NAME" "IP" "ROLE" "SOURCE"
    echo "--------------------------------------------------------------------"

    for vmid in "${!VM_MACS[@]}"; do
        local name="${VM_NAMES[$vmid]}"
        local role="${VM_ROLES[$vmid]}"
        local ip="${VM_IPS[$vmid]:-}"
        local source="--"

        if [ -n "$ip" ]; then
            [ -n "${FOUND_BY_AGENT[$vmid]:-}" ] && source="guest-agent"
            [ -n "${FOUND_BY_ARP[$vmid]:-}" ] && [ "$source" == "--" ] && source="arp-mac"

            if [ "$role" == "control-plane" ]; then
                FILTERED_CP_IPS+=("$ip")
            elif [ "$role" == "worker" ]; then
                FILTERED_WORKER_IPS+=("$ip")
            fi
        else
            ip="NOT FOUND"
        fi

        printf "%-6s %-20s %-15s %-15s %-12s\n" "$vmid" "$name" "$ip" "$role" "$source"
    done

    echo -e "\n${GREEN}Summary:${NC}"
    log_info "Control Plane IPs (${#FILTERED_CP_IPS[@]}): ${FILTERED_CP_IPS[*]:-<none>}"
    log_info "Worker IPs (${#FILTERED_WORKER_IPS[@]}): ${FILTERED_WORKER_IPS[*]:-<none>}"

    return 0
}

# ==================== INTEGRATION TEST ====================

test_haproxy_integration() {
    log_step "Testing HAProxy Integration"

    if [ ! -x "./update-haproxy.sh" ]; then
        log_error "update-haproxy.sh not found or not executable"
        return 1
    fi

    local all_ips=("${FILTERED_CP_IPS[@]}" "${FILTERED_WORKER_IPS[@]}")

    if [ ${#all_ips[@]} -eq 0 ]; then
        log_error "No IPs discovered to send to HAProxy"
        return 1
    fi

    log_info "Control Planes: ${FILTERED_CP_IPS[*]:-<none>}"
    log_info "Workers: ${FILTERED_WORKER_IPS[*]:-<none>}"

    echo
    read -p "Execute HAProxy update now? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if ./update-haproxy.sh "${all_ips[@]}"; then
            log_info "✓ HAProxy updated"
            sleep 5
            if timeout 5 curl -s "http://${HAPROXY_IP}:9000" >/dev/null 2>&1; then
                log_info "✓ HAProxy responding on :9000"
            else
                log_warn "HAProxy :9000 not responding (may need more time)"
            fi
        else
            log_error "HAProxy update failed"
            return 1
        fi
    fi
}

# ==================== MAIN MENU ====================

show_menu() {
    # Don't clear screen in debug mode so we can see previous errors
    if [ "${DEBUG:-0}" != "1" ]; then
        clear 2>/dev/null || echo "===================================="
    else
        echo "===================================="
    fi

    echo "TALOS DISCOVERY VALIDATION SUITE"
    echo "===================================="
    if [ "$IS_WINDOWS" == "true" ]; then
        echo "Platform: Windows/Git Bash (SSH multiplexing disabled)"
    fi
    echo ""
    echo "Discovery Methods:"
    echo "  1. Full Discovery (Recommended: Guest Agent → ARP)"
    echo "  2. Test Guest Agent Only"
    echo "  3. Test ARP/MAC Method Only"
    echo "  4. Test Network Scan Only"
    echo ""
    echo "Validation:"
    echo "  5. Compare Methods (detect conflicts)"
    echo "  6. Show VM→MAC→IP Chain"
    echo ""
    echo "Integration:"
    echo "  7. Full Discovery + HAProxy Update"
    echo "  8. Exit"
    echo ""
    echo "Debug: Run with DEBUG=1 ./$(basename "$0") for verbose output"
    echo ""
}

main_menu() {
    show_menu
    read -p "Select option (1-8): " choice
    echo

    case $choice in
        1) setup_ssh_mux && discover_proxmox_vms ;;
        2) setup_ssh_mux && test_guest_agent_only ;;
        3) setup_ssh_mux && test_arp_method_only ;;
        4) test_network_scan_only ;;
        5) setup_ssh_mux && compare_discovery_methods ;;
        6) setup_ssh_mux && validate_vm_ip_association ;;
        7) setup_ssh_mux && discover_proxmox_vms && test_haproxy_integration ;;
        8) cleanup_ssh_mux; exit 0 ;;
        *) log_error "Invalid option" ;;
    esac

    echo ""
    read -p "Press Enter to continue..."
    main_menu
}

# ==================== INIT ====================

echo "Checking prerequisites..."
command -v ssh &>/dev/null || { log_error "SSH not found"; exit 1; }

if [ "${DEBUG:-0}" == "1" ]; then
    log_info "DEBUG mode enabled"
fi

trap cleanup_ssh_mux EXIT
main_menu