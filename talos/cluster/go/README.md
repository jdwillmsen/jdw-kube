# Talos Bootstrap

A Go tool for bootstrapping and managing Talos Kubernetes clusters on Proxmox VMs. Performs three-way state reconciliation between desired state (Terraform), deployed state (persisted JSON), and live state (ARP/SSH discovery) to converge the cluster.

## Commands

```bash
# Show current cluster state
talos-bootstrap status

# Plan changes (dry-run)
talos-bootstrap reconcile --plan

# Apply changes with confirmation
talos-bootstrap reconcile

# Apply changes without confirmation
talos-bootstrap reconcile --auto-approve

# Reset cluster state
talos-bootstrap reset
```

## Architecture

```
cmd/
  main.go                 # CLI entry point (Corbra), 9-phase orchestration
  status.go               # Status command
  helpers.go              # Plan display, hosts file, verification
pkg/
  types/                  # Domain models: VMID, NodeSpec, ClusterState, Config
  state/                  # Three-way reconciliation, atomic state persistence
  discovery/              # SSH-based ARP scanning, reboot state machine
  talos/                  # Native Talos machine API: config, bootstrap, etcd
    patches/              # go:embed YAML templates for CP and worker configs
  haproxy/                # HAProxy config generation with validation + rollback
  logging/                # Structured JSON + console logging, audit trail, box UI
```

### Reconciliation Flow

1. **Load desired state** from `terraform.tfvars` (HCL parsing)
2. **Load deployed state** from `bootstrap-state.json` (atomic writes)
3. **Discover live state** via ARP scanning across Proxmox nodes
4. **Build plan**: diff desired vs deployed to determine adds/removes/updates
5. **Execute plan** in 9 phases: generate configs, apply to CPs, bootstrap etcd, configure HAProxy, apply to workers, fetch kubeconfig, verify health

## Configuration

Required settings (via flags, env vars, or `terraform.tfvars`):

| Flag | Env Var | Description |
|------|---------|-------------|
| `--control-plane-endpoint` | `CONTROL_PLANE_ENDPOINT` | Cluster API endpoint hostname |
| `--haproxy-ip` | `HAPROXY_IP` | HAProxy load balancer IP |
| `--kubernetes-version` | `KUBERNETES_VERSION` | Kubernetes version (e.g., v1.32.0) |
| `--talos-version` | `TALOS_VERSION` | Talos version (e.g., v1.9.0) |
| `--installer-image` | `INSTALLER_IMAGE` | Talos installer image reference |

Optional:

| Flag | Env Var | Default | Description                      |
|------|---------|---------|----------------------------------|
| `--cluster` | `CLUSTER_NAME` | `cluster` | Cluster name                     |
| `--tfvars` | `TERRAFORM_TFVARS` | `terraform.tfvars` | Path to tfvars file              |
| `--log-level` | `LOG_LEVEL` | `info` | Log level (debug/info/warn/error) |
| `--no-color` | `NO_COLOR` | `false` | Disable colored output           |
| `--insecure-ssh` | - | `false` | Skip SSH host key verification   |

## Building

```bash
make build         # Build binary to ./build/talos-bootstrap
make test          # Run tests
make test-race     # Run tests with race detector
make vet           # Run go vet
make lint          # Run golangci-lint
make build-all     # Cross-compile for Linux, Windows, macOS
```

## Development

```bash
# Run with debug logging
LOG_LEVEL=debug ./build/talos-bootstrap status

# Clean build artifacts and generated configs
make clean

# Clean old log directories (30+ days)
make clean-logs
```

## CI

GitHub Actions runs on push/PR to `main` when Go soruce changes:
- `go vet`
- `go test -race`
- `golangci-lint`
- `go build`
