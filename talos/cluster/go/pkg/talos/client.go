package talos

import (
	"context"
	"fmt"
	"net"
	"time"

	"github.com/jdw/talos-bootstrap/pkg/types"
)

// Client wraps talosctl operations
// Note: This uses shell execution for now, but can be upgraded to native API
type Client struct {
	config *types.Config
	// TODO: Add native Talos client when we import siderolabs/talos
}

// NewClient creates a new Talos client
func NewClient(cfg *types.Config) *Client {
	return &Client{config: cfg}
}

// ApplyConfig sends configuration to a node
// Replaces your apply_config_with_rediscovery()
func (c *Client) ApplyConfig(ctx context.Context, ip net.IP, configPath string, insecure bool) error {
	// For now, shell out to talosctl
	// TODO: Use native client when we have the dependency working

	args := []string{
		"apply-config",
		"--nodes", ip.String(),
		"--file", configPath,
	}

	if insecure {
		args = append(args, "--insecure")
	}

	// This would use exec.CommandContext in real implementation
	// For now, just log what we would do
	fmt.Printf("Would run: talosctl %v\n", args)

	return nil
}

// BootstrapEtcd initializes the etcd cluster on first control plane
// Replaces your bootstrap_etcd_at_ip()
func (c *Client) BootstrapEtcd(ctx context.Context, ip net.IP) error {
	args := []string{
		"bootstrap",
		"--nodes", ip.String(),
		"--endpoints", ip.String(),
	}

	fmt.Printf("Would run: talosctl %v\n", args)
	return nil
}

// WaitForReady blocks until node is ready
// Replaces your wait_for_node_with_rediscovery()
func (c *Client) WaitForReady(ctx context.Context, ip net.IP, role types.Role) error {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()

	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return fmt.Errorf("timeout waiting for node %s to be ready", ip)
		case <-ticker.C:
			ready, err := c.checkReady(ctx, ip, role)
			if err != nil {
				continue // Keep trying
			}
			if ready {
				return nil
			}
		}
	}
}

func (c *Client) checkReady(ctx context.Context, ip net.IP, role types.Role) (bool, error) {
	// Try insecure first (maintenance mode)
	// In real implementation, use native API
	// For now, simulate with port check

	// Check if Talos API port is open
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:50000", ip), 5*time.Second)
	if err != nil {
		return false, err
	}
	conn.Close()

	// In maintenance mode, workers are "ready" when stable
	if role == types.RoleWorker {
		// Would check if in maintenance mode via API
		return true, nil
	}

	// For control planes, need to check if bootstrapped
	// Would query etcd members via API
	return false, nil
}

// GetEtcdMembers returns current etcd member list
// Used for quorum calculations in control plane removal
func (c *Client) GetEtcdMembers(ctx context.Context, ip net.IP) ([]string, error) {
	// Would use: talosctl etcd members --nodes <ip> --endpoints <ip>
	// For now, return mock data
	return []string{"member1", "member2", "member3"}, nil
}

// RemoveEtcdMember removes a member from etcd cluster
// Critical for safe control plane removal
func (c *Client) RemoveEtcdMember(ctx context.Context, endpoint net.IP, memberID string) error {
	args := []string{
		"etcd", "remove-member",
		"--nodes", endpoint.String(),
		"--endpoints", endpoint.String(),
		memberID,
	}

	fmt.Printf("Would run: talosctl %v\n", args)
	return nil
}

// ResetNode resets a Talos node (removes from cluster)
func (c *Client) ResetNode(ctx context.Context, ip net.IP, graceful bool) error {
	args := []string{
		"reset",
		"--nodes", ip.String(),
		"--endpoints", ip.String(),
		"--system-labels-to-wipe", "STATE",
		"--system-labels-to-wipe", "EPHEMERAL",
	}

	if !graceful {
		args = append(args, "--graceful=false")
	}

	fmt.Printf("Would run: talosctl %v\n", args)
	return nil
}

// GenerateNodeConfig creates Talos configuration for a specific node
// Replaces your generate_node_config() and generate_control_plane_patch()
func (c *Client) GenerateNodeConfig(ctx context.Context, spec *types.NodeSpec, secretsDir string) ([]byte, error) {
	// In real implementation, use Talos machinery
	// For now, generate YAML manually

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
	return fmt.Sprintf(`machine:
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
      rotate-server-certificates: true
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
	return fmt.Sprintf(`machine:
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
      rotate-server-certificates: true
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

// Kubeconfig fetches kubeconfig from cluster
func (c *Client) Kubeconfig(ctx context.Context, endpoint net.IP, outputPath string) error {
	args := []string{
		"kubeconfig", outputPath,
		"--nodes", endpoint.String(),
		"--endpoints", endpoint.String(),
	}

	fmt.Printf("Would run: talosctl %v\n", args)
	return nil
}
