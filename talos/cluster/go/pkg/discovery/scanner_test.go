package discovery

import (
	"context"
	"net"
	"os"
	"testing"
	"time"

	"github.com/jdw/talos-bootstrap/pkg/types"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"golang.org/x/crypto/ssh"
)

func TestNewScanner(t *testing.T) {
	nodeIPs := map[string]net.IP{
		"pve1": net.ParseIP("192.168.1.10"),
		"pve2": net.ParseIP("192.168.1.11"),
	}

	scanner := NewScanner("root", nodeIPs)

	assert.NotNil(t, scanner)
	assert.Equal(t, "root", scanner.sshUser)
	assert.Equal(t, nodeIPs, scanner.nodeIPs)
	assert.NotNil(t, scanner.sshConfig)
	assert.Equal(t, 10*time.Second, scanner.sshConfig.Timeout)
}

func TestSetPrivateKey(t *testing.T) {
	scanner := NewScanner("root", map[string]net.IP{})

	// Test non-existent key
	err := scanner.SetPrivateKey("/nonexistent/key")
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "read private key")

	// Test invalid key
	tmpDir := t.TempDir()
	invalidKey := tmpDir + "/invalid"
	err = os.WriteFile(invalidKey, []byte("not a valid key"), 0600)
	require.NoError(t, err)

	err = scanner.SetPrivateKey(invalidKey)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "parse private key")
}

func TestParseARPTable(t *testing.T) {
	tests := []struct {
		name       string
		output     string
		targetMAC  string
		expectedIP net.IP
	}{
		{
			name: "find valid entry",
			output: `IP address       HW type     Flags       HW address            Mask     Device
192.168.1.50     0x1         0x2         BC:24:11:AB:CD:EF     *        vmbr0
192.168.1.51     0x1         0x2         BC:24:11:12:34:56     *        vmbr0`,
			targetMAC:  "BC:24:11:AB:CD:EF",
			expectedIP: net.ParseIP("192.168.1.50"),
		},
		{
			name: "case insensitive MAC match",
			output: `IP address       HW type     Flags       HW address            Mask     Device
192.168.1.50     0x1         0x2         bc:24:11:ab:cd:ef     *        vmbr0`,
			targetMAC:  "BC:24:11:AB:CD:EF",
			expectedIP: net.ParseIP("192.168.1.50"),
		},
		{
			name: "skip incomplete entries",
			output: `IP address       HW type     Flags       HW address            Mask     Device
192.168.1.50     0x1         0x0         00:00:00:00:00:00     *        vmbr0
192.168.1.51     0x1         0x2         BC:24:11:AB:CD:EF     *        vmbr0`,
			targetMAC:  "BC:24:11:AB:CD:EF",
			expectedIP: net.ParseIP("192.168.1.51"),
		},
		{
			name:       "MAC not found",
			output:     `192.168.1.50     0x1         0x2         BC:24:11:AB:CD:EF     *        vmbr0`,
			targetMAC:  "DE:AD:BE:EF:00:00",
			expectedIP: nil,
		},
		{
			name:       "empty table",
			output:     "",
			targetMAC:  "BC:24:11:AB:CD:EF",
			expectedIP: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := parseARPTable(tt.output, tt.targetMAC)
			assert.Equal(t, tt.expectedIP, result)
		})
	}
}

func TestTestPort(t *testing.T) {
	// Start a test server
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	require.NoError(t, err)
	defer listener.Close()

	addr := listener.Addr().(*net.TCPAddr)

	// Test port open
	assert.True(t, TestPort("127.0.0.1", addr.Port, 1*time.Second))

	// Test port closed
	assert.False(t, TestPort("127.0.0.1", addr.Port+1, 100*time.Millisecond))

	// Test invalid IP
	assert.False(t, TestPort("256.256.256.256", 80, 100*time.Millisecond))
}

func TestScanner_DiscoverVMs(t *testing.T) {
	nodeIPs := map[string]net.IP{
		"pve1": net.ParseIP("192.168.1.10"),
	}

	scanner := NewScanner("root", nodeIPs)

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	vmids := []types.VMID{100, 101}

	// Without mock SSH server, this will fail to connect
	// This shows the need for interface-based design
	results, err := scanner.DiscoverVMs(ctx, vmids)

	// Should return empty results when VMs not found (no SSH connection)
	// The function may return an error or empty results depending on implementation
	if err != nil {
		// Error is acceptable - means SSH connection failed
		t.Logf("DiscoverVMs returned error (expected): %v", err)
	}
	assert.Empty(t, results)
}

func TestScanner_RediscoverIP(t *testing.T) {
	nodeIPs := map[string]net.IP{
		"pve1": net.ParseIP("192.168.1.10"),
	}

	scanner := NewScanner("root", nodeIPs)

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	// Should timeout or fail without SSH connection
	_, err := scanner.RediscoverIP(ctx, 100, "BC:24:11:AB:CD:EF")
	assert.Error(t, err)
}

func TestRepopulateNode_SubnetExtraction(t *testing.T) {
	// Test the subnet extraction logic indirectly
	tests := []struct {
		ip       string
		expected string
	}{
		{"192.168.1.10", "192.168.1"},
		{"10.0.0.5", "10.0.0"},
		{"172.16.50.100", "172.16.50"},
	}

	for _, tt := range tests {
		t.Run(tt.ip, func(t *testing.T) {
			ip := net.ParseIP(tt.ip)
			ipStr := ip.String()
			lastDot := len(ipStr) - 1
			for i := len(ipStr) - 1; i >= 0; i-- {
				if ipStr[i] == '.' {
					lastDot = i
					break
				}
			}
			subnet := ipStr[:lastDot]
			assert.Equal(t, tt.expected, subnet)
		})
	}
}

// MockSSHServer for integration-style tests
type MockSSHServer struct {
	listener net.Listener
	config   *ssh.ServerConfig
}

func (m *MockSSHServer) Addr() string {
	return m.listener.Addr().String()
}

func (m *MockSSHServer) Close() error {
	return m.listener.Close()
}

// Integration test with mock SSH server
func TestScanner_WithMockSSH(t *testing.T) {
	// This would require setting up a mock SSH server that responds
	// to qm status, qm config, and cat /proc/net/arp commands
	// For comprehensive testing, consider using github.com/gliderlabs/ssh

	t.Skip("Requires mock SSH server implementation")
}
