package talos

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"time"

	"github.com/jdw/talos-bootstrap/pkg/types"

	"github.com/siderolabs/talos/pkg/machinery/api/machine"
	"github.com/siderolabs/talos/pkg/machinery/client"
	"github.com/siderolabs/talos/pkg/machinery/client/config"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
)

type Client struct {
	config      *types.Config
	talosConfig *config.Config
	ctxName     string
}

func NewClient(cfg *types.Config) *Client {
	return &Client{config: cfg}
}

func (c *Client) Initialize(ctx context.Context) error {
	talosConfigPath := fmt.Sprintf("%s/talosconfig", c.config.SecretsDir)

	if _, err := os.Stat(talosConfigPath); os.IsNotExist(err) {
		return fmt.Errorf("talosconfig not found at %s: run 'talosctl gen config' first", talosConfigPath)
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
		client.WithConfig(c.talosConfig),
		client.WithEndpoints(endpoint.String()),
	}

	if insecure {
		opts = append(opts, client.WithGRPCDialOptions(
			grpc.WithTransportCredentials(credentials.NewTLS(&tls.Config{
				InsecureSkipVerify: true,
			})),
		))
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
			fmt.Printf("Warning: %s\n", warning)
		}
	}

	return nil
}

// ApplyConfigWithRetry appleis configuration with intelligent retry logic
func (c *Client) ApplyConfigWithREty(ctx context.Context, ip net.IP, configPath string, maxAttempts int) error {
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

		// Handle different error types
		switch talosErr.Code {
		case ErrAlreadyConfigured:
			// Verify node is actualy ready
			ready, checkErr := c.checkReadyByIP(ctx, ip, types.RoleWorker)
			if checkErr == nil && ready {
				// Node is configured and ready, this is success
				return nil
			}
			// Node not ready yet, continue retrying

		case ErrCertificateRequired:
			// Switch to secure mode and retry immediately
			insecure = false
			continue

		case ErrConnectionRefused, ErrConnectionTimeout, ErrMaintenanceMode, ErrNodeNotReady:
			// Node might be rebooting or not ready, wait longer
			if attempt < maxAttempts {
				waitTime := time.Duration(attempt*5) * time.Second
				if talosErr.Code == ErrConnectionTimeout {
					// Even longer for timeouts
					waitTime = time.Duration(attempt*10) * time.Second
				}
				fmt.Printf("Attempt %d/%d failed: %v. Retrying in %s...\n", attempt, maxAttempts, err, waitTime)
				time.Sleep(waitTime)
				continue
			}

		case ErrPermissionDenied:
			// Don't retry on permission errors
			return fmt.Errorf("permission denied: %w", err)

		default:
			// Unknown error, retry with standard backoff
			if attempt < maxAttempts && talosErr.IsRetryable() {
				waitTime := time.Duration(attempt*5) * time.Second
				fmt.Printf("Attempt %d/%d failed with retryable error: %v. Retrying in %s...\n", attempt, maxAttempts, err, waitTime)
				time.Sleep(waitTime)
				continue
			}
		}

		// If we're on the last attempt, return the error
		if attempt >= maxAttempts {
			break
		}

		// Standard backoff for other errors
		if attempt < maxAttempts {
			time.Sleep(time.Duration(attempt*5) * time.Second)
		}
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

	// Bootstrap returns only error, not (resp, error)
	if err := tc.Bootstrap(ctx, &machine.BootstrapRequest{}); err != nil {
		return fmt.Errorf("failed to bootstrap etcd: %w", err)
	}

	return nil
}

func (c *Client) WaitForReady(ctx context.Context, ip net.IP, role types.Role) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()

	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	insecure := true
	var tc *client.Client
	var err error

	for {
		select {
		case <-ctx.Done():
			return fmt.Errorf("timeout waiting for node %s to be ready", ip)
		case <-ticker.C:
			if tc == nil {
				tc, err = c.getClient(ctx, ip, insecure)
				if err != nil {
					continue
				}
			}

			ready, err := c.checkReady(ctx, tc, role)
			if err != nil {
				tc.Close()
				tc = nil
				continue
			}

			if ready {
				tc.Close()
				return nil
			}

			if insecure {
				insecure = false
				tc.Close()
				tc = nil
			}
		}
	}
}

func (c *Client) checkReady(ctx context.Context, tc *client.Client, role types.Role) (bool, error) {
	if _, err := tc.Version(ctx); err != nil {
		return false, err
	}

	if role == types.RoleControlPlane {
		// Use EtcdMemberList from the client (machine API)
		_, err := tc.EtcdMemberList(ctx, &machine.EtcdMemberListRequest{})
		if err != nil {
			return false, nil
		}

		services, err := tc.ServiceList(ctx)
		if err != nil {
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
			return false, nil
		}
	}

	return true, nil
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

// GetEtcdMemberIDByIP finds the etcd member ID for a given node IP
func (c *Client) GetEtcdMemberIDByIP(ctx context.Context, endpoint net.IP, nodeIP net.IP) (uint64, error) {
	members, err := c.GetEtcdMembers(ctx, endpoint)
	if err != nil {
		return 0, err
	}

	// Try to match by hostname (IP String)
	nodeIPStr := nodeIP.String()
	for _, member := range members {
		if member.Hostname == nodeIPStr {
			return member.ID, nil
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
	outputDir := filepath.Join("clusters", c.config.ClusterName, "nodes")
	return nc.Generate(spec, secretsDir, outputDir)
}
