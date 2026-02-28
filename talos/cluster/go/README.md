# Talos Bootstrap (Go Rewrite)

A Go reimplementation of the Talos Kubernetes cluster bootstrap tool, replacing the 4,000-line bash script with type-safe, testable Go code.

## Why Go?

| Feature | Bash (Old) | Go (New) |
|---------|-----------|----------|
| Type Safety | None (string/array bugs) | Compile-time checks |
| Error Handling | `set -e`, `$?` checking | Explicit error returns |
| Concurrency | `&` + `wait` (fragile) | Goroutines, channels |
| Testing | Nearly impossible | Unit + integration tests |
| Talos Integration | Shell out to `talosctl` | Native client libraries |
| Windows Support | Git Bash hacks | Native cross-compile |

## Quick Start

```bash
# Build
cd talos-bootstrap-go
make build

# Run (dry-run to see what would happen)
./build/talos-bootstrap reconcile --plan

# Actually apply changes
./build/talos-bootstrap reconcile --auto-approve

# Check status
./build/talos-bootstrap status
```

## Migration from Bash

### Phase 1: Parallel Operation (Week 1-2)

Run both versions and compare output:

```bash
# Old bash version
./bootstrap.sh reconcile --plan > /tmp/bash-plan.txt

# New Go version
./build/talos-bootstrap reconcile --plan > /tmp/go-plan.txt

# Compare
diff /tmp/bash-plan.txt /tmp/go-plan.txt
```

### Phase 2: Feature Parity (Week 3-4)

Implement missing features:
- [ ] Native Talos API (currently shells out)
- [ ] HAProxy configuration generation
- [ ] etcd quorum checking
- [ ] Full IP rediscovery logic
- [ ] Kubeconfig fetching

### Phase 3: Cutover (Week 5-6)

Once plans match exactly:
1. Rename `bootstrap.sh` to `bootstrap.sh.legacy`
2. Use Go version for new clusters
3. Keep bash as backup for 1 month

## Architecture

```
cmd/
  main.go              # CLI entry point (cobra)
pkg/
  types/
    types.go           # Domain models (VMID, NodeSpec, etc.)
  state/
    manager.go         # Three-way state reconciliation
  discovery/
    scanner.go         # ARP scanning, IP discovery
  talos/
    client.go          # Talos API operations
  haproxy/
    config.go          # HAProxy config generation
```

## Key Improvements

### 1. Type Safety

**Before (Bash):**
```bash
vmid="101"  # Could accidentally be "101 102" or "abc"
```

**After (Go):**
```go
type VMID int
vmid := types.VMID(101)  // Compiler guarantees it's an integer
```

### 2. Error Handling

**Before (Bash):**
```bash
run_command ssh ... || {
  log_error "SSH failed"
  return 1
}
# Easy to forget error checking!
```

**After (Go):**
```go
client, err := ssh.Dial(...)
if err != nil {
    return fmt.Errorf("ssh to %s: %w", nodeName, err)
}
// Must handle err or explicitly ignore with _
```

### 3. Concurrency

**Before (Bash):**
```bash
for node in "${nodes[@]}"; do
  (populate_arp "$node") &
done
wait  # No error handling, no timeout
```

**After (Go):**
```go
g, ctx := errgroup.WithContext(ctx)
for nodeName, nodeIP := range s.nodeIPs {
    g.Go(func() error {
        return s.repopulateNode(ctx, nodeName, nodeIP)
    })
}
if err := g.Wait(); err != nil {
    return err  // First error, others cancelled
}
```

### 4. State Management

**Before (Bash):**
```bash
declare -A DEPLOYED_CP_IPS  # No schema, silent failures on missing keys
declare -A LIVE_NODE_STATUS
# 16 associative arrays to track state
```

**After (Go):**
```go
type ClusterState struct {
    ControlPlanes []NodeState `json:"control_planes"`
    Workers       []NodeState `json:"workers"`
    BootstrapCompleted bool   `json:"bootstrap_completed"`
}
// JSON schema enforced, IDE autocomplete
```

## Configuration

Uses same environment variables as bash version:

```bash
export CLUSTER_NAME="prod-cluster"
export TERRAFORM_TFVARS="./terraform.tfvars"
export CONTROL_PLANE_ENDPOINT="kube.example.com"
export HAPROXY_IP="192.168.1.199"
export KUBERNETES_VERSION="v1.28.0"
export TALOS_VERSION="v1.6.0"
```

Or use flags:

```bash
./build/talos-bootstrap reconcile   --cluster prod-cluster   --tfvars ./terraform.tfvars   --plan
```

## Development

```bash
# Run tests
make test

# Format code
make fmt

# Build for all platforms
make build-all

# Run with debug logging
LOG_LEVEL=debug ./build/talos-bootstrap status
```

## Known Limitations (Current)

1. **Talos Native API**: Currently shells out to `talosctl`. Will use `siderolabs/talos/pkg/machinery` when dependency issues resolved.

2. **HCL Parsing**: Basic HCL parsing implemented. Complex terraform.tfvars with variables may need manual handling.

3. **SSH Authentication**: Currently uses private keys only. SSH agent support coming.

## Roadmap

- [ ] Native Talos API (no shelling out)
- [ ] HAProxy config generation
- [ ] etcd quorum safety checks
- [ ] Full IP rediscovery with context timeouts
- [ ] Kubernetes integration (kubectl)
- [ ] Integration tests with mock Proxmox
- [ ] Web UI for cluster visualization
