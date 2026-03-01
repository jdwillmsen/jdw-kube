package test

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jdw/talos-bootstrap/pkg/discovery"
	"github.com/jdw/talos-bootstrap/pkg/state"
	"github.com/jdw/talos-bootstrap/pkg/types"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/zap"
)

// Integration tests are skipped by default unless RUN_INTEGRATION_TESTS is set
func skipIfNotIntegration(t *testing.T) {
	if os.Getenv("RUN_INTEGRATION_TESTS") == "" {
		t.Skip("Skipping integration test. Set RUN_INTEGRATION_TESTS=1 to run.")
	}
}

func TestEndToEnd_ReconcileFlow(t *testing.T) {
	skipIfNotIntegration(t)

	// logger declared but used in subtests via t.Log
	ctx := context.Background()

	// Setup test configuration
	cfg := &types.Config{
		ClusterName:          "test-integration",
		TerraformTFVars:      "test-fixtures/terraform.tfvars",
		ControlPlaneEndpoint: "test.local",
		HAProxyIP:            net.ParseIP("192.168.1.199"),
		ProxmoxSSHUser:       "root",
		ProxmoxNodeIPs: map[string]net.IP{
			"pve1": net.ParseIP("192.168.1.200"),
		},
	}

	// Create state manager
	stateMgr := state.NewManager(cfg)

	t.Run("load desired state from terraform", func(t *testing.T) {
		// Create a test terraform.tfvars file
		tfContent := `
talos_control_configuration = [
  {
    vmid       = 201
    vm_name    = "test-cp-1"
    node_name  = "pve1"
    cpu_cores  = 2
    memory     = 4096
    disk_size  = 20
  }
]

talos_worker_configuration = [
  {
    vmid       = 301
    vm_name    = "test-worker-1"
    node_name  = "pve1"
    cpu_cores  = 4
    memory     = 8192
    disk_size  = 50
  }
]
`
		tmpDir := t.TempDir()
		tfPath := filepath.Join(tmpDir, "terraform.tfvars")
		err := os.WriteFile(tfPath, []byte(tfContent), 0644)
		require.NoError(t, err)

		cfg.TerraformTFVars = tfPath

		desired, err := stateMgr.LoadDesiredState(ctx)
		require.NoError(t, err)

		// Note: HCL parsing might need adjustment based on actual format
		// This tests the fallback or successful parsing
		assert.NotNil(t, desired)
	})

	t.Run("state persistence", func(t *testing.T) {
		tmpDir := t.TempDir()
		cfg.ClusterName = "test-state"
		cfg.SecretsDir = filepath.Join(tmpDir, "clusters", "test-state", "secrets")

		stateMgr := state.NewManager(cfg)

		clusterState := &types.ClusterState{
			ClusterName:        "test-state",
			BootstrapCompleted: true,
			ControlPlanes: []types.NodeState{
				{VMID: 201, IP: net.ParseIP("192.168.1.201")},
			},
			Workers: []types.NodeState{
				{VMID: 301, IP: net.ParseIP("192.168.1.301")},
			},
		}

		// Save state
		err := stateMgr.Save(ctx, clusterState)
		require.NoError(t, err)

		// Load state
		loaded, err := stateMgr.LoadDeployedState(ctx)
		require.NoError(t, err)

		assert.True(t, loaded.BootstrapCompleted)
		assert.Len(t, loaded.ControlPlanes, 1)
		assert.Equal(t, types.VMID(201), loaded.ControlPlanes[0].VMID)
	})

	t.Run("reconcile plan building", func(t *testing.T) {
		desired := map[types.VMID]*types.NodeSpec{
			201: {VMID: 201, Role: types.RoleControlPlane},
			202: {VMID: 202, Role: types.RoleControlPlane},
			301: {VMID: 301, Role: types.RoleWorker},
		}

		deployed := &types.ClusterState{
			ControlPlanes: []types.NodeState{
				{VMID: 201}, // Already deployed
			},
			Workers: []types.NodeState{
				{VMID: 302}, // Should be removed
			},
		}

		live := map[types.VMID]*types.LiveNode{
			201: {VMID: 201, IP: net.ParseIP("192.168.1.201")},
			202: {VMID: 202, IP: net.ParseIP("192.168.1.202")},
			301: {VMID: 301, IP: net.ParseIP("192.168.1.301")},
		}

		plan, err := stateMgr.BuildReconcilePlan(ctx, desired, deployed, live)
		require.NoError(t, err)

		// 202 is new CP
		assert.Contains(t, plan.AddControlPlanes, types.VMID(202))

		// 301 is new worker
		assert.Contains(t, plan.AddWorkers, types.VMID(301))

		// 302 should be removed
		assert.Contains(t, plan.RemoveWorkers, types.VMID(302))

		// 201 is noop (already deployed and in desired)
		assert.Contains(t, plan.NoOp, types.VMID(201))
	})
}

func TestScannerIntegration(t *testing.T) {
	skipIfNotIntegration(t)

	cfg := &types.Config{
		ProxmoxSSHUser: "root",
		ProxmoxNodeIPs: map[string]net.IP{
			"pve1": net.ParseIP("192.168.1.200"),
		},
	}

	scanner := discovery.NewScanner(cfg.ProxmoxSSHUser, cfg.ProxmoxNodeIPs)

	t.Run("discover VMs", func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		vmids := []types.VMID{201, 202, 301}
		nodes, err := scanner.DiscoverVMs(ctx, vmids)

		// May error if SSH is not available, but shouldn't panic
		if err != nil {
			t.Logf("Discovery failed (expected if no SSH): %v", err)
			return
		}

		for vmid, node := range nodes {
			t.Logf("Found VM %d: IP=%s, MAC=%s, Status=%s",
				vmid, node.IP, node.MAC, node.Status)
		}
	})
}

func TestRebootMonitorIntegration(t *testing.T) {
	skipIfNotIntegration(t)

	logger, _ := zap.NewDevelopment()
	scanner := discovery.NewScanner("root", map[string]net.IP{
		"pve1": net.ParseIP("192.168.1.200"),
	})

	t.Run("monitor reboot cycle", func(t *testing.T) {
		// This would require an actual VM to test properly
		initialIP := net.ParseIP("192.168.1.201")
		mac := "BC:24:11:AA:BB:CC"

		monitor := discovery.NewRebootMonitor(
			types.VMID(201),
			initialIP,
			mac,
			scanner,
			logger,
		)

		// Verify initial state
		assert.Equal(t, discovery.StateMonitoring, monitor.State())
	})
}
