
# Talos Bootstrap Migration Guide: Bash → Go

**Version**: 1.0  
**Date**: 2026-03-01  
**Source**: bootstrap.sh v3.23.0 → Go Implementation  

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Architecture Comparison](#architecture-comparison)
3. [Migration Roadmap](#migration-roadmap)
4. [Implementation Prompts](#implementation-prompts)
5. [Risk Assessment](#risk-assessment)
6. [Testing Strategy](#testing-strategy)
7. [Appendix: File Mapping](#appendix-file-mapping)

---

## Executive Summary

### Current State
- **bootstrap.sh**: ~2,500 lines of Bash with sophisticated IP rediscovery, retry logic, and state management
- **Go Implementation**: ~800 lines across 5 files with strong foundations but critical gaps

### Goal
Achieve feature parity with bash script while gaining:
- Type safety and compile-time checking
- Better testability and mocking
- Structured logging with Zap
- Native gRPC Talos API (no talosctl binary dependency)
- Concurrent operations with proper synchronization

### Timeline
**4 weeks** for complete migration with testing and rollout.

---

## Architecture Comparison

### State Management

| Aspect | Bash | Go | Status |
|--------|------|-----|--------|
| Desired State | Associative arrays `DESIRED_CP_VMIDS` | `map[VMID]*NodeSpec` | ✅ Ready |
| Deployed State | JSON + associative arrays | `ClusterState` struct | ✅ Ready |
| Live Discovery | `LIVE_NODE_IPS` array | `map[VMID]*LiveNode` | ⚠️ Partial |
| MAC Tracking | `MAC_BY_VMID` array | `LiveNode.MAC` field | ⚠️ Needs work |

### Key Algorithms

| Function | Bash Lines | Go Location | Gap Analysis |
|----------|-----------|-------------|--------------|
| IP Discovery | 400+ (lines 1610-2010) | `scanner.go` | Missing state machine |
| Config Apply | 150+ (lines 1850-2000) | `client.go` | Missing retry logic |
| Reconcile Plan | 200+ (lines 1100-1300) | `manager.go` | ✅ Complete |
| HAProxy Update | 130+ (lines 2150-2280) | Not implemented | ❌ Missing |
| Control Plane Removal | 200+ (lines 1380-1580) | `main.go` | ⚠️ Partial |

---

## Migration Roadmap

### Phase 1: Foundation (Week 1) — CRITICAL
**Focus**: IP discovery and retry logic (blocking issues)

**Deliverables**:
1. ✅ Complete IP rediscovery state machine
2. ✅ Add retry logic with exponential backoff
3. ✅ Implement aggressive ARP repopulation
4. ✅ Add pre-flight checks

**Success Criteria**:
- Can bootstrap a single control plane successfully
- Handles IP changes during reboot
- Retries on transient failures

---

### Phase 2: Core Operations (Week 2)
**Focus**: Bootstrap and removal operations

**Deliverables**:
1. ✅ Implement bootstrap detection and execution
2. ✅ Add etcd quorum protection
3. ✅ Create HAProxy configuration manager
4. ✅ Port graceful node removal

**Success Criteria**:
- Full cluster bootstrap works end-to-end
- Safe control plane removal with quorum checks
- HAProxy updated automatically

---

### Phase 3: Advanced Features (Week 3)
**Focus**: Dry-run, drift detection, logging

**Deliverables**:
1. ✅ Implement dry-run and plan modes
2. ✅ Add configuration drift detection
3. ✅ Port hierarchical logging system
4. ✅ Add comprehensive error handling

**Success Criteria**:
- --plan shows accurate diff
- --dry-run simulates without side effects
- Logging matches bash format

---

### Phase 4: Migration & Rollout (Week 4)
**Focus**: Testing, migration tools, documentation

**Deliverables**:
1. ✅ Create state migration tool
2. ✅ Integration test suite
3. ✅ Performance comparison
4. ✅ Rollback procedures

**Success Criteria**:
- Existing clusters migrate successfully
- All tests pass
- Performance matches or exceeds bash

---

## Implementation Prompts

### Prompt 1: IP Discovery State Machine [CRITICAL]

**File**: `pkg/discovery/scanner.go`  
**Priority**: P0 (Blocking)  
**Estimate**: 2 days

**Context**: The bash `wait_for_node_with_rediscovery()` function (lines 1610-1810) implements a sophisticated state machine that tracks nodes through reboots. This is the most critical gap—without it, nodes get "lost" after reboot when their IP changes.

**Implementation Requirements**:

```go
// Add to scanner.go

type MonitorState string

const (
    StateMonitoring  MonitorState = "monitoring"
    StateRebooting   MonitorState = "rebooting"  
    StateVerifying   MonitorState = "verifying"
)

type NodeMonitor struct {
    VMID           types.VMID
    InitialIP      net.IP
    CurrentIP      net.IP
    MAC            string
    State          MonitorState
    StateChangedAt time.Time
    LastARPRepop   time.Time
    RebootExpected bool
    Role           types.Role
}

// MonitorNodeReboot tracks a node through reboot and returns final IP
func (s *Scanner) MonitorNodeReboot(
    ctx context.Context,
    monitor *NodeMonitor,
    maxWait time.Duration,
) (net.IP, error) {
    // Implementation matching bash logic:
    // 1. StateMonitoring: Ping InitialIP every 2s
    //    - If ping fails → transition to StateRebooting
    // 2. StateRebooting: 
    //    - Trigger ARP repop every 5s
    //    - Scan for MAC→IP mapping changes
    //    - If new IP found → transition to StateVerifying
    // 3. StateVerifying:
    //    - Test port 50000
    //    - Verify Talos API ready
    //    - Return IP when confirmed
    // 
    // Must handle:
    // - IP staying same after reboot
    // - IP changing after reboot  
    // - Timeout handling
    // - Context cancellation
}

// RepopulateARPAggressive runs parallel ARP repop across all nodes
func (s *Scanner) RepopulateARPAggressive(ctx context.Context, subnet string) error {
    // Parallel SSH to all Proxmox nodes:
    // 1. ip -s -s neigh flush all
    // 2. seq 1 254 | xargs -P 100 -I{} ping -c 1 -W 1 ${subnet}.{}
    // 3. Wait 1 second
    // Use errgroup for concurrency control
}
```

**Acceptance Criteria**:
- [ ] Successfully tracks node through reboot with IP change
- [ ] ARP repopulation happens every 5s during reboot window
- [ ] Returns correct IP within 120s timeout
- [ ] Unit tests with mocked SSH (95% coverage)
- [ ] Integration test with actual VM reboot

**Reference**: bootstrap.sh lines 1610-1810

---

### Prompt 2: Config Application with Retry [CRITICAL]

**File**: `pkg/talos/client.go`  
**Priority**: P0 (Blocking)  
**Estimate**: 2 days

**Context**: Bash `apply_config_with_rediscovery()` (lines 1850-1950) has 5-attempt retry with IP rediscovery between attempts. The current Go `ApplyConfig` does single attempt.

**Implementation Requirements**:

```go
// ApplyConfigWithRediscovery applies config with full retry logic
func (c *Client) ApplyConfigWithRediscovery(
    ctx context.Context,
    vmid types.VMID,
    initialIP net.IP,
    configPath string,
    role types.Role,
    scanner *discovery.Scanner,
) (newIP net.IP, rebootTriggered bool, err error) {
    const maxAttempts = 5

    for attempt := 1; attempt <= maxAttempts; attempt++ {
        currentIP := initialIP

        // On attempts 2+, rediscover IP
        if attempt > 1 {
            freshIP, err := scanner.RediscoverIP(ctx, vmid, mac)
            if err == nil && !freshIP.Equal(currentIP) {
                c.logger.Info("IP changed during retry",
                    zap.String("old", currentIP.String()),
                    zap.String("new", freshIP.String()),
                )
                currentIP = freshIP
            }
        }

        // Attempt apply
        err := c.applyConfigInternal(ctx, currentIP, configPath, true)
        if err == nil {
            return currentIP, true, nil // reboot expected
        }

        // Analyze error
        errStr := err.Error()
        switch {
        case strings.Contains(errStr, "connection refused"):
            // Talos still booting, wait and retry
            time.Sleep(5 * time.Second)
            continue

        case strings.Contains(errStr, "already configured"):
            // Check if actually ready
            if c.checkReady(ctx, currentIP) {
                return currentIP, false, nil // no reboot
            }
            // Partial config, try recovery
            if err := c.attemptRecovery(ctx, currentIP, configPath, role); err == nil {
                return currentIP, false, nil
            }

        case strings.Contains(errStr, "certificate required"):
            // Try secure mode
            err = c.applyConfigInternal(ctx, currentIP, configPath, false)
            if err == nil {
                return currentIP, false, nil
            }
        }

        // Wait before retry
        if attempt < maxAttempts {
            time.Sleep(5 * time.Second)
        }
    }

    return nil, false, fmt.Errorf("failed after %d attempts: %w", maxAttempts, err)
}

// attemptRecovery handles partially configured nodes
func (c *Client) attemptRecovery(ctx, ip net.IP, configPath string, role types.Role) error {
    // Try insecure reapply
    // If that fails, try reset + reapply
}
```

**Acceptance Criteria**:
- [ ] Retries 5 times with IP rediscovery
- [ ] Handles "connection refused" (Talos booting)
- [ ] Handles "already configured" (maintenance mode)
- [ ] Handles "certificate required" (secure mode)
- [ ] Returns actual IP after reboot (may change)
- [ ] Distinguishes reboot vs no-reboot scenarios

**Reference**: bootstrap.sh lines 1850-1950

---

### Prompt 3: HAProxy Configuration Manager

**File**: `pkg/haproxy/manager.go` (new package)  
**Priority**: P1 (High)  
**Estimate**: 2 days

**Context**: Bash `update_haproxy()` (lines 2150-2280) generates full haproxy.cfg and updates HAProxy server. Go has no HAProxy support—this breaks control plane endpoint.

**Implementation Requirements**:

```go
package haproxy

type Manager struct {
    cfg       *types.Config
    sshConfig *ssh.ClientConfig
}

// GenerateConfig creates haproxy.cfg content
func (m *Manager) GenerateConfig(controlPlanes []types.NodeState) string {
    // Template matching bash output exactly:
    // - global section (maxconn, nbthread, cpu-map)
    // - defaults section (timeouts, mode tcp)
    // - stats page (port 9000)
    // - frontend k8s-apiserver (bind :6443)
    // - backend k8s-controlplane (leastconn, VMID-based names)
    // - frontend talos-apiserver (bind :50000)
    // - backend talos-controlplane

    // Server naming: talos-cp-${vmid}
    // Format: server talos-cp-201 192.168.1.201:6443 check
}

// UpdateConfig deploys config to HAProxy server
func (m *Manager) UpdateConfig(ctx context.Context, config string) error {
    // 1. SSH to HAPROXY_IP
    // 2. Backup existing: cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.backup.${timestamp}
    // 3. Write new config to /tmp/haproxy.cfg.new
    // 4. Validate: haproxy -c -f /tmp/haproxy.cfg.new
    // 5. If valid: mv /tmp/haproxy.cfg.new /etc/haproxy/haproxy.cfg
    // 6. Reload: systemctl reload haproxy
    // 7. If any step fails, restore backup
}
```

**Acceptance Criteria**:
- [ ] Generates config matching bash output exactly
- [ ] Uses VMID for server names (not IP octets)
- [ ] Validates config before applying
- [ ] Creates timestamped backups
- [ ] Rolls back on validation failure
- [ ] Skips if dry-run

**Reference**: bootstrap.sh lines 2150-2280

---

### Prompt 4: Control Plane Removal with Quorum

**File**: `pkg/talos/client.go`, `main.go`  
**Priority**: P1 (High)  
**Estimate**: 2 days

**Context**: Bash `remove_control_plane()` (lines 1380-1580) has sophisticated etcd quorum protection and graceful removal. Go has basic placeholder.

**Implementation Requirements**:

```go
// In main.go executePlan()

// Remove control planes (with quorum check)
if len(plan.RemoveControlPlanes) > 0 {
    // 1. Check etcd quorum before any removal
    if err := checkEtcdQuorum(ctx, talosClient, deployed, plan.RemoveControlPlanes); err != nil {
        return fmt.Errorf("quorum check failed: %w", err)
    }

    for _, vmid := range plan.RemoveControlPlanes {
        if cfg.DryRun {
            logger.Info("would remove control plane", zap.Int("vmid", int(vmid)))
            continue
        }

        // Interactive confirmation
        if !cfg.AutoApprove {
            // Prompt user
        }

        // Find node info
        var nodeIP net.IP
        var memberID string
        for _, cp := range deployed.ControlPlanes {
            if cp.VMID == vmid {
                nodeIP = cp.IP
                // Get memberID from etcd members list
                members, _ := talosClient.GetEtcdMembers(ctx, survivingCP.IP)
                memberID = findMemberID(members, nodeIP)
                break
            }
        }

        // Graceful removal sequence:
        // 1. Cordon: kubectl cordon <node>
        // 2. Drain: kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
        // 3. Remove etcd member: talosctl etcd remove-member <id>
        // 4. Reset Talos: talosctl reset --graceful=false
        // 5. Delete node: kubectl delete node <node>
        // 6. Update state

        if err := removeControlPlane(ctx, talosClient, k8sClient, vmid, nodeIP, memberID); err != nil {
            return fmt.Errorf("remove CP %d: %w", vmid, err)
        }

        stateMgr.RemoveNodeState(deployed, vmid, types.RoleControlPlane)
    }
}

func checkEtcdQuorum(ctx context.Context, client *talos.Client, deployed *types.ClusterState, toRemove []types.VMID) error {
    // Get current members
    members, err := client.GetEtcdMembers(ctx, deployed.ControlPlanes[0].IP)
    if err != nil {
        return fmt.Errorf("get etcd members: %w", err)
    }

    currentMembers := len(members)
    removing := len(toRemove)
    afterRemoval := currentMembers - removing
    quorum := (currentMembers / 2) + 1

    if afterRemoval < quorum {
        return fmt.Errorf(
            "cannot remove %d control planes: would violate etcd quorum (current=%d, after=%d, quorum=%d)",
            removing, currentMembers, afterRemoval, quorum,
        )
    }

    if afterRemoval < 1 {
        return fmt.Errorf("cannot remove: would leave cluster with no etcd members")
    }

    return nil
}
```

**Acceptance Criteria**:
- [ ] Calculates quorum correctly: (n/2)+1
- [ ] Prevents removal if would break quorum
- [ ] Gracefully drains workloads (cordon + drain)
- [ ] Removes from etcd, Talos, and Kubernetes
- [ ] Interactive confirmation unless auto-approved
- [ ] Updates state file after removal

**Reference**: bootstrap.sh lines 1380-1580

---

### Prompt 5: Hierarchical Logging System

**File**: `pkg/logger/hierarchical.go` (new package)  
**Priority**: P2 (Medium)  
**Estimate**: 1 day

**Context**: Bash has custom 5-level hierarchy (PLAN/STAGE/JOB/STEP/DETAIL) with colors. Go uses basic Zap.

**Implementation Requirements**:

```go
package logger

import (
    "fmt"
    "time"
    "github.com/fatih/color"
    "go.uber.org/zap"
)

type Hierarchy string

const (
    HierarchyPlan   Hierarchy = "PLAN"
    HierarchyStage  Hierarchy = "STAGE"
    HierarchyJob    Hierarchy = "JOB"
    HierarchyStep   Hierarchy = "STEP"
    HierarchyDetail Hierarchy = "DETAIL"
)

var hierarchyColors = map[Hierarchy]*color.Color{
    HierarchyPlan:   color.New(color.FgMagenta, color.Bold),
    HierarchyStage:  color.New(color.FgBlue, color.Bold),
    HierarchyJob:    color.New(color.FgCyan, color.Bold),
    HierarchyStep:   color.New(color.FgGreen),
    HierarchyDetail: color.New(color.FgWhite),
}

type HierarchicalLogger struct {
    base      *zap.Logger
    depth     int // Max hierarchy to show (LOG_DEPTH equivalent)
    level     zap.AtomicLevel
    useColors bool
}

func NewHierarchicalLogger(level string, depth int) *HierarchicalLogger {
    // Setup with Zap but custom formatting
}

// Log method with hierarchy and severity
func (l *HierarchicalLogger) Log(h Hierarchy, severity string, msg string, fields ...zap.Field) {
    // Check depth
    if l.hierarchyLevel(h) > l.depth {
        return
    }

    // Format: [HH:MM:SS] [INFO ] [STEP  ] message
    timestamp := time.Now().Format("15:04:05")
    severityPadded := fmt.Sprintf("%-5s", severity)
    hierarchyPadded := fmt.Sprintf("%-6s", h)

    // Apply colors
    if l.useColors {
        severityColored := severityColor(severity).Sprint(severityPadded)
        hierarchyColored := hierarchyColors[h].Sprint(hierarchyPadded)
        fmt.Printf("[%s] [%s] [%s] %s\n", timestamp, severityColored, hierarchyColored, msg)
    }

    // Also log to Zap for structured output
    l.base.Log(zapLevel(severity), msg, fields...)
}

// Convenience methods
func (l *HierarchicalLogger) PlanInfo(msg string, fields ...zap.Field) {
    l.Log(HierarchyPlan, "INFO", msg, fields...)
}
func (l *HierarchicalLogger) StageError(msg string, fields ...zap.Field) {
    l.Log(HierarchyStage, "ERROR", msg, fields...)
}
// ... etc for all combinations

// Box drawing for plan display
func (l *HierarchicalLogger) PrintBoxHeader(title string) {
    // ┌─────────────────────────────────────────────────────────────┐
    // │                    RECONCILIATION PLAN                      │
    // ├─────────────────────────────────────────────────────────────┤
}

func (l *HierarchicalLogger) PrintBoxPair(key, value string) {
    // │  Cluster: prod-cluster                                      │
}

func (l *HierarchicalLogger) PrintBoxFooter() {
    // └─────────────────────────────────────────────────────────────┘
}
```

**Acceptance Criteria**:
- [ ] Output format matches bash exactly
- [ ] Respects LOG_DEPTH (0=PLAN only, 4=DETAIL)
- [ ] Colors match: PLAN=magenta, STAGE=blue, JOB=cyan, STEP=green, DETAIL=white
- [ ] Severity colors: FATAL=red bg, ERROR=red, WARN=yellow, INFO=white, DEBUG=blue, TRACE=gray
- [ ] Box drawing for reconciliation plan
- [ ] Both console (colored) and structured (Zap) output

**Reference**: bootstrap.sh lines 180-400

---

### Prompt 6: Dry-Run and Plan Modes

**File**: `main.go`, `pkg/talos/client.go`  
**Priority**: P2 (Medium)  
**Estimate**: 1 day

**Context**: Bash has `--dry-run` and `--plan` flags. Go has flags but no implementation.

**Implementation Requirements**:

```go
// In main.go

func runReconcile(ctx context.Context, cfg *types.Config) error {
    // ... existing code ...

    displayPlan(plan, logger)

    if cfg.PlanMode {
        logger.PlanInfo("plan mode - exiting without changes")
        return nil
    }

    if plan.IsEmpty() {
        logger.PlanInfo("no changes required")
        return nil
    }

    // Confirm if not auto-approved
    if !cfg.AutoApprove && !cfg.DryRun {
        fmt.Print("\nProceed with changes? [y/N]: ")
        // ...
    }

    // Execute with dry-run awareness
    if err := executePlan(ctx, plan, desired, deployed, stateMgr, scanner, talosClient, cfg.DryRun); err != nil {
        return err
    }
}

func executePlan(ctx, ..., dryRun bool) error {
    if plan.NeedsBootstrap {
        if dryRun {
            logger.Info("would bootstrap cluster")
        } else {
            // actual bootstrap
        }
    }

    // All operations check dryRun flag
    for _, vmid := range plan.AddControlPlanes {
        if dryRun {
            logger.Info("would add control plane", zap.Int("vmid", int(vmid)))
            continue
        }
        // actual implementation
    }
}

func displayPlan(plan *types.ReconcilePlan, logger *logger.HierarchicalLogger) {
    logger.PrintBoxHeader("RECONCILIATION PLAN")

    if plan.NeedsBootstrap {
        logger.PrintBoxBadge("BOOTSTRAP", "Cluster needs bootstrap")
    }

    if len(plan.AddControlPlanes) > 0 {
        logger.PrintBoxSection("ADD CONTROL PLANES")
        for _, vmid := range plan.AddControlPlanes {
            logger.PrintBoxItem("", fmt.Sprintf("VMID %d", vmid))
        }
    }

    // ... sections for workers, removals, updates

    logger.PrintBoxFooter()
}
```

**Acceptance Criteria**:
- [ ] --plan shows full plan with box format, exits 0
- [ ] --dry-run logs "would X" for all operations
- [ ] State file not modified in dry-run
- [ ] No SSH/Talos operations in dry-run
- [ ] HAProxy not updated in dry-run
- [ ] Diff display shows hash changes

**Reference**: bootstrap.sh lines 120-140, 1300-1350

---

### Prompt 7: State Migration Tool

**File**: `cmd/migrate/main.go` (new command)  
**Priority**: P2 (Medium)  
**Estimate**: 1 day

**Context**: Need to migrate existing bash-generated state to Go format.

**Implementation Requirements**:

```go
package main

import (
    "encoding/json"
    "fmt"
    "os"
    "path/filepath"
    "time"
)

func main() {
    clusterName := os.Getenv("CLUSTER_NAME")
    if clusterName == "" {
        clusterName = "cluster"
    }

    stateDir := filepath.Join("clusters", clusterName, "state")
    stateFile := filepath.Join(stateDir, "bootstrap-state.json")

    // Read existing state
    data, err := os.ReadFile(stateFile)
    if err != nil {
        fmt.Fprintf(os.Stderr, "Failed to read state: %v\n", err)
        os.Exit(1)
    }

    // Backup
    backupFile := fmt.Sprintf("%s.backup.%s", stateFile, time.Now().Format("20060102_150405"))
    if err := os.WriteFile(backupFile, data, 0600); err != nil {
        fmt.Fprintf(os.Stderr, "Failed to create backup: %v\n", err)
        os.Exit(1)
    }
    fmt.Printf("Created backup: %s\n", backupFile)

    // Parse and validate
    var state map[string]interface{}
    if err := json.Unmarshal(data, &state); err != nil {
        fmt.Fprintf(os.Stderr, "Invalid JSON: %v\n", err)
        os.Exit(1)
    }

    // Validate required fields
    required := []string{"timestamp", "cluster_name", "deployed_state"}
    for _, field := range required {
        if _, ok := state[field]; !ok {
            fmt.Fprintf(os.Stderr, "Missing required field: %s\n", field)
            os.Exit(1)
        }
    }

    // Add version marker for future migrations
    state["_version"] = "2.0"
    state["_migrated_at"] = time.Now().Format(time.RFC3339)
    state["_migrated_from"] = "bootstrap.sh"

    // Write back
    newData, err := json.MarshalIndent(state, "", "  ")
    if err != nil {
        fmt.Fprintf(os.Stderr, "Failed to marshal: %v\n", err)
        os.Exit(1)
    }

    tempFile := stateFile + ".tmp"
    if err := os.WriteFile(tempFile, newData, 0600); err != nil {
        fmt.Fprintf(os.Stderr, "Failed to write: %v\n", err)
        os.Exit(1)
    }

    if err := os.Rename(tempFile, stateFile); err != nil {
        fmt.Fprintf(os.Stderr, "Failed to rename: %v\n", err)
        os.Exit(1)
    }

    fmt.Printf("Successfully migrated state for cluster: %s\n", clusterName)
}
```

**Acceptance Criteria**:
- [ ] Reads bash-generated state successfully
- [ ] Creates timestamped backup
- [ ] Validates all required fields present
- [ ] Adds version metadata
- [ ] Atomic write (temp + rename)
- [ ] Rollback script included

---

### Prompt 8: Configuration Drift Detection

**File**: `pkg/state/manager.go`  
**Priority**: P2 (Medium)  
**Estimate**: 1 day

**Context**: Bash computes SHA256 hashes to detect config drift. Go has `ComputeTerraformHash` but not fully integrated.

**Implementation Requirements**:

```go
// In manager.go

// ComputeConfigHash calculates SHA256 of a config file
func (m *Manager) ComputeConfigHash(configPath string) (string, error) {
    data, err := os.ReadFile(configPath)
    if err != nil {
        return "", err
    }
    hash := sha256.Sum256(data)
    return hex.EncodeToString(hash[:]), nil
}

// Update BuildReconcilePlan to check drift
func (m *Manager) BuildReconcilePlan(...) (*types.ReconcilePlan, error) {
    // ... existing logic ...

    // Check for config drift
    for vmid, spec := range desired {
        configFile := m.NodeConfigPath(vmid, spec.Role)
        currentHash, err := m.ComputeConfigHash(configFile)
        if err != nil {
            // Config doesn't exist, needs generation
            plan.UpdateConfigs = append(plan.UpdateConfigs, vmid)
            continue
        }

        var deployedHash string
        switch spec.Role {
        case types.RoleControlPlane:
            for _, cp := range deployed.ControlPlanes {
                if cp.VMID == vmid {
                    deployedHash = cp.ConfigHash
                    break
                }
            }
        case types.RoleWorker:
            for _, w := range deployed.Workers {
                if w.VMID == vmid {
                    deployedHash = w.ConfigHash
                    break
                }
            }
        }

        if currentHash != deployedHash || m.config.ForceReconfigure {
            plan.UpdateConfigs = append(plan.UpdateConfigs, vmid)
            logger.Debug("config drift detected",
                zap.Int("vmid", int(vmid)),
                zap.String("old", deployedHash[:16]),
                zap.String("new", currentHash[:16]),
            )
        } else {
            plan.NoOp = append(plan.NoOp, vmid)
        }
    }

    // Check if terraform changed
    if deployed.TerraformHash != m.config.TerraformHash {
        logger.Info("terraform configuration changed",
            zap.String("old", deployed.TerraformHash[:16]),
            zap.String("new", m.config.TerraformHash[:16]),
        )
    }

    return plan, nil
}

// UpdateNodeState updates hash after successful apply
func (m *Manager) UpdateNodeState(state *types.ClusterState, vmid types.VMID, ip string, hash string, role types.Role) {
    // ... existing logic ...
    nodeState.ConfigHash = hash
    // ...
}
```

**Acceptance Criteria**:
- [ ] Detects when node config changes (hash mismatch)
- [ ] Detects when terraform.tfvars changes
- [ ] Respects ForceReconfigure flag
- [ ] Shows hash diff in plan output (first 16 chars)
- [ ] Updates hash after successful apply
- [ ] NoOp for unchanged configs

**Reference**: bootstrap.sh lines 1100-1200

---

### Prompt 9: Bootstrap Detection and Execution

**File**: `pkg/talos/client.go`, `main.go`  
**Priority**: P1 (High)  
**Estimate**: 2 days

**Context**: Bash has sophisticated bootstrap logic with etcd health verification. Go has placeholder.

**Implementation Requirements**:

```go
// In client.go

// IsBootstrapped checks if etcd is already initialized
func (c *Client) IsBootstrapped(ctx context.Context, ip net.IP) (bool, error) {
    members, err := c.GetEtcdMembers(ctx, ip)
    if err != nil {
        return false, err
    }
    return len(members) > 0, nil
}

// BootstrapEtcd with retry logic
func (c *Client) BootstrapEtcd(ctx context.Context, ip net.IP) error {
    const maxAttempts = 3

    for attempt := 1; attempt <= maxAttempts; attempt++ {
        // Check if already bootstrapped
        bootstrapped, err := c.IsBootstrapped(ctx, ip)
        if err == nil && bootstrapped {
            return nil // Already done
        }

        // Attempt bootstrap
        tc, err := c.getClient(ctx, ip, false)
        if err != nil {
            time.Sleep(10 * time.Second)
            continue
        }
        defer tc.Close()

        err = tc.Bootstrap(ctx, &machine.BootstrapRequest{})
        if err == nil {
            // Verify etcd healthy
            if err := c.waitForEtcdHealthy(ctx, ip, 30); err == nil {
                return nil
            }
        }

        // Check for "already bootstrapped" error
        if strings.Contains(err.Error(), "already bootstrapped") {
            return nil
        }

        if attempt < maxAttempts {
            time.Sleep(10 * time.Second)
        }
    }

    return fmt.Errorf("failed to bootstrap after %d attempts", maxAttempts)
}

func (c *Client) waitForEtcdHealthy(ctx context.Context, ip net.IP, maxAttempts int) error {
    for i := 0; i < maxAttempts; i++ {
        members, err := c.GetEtcdMembers(ctx, ip)
        if err == nil && len(members) > 0 {
            return nil
        }
        time.Sleep(5 * time.Second)
    }
    return fmt.Errorf("etcd not healthy after %d attempts", maxAttempts)
}

// In main.go executePlan()

if plan.NeedsBootstrap {
    // Find first control plane
    var firstCP *types.NodeSpec
    var firstVMID types.VMID

    if deployed.FirstControlPlane != 0 {
        firstVMID = deployed.FirstControlPlane
        firstCP = desired[firstVMID]
    } else {
        // Use first in AddControlPlanes
        firstVMID = plan.AddControlPlanes[0]
        firstCP = desired[firstVMID]
    }

    // Discover IP
    liveNodes, err := scanner.DiscoverVMs(ctx, []types.VMID{firstVMID})
    // ... error handling ...

    node := liveNodes[firstVMID]

    if dryRun {
        logger.Info("would bootstrap", zap.Int("vmid", int(firstVMID)))
    } else {
        // Apply config
        newIP, _, err := talosClient.ApplyConfigWithRediscovery(ctx, firstVMID, node.IP, configPath, types.RoleControlPlane, scanner)
        if err != nil {
            return fmt.Errorf("apply config: %w", err)
        }

        // Bootstrap etcd
        if err := talosClient.BootstrapEtcd(ctx, newIP); err != nil {
            return fmt.Errorf("bootstrap etcd: %w", err)
        }

        // Update state
        hash, _ := stateMgr.ComputeTerraformHash()
        stateMgr.UpdateNodeState(deployed, firstVMID, newIP.String(), hash, types.RoleControlPlane)
        deployed.BootstrapCompleted = true
        deployed.FirstControlPlane = firstVMID
    }
}
```

**Acceptance Criteria**:
- [ ] Detects unbootstrapped clusters (no etcd members)
- [ ] Selects first control plane correctly
- [ ] Applies config with IP rediscovery
- [ ] Bootstraps etcd with retry
- [ ] Verifies etcd healthy before continuing
- [ ] Updates state (BootstrapCompleted=true)
- [ ] Handles already-bootstrapped case

**Reference**: bootstrap.sh lines 2300-2400, 2700-2800

---

### Prompt 10: Pre-flight Checks

**File**: `pkg/preflight/checker.go` (new package)  
**Priority**: P1 (High)  
**Estimate**: 1 day

**Context**: Bash `run_preflight_checks()` (lines 2450-2600) verifies VMs ready before operations.

**Implementation Requirements**:

```go
package preflight

type Checker struct {
    scanner *discovery.Scanner
    logger  *logger.HierarchicalLogger
}

type CheckResult struct {
    VMID      types.VMID
    Name      string
    Ready     bool
    IP        net.IP
    PortOpen  bool
    Error     error
}

func (c *Checker) RunChecks(ctx context.Context, desired map[types.VMID]*types.NodeSpec) ([]CheckResult, error) {
    maxRetries := 30
    retryDelay := 2 * time.Second

    results := make(map[types.VMID]*CheckResult)
    pending := make([]types.VMID, 0, len(desired))

    for vmid := := range desired {
        pending = append(pending, vmid)
    }

    for attempt := 1; attempt <= maxRetries && len(pending) > 0; attempt++ {
        c.logger.StepInfo(fmt.Sprintf("Preflight attempt %d/%d (%d pending)", 
            attempt, maxRetries, len(pending)))

        // Refresh ARP every 5 attempts
        if attempt%5 == 0 {
            c.logger.StepDebug("Refreshing ARP tables...")
            // Trigger ARP repop
        }

        stillPending := make([]types.VMID, 0)

        for _, vmid := range pending {
            spec := desired[vmid]

            // Discover IP
            liveNodes, err := c.scanner.DiscoverVMs(ctx, []types.VMID{vmid})
            if err != nil {
                stillPending = append(stillPending, vmid)
                continue
            }

            node, ok := liveNodes[vmid]
            if !ok {
                stillPending = append(stillPending, vmid)
                continue
            }

            // Test port 50000
            if !discovery.TestPort(node.IP.String(), 50000, 2*time.Second) {
                stillPending = append(stillPending, vmid)
                continue
            }

            // Check Talos version (optional)
            results[vmid] = &CheckResult{
                VMID:     vmid,
                Name:     spec.Name,
                Ready:    true,
                IP:       node.IP,
                PortOpen: true,
            }
        }

        pending = stillPending

        if len(pending) == 0 {
            break
        }

        time.Sleep(retryDelay)
    }

    // Report results
    ready := 0
    for _, r := range results {
        if r.Ready {
            ready++
        }
    }

    c.logger.StepInfo(fmt.Sprintf("Preflight complete: %d/%d ready", ready, len(desired)))

    if len(pending) > 0 {
        c.logger.StepWarn(fmt.Sprintf("%d VMs not ready:", len(pending)))
        for _, vmid := range pending {
            spec := desired[vmid]
            c.logger.StepWarn(fmt.Sprintf("  - VMID %d (%s)", vmid, spec.Name))
        }

        if !cfg.SkipPreflight {
            // Interactive prompt
        }
    }

    return results, nil
}
```

**Acceptance Criteria**:
- [ ] Discovers all desired VMs
- [ ] Tests Talos API port (50000)
- [ ] Retries 30 times with 2s delay
- [ ] Refreshes ARP every 5 attempts
- [ ] Reports ready/pending/failed counts
- [ ] Interactive prompt if failures (unless --skip-preflight)
- [ ] Can skip with --skip-preflight

**Reference**: bootstrap.sh lines 2450-2600

---

## Risk Assessment

### High Risk (Blocking)

| Risk | Impact | Mitigation |
|------|--------|------------|
| IP rediscovery fails | Nodes lost after reboot | Complete Prompt 1 first, extensive testing |
| No retry logic | Transient failures kill operation | Complete Prompt 2, test with network faults |
| No HAProxy support | Control plane unreachable | Complete Prompt 3 before any CP changes |

### Medium Risk

| Risk | Impact | Mitigation |
|------|--------|------------|
| Logging format change | Breaks log parsing | Implement Prompt 5, provide migration guide |
| etcd quorum miscalculation | Cluster damage | Extensive testing of Prompt 4, add safeguards |
| State corruption | Data loss | Prompt 7 backup/restore, atomic writes |

### Low Risk

| Risk | Impact | Mitigation |
|------|--------|------------|
| Performance regression | Slower operations | Benchmark both versions |
| Different error messages | Confusion | Document changes, improve messages |

---

## Testing Strategy

### Unit Tests (per prompt)
- Mock SSH client for discovery
- Mock Talos gRPC client
- Table-driven tests for state machine
- 80%+ coverage for critical paths

### Integration Tests
- Test cluster in Proxmox lab
- Full bootstrap → reconcile → reset cycle
- Network failure injection (iptables drop)
- VM reboot during operations

### Comparison Tests
- Run bash and Go versions side-by-side
- Compare state files, logs, HAProxy config
- Verify identical outcomes

### Rollback Testing
- Migrate state, run Go, rollback to bash
- Verify bash can still manage cluster
- Emergency rollback procedures

---

## Appendix: File Mapping

### Complete Reference

| Bash Function | Go File | Function | Status |
|--------------|---------|----------|--------|
| `wait_for_node_with_rediscovery` | `scanner.go` | `MonitorNodeReboot` | ❌ Missing |
| `rediscover_ip_by_mac` | `scanner.go` | `RediscoverIP` | ⚠️ Partial |
| `arp_repopulate_aggressive` | `scanner.go` | `RepopulateARPAggressive` | ❌ Missing |
| `apply_config_with_rediscovery` | `client.go` | `ApplyConfigWithRediscovery` | ❌ Missing |
| `attempt_recovery_reapply` | `client.go` | `attemptRecovery` | ❌ Missing |
| `bootstrap_etcd_at_ip` | `client.go` | `BootstrapEtcd` | ⚠️ Partial |
| `wait_for_etcd_healthy` | `client.go` | `waitForEtcdHealthy` | ❌ Missing |
| `build_reconcile_plan` | `manager.go` | `BuildReconcilePlan` | ✅ Complete |
| `execute_reconcile_plan` | `main.go` | `executePlan` | ⚠️ Partial |
| `add_control_plane` | `main.go` | `executePlan` (add section) | ⚠️ Partial |
| `remove_control_plane` | `main.go` | `executePlan` (remove section) | ⚠️ Partial |
| `update_haproxy` | `haproxy/manager.go` | `UpdateConfig` | ❌ Missing |
| `generate_node_config` | `client.go` | `GenerateNodeConfig` | ✅ Complete |
| `run_preflight_checks` | `preflight/checker.go` | `RunChecks` | ❌ Missing |
| `discover_live_state` | `scanner.go` | `DiscoverVMs` | ⚠️ Partial |
| `save_state` | `manager.go` | `Save` | ✅ Complete |
| `load_deployed_state` | `manager.go` | `LoadDeployedState` | ✅ Complete |
| `load_desired_state` | `manager.go` | `LoadDesiredState` | ✅ Complete |
| Logging system | `logger/hierarchical.go` | Various | ⚠️ Different |
| `display_reconcile_plan` | `main.go` | `displayPlan` | ⚠️ Partial |

---

## Definition of Done

### For Each Prompt
- [ ] Code implemented and reviewed
- [ ] Unit tests passing (>80% coverage)
- [ ] Integration tests passing
- [ ] Documentation updated
- [ ] Bash comparison test passed

### For Full Migration
- [ ] All P0 prompts complete
- [ ] All P1 prompts complete
- [ ] Full cluster lifecycle tested (bootstrap → scale → shrink → reset)
- [ ] Performance benchmark vs bash
- [ ] Migration guide published
- [ ] Rollback procedures tested
- [ ] Production cluster migrated successfully

---

**End of Migration Guide**
