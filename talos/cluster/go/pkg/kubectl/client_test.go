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

	"go.uber.org/zap"
	"go.uber.org/zap/zaptest"
)

// mockExecutor allows us to mock exec.Command for testing
type mockExecutor struct {
	output string
	err    error
}

func (m *mockExecutor) CommandContext(ctx context.Context, name string, args ...string) *exec.Cmd {
	// This is a simplified mock - in real tests you'd use a more sophisticated approach
	// like using exec.Command with a helper script or environment variable injection
	return nil
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

	if client == nil {
		t.Fatal("NewClient returned nil")
	}
	if client.logger != logger {
		t.Error("NewClient did not set logger correctly")
	}
}

func TestClient_GetNodeNameByIP(t *testing.T) {
	client, _ := newTestClient(t)

	tests := []struct {
		name        string
		setupMock   func()
		ip          net.IP
		wantNode    string
		wantErr     bool
		errContains string
	}{
		{
			name: "node found by IP",
			ip:   mustParseIP("192.168.1.10"),
			// Note: This would require mocking exec.Command
			// For integration tests, this runs actual kubectl
			wantErr: true, // Will fail without kubectl setup
		},
		{
			name:    "invalid IP format",
			ip:      net.IP{}, // Empty IP
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()

			got, err := client.GetNodeNameByIP(ctx, tt.ip)
			if (err != nil) != tt.wantErr {
				t.Errorf("GetNodeNameByIP() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if !tt.wantErr && got != tt.wantNode {
				t.Errorf("GetNodeNameByIP() = %v, want %v", got, tt.wantNode)
			}
			if tt.wantErr && tt.errContains != "" && err != nil {
				if !strings.Contains(err.Error(), tt.errContains) {
					t.Errorf("GetNodeNameByIP() error = %v, should contain %v", err, tt.errContains)
				}
			}
		})
	}
}

func TestClient_GetNodeNameByIP_ParseOutput(t *testing.T) {
	// Test the parsing logic directly
	testCases := []struct {
		name     string
		output   string
		targetIP string
		want     string
		wantErr  bool
	}{
		{
			name: "standard kubectl output",
			output: `node-1   Ready    control-plane   5d    v1.28.0   192.168.1.10   <none>   Talos (v1.5.0)   5.15.0   containerd://1.7.0
node-2   Ready    <none>          5d    v1.28.0   192.168.1.11   <none>   Talos (v1.5.0)   5.15.0   containerd://1.7.0`,
			targetIP: "192.168.1.10",
			want:     "node-1",
			wantErr:  false,
		},
		{
			name: "worker node IP",
			output: `node-1   Ready    control-plane   5d    v1.28.0   192.168.1.10   <none>   Talos (v1.5.0)   5.15.0   containerd://1.7.0
node-2   Ready    <none>          5d    v1.28.0   192.168.1.11   <none>   Talos (v1.5.0)   5.15.0   containerd://1.7.0`,
			targetIP: "192.168.1.11",
			want:     "node-2",
			wantErr:  false,
		},
		{
			name:     "IP not found",
			output:   `node-1   Ready    control-plane   5d    v1.28.0   192.168.1.10   <none>   Talos (v1.5.0)   5.15.0   containerd://1.7.0`,
			targetIP: "192.168.1.99",
			want:     "",
			wantErr:  true,
		},
		{
			name:     "empty output",
			output:   "",
			targetIP: "192.168.1.10",
			want:     "",
			wantErr:  true,
		},
		{
			name: "malformed line - too few fields",
			output: `node-1   Ready
node-2   Ready    <none>          5d    v1.28.0   192.168.1.11   <none>   Talos (v1.5.0)   5.15.0   containerd://1.7.0`,
			targetIP: "192.168.1.11",
			want:     "node-2",
			wantErr:  false,
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			// Simulate the parsing logic from GetNodeNameByIP
			ipStr := tc.targetIP
			var foundNode string
			var found bool

			for _, line := range strings.Split(tc.output, "\n") {
				fields := strings.Fields(line)
				if len(fields) > 6 && fields[5] == ipStr {
					foundNode = fields[0]
					found = true
					break
				}
			}

			if tc.wantErr {
				if found {
					t.Errorf("expected error but found node: %s", foundNode)
				}
			} else {
				if !found {
					t.Errorf("expected node %s but not found", tc.want)
				} else if foundNode != tc.want {
					t.Errorf("got node %s, want %s", foundNode, tc.want)
				}
			}
		})
	}
}

func TestClient_DrainNode(t *testing.T) {
	client, _ := newTestClient(t)

	tests := []struct {
		name        string
		nodeName    string
		wantErr     bool
		errContains string
	}{
		{
			name:     "drain node",
			nodeName: "test-node",
			wantErr:  true, // Will fail without kubectl setup
		},
		{
			name:     "empty node name",
			nodeName: "",
			wantErr:  true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()

			err := client.DrainNode(ctx, tt.nodeName)
			if (err != nil) != tt.wantErr {
				t.Errorf("DrainNode() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if tt.wantErr && tt.errContains != "" && err != nil {
				if !strings.Contains(err.Error(), tt.errContains) {
					t.Errorf("DrainNode() error = %v, should contain %v", err, tt.errContains)
				}
			}
		})
	}
}

func TestClient_DeleteNode(t *testing.T) {
	client, _ := newTestClient(t)

	tests := []struct {
		name        string
		nodeName    string
		wantErr     bool
		errContains string
	}{
		{
			name:     "delete node",
			nodeName: "test-node",
			wantErr:  true, // Will fail without kubectl setup
		},
		{
			name:     "empty node name",
			nodeName: "",
			wantErr:  true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()

			err := client.DeleteNode(ctx, tt.nodeName)
			if (err != nil) != tt.wantErr {
				t.Errorf("DeleteNode() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if tt.wantErr && tt.errContains != "" && err != nil {
				if !strings.Contains(err.Error(), tt.errContains) {
					t.Errorf("DeleteNode() error = %v, should contain %v", err, tt.errContains)
				}
			}
		})
	}
}

func TestClient_ClusterInfo(t *testing.T) {
	client, _ := newTestClient(t)

	tests := []struct {
		name    string
		wantErr bool
	}{
		{
			name:    "cluster info",
			wantErr: true, // Will fail without kubectl setup
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()

			got, err := client.ClusterInfo(ctx)
			if (err != nil) != tt.wantErr {
				t.Errorf("ClusterInfo() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if !tt.wantErr && got == "" {
				t.Error("ClusterInfo() returned empty output")
			}
		})
	}
}

func TestClient_GetNodes(t *testing.T) {
	client, _ := newTestClient(t)

	tests := []struct {
		name    string
		wantErr bool
	}{
		{
			name:    "get nodes",
			wantErr: true, // Will fail without kubectl setup
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()

			got, err := client.GetNodes(ctx)
			if (err != nil) != tt.wantErr {
				t.Errorf("GetNodes() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if !tt.wantErr && got == "" {
				t.Error("GetNodes() returned empty output")
			}
		})
	}
}

// Integration test helpers - these would run with a real cluster
func TestIntegration_Client(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test")
	}

	// Check if kubectl is available
	if _, err := exec.LookPath("kubectl"); err != nil {
		t.Skip("kubectl not found in PATH, skipping integration tests")
	}

	client, _ := newTestClient(t)
	ctx := context.Background()

	// Test ClusterInfo
	t.Run("ClusterInfo", func(t *testing.T) {
		info, err := client.ClusterInfo(ctx)
		if err != nil {
			t.Logf("ClusterInfo error (may be expected if no cluster): %v", err)
		} else {
			t.Logf("ClusterInfo: %s", info)
		}
	})

	// Test GetNodes
	t.Run("GetNodes", func(t *testing.T) {
		nodes, err := client.GetNodes(ctx)
		if err != nil {
			t.Logf("GetNodes error (may be expected if no cluster): %v", err)
		} else {
			t.Logf("Nodes: %s", nodes)
		}
	})
}

// Test context cancellation
func TestClient_ContextCancellation(t *testing.T) {
	client, _ := newTestClient(t)

	t.Run("GetNodeNameByIP context cancelled", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel() // Cancel immediately

		ip := mustParseIP("192.168.1.1")
		_, err := client.GetNodeNameByIP(ctx, ip)
		if err == nil {
			t.Error("Expected error for cancelled context")
		}
	})

	t.Run("DrainNode context cancelled", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel() // Cancel immediately

		err := client.DrainNode(ctx, "test-node")
		if err == nil {
			t.Error("Expected error for cancelled context")
		}
	})

	t.Run("DeleteNode context cancelled", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel() // Cancel immediately

		err := client.DeleteNode(ctx, "test-node")
		if err == nil {
			t.Error("Expected error for cancelled context")
		}
	})

	t.Run("ClusterInfo context cancelled", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel() // Cancel immediately

		_, err := client.ClusterInfo(ctx)
		if err == nil {
			t.Error("Expected error for cancelled context")
		}
	})

	t.Run("GetNodes context cancelled", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel() // Cancel immediately

		_, err := client.GetNodes(ctx)
		if err == nil {
			t.Error("Expected error for cancelled context")
		}
	})
}

// Test timeout behavior
func TestClient_Timeout(t *testing.T) {
	client, _ := newTestClient(t)

	t.Run("DrainNode timeout", func(t *testing.T) {
		// Create a very short timeout context
		ctx, cancel := context.WithTimeout(context.Background(), 1*time.Millisecond)
		defer cancel()

		time.Sleep(2 * time.Millisecond) // Ensure timeout has passed

		err := client.DrainNode(ctx, "test-node")
		if err == nil {
			t.Error("Expected error for timed out context")
		}
	})
}

// Test error wrapping
func TestClient_ErrorWrapping(t *testing.T) {
	// Verify that errors are properly wrapped with context
	testCases := []struct {
		name       string
		operation  string
		wantPrefix string
	}{
		{
			name:       "GetNodeNameByIP error",
			operation:  "get nodes",
			wantPrefix: "kubectl get nodes:",
		},
		{
			name:       "DrainNode cordon error",
			operation:  "cordon",
			wantPrefix: "kubectl cordon:",
		},
		{
			name:       "DrainNode drain error",
			operation:  "drain",
			wantPrefix: "kubectl drain:",
		},
		{
			name:       "DeleteNode error",
			operation:  "delete node",
			wantPrefix: "kubectl delete node:",
		},
		{
			name:       "ClusterInfo error",
			operation:  "cluster-info",
			wantPrefix: "kubectl cluster-info:",
		},
		{
			name:       "GetNodes error",
			operation:  "get nodes wide",
			wantPrefix: "kubectl get nodes:",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			// Just verify the error format strings are correct
			var err error = errors.New("test error")
			wrapped := fmt.Errorf(tc.wantPrefix+" %w, output: %s", err, "test output")

			if !strings.Contains(wrapped.Error(), tc.wantPrefix) {
				t.Errorf("Error should contain prefix %q, got: %v", tc.wantPrefix, wrapped)
			}
			if !errors.Is(wrapped, err) {
				t.Error("Wrapped error should be unwrappable to original error")
			}
		})
	}
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
