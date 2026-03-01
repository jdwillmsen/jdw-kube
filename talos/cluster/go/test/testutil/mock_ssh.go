package testutil

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"net"
	"os"
	"sync"
	"testing"

	"golang.org/x/crypto/ssh"
)

// MockSSHServer provides a test SSH server for unit tests
type MockSSHServer struct {
	Listener net.Listener
	Config   *ssh.ServerConfig
	Commands map[string]string // command -> response
	mu       sync.RWMutex
	executed []string // history of executed commands
}

// NewMockSSHServer creates a test SSH server with key auth
func NewMockSSHServer(t *testing.T) (*MockSSHServer, error) {
	// Generate test host key
	hostKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, fmt.Errorf("generate host key: %w", err)
	}

	hostSigner, err := ssh.NewSignerFromKey(hostKey)
	if err != nil {
		return nil, fmt.Errorf("create host signer: %w", err)
	}

	mock := &MockSSHServer{
		Commands: make(map[string]string),
		executed: make([]string, 0),
	}

	mock.Config = &ssh.ServerConfig{
		NoClientAuth: true, // Simplify testing
	}
	mock.Config.AddHostKey(hostSigner)

	mock.Listener, err = net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, fmt.Errorf("listen: %w", err)
	}

	go mock.serve(t)

	return mock, nil
}

// Addr returns the server address
func (m *MockSSHServer) Addr() string {
	return m.Listener.Addr().String()
}

// Host returns just the host (IP) without port
func (m *MockSSHServer) Host() string {
	host, _, _ := net.SplitHostPort(m.Addr())
	return host
}

// Port returns the port number
func (m *MockSSHServer) Port() string {
	_, port, _ := net.SplitHostPort(m.Addr())
	return port
}

// SetCommandResponse configures a response for a command
func (m *MockSSHServer) SetCommandResponse(cmd, response string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.Commands[cmd] = response
}

// GetExecutedCommands returns the list of executed commands
func (m *MockSSHServer) GetExecutedCommands() []string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	result := make([]string, len(m.executed))
	copy(result, m.executed)
	return result
}

// Close shuts down the server
func (m *MockSSHServer) Close() error {
	return m.Listener.Close()
}

func (m *MockSSHServer) serve(t *testing.T) {
	for {
		conn, err := m.Listener.Accept()
		if err != nil {
			return
		}

		go m.handleConn(conn)
	}
}

func (m *MockSSHServer) handleConn(conn net.Conn) {
	defer conn.Close()

	sshConn, chans, reqs, err := ssh.NewServerConn(conn, m.Config)
	if err != nil {
		return
	}
	defer sshConn.Close()

	// Discard global requests
	go ssh.DiscardRequests(reqs)

	// Handle channels
	for newChannel := range chans {
		if newChannel.ChannelType() != "session" {
			newChannel.Reject(ssh.UnknownChannelType, "unknown channel type")
			continue
		}

		channel, requests, err := newChannel.Accept()
		if err != nil {
			continue
		}

		go m.handleChannel(channel, requests)
	}
}

func (m *MockSSHServer) handleChannel(channel ssh.Channel, requests <-chan *ssh.Request) {
	defer channel.Close()

	var cmd string

	for req := range requests {
		switch req.Type {
		case "exec":
			// Parse command from payload
			cmdLen := int(req.Payload[3]) // Skip type byte and length
			cmd = string(req.Payload[4 : 4+cmdLen])

			m.mu.Lock()
			m.executed = append(m.executed, cmd)
			response, ok := m.Commands[cmd]
			m.mu.Unlock()

			if ok {
				channel.Write([]byte(response))
				req.Reply(true, nil)
				channel.SendRequest("exit-status", false, []byte{0, 0, 0, 0})
			} else {
				// Default: success with no output
				req.Reply(true, nil)
				channel.SendRequest("exit-status", false, []byte{0, 0, 0, 0})
			}
			return

		case "shell", "pty-req":
			req.Reply(true, nil)
		default:
			req.Reply(false, nil)
		}
	}
}

// GenerateTestPrivateKey creates a temporary private key file for testing
func GenerateTestPrivateKey(t *testing.T) (string, ssh.Signer) {
	tmpDir := t.TempDir()
	keyPath := tmpDir + "/test_key"

	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}

	// Encode private key to PEM
	privateKeyPEM := &pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(privateKey),
	}

	keyFile, err := os.OpenFile(keyPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		t.Fatalf("create key file: %v", err)
	}
	defer keyFile.Close()

	if err := pem.Encode(keyFile, privateKeyPEM); err != nil {
		t.Fatalf("encode key: %v", err)
	}

	signer, err := ssh.NewSignerFromKey(privateKey)
	if err != nil {
		t.Fatalf("create signer: %v", err)
	}

	return keyPath, signer
}
