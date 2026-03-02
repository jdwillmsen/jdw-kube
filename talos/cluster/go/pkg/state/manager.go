package state

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclsimple"
	"github.com/jdw/talos-bootstrap/pkg/types"
)

// Manager handles the three-way state reconciliation
// (Terraform desired → Local deployed → Live reality)
type Manager struct {
	config   *types.Config
	stateDir string
	nodesDir string
}

// NewManager creates a new state manager
func NewManager(cfg *types.Config) *Manager {
	clusterDir := filepath.Join("clusters", cfg.ClusterName)
	return &Manager{
		config:   cfg,
		stateDir: filepath.Join(clusterDir, "state"),
		nodesDir: filepath.Join(clusterDir, "nodes"),
	}
}

// NodeConfigPath returns the path to a node's config file
func (m *Manager) NodeConfigPath(vmid types.VMID, role types.Role) string {
	return filepath.Join(m.nodesDir, fmt.Sprintf("node-%s-%d.yaml", role, vmid))
}

// LoadDesiredState parses terraform.tfvars into NodeSpecs
// This replaces your parse_terraform_array() function with proper HCL parsing
func (m *Manager) LoadDesiredState(ctx context.Context) (map[types.VMID]*types.NodeSpec, error) {
	data, err := os.ReadFile(m.config.TerraformTFVars)
	if err != nil {
		return nil, fmt.Errorf("read terraform.tfvars: %w", err)
	}

	// Parse HCL properly instead of fragile regex
	var tfConfig struct {
		TalosControlConfiguration []struct {
			VMID   int    `hcl:"vmid"`
			Name   string `hcl:"vm_name"`
			Node   string `hcl:"node_name"`
			CPU    int    `hcl:"cpu_cores"`
			Memory int    `hcl:"memory"`
			Disk   int    `hcl:"disk_size"`
		} `hcl:"talos_control_configuration,block"`
		TalosWorkerConfiguration []struct {
			VMID   int    `hcl:"vmid"`
			Name   string `hcl:"vm_name"`
			Node   string `hcl:"node_name"`
			CPU    int    `hcl:"cpu_cores"`
			Memory int    `hcl:"memory"`
			Disk   int    `hcl:"disk_size"`
		} `hcl:"talos_worker_configuration,block"`
	}

	// Use HCL parser
	ctxHCL := &hcl.EvalContext{}
	err = hclsimple.Decode("terraform.tfvars", data, ctxHCL, &tfConfig)
	if err != nil {
		// Fallback: try manual parsing for simple cases
		return m.fallbackParseTerraform(data)
	}

	specs := make(map[types.VMID]*types.NodeSpec)

	// Process control planes
	for _, cfg := range tfConfig.TalosControlConfiguration {
		vmid := types.VMID(cfg.VMID)
		specs[vmid] = &types.NodeSpec{
			VMID:   vmid,
			Name:   cfg.Name,
			Node:   cfg.Node,
			CPU:    cfg.CPU,
			Memory: cfg.Memory,
			Disk:   cfg.Disk,
			Role:   types.RoleControlPlane,
		}
	}

	// Process workers
	for _, cfg := range tfConfig.TalosWorkerConfiguration {
		vmid := types.VMID(cfg.VMID)
		specs[vmid] = &types.NodeSpec{
			VMID:   vmid,
			Name:   cfg.Name,
			Node:   cfg.Node,
			CPU:    cfg.CPU,
			Memory: cfg.Memory,
			Disk:   cfg.Disk,
			Role:   types.RoleWorker,
		}
	}

	return specs, nil
}

// fallbackParseTerraform handles terraform.tfvars parsing when HCL library fails.
// Uses a brace-counting state machine similar to the bash parse_terraform_array
func (m *Manager) fallbackParseTerraform(data []byte) (map[types.VMID]*types.NodeSpec, error) {
	specs := make(map[types.VMID]*types.NodeSpec)

	content := string(data)

	// Parse both configuration arrays
	cpEntries := parseArrayBlocks(content, "talos_control_configuration")
	for _, entry := range cpEntries {
		spec := parseBlockFields(entry, types.RoleControlPlane)
		if spec != nil {
			specs[spec.VMID] = spec
		}
	}

	wEntries := parseArrayBlocks(content, "talos_worker_configuration")
	for _, entry := range wEntries {
		spec := parseBlockFields(entry, types.RoleWorker)
		if spec != nil {
			specs[spec.VMID] = spec
		}
	}

	if len(specs) == 0 {
		return nil, fmt.Errorf("fallback parser found no nodes in terraform.tfvars")
	}

	return specs, nil
}

// parseArrayBlocks extracts individual block strings from a terraform array varaible.
// e.g., talos_control_configuration = [ { ... }, { ... } ]
func parseArrayBlocks(content, varName string) []string {
	var blocks []string

	// Find the variable assignment
	idx := strings.Index(content, varName)
	if idx == -1 {
		return blocks
	}

	// Find the opening bracket
	rest := content[idx:]
	bracketIdx := strings.Index(rest, "[")
	if bracketIdx == -1 {
		return blocks
	}
	rest = rest[bracketIdx+1:]

	// Use brace counting to extract individual blocks
	braceDepth := 0
	blockStart := -1

	for i, ch := range rest {
		switch ch {
		case '{':
			if braceDepth == 0 {
				blockStart = i
			}
			braceDepth++
		case '}':
			braceDepth--
			if braceDepth == 0 && blockStart >= 0 {
				blocks = append(blocks, rest[blockStart:i+1])
				blockStart = -1
			}
		case ']':
			if braceDepth == 0 {
				return blocks
			}
		}
	}

	return blocks
}

// parseBlockFields extracts node spec fields from a single terraform block string
func parseBlockFields(block string, role types.Role) *types.NodeSpec {
	spec := &types.NodeSpec{
		Role:   role,
		Node:   "pve1",
		CPU:    4,
		Memory: 4096,
		Disk:   100,
	}

	spec.VMID = types.VMID(extractIntField(block, "vmid"))
	if spec.VMID == 0 {
		return nil
	}

	if name := extractStringField(block, "vm_name"); name != "" {
		spec.Name = name
	}
	if node := extractStringField(block, "node_name"); node != "" {
		spec.Node = node
	}
	if cpu := extractIntField(block, "cpu_cores"); cpu > 0 {
		spec.CPU = cpu
	}
	if mem := extractIntField(block, "memory"); mem > 0 {
		spec.Memory = mem
	}
	if disk := extractIntField(block, "disk_size"); disk > 0 {
		spec.Disk = disk
	}

	return spec
}

// extractStringField extracts a string value for a key from a terraform block
func extractStringField(block, key string) string {
	re := regexp.MustCompile(key + `\s*=\s*"([^"]*)"`)
	matches := re.FindStringSubmatch(block)
	if len(matches) >= 2 {
		return matches[1]
	}
	return ""
}

// extractIntField extracts an integer value for a key from a terraform block
func extractIntField(block, key string) int {
	re := regexp.MustCompile(key + `\s*=\s*"(\d+)"`)
	matches := re.FindStringSubmatch(block)
	if len(matches) >= 2 {
		val, err := strconv.Atoi(matches[1])
		if err == nil {
			return val
		}
	}
	return 0
}

// ComputeTerraformHash calculates SHA256 of terraform.tfvars
func (m *Manager) ComputeTerraformHash() (string, error) {
	data, err := os.ReadFile(m.config.TerraformTFVars)
	if err != nil {
		return "", err
	}
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:]), nil
}

// LoadDeployedState reads bootstrap-state.json
func (m *Manager) LoadDeployedState(ctx context.Context) (*types.ClusterState, error) {
	stateFile := filepath.Join(m.stateDir, "bootstrap-state.json")

	data, err := os.ReadFile(stateFile)
	if os.IsNotExist(err) {
		// Fresh start - return empty state
		return &types.ClusterState{
			ClusterName:          m.config.ClusterName,
			ControlPlaneEndpoint: m.config.ControlPlaneEndpoint,
			HAProxyIP:            m.config.HAProxyIP,
		}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read state file: %w", err)
	}

	var state types.ClusterState
	if err := json.Unmarshal(data, &state); err != nil {
		return nil, fmt.Errorf("parse state file (corrupted?): %w", err)
	}

	return &state, nil
}

// BuildReconcilePlan computes the diff between desired, deployed, and live
// This replaces your build_reconcile_plan() with proper logic
func (m *Manager) BuildReconcilePlan(
	ctx context.Context,
	desired map[types.VMID]*types.NodeSpec,
	deployed *types.ClusterState,
	live map[types.VMID]*types.LiveNode,
) (*types.ReconcilePlan, error) {

	plan := &types.ReconcilePlan{}

	// Build lookup maps for O(1) access (vs bash array iteration)
	deployedCPs := make(map[types.VMID]types.NodeState)
	for _, cp := range deployed.ControlPlanes {
		deployedCPs[cp.VMID] = cp
	}

	deployedWorkers := make(map[types.VMID]types.NodeState)
	for _, w := range deployed.Workers {
		deployedWorkers[w.VMID] = w
	}

	// Check for additions
	for vmid, spec := range desired {
		switch spec.Role {
		case types.RoleControlPlane:
			if _, exists := deployedCPs[vmid]; !exists {
				plan.AddControlPlanes = append(plan.AddControlPlanes, vmid)
			}
		case types.RoleWorker:
			if _, exists := deployedWorkers[vmid]; !exists {
				plan.AddWorkers = append(plan.AddWorkers, vmid)
			}
		}
	}

	// Check for removals and role changes
	for _, cp := range deployed.ControlPlanes {
		spec, exists := desired[cp.VMID]
		if !exists {
			plan.RemoveControlPlanes = append(plan.RemoveControlPlanes, cp.VMID)
		} else if spec.Role == types.RoleWorker {
			// Role change: CP -> Worker
			plan.RemoveControlPlanes = append(plan.RemoveControlPlanes, cp.VMID)
			plan.AddWorkers = append(plan.AddWorkers, cp.VMID)
		}
	}

	for _, w := range deployed.Workers {
		spec, exists := desired[w.VMID]
		if !exists {
			plan.RemoveWorkers = append(plan.RemoveWorkers, w.VMID)
		} else if spec.Role == types.RoleControlPlane {
			// Role change: Worker -> CP
			plan.RemoveWorkers = append(plan.RemoveWorkers, w.VMID)
			plan.AddControlPlanes = append(plan.AddControlPlanes, w.VMID)
		}
	}

	// Check for config drift (hash comparison)
	for vmid, spec := range desired {
		configFile := m.NodeConfigPath(vmid, spec.Role)
		currentHash, err := m.computeHash(configFile)
		if err != nil {
			// Config doesn't exist, needs generation
			plan.UpdateConfigs = append(plan.UpdateConfigs, vmid)
			continue
		}

		var deployedHash string
		switch spec.Role {
		case types.RoleControlPlane:
			if cp, ok := deployedCPs[vmid]; ok {
				deployedHash = cp.ConfigHash
			}
		case types.RoleWorker:
			if w, ok := deployedWorkers[vmid]; ok {
				deployedHash = w.ConfigHash
			}
		}

		if currentHash != deployedHash || m.config.ForceReconfigure {
			plan.UpdateConfigs = append(plan.UpdateConfigs, vmid)
		} else {
			plan.NoOp = append(plan.NoOp, vmid)
		}
	}

	// Check if bootstrap needed:
	// - Deployed CPs exist but bootstrap not completed (interrupted bootstrap)
	// - No deployed CPs but we're about to add some (fresh cluster)
	if !deployed.BootstrapCompleted {
		if len(deployed.ControlPlanes) > 0 || len(plan.AddControlPlanes) > 0 {
			plan.NeedsBootstrap = true
		}
	}

	// Sort for deterministic output
	sort.Slice(plan.AddControlPlanes, func(i, j int) bool { return plan.AddControlPlanes[i] < plan.AddControlPlanes[j] })
	sort.Slice(plan.AddWorkers, func(i, j int) bool { return plan.AddWorkers[i] < plan.AddWorkers[j] })
	sort.Slice(plan.RemoveControlPlanes, func(i, j int) bool { return plan.RemoveControlPlanes[i] < plan.RemoveControlPlanes[j] })
	sort.Slice(plan.RemoveWorkers, func(i, j int) bool { return plan.RemoveWorkers[i] < plan.RemoveWorkers[j] })
	sort.Slice(plan.UpdateConfigs, func(i, j int) bool { return plan.UpdateConfigs[i] < plan.UpdateConfigs[j] })

	return plan, nil
}

func (m *Manager) computeHash(filePath string) (string, error) {
	data, err := os.ReadFile(filePath)
	if err != nil {
		return "", err
	}
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:]), nil
}

// Save persists state to disk atomically
func (m *Manager) Save(ctx context.Context, state *types.ClusterState) error {
	if err := os.MkdirAll(m.stateDir, 0700); err != nil {
		return fmt.Errorf("create state dir: %w", err)
	}

	state.Timestamp = time.Now()

	hash, err := m.ComputeTerraformHash()
	if err != nil {
		return fmt.Errorf("compute terraform hash: %w", err)
	}
	state.TerraformHash = hash

	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal state: %w", err)
	}

	stateFile := filepath.Join(m.stateDir, "bootstrap-state.json")

	// Atomic write: write to temp, then rename
	tempFile := stateFile + ".tmp"
	if err := os.WriteFile(tempFile, data, 0600); err != nil {
		return fmt.Errorf("write temp state: %w", err)
	}

	if err := os.Rename(tempFile, stateFile); err != nil {
		return fmt.Errorf("rename state file: %w", err)
	}

	return nil
}

// UpdateNodeState updates a node's state in the cluster state
func (m *Manager) UpdateNodeState(state *types.ClusterState, vmid types.VMID, ip string, hash string, role types.Role) {
	nodeState := types.NodeState{
		VMID:       vmid,
		ConfigHash: hash,
		LastSeen:   time.Now(),
	}
	if ip != "" {
		nodeState.IP = parseIP(ip)
	}

	switch role {
	case types.RoleControlPlane:
		// Check if already exists
		found := false
		for i, cp := range state.ControlPlanes {
			if cp.VMID == vmid {
				state.ControlPlanes[i] = nodeState
				found = true
				break
			}
		}
		if !found {
			state.ControlPlanes = append(state.ControlPlanes, nodeState)
		}
	case types.RoleWorker:
		found := false
		for i, w := range state.Workers {
			if w.VMID == vmid {
				state.Workers[i] = nodeState
				found = true
				break
			}
		}
		if !found {
			state.Workers = append(state.Workers, nodeState)
		}
	}
}

// RemoveNodeState removes a node from the cluster state
func (m *Manager) RemoveNodeState(state *types.ClusterState, vmid types.VMID, role types.Role) {
	switch role {
	case types.RoleControlPlane:
		filtered := make([]types.NodeState, 0, len(state.ControlPlanes))
		for _, cp := range state.ControlPlanes {
			if cp.VMID != vmid {
				filtered = append(filtered, cp)
			}
		}
		state.ControlPlanes = filtered

	case types.RoleWorker:
		filtered := make([]types.NodeState, 0, len(state.Workers))
		for _, w := range state.Workers {
			if w.VMID != vmid {
				filtered = append(filtered, w)
			}
		}
		state.Workers = filtered
	}
}

func parseIP(s string) net.IP {
	return net.ParseIP(s)
}
