package app

import (
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/jdwlabs/infrastructure/bootstrap/internal/kubectl"
	"github.com/jdwlabs/infrastructure/bootstrap/internal/logging"
	"github.com/jdwlabs/infrastructure/bootstrap/internal/talos"
	"github.com/jdwlabs/infrastructure/bootstrap/internal/types"
	"go.uber.org/zap"
)

func (app *App) DisplayPlan(plan *types.ReconcilePlan) {
	app.DisplayPlanTo(plan, app.Session.Console)
}

func (app *App) DisplayPlanTo(plan *types.ReconcilePlan, w io.Writer) {
	box := logging.NewBox(w, app.Cfg.NoColor)
	box.Header("RECONCILIATION PLAN")
	if plan.NeedsBootstrap {
		box.Badge("BOOTSTRAP", "Cluster needs initial bootstrap")
	}
	if len(plan.AddControlPlanes) > 0 {
		box.Item("+", fmt.Sprintf("Add %d control plane(s): %v", len(plan.AddControlPlanes), plan.AddControlPlanes))
	}
	if len(plan.AddWorkers) > 0 {
		box.Item("+", fmt.Sprintf("Add %d worker(s): %v", len(plan.AddWorkers), plan.AddWorkers))
	}
	if len(plan.RemoveControlPlanes) > 0 {
		box.Item("-", fmt.Sprintf("Remove %d control plane(s): %v", len(plan.RemoveControlPlanes), plan.RemoveControlPlanes))
	}
	if len(plan.RemoveWorkers) > 0 {
		box.Item("-", fmt.Sprintf("Remove %d worker(s): %v", len(plan.RemoveWorkers), plan.RemoveWorkers))
	}
	if len(plan.UpdateConfigs) > 0 {
		box.Item("~", fmt.Sprintf("Update %d node config(s): %v", len(plan.UpdateConfigs), plan.UpdateConfigs))
	}
	if len(plan.NoOp) > 0 {
		box.Item("=", fmt.Sprintf("%d node(s) unchanged", len(plan.NoOp)))
	}
	if plan.IsEmpty() {
		box.Badge("OK", "Cluster matches desired state — no changes needed")
	}
	box.Footer()
}

// hostsFilePath returns the platform-appropriate hosts file path.
func hostsFilePath() string {
	if runtime.GOOS == "windows" {
		return filepath.Join(os.Getenv("SystemRoot"), "System32", "drivers", "etc", "hosts")
	}
	return "/etc/hosts"
}

// EnsureEndpointResolvable checks DNS for the control plane endpoint and
// adds a hosts file entry if resolution fails or points to the wrong IP.
func (app *App) EnsureEndpointResolvable() {
	cfg := app.Cfg
	// Skip if endpoint is already an IP
	if net.ParseIP(cfg.ControlPlaneEndpoint) != nil {
		return
	}

	// Check if endpoint resolves correctly
	addrs, err := net.LookupHost(cfg.ControlPlaneEndpoint)
	if err == nil && len(addrs) > 0 {
		for _, addr := range addrs {
			if addr == cfg.HAProxyIP.String() {
				return // Resolves correctly
			}
		}
	}

	entry := fmt.Sprintf("%s %s", cfg.HAProxyIP, cfg.ControlPlaneEndpoint)
	hostsFile := hostsFilePath()

	data, err := os.ReadFile(hostsFile)
	if err != nil {
		app.Logger.Warn("cannot read hosts file", zap.String("path", hostsFile), zap.Error(err))
		app.Logger.Warn("add the following entry manually", zap.String("entry", entry))
		return
	}

	content := string(data)

	// Already correct
	if strings.Contains(content, entry) {
		return
	}

	// Entry exists with wrong IP - update it
	if strings.Contains(content, cfg.ControlPlaneEndpoint) {
		lines := strings.Split(content, "\n")
		for i, line := range lines {
			if strings.Contains(line, cfg.ControlPlaneEndpoint) && !strings.HasPrefix(strings.TrimSpace(line), "#") {
				lines[i] = entry
			}
		}
		if err := writeHostsFile(hostsFile, []byte(strings.Join(lines, "\n"))); err != nil {
			app.Logger.Warn("failed to update hosts file (add manually)", zap.String("path", hostsFile), zap.String("entry", entry), zap.Error(err))
		} else {
			app.Logger.Info("updated hosts entry", zap.String("entry", entry))
		}
		return
	}

	// Append new entry
	appendData := []byte("\n" + entry + "\n")
	if err := appendHostsFile(hostsFile, appendData); err != nil {
		app.Logger.Warn("failed to append to hosts file (add manually)", zap.String("path", hostsFile), zap.String("entry", entry), zap.Error(err))
	} else {
		app.Logger.Info("added hosts entry", zap.String("entry", entry))
	}
}

// writeHostsFile writes the full hosts file content, escalating privileges if needed.
func writeHostsFile(hostsFile string, data []byte) error {
	// Try direct write first
	if err := os.WriteFile(hostsFile, data, 0644); err == nil {
		return nil
	}
	if runtime.GOOS == "windows" {
		return fmt.Errorf("permission denied: run as Administrator to modify %s", hostsFile)
	}
	cmd := exec.Command("sudo", "tee", hostsFile)
	cmd.Stdin = strings.NewReader(string(data))
	cmd.Stdout = nil
	return cmd.Run()
}

// appendHostsFile appends to the hosts file, escalating privileges if needed.
func appendHostsFile(hostsFile string, data []byte) error {
	f, err := os.OpenFile(hostsFile, os.O_APPEND|os.O_WRONLY, 0644)
	if err == nil {
		_, writeErr := f.Write(data)
		f.Close()
		return writeErr
	}
	if runtime.GOOS == "windows" {
		return fmt.Errorf("permission denied: run as Administrator to modify %s", hostsFile)
	}
	cmd := exec.Command("sudo", "tee", "-a", hostsFile)
	cmd.Stdin = strings.NewReader(string(data))
	cmd.Stdout = nil
	return cmd.Run()
}

// ConfigureTalosctlEndpoints sets talosctl endpoints and nodes
func (app *App) ConfigureTalosctlEndpoints(deployed *types.ClusterState) {
	cfg := app.Cfg
	// Set endpoint to HAProxy IP
	cmd := exec.Command("talosctl", "config", "endpoint", cfg.HAProxyIP.String())
	cmd.Env = append(os.Environ(), "TALOSCONFIG="+filepath.Join(cfg.SecretsDir, "talosconfig"))
	if output, err := cmd.CombinedOutput(); err != nil {
		app.Logger.Warn("failed to set talosctl endpoint", zap.Error(err), zap.String("output", string(output)))
	}

	// Set node to first control plane
	if len(deployed.ControlPlanes) > 0 {
		cmd = exec.Command("talosctl", "config", "node", deployed.ControlPlanes[0].IP.String())
		cmd.Env = append(os.Environ(), "TALOSCONFIG="+filepath.Join(cfg.SecretsDir, "talosconfig"))
		if output, err := cmd.CombinedOutput(); err != nil {
			app.Logger.Warn("failed to set talosctl node", zap.Error(err), zap.String("output", string(output)))
		}
	}
}

// VerifyCluster performs post-reconciliation health checks
func (app *App) VerifyCluster(ctx context.Context, talosClient *talos.Client, k8sClient *kubectl.Client, deployed *types.ClusterState) {
	app.Logger.Info("verifying cluster health")

	// Check Kubernetes API
	info, err := k8sClient.ClusterInfo(ctx)
	if err != nil {
		app.Logger.Warn("cluster-info check failed", zap.Error(err))
	} else {
		app.Logger.Info("kubernetes API accessible", zap.String("info", strings.TrimSpace(info)))
	}

	// List nodes
	nodes, err := k8sClient.GetNodes(ctx)
	if err != nil {
		app.Logger.Warn("failed to get nodes", zap.Error(err))
	} else {
		app.Logger.Info("cluster nodes:\n" + nodes)
	}

	// Check etcd health
	if len(deployed.ControlPlanes) > 0 {
		members, err := talosClient.GetEtcdMembers(ctx, deployed.ControlPlanes[0].IP)
		if err != nil {
			app.Logger.Warn("failed to get etcd members", zap.Error(err))
		} else {
			app.Logger.Info("etcd members healthy", zap.Int("count", len(members)))
		}
	}

	// Print success summary using box
	box := logging.NewBox(app.Session.Console, app.Cfg.NoColor)
	box.Header("BOOTSTRAP SUCCESSFUL")
	box.Row("Cluster", deployed.ClusterName)
	box.Row("Endpoint", app.Cfg.ControlPlaneEndpoint)
	box.Row("Control Planes", fmt.Sprintf("%d", len(deployed.ControlPlanes)))
	for _, cp := range deployed.ControlPlanes {
		box.Item("•", fmt.Sprintf("VMID %d: %s", cp.VMID, cp.IP))
	}
	box.Row("Workers", fmt.Sprintf("%d", len(deployed.Workers)))
	for _, w := range deployed.Workers {
		box.Item("•", fmt.Sprintf("VMID %d: %s", w.VMID, w.IP))
	}
	box.Section("Quick Start")
	box.Item("$", "kubectl get nodes")
	box.Item("$", "talosctl dashboard")
	box.Item("$", "talosctl etcd members")
	box.Footer()
}
