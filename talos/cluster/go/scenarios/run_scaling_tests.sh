#!/bin/bash
set -euo pipefail

# Test Configuration
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scaling_tests"
RESULTS_DIR="$TEST_DIR/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
PASSED=0
FAILED=0
SKIPPED=0

log_info() { echo -e "[$(date '+%H:%M:%S')] ${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "[$(date '+%H:%M:%S')] ${GREEN}[PASS]${NC} $1"; }
log_error() { echo -e "[$(date '+%H:%M:%S')] ${RED}[FAIL]${NC} $1"; }
log_skip() { echo -e "[$(date '+%H:%M:%S')] ${YELLOW}[SKIP]${NC} $1"; }
log_header() { echo -e "\n${CYAN}══════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════════════════${NC}"; }

# Ensure directories exist
mkdir -p "$RESULTS_DIR"

# Test scenarios in order
declare -a TESTS=(
    "01_baseline_3cp_2w:3 CP + 2 Workers:Baseline HA setup:validate_basic"
    "02_scale_cp_up_5cp_0w:5 CP + 0 Workers:CP expansion (3→5):validate_no_workers"
    "03_scale_cp_down_3cp_2w:3 CP + 2 Workers:CP reduction (5→3):validate_basic"
    "04_scale_workers_up_3cp_10w:3 CP + 10 Workers:Worker expansion (2→10):validate_many_workers"
    "05_scale_workers_down_3cp_3w:3 CP + 3 Workers:Worker reduction (10→3):validate_few_workers"
    "06_extreme_scale_3cp_20w:3 CP + 20 Workers:Extreme scale (3→20):validate_extreme"
    "07_zero_workers_3cp_0w:3 CP + 0 Workers:Zero workers:validate_no_workers"
    "08_mixed_scale_5cp_10w:5 CP + 10 Workers:Maximum density:validate_complex"
    "09_quorum_loss_risk_2cp_2w:2 CP + 2 Workers:Validation test (should fail):validate_rejected"
)

# Extract expected counts from filename
parse_test_file() {
    local filename="$1"
    local basename=$(basename "$filename" .tfvars)

    # Extract CP count
    local cp_count=$(echo "$basename" | grep -oE '[0-9]+cp' | grep -oE '[0-9]+')
    # Extract Worker count
    local worker_count=$(echo "$basename" | grep -oE '[0-9]+w' | grep -oE '[0-9]+')

    echo "$cp_count $worker_count"
}

# Validation functions
validate_basic() {
    local cp_expected=$1
    local worker_expected=$2
    local result_file=$3

    local vm_count=$(grep -c "proxmox_virtual_environment_vm" "$result_file" 2>/dev/null || echo "0")
    local cp_count=$(grep -c "talos-cp-" "$result_file" 2>/dev/null || echo "0")
    local worker_count=$(grep -c "talos-worker-" "$result_file" 2>/dev/null || echo "0")

    [[ "$cp_count" -eq "$cp_expected" && "$worker_count" -eq "$worker_expected" ]]
}

validate_no_workers() {
    local cp_expected=$1
    local worker_expected=$2
    local result_file=$3

    # Should have CPs but no workers
    local cp_count=$(grep -c "talos-cp-" "$result_file" 2>/dev/null || echo "0")
    local worker_count=$(grep -c "talos-worker-" "$result_file" 2>/dev/null || echo "0")

    [[ "$cp_count" -eq "$cp_expected" && "$worker_count" -eq "0" ]]
}

validate_many_workers() {
    local cp_expected=$1
    local worker_expected=$2
    local result_file=$3

    # Check we have many workers (10+)
    local cp_count=$(grep -c "talos-cp-" "$result_file" 2>/dev/null || echo "0")
    local worker_count=$(grep -c "talos-worker-" "$result_file" 2>/dev/null || echo "0")
    local unique_vmids=$(grep "vm_id" "$result_file" | sort -u | wc -l)

    [[ "$cp_count" -eq "$cp_expected" && "$worker_count" -ge "10" && "$unique_vmids" -eq "$((cp_expected + worker_expected))" ]]
}

validate_few_workers() {
    local cp_expected=$1
    local worker_expected=$2
    local result_file=$3

    # Check non-sequential workers (gaps in numbering)
    local cp_count=$(grep -c "talos-cp-" "$result_file" 2>/dev/null || echo "0")
    local worker_count=$(grep -c "talos-worker-" "$result_file" 2>/dev/null || echo "0")

    # Verify specific workers exist (01, 08, 10 for test 05)
    local has_worker_01=$(grep -c "talos-worker-01" "$result_file" || echo "0")
    local has_worker_08=$(grep -c "talos-worker-08" "$result_file" || echo "0")
    local has_worker_10=$(grep -c "talos-worker-10" "$result_file" || echo "0")

    [[ "$cp_count" -eq "$cp_expected" && "$worker_count" -eq "$worker_expected" && "$has_worker_01" -gt "0" && "$has_worker_10" -gt "0" ]]
}

validate_extreme() {
    local cp_expected=$1
    local worker_expected=$2
    local result_file=$3

    # Check 20+ total nodes
    local total_count=$(grep -c "talos-" "$result_file" 2>/dev/null || echo "0")

    [[ "$total_count" -ge "23" ]]
}

validate_complex() {
    local cp_expected=$1
    local worker_expected=$2
    local result_file=$3

    # Check stacked nodes (CP + Worker on same Proxmox node)
    local cp_count=$(grep -c "talos-cp-" "$result_file" 2>/dev/null || echo "0")
    local worker_count=$(grep -c "talos-worker-" "$result_file" 2>/dev/null || echo "0")

    # Check for pve2 having both CP and Worker
    local pve2_resources=$(grep -A5 "pve2" "$result_file" | grep -c "talos-" || echo "0")

    [[ "$cp_count" -eq "$cp_expected" && "$worker_count" -eq "$worker_expected" && "$pve2_resources" -gt "1" ]]
}

validate_rejected() {
    local cp_expected=$1
    local worker_expected=$2
    local result_file=$3

    # This should FAIL or be rejected
    # If we get here with VMs created, that's a failure
    local vm_count=$(grep -c "proxmox_virtual_environment_vm" "$result_file" 2>/dev/null || echo "0")

    [[ "$vm_count" -eq "0" ]]
}

run_single_test() {
    local test_def="$1"
    IFS=':' read -r filename description test_func <<< "$test_def"

    local test_file="$TEST_DIR/${filename}.tfvars"
    local result_file="$RESULTS_DIR/${filename}_${TIMESTAMP}.log"

    log_header "TEST: $description"

    # Check test file exists
    if [[ ! -f "$test_file" ]]; then
        log_skip "Test file not found: $test_file"
        ((SKIPPED++))
        return 0
    fi

    # Parse expected counts
    read cp_expected worker_expected <<< $(parse_test_file "$test_file")
    log_info "Expected: $cp_expected CPs, $worker_expected Workers"

    # Copy test config
    log_info "Applying configuration: $filename.tfvars"
    cp "$test_file" "$PROJECT_DIR/terraform.tfvars"

    # Destroy previous and deploy new
    log_info "Destroying previous infrastructure..."
    if ! bash "$PROJECT_DIR/cluster.sh" destroy -fa >> "$result_file" 2>&1; then
        log_warning "Destroy had issues (may be expected for first run)"
    fi

    log_info "Deploying new infrastructure..."
    if ! bash "$PROJECT_DIR/cluster.sh" deploy -a >> "$result_file" 2>&1; then
        # Special case: test 09 should fail
        if [[ "$filename" == "09_quorum_loss_risk"* ]]; then
            log_success "Correctly rejected invalid configuration"
            ((PASSED++))
            return 0
        fi
        log_error "Deployment failed - check $result_file"
        ((FAILED++))
        return 1
    fi

    # Capture terraform state
    terraform show > "$RESULTS_DIR/${filename}_${TIMESTAMP}_state.txt" 2>/dev/null || true

    # Validate results
    log_info "Validating results..."
    if $test_func "$cp_expected" "$worker_expected" "$RESULTS_DIR/${filename}_${TIMESTAMP}_state.txt"; then
        log_success "Validation passed"
        ((PASSED++))
    else
        log_error "Validation failed"
        ((FAILED++))
    fi

    # Optional: pause between tests
    if [[ "${PAUSE_BETWEEN_TESTS:-false}" == "true" ]]; then
        read -p "Press Enter to continue to next test..."
    fi
}

run_all_tests() {
    log_header "TALOS CLUSTER SCALING TESTS"
    log_info "Results directory: $RESULTS_DIR"
    log_info "Timestamp: $TIMESTAMP"

    for test_def in "${TESTS[@]}"; do
        run_single_test "$test_def" || true  # Continue on failure
    done

    # Summary
    log_header "TEST SUMMARY"
    echo -e "  ${GREEN}Passed:${NC}  $PASSED"
    echo -e "  ${RED}Failed:${NC}  $FAILED"
    echo -e "  ${YELLOW}Skipped:${NC} $SKIPPED"
    echo ""
    echo -e "Results saved to: ${CYAN}$RESULTS_DIR${NC}"

    # Return exit code
    [[ "$FAILED" -eq "0" ]]
}

# Main
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-all}" in
    all)
        run_all_tests
        ;;
    list)
        echo "Available tests:"
        for test_def in "${TESTS[@]}"; do
            IFS=':' read -r filename description _ <<< "$test_def"
            echo "  ${filename%.tfvars} - $description"
        done
        ;;
    [0-9]*)
        # Run specific test by number
        test_num="$1"
        for test_def in "${TESTS[@]}"; do
            if [[ "$test_def" == "$test_num"* ]]; then
                run_single_test "$test_def"
                break
            fi
        done
        ;;
    *)
        echo "Usage: $0 [all|list|<test_number>]"
        echo "Examples:"
        echo "  $0 all          # Run all tests"
        echo "  $0 list         # List available tests"
        echo "  $0 01           # Run test 01 only"
        exit 1
        ;;
esac