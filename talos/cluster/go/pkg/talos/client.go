package talos

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/jdw/talos-bootstrap/pkg/logging"
	"github.com/jdw/talos-bootstrap/pkg/types"
	"github.com/siderolabs/talos/pkg/machinery/api/machine"
	"github.com/siderolabs/talos/pkg/machinery/client"
	"github.com/siderolabs/talos/pkg/machinery/client/config"
	"go.uber.org/zap"
)

type Client struct {
	config      *types.Config
	talosConfig *config.Config
	ctxName     string
	audit       *logging.AuditLogger
	logger      *zap.Logger
}

// SetLogger attaches a structured logger. Falls back to fmt if nil.
func (c *Client) SetLogger(logger *zap.Logger) {
	c.logger = logger
}

func NewClient(cfg *types.Config) *Client {
	return &Client{config: cfg}
}

// SetAuditLogger attaches an audit logger for command tracking
func (c *Client) SetAuditLogger(audit *logging.AuditLogger) {
	c.audit = audit
}

func (c *Client) Initialize(ctx context.Context) error {
	talosConfigPath := filepath.Join(c.config.SecretsDir, "talosconfig")

	if _, err := os.Stat(talosConfigPath); os.IsNotExist(err) {
		// Auto-generate secrets and base configs
		nc := NewNodeConfig(c.config)
		if c.audit != nil {
			nc.SetAuditLogger(c.audit)
		}
		if err := nc.GenerateBaseConfigs(); err != nil {
			return fmt.Errorf("generate base configs: %w", err)
		}
	}

	talosCfg, err := config.Open(talosConfigPath)
	if err != nil {
		return fmt.Errorf("failed to load talosconfig: %w", err)
	}

	c.talosConfig = talosCfg
	c.ctxName = talosCfg.Context
	return nil
}

func (c *Client) getClient(ctx context.Context, endpoint net.IP, insecure bool) (*client.Client, error) {
	if c.talosConfig == nil {
		return nil, fmt.Errorf("client not initialized")
	}

	opts := []client.OptionFunc{
		client.WithEndpoints(endpoint.String()),
	}

	if insecure {
		// For maintenance mode: use WithTLSConfig to skip server cert verification.
		// We must NOT load the talosconfig (WithConfig) here because the Talos client
		// library builds its own TLS credentials from the config context and appends
		// grpc.WithTransportCredentaisl AFTER our dial options, overriding InsecureSkipVerify
		opts = append(opts, client.WithTLSConfig(&tls.Config{
			InsecureSkipVerify: true,
		}))
	} else {
		opts = append(opts, client.WithConfig(c.talosConfig))
	}

	return client.New(ctx, opts...)
}

func (c *Client) ApplyConfig(ctx context.Context, ip net.IP, configPath string, insecure bool) error {
	configData, err := os.ReadFile(configPath)
	if err != nil {
		return fmt.Errorf("failed to read config file: %w", err)
	}

	tc, err := c.getClient(ctx, ip, insecure)
	if err != nil {
		return fmt.Errorf("failed to create talos client: %w", err)
	}
	defer tc.Close()

	mode := machine.ApplyConfigurationRequest_AUTO
	if insecure {
		mode = machine.ApplyConfigurationRequest_REBOOT
	}

	resp, err := tc.ApplyConfiguration(ctx, &machine.ApplyConfigurationRequest{
		Data: configData,
		Mode: mode,
	})
	if err != nil {
		return fmt.Errorf("failed to apply configuration: %w", err)
	}

	if len(resp.Messages) > 0 && len(resp.Messages[0].Warnings) > 0 {
		for _, warning := range resp.Messages[0].Warnings {
			if c.logger != nil {
				c.logger.Warn("talos apply-config warning", zap.String("reason", warning))
			}
		}
	}

	return nil
}

// ApplyConfigWithRetry applies configuration with intelligent retry logic.
// The role parameter is used to determine readiness checks (e.g., etcd for control planes).
func (c *Client) ApplyConfigWithRetry(ctx context.Context, ip net.IP, configPath string, role types.Role, maxAttempts int) error {
	if maxAttempts <= 0 {
		maxAttempts = 5
	}

	var lastErr error
	insecure := true

	for attempt := 1; attempt <= maxAttempts; attempt++ {
		err := c.ApplyConfig(ctx, ip, configPath, insecure)

		if err == nil {
			return nil
		}

		lastErr = err
		talosErr := ParseTalosError(err)

		switch talosErr.Code {
		case ErrAlreadyConfigured:
			ready, checkErr := c.checkReadyByIP(ctx, ip, role)
			if checkErr == nil && ready {
				// Node is configured and ready, this is success
				return nil
			}

		case ErrCertificateRequired:
			if insecure {
				// Node has existing TLS config - switch to secure mode using our talosconfig certs
				insecure = false
				if c.logger != nil {
					c.logger.Warn("node has existing TLS config, switching to secure mode",
						zap.String("ip", ip.String()), zap.Int("attempt", attempt))
				}
				continue
			}
			// Secure mode also failed - node has certs from a different CA (previous run).
			// Check if the node is actually configured and healthy before giving up.
			if c.logger != nil {
				c.logger.Warn("TLS cert mismatch, checking if node is already configured and ready",
					zap.String("ip", ip.String()), zap.Int("attempt", attempt))
			}
			ready, checkErr := c.checkReadyByIP(ctx, ip, role)
			if checkErr == nil && ready {
				if c.logger != nil {
					c.logger.Info("node is already configured and ready, treating as success",
						zap.String("ip", ip.String()), zap.Int("attempt", attempt))
				}
				return nil
			}
			if c.logger != nil {
				c.logger.Error("TLS cert mismatch and node not ready - node has stale config from a previous run. Reset the node with `talosctl reset` or reinstall Talos",
					zap.String("ip", ip.String()), zap.Int("attempt", attempt))
			}
			return fmt.Errorf("certificate mismatch on %s: node has config from a different CA and is not ready - reset the node or reinstall Talos: %w", ip, err)

		case ErrConnectionRefused, ErrConnectionTimeout, ErrMaintenanceMode, ErrNodeNotReady:
			if attempt < maxAttempts {
				waitTime := time.Duration(attempt*5) * time.Second
				if talosErr.Code == ErrConnectionTimeout {
					waitTime = time.Duration(attempt*10) * time.Second
				}
				if c.logger != nil {
					c.logger.Warn("talos config attempt failed, retrying",
						zap.Int("attempt", attempt), zap.Int("max", maxAttempts),
						zap.Duration("wait", waitTime), zap.Error(err))
				}
				time.Sleep(waitTime)
				continue
			}

		case ErrPermissionDenied:
			return fmt.Errorf("permission denied: %w", err)

		default:
			if attempt < maxAttempts && talosErr.IsRetryable() {
				waitTime := time.Duration(attempt*5) * time.Second
				if c.logger != nil {
					c.logger.Warn("apply config retryable error",
						zap.Int("attempt", attempt), zap.Int("max", maxAttempts),
						zap.Duration("wait", waitTime), zap.Error(err))
				}
				time.Sleep(waitTime)
				continue
			}
		}

		if attempt >= maxAttempts {
			break
		}

		// Standard backoff for unhanded cases (ErrAlreadyConfigured that isn't ready)
		time.Sleep(time.Duration(attempt*5) * time.Second)
	}

	return fmt.Errorf("failed after %d attempts: %w", maxAttempts, lastErr)
}

// checkReady is a helper that works with an IP instead of requiring a client
func (c *Client) checkReadyByIP(ctx context.Context, ip net.IP, role types.Role) (bool, error) {
	tc, err := c.getClient(ctx, ip, false)
	if err != nil {
		// Try insecure mode if secure connection fails
		tc, err = c.getClient(ctx, ip, true)
		if err != nil {
			return false, err
		}
	}
	defer tc.Close()

	return c.checkReady(ctx, tc, role)
}

func (c *Client) BootstrapEtcd(ctx context.Context, ip net.IP) error {
	tc, err := c.getClient(ctx, ip, false)
	if err != nil {
		return fmt.Errorf("failed to create talos client: %w", err)
	}
	defer tc.Close()

	if err := tc.Bootstrap(ctx, &machine.BootstrapRequest{}); err != nil {
		talosErr := ParseTalosError(err)
		if talosErr != nil && talosErr.Code == ErrAlreadyBootstrapped {
			// Already bootstrapped is success
			return nil
		}
		return fmt.Errorf("failed to bootstrap etcd: %w", err)
	}

	return nil
}

// WaitForEtcdHealthy polls etcd member list until members are present and healthy
func (c *Client) WaitForEtcdHealthy(ctx context.Context, ip net.IP, maxWait time.Duration) error {
	ctx, cancel := context.WithTimeout(ctx, maxWait)
	defer cancel()

	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return fmt.Errorf("timeout waiting for etcd to become healthy on %s", ip)
		case <-ticker.C:
			members, err := c.GetEtcdMembers(ctx, ip)
			if err != nil {
				continue
			}
			if len(members) > 0 {
				return nil
			}
		}
	}
}

// WaitForAPI polls until the Talos API responds to a Version() call.
// This is the minimum check needed after config apply + reboot - it confirms the
// node is up and the API is reachable, without requiring etcd or kubelet.
func (c *Client) WaitForAPI(ctx context.Context, ip net.IP) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()

	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	insecure := true
	switchToSecure := false

	for {
		select {
		case <-ctx.Done():
			return fmt.Errorf("timeout waiting for api to become healthy on %s", ip)
		case <-ticker.C:
			tc, err := c.getClient(ctx, ip, insecure)
			if err != nil {
				continue
			}

			_, err = tc.Version(ctx)
			tc.Close()

			if err == nil {
				return nil
			}

			// Switch to secure mode once after first failed attempt
			if insecure && !switchToSecure {
				insecure = false
				switchToSecure = true
			}
		}
	}
}

func (c *Client) WaitForReady(ctx context.Context, ip net.IP, role types.Role) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()

	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	// Start in secure mode - this is caleld after the node is configured and API-responsive.
	// The insecure fallback is only needed if the secure conenction fails (e.g. during early boot).
	insecure := false
	triedInsecure := false
	var tc *client.Client
	var err error

	for {
		select {
		case <-ctx.Done():
			if tc != nil {
				tc.Close()
			}
			return fmt.Errorf("timeout waiting for node %s to be ready", ip)
		case <-ticker.C:
			if tc == nil {
				tc, err = c.getClient(ctx, ip, insecure)
				if err != nil {
					// If secure fails, try insecure once (node may still be in early boot)
					if !insecure && !triedInsecure {
						insecure = true
						triedInsecure = true
					}
					continue
				}
			}

			ready, err := c.checkReady(ctx, tc, role)
			if err != nil {
				tc.Close()
				tc = nil

				// If secure fails, try insecure once
				if insecure && !triedInsecure {
					insecure = false
					triedInsecure = true
				}
				continue
			}

			if ready {
				tc.Close()
				return nil
			}
		}
	}
}

func (c *Client) checkReady(ctx context.Context, tc *client.Client, role types.Role) (bool, error) {
	if _, err := tc.Version(ctx); err != nil {
		// Workers in maintenance mode respond on port 50000 but Version() fails.
		// Treat maintenance-mode workers as ready - they can accept ApplyConfig.
		if role == types.RoleWorker && isMaintenanceModeError(err) {
			return true, nil
		}
		if c.logger != nil {
			c.logger.Debug("version check failed in readiness poll", zap.Error(err))
		}
		return false, err
	}

	if role == types.RoleControlPlane {
		_, err := tc.EtcdMemberList(ctx, &machine.EtcdMemberListRequest{})
		if err != nil {
			if c.logger != nil {
				c.logger.Debug("etcd member list not ready", zap.Error(err))
			}
			return false, nil
		}

		services, err := tc.ServiceList(ctx)
		if err != nil {
			if c.logger != nil {
				c.logger.Debug("service list not ready", zap.Error(err))
			}
			return false, nil
		}

		kubeletRunning := false
		for _, svc := range services.Messages {
			for _, s := range svc.Services {
				if s.Id == "kubelet" && s.State == "running" {
					kubeletRunning = true
					break
				}
			}
		}

		if !kubeletRunning {
			if c.logger != nil {
				c.logger.Debug("kubelet not running", zap.Error(err))
			}
			return false, nil
		}
	}

	return true, nil
}

// isMaintenanceModeError returns true when the gRPC error indicates Talos is in
// maintenance mode (listening but not fully initialised).
func isMaintenanceModeError(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "Unavailable") ||
		strings.Contains(msg, "maintenance") ||
		strings.Contains(msg, "unimplemented")
}

// EtcdMember represents a member in the etcd cluster
type EtcdMember struct {
	ID        uint64
	Hostname  string
	IsHealthy bool
}

// GetEtcdMembers uses the machine API EtcdMemberList method
func (c *Client) GetEtcdMembers(ctx context.Context, ip net.IP) ([]EtcdMember, error) {
	tc, err := c.getClient(ctx, ip, false)
	if err != nil {
		return nil, fmt.Errorf("failed to create talos client: %w", err)
	}
	defer tc.Close()

	resp, err := tc.EtcdMemberList(ctx, &machine.EtcdMemberListRequest{})
	if err != nil {
		return nil, fmt.Errorf("failed to get etcd members: %w", err)
	}

	if len(resp.Messages) == 0 {
		return nil, fmt.Errorf("no etcd members response")
	}

	members := make([]EtcdMember, 0, len(resp.Messages[0].Members))
	for _, member := range resp.Messages[0].Members {
		members = append(members, EtcdMember{
			ID:        member.Id,
			Hostname:  member.Hostname,
			IsHealthy: true, // Talos API only returns healthy members
		})
	}

	return members, nil
}

// GetClusterMembers returns the peer URLs/hostnames of all current etcd members.
// Used to mark live nodes with StatusJoined.
func (c *Client) GetClusterMembers(ctx context.Context, endpoint net.IP) ([]string, error) {
	members, err := c.GetEtcdMembers(ctx, endpoint)
	if err != nil {
		return nil, err
	}
	addrs := make([]string, 0, len(members))
	for _, m := range members {
		addrs = append(addrs, m.Hostname)
	}
	return addrs, nil
}

// ValidateRemovalQuorum checks if removing a control plane would violate the etcd quorum
func (c *Client) ValidateRemovalQuorum(ctx context.Context, endpoint net.IP, currentCPCount int) error {
	if currentCPCount <= 0 {
		return fmt.Errorf("invalid control plane count: %d", currentCPCount)
	}

	members, err := c.GetEtcdMembers(ctx, endpoint)
	if err != nil {
		return fmt.Errorf("failed to get etcd members for quorum validation: %w", err)
	}

	healthyCount := len(members)

	if healthyCount == 0 {
		return fmt.Errorf("no healthy etcd members found")
	}

	afterRemoval := healthyCount - 1
	minQuorum := (currentCPCount / 2) + 1

	if afterRemoval < 1 {
		return fmt.Errorf("cannot remove member: at least 1 healthy member is required")
	}

	if afterRemoval < minQuorum {
		return fmt.Errorf("cannot remove member: would violate etcd quorum (remaining healthy members: %d, required for quorum: %d)", afterRemoval, minQuorum)
	}

	return nil
}

// RemoveEtcdMember uses the machine API EtcdRemoveMemberByID method
func (c *Client) RemoveEtcdMember(ctx context.Context, endpoint net.IP, memberID uint64) error {
	tc, err := c.getClient(ctx, endpoint, false)
	if err != nil {
		return fmt.Errorf("failed to create talos client: %w", err)
	}
	defer tc.Close()

	// EtcdRemoveMemberByID returns only error, not (resp, error)
	if err := tc.EtcdRemoveMemberByID(ctx, &machine.EtcdRemoveMemberByIDRequest{
		MemberId: memberID,
	}); err != nil {
		return fmt.Errorf("failed to remove etcd member %d: %w", memberID, err)
	}

	return nil
}

// GetEtcdMemberIDByIP finds the etcd member ID for a given node IP.
// Matches against hostname and peer URLs for robust identification.
func (c *Client) GetEtcdMemberIDByIP(ctx context.Context, endpoint net.IP, nodeIP net.IP) (uint64, error) {
	tc, err := c.getClient(ctx, nodeIP, false)
	if err != nil {
		return 0, fmt.Errorf("failed to create talos client: %w", err)
	}
	defer tc.Close()

	resp, err := tc.EtcdMemberList(ctx, &machine.EtcdMemberListRequest{})
	if err != nil {
		return 0, fmt.Errorf("failed to get etcd members: %w", err)
	}

	if len(resp.Messages) == 0 {
		return 0, fmt.Errorf("no etcd members response")
	}

	nodeIPStr := nodeIP.String()
	for _, member := range resp.Messages[0].Members {
		// Match by hostname
		if member.Hostname == nodeIPStr {
			return member.Id, nil
		}
		// Match by peer URLs (e.g., "https://192.168.1.50:2300")
		for _, peerURL := range member.PeerUrls {
			if strings.Contains(peerURL, nodeIPStr) {
				return member.Id, nil
			}
		}
	}

	return 0, fmt.Errorf("etcd member with IP %s not found", nodeIPStr)
}

func (c *Client) ResetNode(ctx context.Context, ip net.IP, graceful bool) error {
	tc, err := c.getClient(ctx, ip, false)
	if err != nil {
		return fmt.Errorf("failed to create talos client: %w", err)
	}
	defer tc.Close()

	// Reset signature: (ctx context.Context, graceful bool, reboot bool) error
	// We want to reset without reboot (the node will be reconfigured after)
	if err := tc.Reset(ctx, graceful, false); err != nil {
		return fmt.Errorf("failed to reset node: %w", err)
	}

	return nil
}

func (c *Client) Kubeconfig(ctx context.Context, endpoint net.IP, outputPath string) error {
	tc, err := c.getClient(ctx, endpoint, false)
	if err != nil {
		return fmt.Errorf("failed to create talos client: %w", err)
	}
	defer tc.Close()

	// Kubeconfig returns ([]byte, error), not a stream
	data, err := tc.Kubeconfig(ctx)
	if err != nil {
		return fmt.Errorf("failed to get kubeconfig: %w", err)
	}

	if err := os.WriteFile(outputPath, data, 0600); err != nil {
		return fmt.Errorf("failed to write kubeconfig: %w", err)
	}

	return nil
}

func (c *Client) GenerateNodeConfig(ctx context.Context, spec *types.NodeSpec, secretsDir string) (string, error) {
	nc := NewNodeConfig(c.config)
	if c.audit != nil {
		nc.SetAuditLogger(c.audit)
	}
	outputDir := filepath.Join(secretsDir, "..", "nodes")
	return nc.Generate(spec, outputDir)
}
