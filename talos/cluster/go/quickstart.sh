#!/bin/bash
# Quick start script for talos-bootstrap-go

set -e

echo "=== Talos Bootstrap (Go) Quick Start ==="
echo

# Check Go installation
if ! command -v go &> /dev/null; then
    echo "❌ Go is not installed. Please install Go 1.21+ first."
    echo "   https://go.dev/dl/"
    exit 1
fi

GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
echo "✓ Go version: $GO_VERSION"

# Download dependencies
echo
echo "=== Downloading dependencies ==="
go mod tidy

# Build
echo
echo "=== Building ==="
make build

# Test
echo
echo "=== Running tests ==="
make test

# Demo
echo
echo "=== Demo: Status command ==="
./build/talos-bootstrap status || true

echo
echo "=== Setup complete! ==="
echo
echo "Next steps:"
echo "1. Copy your terraform.tfvars to this directory"
echo "2. Run: ./build/talos-bootstrap reconcile --plan"
echo "3. Compare with: ./bootstrap.sh reconcile --plan"
echo
echo "For detailed migration guide, see MIGRATION.md"
