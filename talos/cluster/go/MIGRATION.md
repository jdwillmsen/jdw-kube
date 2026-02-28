# Migration Guide: Bash to Go

## Overview

This guide walks you through migrating from the 4,000-line bash script to the Go implementation.

## Pre-Migration Checklist

- [ ] Back up your existing `bootstrap.sh`
- [ ] Ensure `terraform.tfvars` is committed to git
- [ ] Test on non-production cluster first
- [ ] Have rollback plan (keep bash version accessible)

## Phase 1: Side-by-Side Testing (Week 1-2)

### Step 1: Build the Go version

```bash
cd talos-bootstrap-go
go mod tidy
make build
```

### Step 2: Compare plan outputs

Create a test script:

```bash
#!/bin/bash
# compare-plans.sh

echo "=== Bash Plan ===" > /tmp/plan-comparison.txt
./bootstrap.sh reconcile --plan >> /tmp/plan-comparison.txt 2>&1

echo "" >> /tmp/plan-comparison.txt
echo "=== Go Plan ===" >> /tmp/plan-comparison.txt
./talos-bootstrap-go/build/talos-bootstrap reconcile --plan >> /tmp/plan-comparison.txt 2>&1

diff -u <(./bootstrap.sh reconcile --plan 2>&1) <(./talos-bootstrap-go/build/talos-bootstrap reconcile --plan 2>&1)
```

### Step 3: Test individual commands

| Command | Bash | Go | Status |
|---------|------|-----|--------|
| `status` | `./bootstrap.sh status` | `./build/talos-bootstrap status` | |
| `reconcile --plan` | `./bootstrap.sh reconcile --plan` | `./build/talos-bootstrap reconcile --plan` | |
| `reconcile -p` | `./bootstrap.sh reconcile -p` | `./build/talos-bootstrap reconcile -p` | |

## Phase 2: Feature Implementation (Week 3-4)

### Priority 1: Critical Path (Must Have)

1. **SSH Key Authentication**
   - File: `pkg/discovery/scanner.go`
   - Add: `SetPrivateKey()` method
   - Test: `ssh -i ~/.ssh/proxmox root@pve1 "echo ok"`

2. **Terraform.tfvars Parsing**
   - File: `pkg/state/manager.go`
   - Current: Basic HCL parsing
   - Need: Handle your specific tfvars format
   - Test: Parse your actual terraform.tfvars

3. **State File Compatibility**
   - File: `pkg/state/manager.go`
   - Ensure Go writes JSON that bash can read (and vice versa)
   - Test: Create state with bash, read with Go

### Priority 2: Core Operations (Should Have)

4. **IP Discovery**
   - File: `pkg/discovery/scanner.go`
   - Implement: `DiscoverVMs()`, `RediscoverIP()`
   - Test: Run against your Proxmox cluster

5. **Config Generation**
   - File: `pkg/talos/client.go`
   - Implement: `GenerateNodeConfig()`
   - Test: Compare generated YAML with bash version

6. **Talos Operations**
   - File: `pkg/talos/client.go`
   - Implement: `ApplyConfig()`, `BootstrapEtcd()`
   - Note: Currently shells out, upgrade to native API later

### Priority 3: Safety Features (Must Have for Production)

7. **etcd Quorum Checking**
   - File: `cmd/main.go` in `executePlan()`
   - Before removing control planes, verify: `after_removal >= (current/2)+1`
   - Test: Try to remove too many CPs, verify blocked

8. **Dry Run Mode**
   - File: `cmd/main.go`
   - Already implemented, verify all operations respect `--dry-run`

## Phase 3: Production Cutover (Week 5-6)

### Gradual Rollout Strategy

```bash
# Week 5: Use Go for new clusters only
export BOOTSTRAP_BINARY="./talos-bootstrap-go/build/talos-bootstrap"

# Week 6: Use Go for existing clusters (with bash backup)
alias talos-bootstrap="./talos-bootstrap-go/build/talos-bootstrap"
alias talos-bootstrap-legacy="./bootstrap.sh"

# Week 7+: Full cutover
mv bootstrap.sh bootstrap.sh.legacy
ln -s talos-bootstrap-go/build/talos-bootstrap bootstrap.sh
```

### Validation Checklist

Before full cutover, verify:

- [ ] Go version produces identical plan to bash (for your cluster)
- [ ] Dry-run mode shows expected changes
- [ ] Can add worker nodes successfully
- [ ] Can remove worker nodes successfully
- [ ] Can add control plane successfully
- [ ] **etcd quorum check prevents unsafe CP removal**
- [ ] IP rediscovery works after node reboot
- [ ] State file is readable by both versions
- [ ] HAProxy config generation works
- [ ] Kubeconfig fetching works
- [ ] Windows build works (if needed)

## Troubleshooting

### Issue: Different plan output

**Symptom:** Bash and Go show different reconciliation plans

**Debug:**
```bash
# Check desired state parsing
./build/talos-bootstrap status  # Shows what Go parsed from tfvars

# Compare with bash debug output
LOG_LEVEL=debug ./bootstrap.sh status 2>&1 | head -50
```

**Fix:** Likely HCL parsing difference. Check `pkg/state/manager.go` `LoadDesiredState()`.

### Issue: SSH connection fails

**Symptom:** "ssh dial: connection refused" or auth failure

**Debug:**
```bash
# Test SSH manually
ssh -i ~/.ssh/your-key root@192.168.1.200 "qm status 201"

# Check key path in Go
./build/talos-bootstrap status --log-level debug 2>&1 | grep -i ssh
```

**Fix:** Ensure `SetPrivateKey()` is called with correct path.

### Issue: State file corruption

**Symptom:** "parse state file (corrupted?)"

**Debug:**
```bash
# Check JSON validity
cat clusters/<name>/state/bootstrap-state.json | jq .

# Compare with bash-generated state
diff <(jq -S . bash-state.json) <(jq -S . go-state.json)
```

**Fix:** Check `types.ClusterState` struct tags match JSON field names.

## Feature Parity Matrix

| Feature | Bash | Go Current | Go Target |
|---------|------|-----------|-----------|
| Parse terraform.tfvars | ✅ Regex | ⚠️ Basic HCL | ✅ Full HCL |
| State management (JSON) | ✅ | ✅ | ✅ |
| IP discovery (ARP) | ✅ | ✅ | ✅ |
| Config generation | ✅ | ✅ | ✅ |
| Apply config | ✅ | ⚠️ Shell out | ✅ Native API |
| Bootstrap etcd | ✅ | ⚠️ Shell out | ✅ Native API |
| etcd quorum check | ✅ | ⚠️ Stub | ✅ Full |
| HAProxy config | ✅ | ❌ | ✅ |
| Kubeconfig fetch | ✅ | ❌ | ✅ |
| Worker drain/remove | ✅ | ❌ | ✅ |
| Control plane remove | ✅ | ❌ | ✅ |
| IP rediscovery | ✅ | ⚠️ Partial | ✅ Full |
| Windows support | ⚠️ Git Bash | ✅ Native | ✅ Native |
| Logging | Custom | Zap | Zap |
| Tests | ❌ | ✅ Basic | ✅ Full |

## Rollback Plan

If issues occur:

```bash
# Immediate rollback
mv bootstrap.sh.legacy bootstrap.sh
./bootstrap.sh reconcile --plan  # Verify bash still works

# Or use alias
alias talos-bootstrap="./bootstrap.sh"
```

## Post-Migration

Once stable:

1. Archive bash version:
   ```bash
   git tag bash-final-version
   mv bootstrap.sh archive/bootstrap-legacy.sh
   ```

2. Update CI/CD to use Go binary

3. Update documentation

4. Celebrate type safety and proper error handling! 🎉
