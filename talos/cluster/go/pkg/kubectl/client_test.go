package kubectl

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/zap"
	"go.uber.org/zap/zaptest"
)

// mockCommandContext creates a mock exec.Cmd that returns predefined output
func mockCommandContext(output string, err error) func(ctx context.Context, name string, args ...string) *exec.Cmd {
	return func(ctx context.Context, name string, args ...string) *exec.Cmd {
		// Create a command that just echoes the output or returns an error
		if err != nil {
			return exec.Command("cmd", "/c", "exit", "1") // Windows
		}
		// Use echo to return output (cross-platform via shell)
		return exec.Command("echo", output)
	}
}

// Helper to create a test client
func newTestClient(t *testing.T) (*Client, *zap.Logger) {
	logger := zaptest.NewLogger(t)
	return NewClient(logger), logger
}

// Helper to create a test IP
func mustParseIP(ip string) net.IP {
	parsed := net.ParseIP(ip)
	if parsed == nil {
		panic(fmt.Sprintf("invalid IP: %s", ip))
	}
	return parsed
}

func TestNewClient(t *testing.T) {
	logger := zaptest.NewLogger(t)
	client := NewClient(logger)

	require.NotNil(t, client)
	assert.Equal(t, logger, client.logger)
}

func TestClient_SetContext(t *testing.T) {
	client, _ := newTestClient(t)

	// Context should be empty initially
	assert.Empty(t, client.context)

	// Set context
	client.SetContext("test-context")
	assert.Equal(t, "test-context", client.context)

	// Verify baseArgs includes context
	args := client.baseArgs()
	assert.Contains(t, args, "--context")
	assert.Contains(t, args, "test-context")
}

func TestClient_baseArgs(t *testing.T) {
	t.Run("empty client", func(t *testing.T) {
		client, _ := newTestClient(t)
		args := client.baseArgs()
		assert.Empty(t, args)
	})

	t.Run("with kubeconfig", func(t *testing.T) {
		client, _ := newTestClient(t)
		client.kubeconfig = "/path/to/kubeconfig"
		args := client.baseArgs()
		assert.Equal(t, []string{"--kubeconfig", "/path/to/kubeconfig"}, args)
	})

	t.Run("with context", func(t *testing.T) {
		client, _ := newTestClient(t)
		client.SetContext("prod-cluster")
		args := client.baseArgs()
		assert.Equal(t, []string{"--context", "prod-cluster"}, args)
	})

	t.Run("with both", func(t *testing.T) {
		client, _ := newTestClient(t)
		client.kubeconfig = "/path/to/kubeconfig"
		client.SetContext("prod-cluster")
		args := client.baseArgs()
		assert.Equal(t, []string{"--kubeconfig", "/path/to/kubeconfig", "--context", "prod-cluster"}, args)
	})
}

func TestClient_GetNodeNameByIP(t *testing.T) {
	// Save and restore original execCommandContext
	originalExec := execCommandContext
	defer func() { execCommandContext = originalExec }()

	tests := []struct {
		name        string
		mockOutput  string
		mockErr     error
		ip          net.IP
		wantNode    string
		wantErr     bool
		errContains string
	}{
		{
			name: "node found by IP - control plane",
			mockOutput: "node-1   Ready    control-plane   5d    v1.28.0   192.168.1.10   <none>   Talos (v1.5.0)   5.15.0   containerd://1.7.0\n" +
				"node-2   Ready    <none>          5d    v1.28.0   192.168.1.11   <none>   Talos (v1.5.0)   5.15.0   containerd://1.7.0",
			ip:       mustParseIP("192.168.1.10"),
			wantNode: "node-1",
			wantErr:  false,
		},
		{
			name: "node found by IP - worker",
			mockOutput: "node-1   Ready    control-plane   5d    v1.28.0   192.168.1.10   <none>   Talos (v1.5.0)   5.15.0   containerd://1.7.0\n" +
				"node-2   Ready    <none>          5d    v1.28.0   192.168.1.11   <none>   Talos (v1.5.0)   5.15.0   containerd://1.7.0",
			ip:       mustParseIP("192.168.1.11"),
			wantNode: "node-2",
			wantErr:  false,
		},
		{
			name:        "IP not found",
			mockOutput:  "node-1   Ready    control-plane   5d    v1.28.0   192.168.1.10   <none>   Talos (v1.5.0)   5.15.0   containerd://1.7.0",
			ip:          mustParseIP("192.168.1.99"),
			wantErr:     true,
			errContains: "not found",
		},
		{
			name:        "kubectl command fails",
			mockOutput:  "",
			mockErr:     errors.New("kubectl: command not found"),
			ip:          mustParseIP("192.168.1.10"),
			wantErr:     true,
			errContains: "kubectl get nodes",
		},
		{
			name:        "empty output",
			mockOutput:  "",
			ip:          mustParseIP("192.168.1.10"),
			wantErr:     true,
			errContains: "not found",
		},
		{
			name:        "malformed output - too few fields",
			mockOutput:  "node-1   Ready",
			ip:          mustParseIP("192.168.1.10"),
			wantErr:     true,
			errContains: "not found",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Mock the exec command
			execCommandContext = func(ctx context.Context, name string, args ...string) *exec.Cmd {
				// Verify kubectl is being called
				assert.Equal(t, "kubectl", name)
				assert.Contains(t, args, "get")
				assert.Contains(t, args, "nodes")

				if tt.mockErr != nil {
					// Return a command that will fail
					return exec.Command("cmd", "/c", "exit", "1")
				}
				// Return echo with mock output (use printf for cross-platform or just echo)
				return exec.Command("cmd", "/c", "echo", tt.mockOutput)
			}

			client, _ := newTestClient(t)
			ctx := context.Background()

			got, err := client.GetNodeNameByIP(ctx, tt.ip)

			if tt.wantErr {
				assert.Error(t, err)
				if tt.errContains != "" {
					assert.Contains(t, err.Error(), tt.errContains)
				}
			} else {
				assert.NoError(t, err)
				assert.Equal(t, tt.wantNode, got)
			}
		})
	}
}

func TestClient_DrainNode(t *testing.T) {
	originalExec := execCommandContext
	defer func() { execCommandContext = originalExec }()

	tests := []struct {
		name        string
		nodeName    string
		mockErr     error
		wantErr     bool
		errContains string
	}{
		{
			name:     "successful drain",
			nodeName: "test-node",
			wantErr:  false,
		},
		{
			name:        "cordon fails",
			nodeName:    "test-node",
			mockErr:     errors.New("connection refused"),
			wantErr:     true,
			errContains: "kubectl cordon",
		},
		{
			name:     "empty node name",
			nodeName: "",
			// kubectl will still try to run, behavior depends on kubectl
			wantErr: false, // Or true if kubectl returns error for empty name
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			callCount := 0
			execCommandContext = func(ctx context.Context, name string, args ...string) *exec.Cmd {
				callCount++
				assert.Equal(t, "kubectl", name)

				// First call should be cordon, second should be drain
				if callCount == 1 {
					assert.Contains(t, args, "cordon")
				} else if callCount == 2 {
					assert.Contains(t, args, "drain")
					assert.Contains(t, args, "--ignore-daemonsets")
					assert.Contains(t, args, "--delete-emptydir-data")
				}

				if tt.mockErr != nil {
					return exec.Command("cmd", "/c", "exit", "1")
				}
				return exec.Command("cmd", "/c", "echo", "success")
			}

			client, _ := newTestClient(t)
			ctx := context.Background()

			err := client.DrainNode(ctx, tt.nodeName)

			if tt.wantErr {
				assert.Error(t, err)
				if tt.errContains != "" {
					assert.Contains(t, err.Error(), tt.errContains)
				}
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestClient_DeleteNode(t *testing.T) {
	originalExec := execCommandContext
	defer func() { execCommandContext = originalExec }()

	tests := []struct {
		name        string
		nodeName    string
		mockErr     error
		wantErr     bool
		errContains string
	}{
		{
			name:     "successful delete",
			nodeName: "test-node",
			wantErr:  false,
		},
		{
			name:        "delete fails",
			nodeName:    "test-node",
			mockErr:     errors.New("node not found"),
			wantErr:     true,
			errContains: "kubectl delete node",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			execCommandContext = func(ctx context.Context, name string, args ...string) *exec.Cmd {
				assert.Equal(t, "kubectl", name)
				assert.Contains(t, args, "delete")
				assert.Contains(t, args, "node")
				assert.Contains(t, args, tt.nodeName)

				if tt.mockErr != nil {
					return exec.Command("cmd", "/c", "exit", "1")
				}
				return exec.Command("cmd", "/c", "echo", "node deleted")
			}

			client, _ := newTestClient(t)
			ctx := context.Background()

			err := client.DeleteNode(ctx, tt.nodeName)

			if tt.wantErr {
				assert.Error(t, err)
				if tt.errContains != "" {
					assert.Contains(t, err.Error(), tt.errContains)
				}
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestClient_ClusterInfo(t *testing.T) {
	originalExec := execCommandContext
	defer func() { execCommandContext = originalExec }()

	t.Run("successful cluster info", func(t *testing.T) {
		expectedOutput := "Kubernetes control plane is running at https://192.168.1.10:6443"

		execCommandContext = func(ctx context.Context, name string, args ...string) *exec.Cmd {
			assert.Equal(t, "kubectl", name)
			assert.Contains(t, args, "cluster-info")
			return exec.Command("cmd", "/c", "echo", expectedOutput)
		}

		client, _ := newTestClient(t)
		ctx := context.Background()

		got, err := client.ClusterInfo(ctx)
		assert.NoError(t, err)
		assert.Contains(t, got, "Kubernetes control plane")
	})

	t.Run("cluster info fails", func(t *testing.T) {
		execCommandContext = func(ctx context.Context, name string, args ...string) *exec.Cmd {
			return exec.Command("cmd", "/c", "exit", "1")
		}

		client, _ := newTestClient(t)
		ctx := context.Background()

		_, err := client.ClusterInfo(ctx)
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "kubectl cluster-info")
	})
}

func TestClient_GetNodes(t *testing.T) {
	originalExec := execCommandContext
	defer func() { execCommandContext = originalExec }()

	t.Run("successful get nodes", func(t *testing.T) {
		expectedOutput := "NAME     STATUS   ROLES           AGE   VERSION\nnode-1   Ready    control-plane   5d    v1.28.0"

		execCommandContext = func(ctx context.Context, name string, args ...string) *exec.Cmd {
			assert.Equal(t, "kubectl", name)
			assert.Contains(t, args, "get")
			assert.Contains(t, args, "nodes")
			assert.Contains(t, args, "-o")
			assert.Contains(t, args, "wide")
			return exec.Command("cmd", "/c", "echo", expectedOutput)
		}

		client, _ := newTestClient(t)
		ctx := context.Background()

		got, err := client.GetNodes(ctx)
		assert.NoError(t, err)
		assert.Contains(t, got, "node-1")
	})

	t.Run("get nodes fails", func(t *testing.T) {
		execCommandContext = func(ctx context.Context, name string, args ...string) *exec.Cmd {
			return exec.Command("cmd", "/c", "exit", "1")
		}

		client, _ := newTestClient(t)
		ctx := context.Background()

		_, err := client.GetNodes(ctx)
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "kubectl get nodes")
	})
}

// Context cancellation tests
func TestClient_ContextCancellation(t *testing.T) {
	originalExec := execCommandContext
	defer func() { execCommandContext = originalExec }()

	t.Run("GetNodeNameByIP context cancelled", func(t *testing.T) {
		execCommandContext = func(ctx context.Context, name string, args ...string) *exec.Cmd {
			// Simulate slow command that checks context
			select {
			case <-ctx.Done():
				return exec.Command("cmd", "/c", "exit", "1")
			case <-time.After(100 * time.Millisecond):
				return exec.Command("cmd", "/c", "echo", "output")
			}
		}

		client, _ := newTestClient(t)
		ctx, cancel := context.WithCancel(context.Background())
		cancel() // Cancel immediately

		_, err := client.GetNodeNameByIP(ctx, mustParseIP("192.168.1.1"))
		assert.Error(t, err)
	})

	t.Run("DrainNode context cancelled", func(t *testing.T) {
		callCount := 0
		execCommandContext = func(ctx context.Context, name string, args ...string) *exec.Cmd {
			callCount++
			select {
			case <-ctx.Done():
				return exec.Command("cmd", "/c", "exit", "1")
			default:
				if callCount == 1 {
					return exec.Command("cmd", "/c", "echo", "cordoned")
				}
				return exec.Command("cmd", "/c", "echo", "drained")
			}
		}

		client, _ := newTestClient(t)
		ctx, cancel := context.WithCancel(context.Background())
		cancel()

		err := client.DrainNode(ctx, "test-node")
		assert.Error(t, err)
	})
}

// Timeout tests
func TestClient_Timeout(t *testing.T) {
	originalExec := execCommandContext
	defer func() { execCommandContext = originalExec }()

	t.Run("DrainNode timeout during drain phase", func(t *testing.T) {
		execCommandContext = func(ctx context.Context, name string, args ...string) *exec.Cmd {
			// First call (cordon) succeeds quickly
			if contains(args, "cordon") {
				return exec.Command("cmd", "/c", "echo", "cordoned")
			}
			// Second call (drain) takes too long
			select {
			case <-ctx.Done():
				return exec.Command("cmd", "/c", "exit", "1")
			case <-time.After(100 * time.Millisecond):
				return exec.Command("cmd", "/c", "echo", "drained")
			}
		}

		client, _ := newTestClient(t)
		// Very short timeout to trigger timeout
		ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
		defer cancel()

		err := client.DrainNode(ctx, "test-node")
		assert.Error(t, err)
	})
}

// Error wrapping tests
func TestClient_ErrorWrapping(t *testing.T) {
	originalExec := execCommandContext
	defer func() { execCommandContext = originalExec }()

	t.Run("errors are wrapped correctly", func(t *testing.T) {
		execCommandContext = func(ctx context.Context, name string, args ...string) *exec.Cmd {
			return exec.Command("cmd", "/c", "exit", "1")
		}

		client, _ := newTestClient(t)
		ctx := context.Background()

		_, err := client.GetNodeNameByIP(ctx, mustParseIP("192.168.1.1"))
		assert.Error(t, err)
		// The error should contain the kubectl command info
		assert.Contains(t, err.Error(), "kubectl get nodes")
	})
}

// Helper function
func contains(slice []string, item string) bool {
	for _, s := range slice {
		if s == item {
			return true
		}
	}
	return false
}

// Integration tests (require real kubectl)
func TestIntegration_Client(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	// Check if kubectl is available
	if _, err := exec.LookPath("kubectl"); err != nil {
		t.Skip("kubectl not found in PATH, skipping integration tests")
	}

	client, _ := newTestClient(t)
	ctx := context.Background()

	t.Run("ClusterInfo", func(t *testing.T) {
		info, err := client.ClusterInfo(ctx)
		if err != nil {
			t.Logf("ClusterInfo error (may be expected if no cluster): %v", err)
		} else {
			t.Logf("ClusterInfo: %s", info)
		}
	})

	t.Run("GetNodes", func(t *testing.T) {
		nodes, err := client.GetNodes(ctx)
		if err != nil {
			t.Logf("GetNodes error (may be expected if no cluster): %v", err)
		} else {
			t.Logf("Nodes: %s", nodes)
		}
	})
}

// Benchmark the parsing logic
func BenchmarkGetNodeNameByIP_Parsing(b *testing.B) {
	output := `node-1   Ready    control-plane   5d    v1.28.0   192.168.1.10   <none>   Talos (v1.5.0)   5.15.0   containerd://1.7.0
node-2   Ready    <none>          5d    v1.28.0   192.168.1.11   <none>   Talos (v1.5.0)   5.15.0   containerd://1.7.0
node-3   Ready    <none>          5d    v1.28.0   192.168.1.12   <none>   Talos (v1.5.0)   5.15.0   containerd://1.7.0`
	targetIP := "192.168.1.11"

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		for _, line := range strings.Split(output, "\n") {
			fields := strings.Fields(line)
			if len(fields) > 6 && fields[5] == targetIP {
				_ = fields[0]
				break
			}
		}
	}
}
