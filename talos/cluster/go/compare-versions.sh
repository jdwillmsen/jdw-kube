#!/bin/bash
# Compare bash and Go versions side-by-side

set -e

echo "=== Comparing Bash vs Go Implementations ==="
echo

BASH_BIN="${1:-./bootstrap.sh}"
GO_BIN="${2:-./talos-bootstrap-go/build/talos-bootstrap}"

if [ ! -f "$BASH_BIN" ]; then
    echo "❌ Bash binary not found: $BASH_BIN"
    echo "Usage: $0 [path-to-bootstrap.sh] [path-to-go-binary]"
    exit 1
fi

if [ ! -f "$GO_BIN" ]; then
    echo "❌ Go binary not found: $GO_BIN"
    echo "Run: cd talos-bootstrap-go && make build"
    exit 1
fi

echo "Bash version: $BASH_BIN"
echo "Go version:   $GO_BIN"
echo

# Test 1: Status
echo "=== Test 1: Status ==="
echo "Bash:"
$BASH_BIN status 2>&1 | head -20 || true
echo
echo "Go:"
$GO_BIN status 2>&1 | head -20 || true
echo

# Test 2: Plan
echo "=== Test 2: Reconcile Plan ==="
echo "Bash:"
$BASH_BIN reconcile --plan 2>&1 | tee /tmp/bash-plan.txt || true
echo
echo "Go:"
$GO_BIN reconcile --plan 2>&1 | tee /tmp/go-plan.txt || true
echo

# Compare
echo "=== Diff ==="
if diff -u /tmp/bash-plan.txt /tmp/go-plan.txt > /tmp/plan-diff.txt 2>&1; then
    echo "✓ Plans are identical!"
else
    echo "⚠ Plans differ (this is expected during migration):"
    head -50 /tmp/plan-diff.txt
fi

echo
echo "Full diff saved to: /tmp/plan-diff.txt"
