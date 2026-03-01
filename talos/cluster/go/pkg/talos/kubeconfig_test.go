package talos

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/zap"
	"gopkg.in/yaml.v3"
)

func TestNewKubeconfigManager(t *testing.T) {
	logger := zap.NewNop()
	client := &Client{}

	km := NewKubeconfigManager(client, logger)

	assert.NotNil(t, km)
	assert.Equal(t, client, km.client)
	assert.Equal(t, logger, km.logger)
}

func TestKubeconfigPath(t *testing.T) {
	logger := zap.NewNop()
	km := NewKubeconfigManager(nil, logger)

	t.Run("KUBECONFIG env var set", func(t *testing.T) {
		tmpDir := t.TempDir()
		kubeconfigPath := filepath.Join(tmpDir, "config")
		t.Setenv("KUBECONFIG", kubeconfigPath)

		path := km.kubeconfigPath()
		assert.Equal(t, kubeconfigPath, path)
	})

	t.Run("KUBECONFIG with multiple paths", func(t *testing.T) {
		tmpDir := t.TempDir()
		path1 := filepath.Join(tmpDir, "config1")
		path2 := filepath.Join(tmpDir, "config2")

		// Use filepath.SplitList to join paths correctly for the OS
		t.Setenv("KUBECONFIG", strings.Join([]string{path1, path2}, string(filepath.ListSeparator)))

		path := km.kubeconfigPath()
		assert.Equal(t, path1, path) // Should take first
	})

	t.Run("default path", func(t *testing.T) {
		t.Setenv("KUBECONFIG", "")
		// Don't set HOME on Windows, just check it returns a valid path
		path := km.kubeconfigPath()

		// Should contain .kube/config
		assert.Contains(t, path, ".kube")
		assert.Contains(t, path, "config")
	})
}

func TestMergeKubeconfig_NewFile(t *testing.T) {
	logger := zap.NewNop()
	km := NewKubeconfigManager(nil, logger)

	tmpDir := t.TempDir()
	existingPath := filepath.Join(tmpDir, "existing", "config")
	newPath := filepath.Join(tmpDir, "new.yaml")

	// Create new config content
	newConfig := kubeConfig{
		APIVersion:     "v1",
		Kind:           "Config",
		CurrentContext: "test-cluster",
		Clusters: []kubeCluster{
			{
				Name: "test-cluster",
				Cluster: kubeClusterDetail{
					Server: "https://test.example.com:6443",
				},
			},
		},
		Contexts: []kubeContext{
			{
				Name: "test-cluster",
				Context: kubeContextDetail{
					Cluster: "test-cluster",
					User:    "test-admin",
				},
			},
		},
		Users: []kubeUser{
			{Name: "test-admin"},
		},
	}

	data, _ := yaml.Marshal(newConfig)
	err := os.WriteFile(newPath, data, 0600)
	require.NoError(t, err)

	// Merge should create the file since existing doesn't exist
	err = km.mergeKubeconfig(existingPath, newPath)
	require.NoError(t, err)

	// Verify file was created
	_, err = os.Stat(existingPath)
	require.NoError(t, err)

	// Verify content
	content, _ := os.ReadFile(existingPath)
	var result kubeConfig
	err = yaml.Unmarshal(content, &result)
	require.NoError(t, err)
	assert.Equal(t, "test-cluster", result.CurrentContext)
}

func TestWriteDirectly(t *testing.T) {
	logger := zap.NewNop()
	km := NewKubeconfigManager(nil, logger)

	tmpDir := t.TempDir()
	testPath := filepath.Join(tmpDir, "deep", "path", "config")

	data := []byte("test kubeconfig data")
	err := km.writeDirectly(testPath, data)
	require.NoError(t, err)

	// Verify directory created
	_, err = os.Stat(filepath.Dir(testPath))
	require.NoError(t, err)

	// Verify file content
	content, _ := os.ReadFile(testPath)
	assert.Equal(t, data, content)
}

func TestKubeConfigStructs(t *testing.T) {
	// Test that all struct fields are properly tagged
	config := kubeConfig{
		APIVersion:     "v1",
		Kind:           "Config",
		CurrentContext: "test",
		Clusters: []kubeCluster{
			{
				Name: "cluster1",
				Cluster: kubeClusterDetail{
					Server:                   "https://server:6443",
					CertificateAuthorityData: "certdata",
				},
			},
		},
		Contexts: []kubeContext{
			{
				Name: "context1",
				Context: kubeContextDetail{
					Cluster: "cluster1",
					User:    "user1",
				},
			},
		},
		Users: []kubeUser{
			{Name: "user1", User: map[string]interface{}{"token": "abc"}},
		},
	}

	// Verify YAML marshaling
	data, err := yaml.Marshal(config)
	require.NoError(t, err)

	// Verify YAML unmarshaling
	var result kubeConfig
	err = yaml.Unmarshal(data, &result)
	require.NoError(t, err)

	assert.Equal(t, config.APIVersion, result.APIVersion)
	assert.Equal(t, config.CurrentContext, result.CurrentContext)
	assert.Len(t, result.Clusters, 1)
	assert.Equal(t, "cluster1", result.Clusters[0].Name)
	assert.Equal(t, "https://server:6443", result.Clusters[0].Cluster.Server)
}

func TestFetchAndMerge_Modifications(t *testing.T) {
	// Test the config modification logic
	original := kubeConfig{
		APIVersion:     "v1",
		Kind:           "Config",
		CurrentContext: "original-context",
		Clusters: []kubeCluster{
			{Name: "original", Cluster: kubeClusterDetail{Server: "https://original:6443"}},
		},
		Contexts: []kubeContext{
			{Name: "original-context", Context: kubeContextDetail{Cluster: "original", User: "original-admin"}},
		},
		Users: []kubeUser{
			{Name: "original-admin"},
		},
	}

	// Simulate the modifications FetchAndMerge would make
	clusterName := "my-cluster"
	controlPlaneEndpoint := "k8s.example.com"

	// Update server URL
	for i := range original.Clusters {
		original.Clusters[i].Cluster.Server = "https://" + controlPlaneEndpoint + ":6443"
		original.Clusters[i].Name = clusterName
	}

	// Rename context
	for i := range original.Contexts {
		original.Contexts[i].Name = clusterName
		original.Contexts[i].Context.Cluster = clusterName
	}
	original.CurrentContext = clusterName

	// Rename user
	oldUser := original.Users[0].Name
	for i := range original.Users {
		original.Users[i].Name = clusterName + "-admin"
	}
	for i := range original.Contexts {
		if original.Contexts[i].Context.User == oldUser {
			original.Contexts[i].Context.User = clusterName + "-admin"
		}
	}

	// Verify modifications
	assert.Equal(t, "my-cluster", original.CurrentContext)
	assert.Equal(t, "https://k8s.example.com:6443", original.Clusters[0].Cluster.Server)
	assert.Equal(t, "my-cluster", original.Contexts[0].Name)
	assert.Equal(t, "my-cluster-admin", original.Users[0].Name)
}
