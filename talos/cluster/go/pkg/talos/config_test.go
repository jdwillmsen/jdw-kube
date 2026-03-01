package talos

import (
	"net"
	"os"
	"path/filepath"
	"testing"

	"github.com/jdw/talos-bootstrap/pkg/types"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestNewNodeConfig(t *testing.T) {
	cfg := types.DefaultConfig()
	nc := NewNodeConfig(cfg)

	assert.NotNil(t, nc)
	assert.Equal(t, cfg, nc.cfg)
}

func TestNodeConfigGenerate_ControlPlane(t *testing.T) {
	cfg := types.DefaultConfig()
	nc := NewNodeConfig(cfg)

	spec := &types.NodeSpec{
		VMID:   201,
		Name:   "talos-cp-1",
		Node:   "pve1",
		CPU:    4,
		Memory: 8192,
		Disk:   50,
		Role:   types.RoleControlPlane,
	}

	tmpDir := t.TempDir()
	hash, err := nc.Generate(spec, tmpDir)

	require.NoError(t, err)
	assert.NotEmpty(t, hash)
	assert.Len(t, hash, 64) // SHA256 hex string

	// Verify file was created
	expectedPath := filepath.Join(tmpDir, "node-control-plane-201.yaml")
	_, err = os.Stat(expectedPath)
	require.NoError(t, err)

	// Read and verify content
	content, err := os.ReadFile(expectedPath)
	require.NoError(t, err)

	contentStr := string(content)
	assert.Contains(t, contentStr, "version: v1alpha1")
	assert.Contains(t, contentStr, "type: controlplane")
	assert.Contains(t, contentStr, "hostname: talos-cp-1")
	assert.Contains(t, contentStr, "clusterName: cluster")
	assert.Contains(t, contentStr, "endpoint: https://cluster.jdwlabs.com:6443")
	assert.Contains(t, contentStr, "disk: /dev/sda")
	assert.Contains(t, contentStr, "interface: eth0")
	assert.Contains(t, contentStr, "vm.nr_hugepages: \"1024\"")
	assert.Contains(t, contentStr, "allowSchedulingOnControlPlane: false")
}

func TestNodeConfigGenerate_Worker(t *testing.T) {
	cfg := types.DefaultConfig()
	nc := NewNodeConfig(cfg)

	spec := &types.NodeSpec{
		VMID:   301,
		Name:   "talos-worker-1",
		Node:   "pve2",
		CPU:    8,
		Memory: 16384,
		Disk:   100,
		Role:   types.RoleWorker,
	}

	tmpDir := t.TempDir()
	hash, err := nc.Generate(spec, tmpDir)

	require.NoError(t, err)
	assert.NotEmpty(t, hash)

	// Verify file was created with correct name
	expectedPath := filepath.Join(tmpDir, "node-worker-301.yaml")
	_, err = os.Stat(expectedPath)
	require.NoError(t, err)

	// Read and verify content
	content, err := os.ReadFile(expectedPath)
	require.NoError(t, err)

	contentStr := string(content)
	assert.Contains(t, contentStr, "type: worker")
	assert.Contains(t, contentStr, "hostname: talos-worker-1")
	assert.Contains(t, contentStr, "destination: /var/local")
	assert.NotContains(t, contentStr, "allowSchedulingOnControlPlane") // Only in CP
}

func TestNodeConfigGenerate_UnknownRole(t *testing.T) {
	cfg := types.DefaultConfig()
	nc := NewNodeConfig(cfg)

	spec := &types.NodeSpec{
		VMID: 401,
		Name: "unknown",
		Role: types.Role("unknown-role"),
	}

	tmpDir := t.TempDir()
	_, err := nc.Generate(spec, tmpDir)

	require.Error(t, err)
	assert.Contains(t, err.Error(), "unknown node role")
}

func TestNodeConfigGenerate_CreatesDirectory(t *testing.T) {
	cfg := types.DefaultConfig()
	nc := NewNodeConfig(cfg)

	spec := &types.NodeSpec{
		VMID: 201,
		Name: "test",
		Role: types.RoleControlPlane,
	}

	// Use a nested directory that doesn't exist yet
	tmpDir := t.TempDir()
	nestedDir := filepath.Join(tmpDir, "nested", "config", "dir")

	hash, err := nc.Generate(spec, nestedDir)
	require.NoError(t, err)
	assert.NotEmpty(t, hash)

	// Verify directory was created
	_, err = os.Stat(nestedDir)
	require.NoError(t, err)
}

func TestConfigPath(t *testing.T) {
	cfg := types.DefaultConfig()
	nc := NewNodeConfig(cfg)

	tmpDir := "/tmp/test" // Use Unix-style path for test consistency

	path := nc.ConfigPath(tmpDir, 201, types.RoleControlPlane)
	// Use filepath.Join to get OS-specific path for comparison
	expected := filepath.Join(tmpDir, "node-control-plane-201.yaml")
	assert.Equal(t, expected, path)

	path = nc.ConfigPath(tmpDir, 301, types.RoleWorker)
	expected = filepath.Join(tmpDir, "node-worker-301.yaml")
	assert.Equal(t, expected, path)
}

func TestHashFile(t *testing.T) {
	// Create a temporary file with known content
	tmpDir := t.TempDir()
	testFile := filepath.Join(tmpDir, "test.yaml")
	content := []byte("test content for hashing")

	err := os.WriteFile(testFile, content, 0600)
	require.NoError(t, err)

	// Hash the file
	hash, err := HashFile(testFile)
	require.NoError(t, err)
	assert.Len(t, hash, 64) // SHA256 hex

	// Verify it's deterministic
	hash2, err := HashFile(testFile)
	require.NoError(t, err)
	assert.Equal(t, hash, hash2)

	// Different content should produce different hash
	differentFile := filepath.Join(tmpDir, "different.yaml")
	err = os.WriteFile(differentFile, []byte("different content"), 0600)
	require.NoError(t, err)

	differentHash, err := HashFile(differentFile)
	require.NoError(t, err)
	assert.NotEqual(t, hash, differentHash)

	// Non-existent file should error
	_, err = HashFile("/nonexistent/file.yaml")
	require.Error(t, err)
}

func TestGenerate_ConfigContentStructure(t *testing.T) {
	cfg := &types.Config{
		ClusterName:             "test-cluster",
		ControlPlaneEndpoint:    "k8s.example.com",
		HAProxyIP:               net.ParseIP("10.0.0.1"),
		InstallerImage:          "factory.talos.dev/installer:v1.0.0",
		DefaultDisk:             "vda",
		DefaultNetworkInterface: "ens18",
	}
	nc := NewNodeConfig(cfg)

	spec := &types.NodeSpec{
		VMID: 201,
		Name: "cp-1",
		Role: types.RoleControlPlane,
	}

	tmpDir := t.TempDir()
	_, err := nc.Generate(spec, tmpDir)
	require.NoError(t, err)

	content, _ := os.ReadFile(filepath.Join(tmpDir, "node-control-plane-201.yaml"))
	contentStr := string(content)

	// Verify custom values are used
	assert.Contains(t, contentStr, "test-cluster")
	assert.Contains(t, contentStr, "k8s.example.com")
	assert.Contains(t, contentStr, "10.0.0.1")
	assert.Contains(t, contentStr, "factory.talos.dev/installer:v1.0.0")
	assert.Contains(t, contentStr, "/dev/vda")
	assert.Contains(t, contentStr, "ens18")
}
