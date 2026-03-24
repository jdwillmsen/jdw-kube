package haproxy

import (
	"context"
	"encoding/base64"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"time"

	"go.uber.org/zap"
	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
)

func base64Encode(s string) string {
	return base64.StdEncoding.EncodeToString([]byte(s))
}

// sshRunner defines the interface for SSH operations
type sshRunner interface {
	runSSH(cmd string) error
}

// Client manages HAProxy configuration via SSH
type Client struct {
	sshUser   string
	sshHost   string
	sshPort   string
	sshConfig *ssh.ClientConfig
	logger    *zap.Logger
	runner    sshRunner // injectable for testing
}

// NewClient creates a new HAProxy SSH client.
// If insecureSSH is false, host keys are verified against ~/.ssh/known_hosts.
func NewClient(sshUser, sshHost string, logger *zap.Logger, insecureSSH bool) *Client {
	hostKeyCallback := knownHostsCallback(insecureSSH)

	c := &Client{
		sshUser: sshUser,
		sshHost: sshHost,
		sshPort: "22",
		logger:  logger,
		sshConfig: &ssh.ClientConfig{
			User:            sshUser,
			HostKeyCallback: hostKeyCallback,
			Timeout:         10 * time.Second,
		},
	}
	c.runner = c // default runner is self
	return c
}

// SetPrivateKey configures SSH public key authentication
func (c *Client) SetPrivateKey(keyPath string) error {
	key, err := os.ReadFile(keyPath)
	if err != nil {
		return fmt.Errorf("read private key: %w", err)
	}

	signer, err := ssh.ParsePrivateKey(key)
	if err != nil {
		return fmt.Errorf("parse private key: %w", err)
	}

	c.sshConfig.Auth = []ssh.AuthMethod{ssh.PublicKeys(signer)}
	return nil
}

// SetPort allows overriding the default SSH port (for testing)
func (c *Client) SetPort(port string) {
	c.sshPort = port
}

// Update writes a new HAProxy configuration, validates it, and reloads the service.
// On validation failure, it automatically rolls back to the previous config.
func (c *Client) Update(ctx context.Context, config string) error {
	timestamp := time.Now().Format("20060102-150405")

	c.logger.Info("updating HAProxy configuration",
		zap.String("host", c.sshHost),
		zap.String("backup_suffix", timestamp))

	// 1. Write new config to temp location using base64 to avoid heredoc injection
	encoded := base64Encode(config)
	writeCmd := fmt.Sprintf("echo '%s' | base64 -d > /tmp/haproxy.cfg.new", encoded)
	if err := c.runner.runSSH(writeCmd); err != nil {
		return fmt.Errorf("write temp config: %w", err)
	}

	// 2. Backup existing config
	backupCmd := fmt.Sprintf("sudo cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.backup.%s", timestamp)
	if err := c.runner.runSSH(backupCmd); err != nil {
		c.logger.Warn("failed to backup existing config (may not exist yet)", zap.Error(err))
	}

	// 3. Install new config
	if err := c.runner.runSSH("sudo mv /tmp/haproxy.cfg.new /etc/haproxy/haproxy.cfg"); err != nil {
		return fmt.Errorf("install config: %w", err)
	}

	// 4. Validate config
	if err := c.runner.runSSH("sudo haproxy -c -f /etc/haproxy/haproxy.cfg"); err != nil {
		c.logger.Error("HAProxy config validation failed, rolling back", zap.Error(err))
		rollbackCmd := fmt.Sprintf("sudo cp /etc/haproxy/haproxy.cfg.backup.%s /etc/haproxy/haproxy.cfg", timestamp)
		if rollbackErr := c.runner.runSSH(rollbackCmd); rollbackErr != nil {
			return fmt.Errorf("config validation failed and rollback also failed: validation=%w, rollback=%v", err, rollbackErr)
		}
		return fmt.Errorf("config validation failed (rolled back): %w", err)
	}

	// 5. Reload HAProxy
	if err := c.runner.runSSH("sudo systemctl reload haproxy"); err != nil {
		return fmt.Errorf("reload HAProxy: %w", err)
	}

	c.logger.Info("HAProxy configuration updated and reloaded successfully")
	return nil
}

// Validate checks if HAProxy is currently running and healthy
func (c *Client) Validate(ctx context.Context) error {
	return c.runner.runSSH("sudo systemctl is-active haproxy")
}

func (c *Client) runSSH(cmd string) error {
	addr := net.JoinHostPort(c.sshHost, c.sshPort)
	conn, err := ssh.Dial("tcp", addr, c.sshConfig)
	if err != nil {
		return fmt.Errorf("dial SSH: %w", err)
	}
	defer conn.Close()

	session, err := conn.NewSession()
	if err != nil {
		return fmt.Errorf("create SSH session: %w", err)
	}
	defer session.Close()

	output, err := session.CombinedOutput(cmd)
	if err != nil {
		return fmt.Errorf("run SSH command: %w, output: %s", err, string(output))
	}

	return nil
}

// knownHostsCallback returns an ssh.HostKeyCallback. When insecure is true,
// all host keys are accepted. Otherwise, keys are verified against the user's
// ~/.ssh/known_hosts file. If that file is missing or unreadable, connections
// are rejected with a hint to either populate known_hosts or use --insecure-ssh.
func knownHostsCallback(insecure bool) ssh.HostKeyCallback {
	if insecure {
		return ssh.InsecureIgnoreHostKey()
	}

	home, err := os.UserHomeDir()
	if err == nil {
		khPath := filepath.Join(home, ".ssh", "known_hosts")
		if cb, err := knownhosts.New(khPath); err == nil {
			return cb
		}
	}

	return func(hostname string, remote net.Addr, key ssh.PublicKey) error {
		return fmt.Errorf("SSH host key verification failed for %s: add host keys with ssh-keyscan or use --insecure-ssh", hostname)
	}
}
