package main

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/jdw/talos-bootstrap/pkg/types"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestVMIDType(t *testing.T) {
	tests := []struct {
		name     string
		vmid     types.VMID
		expected string
	}{
		{"single digit", types.VMID(1), "1"},
		{"standard VMID", types.VMID(201), "201"},
		{"large VMID", types.VMID(999999), "999999"},
		{"zero", types.VMID(0), "0"},
		{"negative", types.VMID(-1), "-1"},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			result := tt.vmid.String()
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestDefaultConfig(t *testing.T) {
	cfg := types.DefaultConfig()

	assert.Equal(t, "cluster", cfg.ClusterName)
	assert.Equal(t, "terraform.tfvars", cfg.TerraformTFVars)
	assert.Equal(t, "cluster.jdwlabs.com", cfg.ControlPlaneEndpoint)
	assert.Equal(t, "192.168.1.199", cfg.HAProxyIP.String())
	assert.Equal(t, "admin", cfg.HAProxyStatsUser)
	assert.Equal(t, "v1.35.1", cfg.KubernetesVersion)
	assert.Equal(t, "v1.12.3", cfg.TalosVersion)
	assert.Equal(t, "eth0", cfg.DefaultNetworkInterface)
	assert.Equal(t, "sda", cfg.DefaultDisk)
	assert.Equal(t, "info", cfg.LogLevel)

	expectedSecretsDir := filepath.Join("clusters", "cluster", "secrets")
	assert.Equal(t, expectedSecretsDir, cfg.SecretsDir)

	assert.Len(t, cfg.ProxmoxNodeIPs, 4)
	assert.Contains(t, cfg.ProxmoxNodeIPs, "pve1")
}

func TestReconcilePlanEmpty(t *testing.T) {
	tests := []struct {
		name     string
		plan     *types.ReconcilePlan
		expected bool
	}{
		{
			name:     "empty plan should be empty",
			plan:     &types.ReconcilePlan{},
			expected: true,
		},
		{
			name: "plan with additions should not be empty",
			plan: &types.ReconcilePlan{
				AddControlPlanes: []types.VMID{201},
			},
			expected: false,
		},
		{
			name: "plan with removals should not be empty",
			plan: &types.ReconcilePlan{
				RemoveWorkers: []types.VMID{301},
			},
			expected: false,
		},
		{
			name: "plan with updates should not be empty",
			plan: &types.ReconcilePlan{
				UpdateConfigs: []types.VMID{201},
			},
			expected: false,
		},
		{
			name: "plan needing bootstrap should not be empty",
			plan: &types.ReconcilePlan{
				NeedsBootstrap: true,
			},
			expected: false,
		},
		{
			name: "plan with noop should be empty",
			plan: &types.ReconcilePlan{
				NoOp: []types.VMID{202},
			},
			expected: true,
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			result := tt.plan.IsEmpty()
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestCountByRole(t *testing.T) {
	tests := []struct {
		name     string
		specs    map[types.VMID]*types.NodeSpec
		role     types.Role
		expected int
	}{
		{
			name: "count control planes",
			specs: map[types.VMID]*types.NodeSpec{
				201: {VMID: 201, Role: types.RoleControlPlane},
				202: {VMID: 202, Role: types.RoleControlPlane},
				301: {VMID: 301, Role: types.RoleWorker},
			},
			role:     types.RoleControlPlane,
			expected: 2,
		},
		{
			name: "count workers",
			specs: map[types.VMID]*types.NodeSpec{
				201: {VMID: 201, Role: types.RoleControlPlane},
				301: {VMID: 301, Role: types.RoleWorker},
				302: {VMID: 302, Role: types.RoleWorker},
			},
			role:     types.RoleWorker,
			expected: 2,
		},
		{
			name:     "empty specs",
			specs:    map[types.VMID]*types.NodeSpec{},
			role:     types.RoleControlPlane,
			expected: 0,
		},
		{
			name:     "nil specs",
			specs:    nil,
			role:     types.RoleControlPlane,
			expected: 0,
		},
		{
			name: "no matching role",
			specs: map[types.VMID]*types.NodeSpec{
				301: {VMID: 301, Role: types.RoleWorker},
			},
			role:     types.RoleControlPlane,
			expected: 0,
		},
		{
			name: "mixed roles",
			specs: map[types.VMID]*types.NodeSpec{
				201: {VMID: 201, Role: types.RoleControlPlane},
				202: {VMID: 202, Role: types.RoleControlPlane},
				203: {VMID: 203, Role: types.RoleControlPlane},
				301: {VMID: 301, Role: types.RoleWorker},
				302: {VMID: 302, Role: types.RoleWorker},
			},
			role:     types.RoleWorker,
			expected: 2,
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			result := countByRole(tt.specs, tt.role)
			assert.Equal(t, tt.expected, result)
		})
	}
}

// captureOutput redirects stderr and captures it
func captureOutput(t *testing.T, fn func()) string {
	t.Helper()

	// Save original stderr
	oldStderr := os.Stderr

	// Create pipe
	r, w, err := os.Pipe()
	require.NoError(t, err)

	// Redirect stderr
	os.Stderr = w

	// Capture in goroutine
	outChan := make(chan string, 1)
	go func() {
		var buf bytes.Buffer
		_, _ = io.Copy(&buf, r)
		outChan <- buf.String()
	}()

	// Run function
	fn()

	// Close writer and restore stderr
	w.Close()
	os.Stderr = oldStderr

	// Get output with timeout protection
	return <-outChan
}

func TestDisplayPlan(t *testing.T) {
	// Set NoColor for consistent output (no ANSI codes)
	oldCfg := cfg
	cfg = &types.Config{NoColor: true}
	defer func() { cfg = oldCfg }()

	tests := []struct {
		name        string
		plan        *types.ReconcilePlan
		wantContain []string
	}{
		{
			name:        "empty plan",
			plan:        &types.ReconcilePlan{},
			wantContain: []string{"no changes needed", "OK"},
		},
		{
			name: "bootstrap plan",
			plan: &types.ReconcilePlan{
				NeedsBootstrap: true,
			},
			wantContain: []string{"BOOTSTRAP", "Cluster needs initial bootstrap"},
		},
		{
			name: "add control planes",
			plan: &types.ReconcilePlan{
				AddControlPlanes: []types.VMID{201, 202},
			},
			wantContain: []string{"Add 2 control plane(s)", "201", "202"},
		},
		{
			name: "add workers",
			plan: &types.ReconcilePlan{
				AddWorkers: []types.VMID{301, 302, 303},
			},
			wantContain: []string{"Add 3 worker(s)", "301", "302", "303"},
		},
		{
			name: "remove control planes",
			plan: &types.ReconcilePlan{
				RemoveControlPlanes: []types.VMID{203},
			},
			wantContain: []string{"Remove 1 control plane(s)", "203"},
		},
		{
			name: "remove workers",
			plan: &types.ReconcilePlan{
				RemoveWorkers: []types.VMID{304, 305},
			},
			wantContain: []string{"Remove 2 worker(s)", "304", "305"},
		},
		{
			name: "update configs",
			plan: &types.ReconcilePlan{
				UpdateConfigs: []types.VMID{201, 202},
			},
			wantContain: []string{"Update 2 node config(s)", "201", "202"},
		},
		{
			name: "noop nodes",
			plan: &types.ReconcilePlan{
				NoOp: []types.VMID{201, 202, 203},
			},
			wantContain: []string{"3 node(s) unchanged"},
		},
		{
			name: "full plan",
			plan: &types.ReconcilePlan{
				NeedsBootstrap:      true,
				AddControlPlanes:    []types.VMID{201, 202},
				AddWorkers:          []types.VMID{301},
				RemoveControlPlanes: []types.VMID{203},
				RemoveWorkers:       []types.VMID{302},
				UpdateConfigs:       []types.VMID{201},
				NoOp:                []types.VMID{202},
			},
			wantContain: []string{
				"BOOTSTRAP",
				"Add 2 control plane(s)",
				"Add 1 worker(s)",
				"Remove 1 control plane(s)",
				"Remove 1 worker(s)",
				"Update 1 node config(s)",
				"1 node(s) unchanged",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Not parallel - stdout/stderr capture is not thread-safe
			output := captureOutput(t, func() {
				displayPlan(tt.plan)
			})

			for _, want := range tt.wantContain {
				assert.Contains(t, output, want, "expected output to contain %q", want)
			}
		})
	}
}

// Benchmarks
func BenchmarkCountByRole(b *testing.B) {
	specs := make(map[types.VMID]*types.NodeSpec)
	for i := 0; i < 1000; i++ {
		role := types.RoleWorker
		if i%3 == 0 {
			role = types.RoleControlPlane
		}
		specs[types.VMID(i)] = &types.NodeSpec{
			VMID: types.VMID(i),
			Role: role,
		}
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		countByRole(specs, types.RoleControlPlane)
	}
}

func BenchmarkCountByRole_Small(b *testing.B) {
	specs := map[types.VMID]*types.NodeSpec{
		201: {VMID: 201, Role: types.RoleControlPlane},
		202: {VMID: 202, Role: types.RoleControlPlane},
		301: {VMID: 301, Role: types.RoleWorker},
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		countByRole(specs, types.RoleControlPlane)
	}
}

// Fuzz tests
func FuzzVMIDString(f *testing.F) {
	f.Add(uint32(0))
	f.Add(uint32(1))
	f.Add(uint32(201))
	f.Add(uint32(999999))
	f.Add(uint32(4294967295)) // max uint32

	f.Fuzz(func(t *testing.T, vmid uint32) {
		v := types.VMID(vmid)
		result := v.String()

		// Should never be empty
		require.NotEmpty(t, result)
	})
}
