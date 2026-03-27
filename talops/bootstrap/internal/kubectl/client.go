package kubectl

import (
	"context"
	"fmt"
	"net"
	"os/exec"
	"strings"
	"time"

	"github.com/jdwlabs/infrastructure/bootstrap/internal/logging"
	"go.uber.org/zap"
)

// execCommandContext allows tests to mock command execution
var execCommandContext = exec.CommandContext

// Client wraps kubectl operations for node lifecycle management
type Client struct {
	logger     *zap.Logger
	kubeconfig string // explicit kubeconfig path (empty = use default)
	audit      *logging.AuditLogger
	context    string // explicit context name (empty = use default)
}

// NewClient creates a new kubectl client
func NewClient(logger *zap.Logger) *Client {
	return &Client{logger: logger}
}

// SetAuditLogger attaches an audit logger for command tracking
func (c *Client) SetAuditLogger(audit *logging.AuditLogger) {
	c.audit = audit
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

// auditedCommand builds an AuditedCmd when audit is available, otherwise nil.
// Callers that need audit-aware CombinedOutput/Output should use this.
func (c *Client) auditedCommand(ctx context.Context, args ...string) (*logging.AuditedCmd, *exec.Cmd) {
	fullArgs := append(c.baseArgs(), args...)
	if c.audit != nil {
		ac := c.audit.CommandContext(ctx, "kubectl", fullArgs...)
		return ac, ac.Cmd
	}
	cmd := execCommandContext(ctx, "kubectl", fullArgs...)
	return nil, cmd
}

// cmdString returns a human-readable representation of the command that would be run
func (c *Client) cmdString(args ...string) string {
	fullArgs := append(c.baseArgs(), args...)
	return "kubectl " + strings.Join(fullArgs, " ")
}

// combinedOutput runs CombinedOutput through the audited command if available,
// otherwise falls back to raw exec.
func combinedOutput(ac *logging.AuditedCmd, cmd *exec.Cmd) ([]byte, error) {
	if ac != nil {
		return ac.CombinedOutput()
	}
	return cmd.CombinedOutput()
}

// GetNodeNameByIP finds the Kubernetes node name for a given IP address
func (c *Client) GetNodeNameByIP(ctx context.Context, ip net.IP) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	cmdArgs := []string{"get", "nodes", "-o", "wide", "--no-headers"}
	ac, cmd := c.auditedCommand(ctx, cmdArgs...)
	output, err := combinedOutput(ac, cmd)
	if err != nil {
		return "", fmt.Errorf("%s: %w, output: %s", c.cmdString(cmdArgs...), err, string(output))
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

	cordonArgs := []string{"cordon", nodeName}
	ac, cmd := c.auditedCommand(ctx, cordonArgs...)
	if output, err := combinedOutput(ac, cmd); err != nil {
		return fmt.Errorf("%s: %w, output: %s", c.cmdString(cordonArgs...), err, string(output))
	}

	c.logger.Info("draining node", zap.String("node", nodeName))

	drainCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()

	drainArgs := []string{"drain", nodeName,
		"--ignore-daemonsets",
		"--delete-emptydir-data",
		"--timeout=30s",
	}
	ac, cmd = c.auditedCommand(drainCtx, drainArgs...)
	if output, err := combinedOutput(ac, cmd); err != nil {
		return fmt.Errorf("%s: %w, output: %s", c.cmdString(drainArgs...), err, string(output))
	}

	return nil
}

// DeleteNode removes a node from the Kubernetes cluster
func (c *Client) DeleteNode(ctx context.Context, nodeName string) error {
	c.logger.Info("deleting node from kubernetes", zap.String("node", nodeName))

	deleteArgs := []string{"delete", "node", nodeName}
	ac, cmd := c.auditedCommand(ctx, deleteArgs...)
	if output, err := combinedOutput(ac, cmd); err != nil {
		return fmt.Errorf("%s: %w, output: %s", c.cmdString(deleteArgs...), err, string(output))
	}

	return nil
}

// ClusterInfo runs kubectl cluster-info and returns the output
func (c *Client) ClusterInfo(ctx context.Context) (string, error) {
	cmdArgs := []string{"cluster-info"}
	ac, cmd := c.auditedCommand(ctx, cmdArgs...)
	output, err := combinedOutput(ac, cmd)
	if err != nil {
		return "", fmt.Errorf("%s: %w, output: %s", c.cmdString(cmdArgs...), err, string(output))
	}
	return string(output), nil
}

// GetNodes runs kubectl get nodes -o wide and returns the output
func (c *Client) GetNodes(ctx context.Context) (string, error) {
	cmdArgs := []string{"get", "nodes", "-o", "wide"}
	ac, cmd := c.auditedCommand(ctx, cmdArgs...)
	output, err := combinedOutput(ac, cmd)
	if err != nil {
		return "", fmt.Errorf("%s: %w, output: %s", c.cmdString(cmdArgs...), err, string(output))
	}
	return string(output), nil
}
