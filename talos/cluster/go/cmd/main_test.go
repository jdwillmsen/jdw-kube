package main

import (
	"path/filepath"
	"testing"

	"github.com/jdw/talos-bootstrap/pkg/types"
	"github.com/stretchr/testify/assert"
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
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
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

	// Use filepath.Join for cross-platform path comparison
	expectedSecretsDir := filepath.Join("clusters", "cluster", "secrets")
	assert.Equal(t, expectedSecretsDir, cfg.SecretsDir)

	// Check Proxmox nodes
	assert.Len(t, cfg.ProxmoxNodeIPs, 4)
	assert.Contains(t, cfg.ProxmoxNodeIPs, "pve1")
}

func TestReconcilePlanEmpty(t *testing.T) {
	t.Run("empty plan should be empty", func(t *testing.T) {
		plan := &types.ReconcilePlan{}
		assert.True(t, plan.IsEmpty())
	})

	t.Run("plan with additions should not be empty", func(t *testing.T) {
		plan := &types.ReconcilePlan{
			AddControlPlanes: []types.VMID{201},
		}
		assert.False(t, plan.IsEmpty())
	})

	t.Run("plan with removals should not be empty", func(t *testing.T) {
		plan := &types.ReconcilePlan{
			RemoveWorkers: []types.VMID{301},
		}
		assert.False(t, plan.IsEmpty())
	})

	t.Run("plan with updates should not be empty", func(t *testing.T) {
		plan := &types.ReconcilePlan{
			UpdateConfigs: []types.VMID{201},
		}
		assert.False(t, plan.IsEmpty())
	})

	t.Run("plan needing bootstrap should not be empty", func(t *testing.T) {
		plan := &types.ReconcilePlan{
			NeedsBootstrap: true,
		}
		assert.False(t, plan.IsEmpty())
	})
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
			name: "no matching role",
			specs: map[types.VMID]*types.NodeSpec{
				301: {VMID: 301, Role: types.RoleWorker},
			},
			role:     types.RoleControlPlane,
			expected: 0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := countByRole(tt.specs, tt.role)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestDisplayPlan(t *testing.T) {
	// This is mostly a smoke test since displayPlan prints to stdout
	tests := []struct {
		name string
		plan *types.ReconcilePlan
	}{
		{
			name: "empty plan",
			plan: &types.ReconcilePlan{},
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
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Should not panic
			assert.NotPanics(t, func() {
				displayPlan(tt.plan)
			})
		})
	}
}
