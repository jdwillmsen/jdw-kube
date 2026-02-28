package talos

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"os"
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

// GetEtcdMembers uses the machine API EtcdMemberList method
func (c *Client) GetEtcdMembers(ctx context.Context, ip net.IP) ([]string, error) {
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

	members := make([]string, 0, len(resp.Messages[0].Members))
	for _, member := range resp.Messages[0].Members {
		// Convert uint64 ID to string
		members = append(members, fmt.Sprintf("%d", member.Id))
	}

	return members, nil
}

// RemoveEtcdMember uses the machine API EtcdRemoveMemberByID method
func (c *Client) RemoveEtcdMember(ctx context.Context, endpoint net.IP, memberID string) error {
	tc, err := c.getClient(ctx, endpoint, false)
	if err != nil {
		return fmt.Errorf("failed to create talos client: %w", err)
	}
	defer tc.Close()

	// Parse memberID string to uint64
	var memberIDUint uint64
	_, err = fmt.Sscanf(memberID, "%d", &memberIDUint)
	if err != nil {
		return fmt.Errorf("invalid member ID %s: %w", memberID, err)
	}

	// EtcdRemoveMemberByID returns only error, not (resp, error)
	if err := tc.EtcdRemoveMemberByID(ctx, &machine.EtcdRemoveMemberByIDRequest{
		MemberId: memberIDUint,
	}); err != nil {
		return fmt.Errorf("failed to remove etcd member %s: %w", memberID, err)
	}

	return nil
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

func (c *Client) GenerateNodeConfig(ctx context.Context, spec *types.NodeSpec, secretsDir string) ([]byte, error) {
	var config string
	switch spec.Role {
	case types.RoleControlPlane:
		config = c.generateControlPlaneConfig(spec)
	case types.RoleWorker:
		config = c.generateWorkerConfig(spec)
	}
	return []byte(config), nil
}

func (c *Client) generateControlPlaneConfig(spec *types.NodeSpec) string {
	return fmt.Sprintf(`version: v1alpha1
machine:
  install:
    disk: /dev/%s
    extraKernelArgs:
      - console=tty0
      - console=ttyS0
  network:
    interfaces:
      - interface: %s
        dhcp: true
    extraHostEntries:
      - ip: %s
        aliases:
          - %s
  sysctls:
    vm.nr_hugepages: "1024"
  kubelet:
    extraArgs:
      rotate-server-certificates: "true"
  kernel:
    modules:
      - name: nvme_tcp
      - name: vfio_pci
      - name: zfs
cluster:
  extraManifests:
    - https://raw.githubusercontent.com/alex1989hu/kubelet-serving-cert-approver/main/deploy/standalone-install.yaml
    - https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  allowSchedulingOnControlPlanes: false
  apiServer:
    certSANs:
      - %s
      - %s
      - 127.0.0.1
`,
		c.config.DefaultDisk,
		c.config.DefaultNetworkInterface,
		c.config.HAProxyIP.String(),
		c.config.ControlPlaneEndpoint,
		c.config.ControlPlaneEndpoint,
		c.config.HAProxyIP.String(),
	)
}

func (c *Client) generateWorkerConfig(spec *types.NodeSpec) string {
	return fmt.Sprintf(`version: v1alpha1
machine:
  install:
    disk: /dev/%s
    extraKernelArgs:
      - console=tty0
      - console=ttyS0
  network:
    interfaces:
      - interface: %s
        dhcp: true
    extraHostEntries:
      - ip: %s
        aliases:
          - %s
  sysctls:
    vm.nr_hugepages: "1024"
  kernel:
    modules:
      - name: nvme_tcp
      - name: vfio_pci
      - name: zfs
  kubelet:
    extraArgs:
      rotate-server-certificates: "true"
    extraMounts:
      - destination: /var/local
        type: bind
        source: /var/local
        options:
          - bind
          - rshared
          - rw
`,
		c.config.DefaultDisk,
		c.config.DefaultNetworkInterface,
		c.config.HAProxyIP.String(),
		c.config.ControlPlaneEndpoint,
	)
}
