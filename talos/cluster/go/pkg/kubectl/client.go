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

// Client wraps kubectl operations for node lifecycle management
type Client struct {
	logger *zap.Logger
}

// NewClient creates a new kubectl client
func NewClient(logger *zap.Logger) *Client {
	return &Client{logger: logger}
}

// GetNodeNameByIP finds the Kubernetes node name for a given IP address
func (c *Client) GetNodeNameByIP(ctx context.Context, ip net.IP) (string, error) {
	cmd := exec.CommandContext(ctx, "kubectl", "get", "nodes", "-o", "wide", "--no-headers")
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

	cmd := exec.CommandContext(ctx, "kubectl", "cordon", nodeName)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("kubectl cordon: %w, output: %s", err, string(output))
	}

	c.logger.Info("draining node", zap.String("node", nodeName))

	drainCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()

	cmd = exec.CommandContext(drainCtx, "kubectl", "drain", nodeName,
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

	cmd := exec.CommandContext(ctx, "kubectl", "delete", "node", nodeName)
	if output, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("kubectl delete node: %w, output: %s", err, string(output))
	}

	return nil
}

// ClusterInfo runs kubectl cluster-info and retruns the output
func (c *Client) ClusterInfo(ctx context.Context) (string, error) {
	cmd := exec.CommandContext(ctx, "kubectl", "cluster-info")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("kubectl cluster-info: %w, output: %s", err, string(output))
	}
	return string(output), nil
}

// GetNodes runs kubectl get nodes -o wide and returns the output
func (c *Client) GetNodes(ctx context.Context) (string, error) {
	cmd := exec.CommandContext(ctx, "kubectl", "get", "nodes", "-o", "wide")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("kubectl get nodes: %w, output: %s", err, string(output))
	}
	return string(output), nil
}
