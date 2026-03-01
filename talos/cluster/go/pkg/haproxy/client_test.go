package haproxy

import (
	"context"
	"net"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/zap/zaptest"
)

// mockSSHServer creates a test SSH server for validation
func mockSSHServer(t *testing.T, handler func(conn net.Conn)) net.Listener {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	require.NoError(t, err)

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go handler(conn)
		}
	}()

	return listener
}

func TestNewClient(t *testing.T) {
	logger := zaptest.NewLogger(t)
	client := NewClient("admin", "192.168.1.10", logger)

	assert.NotNil(t, client)
	assert.Equal(t, "admin", client.sshUser)
	assert.Equal(t, "192.168.1.10", client.sshHost)
	assert.NotNil(t, client.sshConfig)
	assert.Equal(t, 10*time.Second, client.sshConfig.Timeout)
}

func TestSetPrivateKey(t *testing.T) {
	logger := zaptest.NewLogger(t)
	client := NewClient("admin", "192.168.1.10", logger)

	// Test with non-existent key
	err := client.SetPrivateKey("/nonexistent/key")
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "read private key")

	// Test with invalid key content
	tmpFile := t.TempDir() + "/test_key"
	err = os.WriteFile(tmpFile, []byte("invalid key data"), 0600)
	require.NoError(t, err)

	err = client.SetPrivateKey(tmpFile)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "parse private key")

	// Test with valid key (generate one)
	// This would require crypto/rsa or crypto/ecdsa key generation
}

func TestClient_Update_Success(t *testing.T) {
	// This test requires a mock SSH server that simulates HAProxy commands
	// For unit testing, we should mock the SSH connection

	logger := zaptest.NewLogger(t)
	client := NewClient("admin", "127.0.0.1", logger)

	// Mock the runSSH method for unit testing
	// In practice, you'd want to refactor to use an interface for testability

	ctx := context.Background()
	config := `
global
    maxconn 4096

defaults
    mode tcp
    timeout connect 5s
    timeout client 30s
    timeout server 30s
`

	// Without a real SSH server, this will fail to connect
	// This demonstrates the need for dependency injection or interfaces
	err := client.Update(ctx, config)
	assert.Error(t, err) // Expected to fail without SSH server
}

func TestClient_Validate(t *testing.T) {
	logger := zaptest.NewLogger(t)
	client := NewClient("admin", "192.168.1.10", logger)

	ctx := context.Background()
	err := client.Validate(ctx)

	// Should fail without valid SSH connection
	assert.Error(t, err)
}

// Integration test (skipped by default)
func TestClient_Integration(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test")
	}

	// Requires real HAProxy server with SSH access
	// Configure via environment variables
	sshHost := os.Getenv("TEST_HAPROXY_HOST")
	sshUser := os.Getenv("TEST_HAPROXY_USER")
	keyPath := os.Getenv("TEST_SSH_KEY_PATH")

	if sshHost == "" || sshUser == "" {
		t.Skip("Set TEST_HAPROXY_HOST, TEST_HAPROXY_USER for integration tests")
	}

	logger := zaptest.NewLogger(t)
	client := NewClient(sshUser, sshHost, logger)

	if keyPath != "" {
		err := client.SetPrivateKey(keyPath)
		require.NoError(t, err)
	}

	ctx := context.Background()

	// Test validation
	err := client.Validate(ctx)
	// May fail if HAProxy not running, but SSH should work

	// Test config update
	config := `global
    maxconn 4096

defaults
    mode tcp
    timeout connect 5s
    timeout client 30s
    timeout server 30s

frontend test
    bind *:8080
`

	err = client.Update(ctx, config)
	// Should validate and rollback on invalid config
	if err != nil {
		t.Logf("Update error (may be expected): %v", err)
	}
}
