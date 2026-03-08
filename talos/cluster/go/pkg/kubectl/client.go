package kubectl

import (
	"context"
	"fmt"
	"net"
	"os/exec"
	"strings"
	"time"

	"go.uber.org/zap"
)

// execCommandContext allows tests to mock command execution
var execCommandContext = exec.CommandContext

// Client wraps kubectl operations for node lifecycle management
type Client struct {
	logger     *zap.Logger
	kubeconfig string // explicit kubeconfig path (empty = use default)
	context    string // explicit context name (empty = use default)
}

// NewClient creates a new kubectl client
func NewClient(logger *zap.Logger) *Client {
	return &Client{logger: logger}
}

// SetContext sets an explicit context name
func (c *Client) SetContext(name string) {
	c.context = name
}

// baseArgs returns the common args that should prepend all kubectl commands
func (c *Client) baseArgs() []string {
	var args []string
	if c.kubeconfig != "" {
		args = append(args, "--kubeconfig", c.kubeconfig)
	}
	if c.context != "" {
		args = append(args, "--context", c.context)
	}
	return args
}

// command builds an exec.Cmd with the base args prepended
func (c *Client) command(ctx context.Context, args ...string) *exec.Cmd {
	fullArgs := append(c.baseArgs(), args...)
	return execCommandContext(ctx, "kubectl", fullArgs...)
}

// GetNodeNameByIP finds the Kubernetes node name for a given IP address
func (c *Client) GetNodeNameByIP(ctx context.Context, ip net.IP) (string, error) {
	cmd := c.command(ctx, "get", "nodes", "-o", "wide", "--no-headers")
	output, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("kubectl get nodes: %w", err)
	}

	ipStr := ip.String()
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) > 6 && fields[5] == ipStr {
			return fields[0], nil
		}
	}

	return "", fmt.Errorf("node with IP %s not found in Kubernetes", ipStr)
}

// DrainNode cordons and drains a Kubernetes node
func (c *Client) DrainNode(ctx context.Context, nodeName string) error {
	c.logger.Info("cordoning node", zap.String("node", nodeName))

	cmd := c.command(ctx, "cordon", nodeName)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("kubectl cordon: %w, output: %s", err, string(output))
	}

	c.logger.Info("draining node", zap.String("node", nodeName))

	drainCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()

	cmd = c.command(drainCtx, "drain", nodeName,
		"--ignore-daemonsets",
		"--delete-emptydir-data",
		"--timeout=30s",
	)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("kubectl drain: %w, output: %s", err, string(output))
	}

	return nil
}

// DeleteNode removes a node from the Kubernetes cluster
func (c *Client) DeleteNode(ctx context.Context, nodeName string) error {
	c.logger.Info("deleting node from kubernetes", zap.String("node", nodeName))

	cmd := c.command(ctx, "delete", "node", nodeName)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("kubectl delete node: %w, output: %s", err, string(output))
	}

	return nil
}

// ClusterInfo runs kubectl cluster-info and returns the output
func (c *Client) ClusterInfo(ctx context.Context) (string, error) {
	cmd := c.command(ctx, "cluster-info")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("kubectl cluster-info: %w, output: %s", err, string(output))
	}
	return string(output), nil
}

// GetNodes runs kubectl get nodes -o wide and returns the output
func (c *Client) GetNodes(ctx context.Context) (string, error) {
	cmd := c.command(ctx, "get", "nodes", "-o", "wide")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("kubectl get nodes: %w, output: %s", err, string(output))
	}
	return string(output), nil
}
