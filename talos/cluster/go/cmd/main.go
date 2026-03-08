package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/jdw/talos-bootstrap/pkg/discovery"
	"github.com/jdw/talos-bootstrap/pkg/haproxy"
	"github.com/jdw/talos-bootstrap/pkg/kubectl"
	"github.com/jdw/talos-bootstrap/pkg/logging"
	"github.com/jdw/talos-bootstrap/pkg/state"
	"github.com/jdw/talos-bootstrap/pkg/talos"
	"github.com/jdw/talos-bootstrap/pkg/types"
	"github.com/spf13/cobra"
	"go.uber.org/zap"
	"golang.org/x/sync/errgroup"
)

const version = "v0.1.0"

var (
	cfg     *types.Config
	logger  *zap.Logger
	session *logging.RunSession
)

func init() {
	cfg = types.DefaultConfig()
}

func main() {
	var runErr error
	defer func() {
		if session != nil {
			session.Close(runErr)
		}
	}()

	rootCmd := &cobra.Command{
		Use:   "talos-bootstrap",
		Short: "Smart reconciliation for Talos clusters",
		PersistentPreRunE: func(cmd *cobra.Command, args []string) error {
			if err := initConfig(cmd); err != nil {
				return err
			}
			return initSession()
		},
	}

	// Global flags
	rootCmd.PersistentFlags().StringVarP(&cfg.ClusterName, "cluster", "c", "cluster", "Cluster name")
	rootCmd.PersistentFlags().StringVar(&cfg.TerraformTFVars, "tfvars", "terraform.tfvars", "Path to terraform.tfvars")
	rootCmd.PersistentFlags().BoolVarP(&cfg.AutoApprove, "auto-approve", "a", false, "Skip confirmations")
	rootCmd.PersistentFlags().BoolVarP(&cfg.DryRun, "dry-run", "d", false, "Simulate only")
	rootCmd.PersistentFlags().BoolVarP(&cfg.SkipPreflight, "skip-preflight", "s", false, "Skip connectivity checks")
	rootCmd.PersistentFlags().StringVarP(&cfg.LogLevel, "log-level", "l", "info", "Log level (debug, info, warn, error)")
	rootCmd.PersistentFlags().StringVar(&cfg.ProxmoxSSHKeyPath, "ssh-key", cfg.ProxmoxSSHKeyPath, "Path to SSH private key")
	rootCmd.PersistentFlags().BoolVarP(&cfg.ForceReconfigure, "force-reconfigure", "f", false, "Force reconfigure all nodes")
	rootCmd.PersistentFlags().StringVar(&cfg.LogDir, "log-dir", cfg.LogDir, "Log directory")
	rootCmd.PersistentFlags().BoolVar(&cfg.NoColor, "no-color", cfg.NoColor, "Disable colored output")

	rootCmd.AddCommand(
		bootstrapCmd(),
		reconcileCmd(),
		statusCmd(),
		resetCmd(),
	)

	runErr = rootCmd.Execute()
	if runErr != nil {
		os.Exit(1)
	}
}

func initSession() error {
	var err error
	session, err = logging.NewRunSession(cfg)
	if err != nil {
		return fmt.Errorf("initialize logging session: %w", err)
	}
	logger = session.Logger

	// Print banner
	logging.PrintBanner(os.Stderr, version, cfg.NoColor)

	// Check prerequisites
	checkPrerequisites(logger)

	// Ensure cluster .gitignore
	clusterDir := filepath.Join("clusters", cfg.ClusterName)
	ensureClusterGitignore(clusterDir)

	return nil
}

func initConfig(cmd *cobra.Command) error {
	if v := os.Getenv("CLUSTER_NAME"); v != "" {
		cfg.ClusterName = v
		cfg.SecretsDir = filepath.Join("clusters", cfg.ClusterName, "secrets")
	}
	if v := os.Getenv("TERRAFORM_TFVARS"); v != "" {
		cfg.TerraformTFVars = v
	}
	if v := os.Getenv("CONTROL_PLANE_ENDPOINT"); v != "" {
		cfg.ControlPlaneEndpoint = v
	}
	if v := os.Getenv("HAPROXY_IP"); v != "" {
		cfg.HAProxyIP = net.ParseIP(v)
	}
	if v := os.Getenv("KUBERNETES_VERSION"); v != "" {
		cfg.KubernetesVersion = v
	}
	if v := os.Getenv("TALOS_VERSION"); v != "" {
		cfg.TalosVersion = v
	}
	if v := os.Getenv("SECRETS_DIR"); v != "" {
		cfg.SecretsDir = v
	}
	if v := os.Getenv("SSH_KEY_PATH"); v != "" {
		cfg.ProxmoxSSHKeyPath = v
	}

	return nil
}

// checkPrerequisites verifies required CLI tools are available
func checkPrerequisites(logger *zap.Logger) {
	for _, tool := range []string{"talosctl", "kubectl"} {
		path, err := exec.LookPath(tool)
		if err != nil {
			logger.Warn("prerequisite not found in PATH", zap.String("tool", tool))
			continue
		}
		// Get version
		cmd := exec.Command(tool, "version", "--client")
		out, err := cmd.CombinedOutput()
		if err != nil {
			// Some tools use different version flags
			cmd = exec.Command(tool, "version")
			out, _ = cmd.CombinedOutput()
		}
		ver := strings.TrimSpace(strings.Split(string(out), "\n")[0])
		logger.Debug("prerequisite found", zap.String("tool", tool), zap.String("path", path), zap.String("version", ver))
	}
}

// ensureClusterGitignore creates a .gitignore in the cluster directory
// to prevent committing generated secrets, node configs, state, and logs.
func ensureClusterGitignore(clusterDir string) {
	gitignorePath := filepath.Join(clusterDir, ".gitignore")
	if _, err := os.Stat(gitignorePath); err == nil {
		return // already exists
	}
	if err := os.MkdirAll(clusterDir, 0755); err != nil {
		return
	}
	content := "/nodes/\n/secrets/\n/state/\n/*.log\n"
	os.WriteFile(gitignorePath, []byte(content), 0644)
}

func bootstrapCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "bootstrap",
		Short: "Initial cluster deployment",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
			defer cancel()
			return runReconcile(ctx, cfg)
		},
	}
}

func reconcileCmd() *cobra.Command {
	var planMode bool
	cmd := &cobra.Command{
		Use:   "reconcile",
		Short: "Reconcile cluster with terraform.tfvars",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
			defer cancel()

			if planMode {
				cfg.PlanMode = true
				cfg.DryRun = true
			}

			return runReconcile(ctx, cfg)
		},
	}
	cmd.Flags().BoolVarP(&planMode, "plan", "p", false, "Show changes without applying")
	return cmd
}

func statusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show current cluster status",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := context.Background()
			return runStatus(ctx, cfg)
		},
	}
}

func resetCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "reset",
		Short: "Reset cluster state",
		RunE: func(cmd *cobra.Command, args []string) error {
			if !cfg.AutoApprove {
				fmt.Print("Are you sure you want to reset? [y/N]: ")
				var response string
				fmt.Scanln(&response)
				if response != "y" && response != "Y" {
					fmt.Println("Cancelled")
					return nil
				}
			}

			clusterDir := filepath.Join("clusters", cfg.ClusterName)
			if err := os.RemoveAll(clusterDir); err != nil {
				return fmt.Errorf("remove cluster dir: %w", err)
			}
			fmt.Printf("Reset cluster %s\n", cfg.ClusterName)
			return nil
		},
	}
}

func runReconcile(ctx context.Context, cfg *types.Config) error {
	stateMgr := state.NewManager(cfg, logger)

	// Load additional fields from terraform.tfvars (cluster_name, proxmox tokens)
	if err := stateMgr.LoadTerraformExtras(ctx); err != nil {
		logger.Debug("could not load terraform extras", zap.Error(err))
	}

	logger.Info("starting reconciliation",
		zap.String("cluster", cfg.ClusterName),
		zap.Bool("dry_run", cfg.DryRun),
		zap.Bool("plan_mode", cfg.PlanMode),
	)

	scanner := discovery.NewScanner(cfg.ProxmoxSSHUser, cfg.ProxmoxNodeIPs)
	defer scanner.Close()
	talosClient := talos.NewClient(cfg)
	talosClient.SetLogger(logger)
	if session != nil && session.AuditLog != nil {
		talosClient.SetAuditLogger(session.AuditLog)
	}
	k8sClient := kubectl.NewClient(logger)
	k8sClient.SetContext(cfg.ClusterName)

	// Configure SSH authentication for scanner
	if cfg.ProxmoxSSHKeyPath != "" {
		if err := scanner.SetPrivateKey(cfg.ProxmoxSSHKeyPath); err != nil {
			logger.Warn("failed to set SSH private key for scanner", zap.String("key_path", cfg.ProxmoxSSHKeyPath), zap.Error(err))
		}
	}

	// Refresh Proxmox node IP map from the cluster - updates the static default map
	// with live IPs. Fails silently if all nodes are unreachable.
	if !cfg.SkipPreflight {
		logger.Info("refreshing proxmox node IPs")
		scanner.RefreshProxmoxNodes(ctx)
	}

	// Initialize Talos client
	if err := talosClient.Initialize(ctx); err != nil {
		return fmt.Errorf("initialize talos client: %w", err)
	}

	// Phase 1: Load states
	logger.Info("loading desired state from terraform")
	desired, err := stateMgr.LoadDesiredState(ctx)
	if err != nil {
		return fmt.Errorf("load desired state: %w", err)
	}
	if len(desired) == 0 {
		return fmt.Errorf("no nodes defined in desired state - check your terraform.tfvars")
	}
	logger.Info("loaded desired state", zap.Int("nodes", len(desired)))

	// Generate node configs for any desired nodes missing configs
	for vmid, spec := range desired {
		configPath := stateMgr.NodeConfigPath(vmid, spec.Role)
		if _, err := os.Stat(configPath); os.IsNotExist(err) {
			logger.Info("generating config for node", zap.Int("vmid", int(vmid)), zap.String("role", string(spec.Role)))
			if _, err := talosClient.GenerateNodeConfig(ctx, spec, cfg.SecretsDir); err != nil {
				return fmt.Errorf("generate config for VMID %d: %w", vmid, err)
			}
		}
	}

	logger.Info("loading deployed state")
	deployed, err := stateMgr.LoadDeployedState(ctx)
	if err != nil {
		return fmt.Errorf("load deployed state: %w", err)
	}

	// Phase 2: Discovery
	logger.Info("discovering live state")
	vmids := make([]types.VMID, 0, len(desired))
	for vmid := range desired {
		vmids = append(vmids, vmid)
	}

	var live map[types.VMID]*types.LiveNode
	if !cfg.SkipPreflight {
		live, err = scanner.DiscoverVMs(ctx, vmids)
		if err != nil {
			return fmt.Errorf("discover VMs: %w", err)
		}
		logger.Info("discovered live state", zap.Int("found", len(live)))

		// Mark nodes that are already joined Talos cluster members
		if deployed.BootstrapCompleted && len(deployed.ControlPlanes) > 0 {
			if members, err := talosClient.GetClusterMembers(ctx, deployed.ControlPlanes[0].IP); err == nil {
				scanner.MarkJoinedNodes(members, live)
			}
		}
	} else {
		live = make(map[types.VMID]*types.LiveNode)
	}

	// Phase 3: Build plan
	logger.Info("building reconciliation plan")
	plan, err := stateMgr.BuildReconcilePlan(ctx, desired, deployed, live)
	if err != nil {
		return fmt.Errorf("build plan: %w", err)
	}

	displayPlan(plan)

	if cfg.PlanMode {
		logger.Info("plan mode - exiting without changes")
		return nil
	}

	if plan.IsEmpty() {
		logger.Info("no changes required")
		return nil
	}

	// Confirm if not auto-approved
	if !cfg.AutoApprove && !cfg.DryRun {
		fmt.Print("\nProceed with changes? [y/N]: ")
		var response string
		fmt.Scanln(&response)
		if response != "y" && response != "Y" {
			fmt.Println("Cancelled")
			return nil
		}
	}

	// Phase 4: Execute
	if err := executePlan(ctx, plan, desired, deployed, stateMgr, scanner, talosClient, k8sClient); err != nil {
		return fmt.Errorf("execute plan: %w", err)
	}

	logger.Info("reconciliation complete")
	return nil
}

func runStatus(ctx context.Context, cfg *types.Config) error {
	stateMgr := state.NewManager(cfg, logger)

	// Load additional fields from terraform.tfvars
	if err := stateMgr.LoadTerraformExtras(ctx); err != nil {
		logger.Debug("could not load terraform extras", zap.Error(err))
	}

	desired, err := stateMgr.LoadDesiredState(ctx)
	if err != nil {
		return err
	}

	deployed, err := stateMgr.LoadDeployedState(ctx)
	if err != nil {
		return err
	}

	box := logging.NewBox(os.Stdout, cfg.NoColor)
	box.Header(fmt.Sprintf("CLUSTER STATUS: %s", cfg.ClusterName))

	box.Section("Desired State (Terraform)")
	box.Row("Control Planes", fmt.Sprintf("%d", countByRole(desired, types.RoleControlPlane)))
	box.Row("Workers", fmt.Sprintf("%d", countByRole(desired, types.RoleWorker)))

	box.Section("Deployed State")
	box.Row("Control Planes", fmt.Sprintf("%d", len(deployed.ControlPlanes)))
	for _, cp := range deployed.ControlPlanes {
		box.Item("•", fmt.Sprintf("VMID %d: %s", cp.VMID, cp.IP))
	}
	box.Row("Workers", fmt.Sprintf("%d", len(deployed.Workers)))
	for _, w := range deployed.Workers {
		box.Item("•", fmt.Sprintf("VMID %d: %s", w.VMID, w.IP))
	}
	box.Row("Bootstrap Completed", fmt.Sprintf("%v", deployed.BootstrapCompleted))

	if deployed.TerraformHash != "" {
		currentHash, err := stateMgr.ComputeTerraformHash()
		if err == nil {
			if currentHash == deployed.TerraformHash {
				fmt.Printf("  Terraform Hash: %s (unchanged)\n", currentHash)
				box.Row("Terraform Hash", fmt.Sprintf("%s (unchanged)", currentHash))
			} else {
				box.Row("Terraform Hash", fmt.Sprintf("%s (CHANGED from %s)", currentHash, deployed.TerraformHash))
			}
		}
	}

	box.Footer()
	return nil
}

func countByRole(specs map[types.VMID]*types.NodeSpec, role types.Role) int {
	count := 0
	for _, spec := range specs {
		if spec.Role == role {
			count++
		}
	}
	return count
}

func displayPlan(plan *types.ReconcilePlan) {
	displayPlanTo(plan, os.Stderr)
}

func displayPlanTo(plan *types.ReconcilePlan, w io.Writer) {
	box := logging.NewBox(w, cfg.NoColor)
	fmt.Fprintln(w)
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
	fmt.Fprintln(os.Stderr)
}

// deployNode handles the common discover -> apply -> reboot -> wait -> hash flow
// for adding a node (control plane or worker). Returns the post-reboot IP.
func deployNode(
	ctx context.Context,
	vmid types.VMID,
	role types.Role,
	deployed *types.ClusterState,
	stateMgr *state.Manager,
	scanner *discovery.Scanner,
	talosClient *talos.Client,
) (net.IP, error) {
	liveNodes, err := scanner.DiscoverVMs(ctx, []types.VMID{vmid})
	if err != nil {
		return nil, fmt.Errorf("discover VM %d: %w", vmid, err)
	}

	node, ok := liveNodes[vmid]
	if !ok || node.IP == nil {
		return nil, fmt.Errorf("VM %d IP not discovered", vmid)
	}

	configPath := stateMgr.NodeConfigPath(vmid, role)
	logger.Info("applying config", zap.Int("vmid", int(vmid)), zap.String("role", string(role)))
	if err := talosClient.ApplyConfigWithRetry(ctx, node.IP, configPath, role, 5); err != nil {
		return nil, fmt.Errorf("apply config to %s %d: %w", role, vmid, err)
	}

	monitor := discovery.NewRebootMonitor(vmid, node.IP, node.MAC, scanner, logger)
	newIP, err := monitor.WaitForReady(ctx, 3*time.Minute)
	if err != nil {
		return nil, fmt.Errorf("wait for %s %d reboot: %w", role, vmid, err)
	}

	if err := talosClient.WaitForReady(ctx, newIP, role); err != nil {
		return nil, fmt.Errorf("wait for %s %d ready: %w", role, vmid, err)
	}

	configHash, hashErr := talos.HashFile(configPath)
	if hashErr != nil {
		logger.Warn("failed to hash config file", zap.Int("vmid", int(vmid)), zap.Error(hashErr))
	}
	stateMgr.UpdateNodeState(deployed, vmid, newIP.String(), configHash, role)

	logger.Info("node deployed and joined", zap.Int("vmid", int(vmid)), zap.String("role", string(role)), zap.String("ip", newIP.String()), zap.String("status", string(types.StatusJoined)))
	return newIP, nil
}

func executePlan(
	ctx context.Context,
	plan *types.ReconcilePlan,
	desired map[types.VMID]*types.NodeSpec,
	deployed *types.ClusterState,
	stateMgr *state.Manager,
	scanner *discovery.Scanner,
	talosClient *talos.Client,
	k8sClient *kubectl.Client,
) error {

	// Track which VMID was bootstrapped so we skip it in the add-CPs phase
	var bootstrappedVMID types.VMID

	// Phase 0: Bootstrap first CP if needed
	//
	// Two cases:
	// (a) Fresh cluster: NeedsBootstrap + AddControlPlanes non-empty - deploy first CP then bootstrap etcd.
	// (b) Deferred bootstrap: NeedsBootstrap + no AddControlPlanes but deployed CPs already exist
	//     (e.g., previous run applied configs but was interrupted before BootstrapEtcd) - Just run etcd bootstrap.
	if plan.NeedsBootstrap {
		logger.Info("executing bootstrap")

		if len(plan.AddControlPlanes) > 0 {
			firstVMID := plan.AddControlPlanes[0]
			bootstrappedVMID = firstVMID
			spec := desired[firstVMID]

			if cfg.DryRun {
				logger.Info("would bootstrap first control plane",
					zap.Int("vmid", int(firstVMID)),
					zap.String("name", spec.Name))
			} else {
				newIP, err := deployNode(ctx, firstVMID, types.RoleControlPlane, deployed, stateMgr, scanner, talosClient)
				if err != nil {
					return fmt.Errorf("bootstrap first CP: %w", err)
				}

				logger.Info("bootstrapping etcd on first control plane", zap.String("ip", newIP.String()), zap.Int("vmid", int(firstVMID)))
				if err := talosClient.BootstrapEtcd(ctx, newIP); err != nil {
					return fmt.Errorf("bootstrap etcd: %w", err)
				}

				if err := talosClient.WaitForEtcdHealthy(ctx, newIP, 5*time.Minute); err != nil {
					return fmt.Errorf("wait for etcd healthy: %w", err)
				}
			}

			deployed.BootstrapCompleted = true
			if err := stateMgr.Save(ctx, deployed); err != nil {
				return fmt.Errorf("save state after bootstrap: %w", err)
			}
		}
	} else if len(deployed.ControlPlanes) > 0 {
		if cfg.DryRun {
			logger.Info("would bootstrap etcd on existing first control plane",
				zap.Int("vmid", int(deployed.ControlPlanes[0].VMID)))
		} else {
			firstCP := deployed.ControlPlanes[0]
			logger.Info("bootstrapping etcd on already-deployed control plane",
				zap.String("ip", firstCP.IP.String()), zap.Int("vmid", int(firstCP.VMID)))
			if err := talosClient.BootstrapEtcd(ctx, firstCP.IP); err != nil {
				return fmt.Errorf("deferred bootstrap etcd: %w", err)
			}

			if err := talosClient.WaitForEtcdHealthy(ctx, firstCP.IP, 5*time.Minute); err != nil {
				return fmt.Errorf("wait for etcd healthy: %w", err)
			}

			deployed.BootstrapCompleted = true
			if err := stateMgr.Save(ctx, deployed); err != nil {
				return fmt.Errorf("save state after deferred bootstrap: %w", err)
			}
		}
	}

	// Phase 1: Remove workers (before additions to free resources)
	if len(plan.RemoveWorkers) > 0 {
		logger.Info("removing workers", zap.Int("count", len(plan.RemoveWorkers)))

		for _, vmid := range plan.RemoveWorkers {
			if cfg.DryRun {
				logger.Info("would remove worker", zap.Int("vmid", int(vmid)))
				continue
			}

			var nodeIP net.IP
			for _, w := range deployed.Workers {
				if w.VMID == vmid {
					nodeIP = w.IP
					break
				}
			}

			if nodeIP != nil {
				nodeName, err := k8sClient.GetNodeNameByIP(ctx, nodeIP)
				if err != nil {
					logger.Warn("failed to get node name for worker", zap.Int("vmid", int(vmid)), zap.Error(err))
				} else {
					if err := k8sClient.DrainNode(ctx, nodeName); err != nil {
						logger.Warn("failed to drain worker", zap.String("node", nodeName), zap.Error(err))
					}
					if err := k8sClient.DeleteNode(ctx, nodeName); err != nil {
						logger.Warn("failed to delete worker from Kubernetes", zap.String("node", nodeName), zap.Error(err))
					}
				}

				if err := talosClient.ResetNode(ctx, nodeIP, true); err != nil {
					logger.Warn("graceful reset failed, trying forced reset", zap.Int("vmid", int(vmid)), zap.Error(err))
					if err := talosClient.ResetNode(ctx, nodeIP, false); err != nil {
						logger.Warn("forced reset also failed", zap.Int("vmid", int(vmid)), zap.Error(err))
					}
				}
			}

			stateMgr.RemoveNodeState(deployed, vmid, types.RoleWorker)
		}
	}

	// Phase 2: Remove control planes (with quorum check, before additions)
	if len(plan.RemoveControlPlanes) > 0 {
		logger.Info("removing control planes", zap.Int("count", len(plan.RemoveControlPlanes)))

		if len(deployed.ControlPlanes) > 0 && !cfg.DryRun {
			firstHealthyCP := deployed.ControlPlanes[0].IP
			remainingCPs := len(deployed.ControlPlanes)

			for i := range plan.RemoveControlPlanes {
				if err := talosClient.ValidateRemovalQuorum(ctx, firstHealthyCP, remainingCPs); err != nil {
					return fmt.Errorf("quorum safety check failed for removal %d/%d: %w", i+1, len(plan.RemoveControlPlanes), err)
				}
				remainingCPs--
			}

			logger.Info("quorum safety check passed",
				zap.Int("current_cps", len(deployed.ControlPlanes)),
				zap.Int("removing", len(plan.RemoveControlPlanes)))
		}

		for _, vmid := range plan.RemoveControlPlanes {
			if cfg.DryRun {
				logger.Info("would remove control plane", zap.Int("vmid", int(vmid)))
				continue
			}

			var nodeIP net.IP
			for _, cp := range deployed.ControlPlanes {
				if cp.VMID == vmid {
					nodeIP = cp.IP
					break
				}
			}

			if nodeIP != nil {
				nodeName, err := k8sClient.GetNodeNameByIP(ctx, nodeIP)
				if err != nil {
					logger.Warn("could not find k8s node name for CP", zap.Int("vmid", int(vmid)), zap.Error(err))
				} else {
					if err := k8sClient.DrainNode(ctx, nodeName); err != nil {
						logger.Warn("failed to drain control plane", zap.String("node", nodeName), zap.Error(err))
					}
				}

				var healthyEndpoint net.IP
				for _, cp := range deployed.ControlPlanes {
					if cp.VMID != vmid {
						healthyEndpoint = cp.IP
						break
					}
				}

				if healthyEndpoint != nil {
					memberID, err := talosClient.GetEtcdMemberIDByIP(ctx, healthyEndpoint, nodeIP)
					if err != nil {
						logger.Warn("failed to get etcd member ID", zap.Error(err))
					} else {
						if err := talosClient.RemoveEtcdMember(ctx, healthyEndpoint, memberID); err != nil {
							logger.Warn("failed to remove etcd member", zap.Error(err))
						}
					}
				}

				if nodeName != "" {
					if err := k8sClient.DeleteNode(ctx, nodeName); err != nil {
						logger.Warn("failed to delete CP from k8s", zap.Error(err))
					}
				}

				if err := talosClient.ResetNode(ctx, nodeIP, true); err != nil {
					logger.Warn("graceful reset failed, trying forced", zap.Int("vmid", int(vmid)), zap.Error(err))
					if err := talosClient.ResetNode(ctx, nodeIP, false); err != nil {
						logger.Warn("forced reset also failed", zap.Int("vmid", int(vmid)), zap.Error(err))
					}
				}
			}

			stateMgr.RemoveNodeState(deployed, vmid, types.RoleControlPlane)
		}
	}

	// Phase 3: Add Remaining control planes (sequential for etcd safety)
	if len(plan.AddControlPlanes) > 0 {
		logger.Info("adding control planes", zap.Int("count", len(plan.AddControlPlanes)))

		for _, vmid := range plan.AddControlPlanes {
			if plan.NeedsBootstrap && vmid == bootstrappedVMID {
				continue
			}

			spec := desired[vmid]

			if cfg.DryRun {
				logger.Info("would add control plane",
					zap.Int("vmid", int(vmid)),
					zap.String("name", spec.Name),
				)
				continue
			}

			if _, err := deployNode(ctx, vmid, types.RoleControlPlane, deployed, stateMgr, scanner, talosClient); err != nil {
				return fmt.Errorf("add CP %d: %w", vmid, err)
			}
		}
	}

	// Phase 4: Update HAProxy after any CP membership changes.
	// This MUST run before workers join so they can reach the API server via HAProxy.
	if len(plan.AddControlPlanes) > 0 || len(plan.RemoveControlPlanes) > 0 || plan.NeedsBootstrap {
		if !cfg.DryRun && len(deployed.ControlPlanes) > 0 {
			haproxyConfig := haproxy.ConfigFromClusterState(cfg, deployed)
			configStr, err := haproxyConfig.Generate()
			if err != nil {
				logger.Warn("failed to generate HAProxy config", zap.Error(err))
			} else {
				haproxyClient := haproxy.NewClient(cfg.HAProxyLoginUser, cfg.HAProxyIP.String(), logger)
				if cfg.ProxmoxSSHKeyPath != "" {
					if err := haproxyClient.SetPrivateKey(cfg.ProxmoxSSHKeyPath); err != nil {
						logger.Warn("failed to set SSH private key for HAProxy client", zap.String("key_path", cfg.ProxmoxSSHKeyPath), zap.Error(err))
					}
				}
				if err := haproxyClient.Update(ctx, configStr); err != nil {
					logger.Warn("HAProxy update failed", zap.Error(err))
				}
			}
		} else if cfg.DryRun {
			logger.Info("would update HAProxy configuration", zap.Int("backends", len(deployed.ControlPlanes)))
		}
	}

	// Phase 5: Fetch kubeconfig after bootstrap
	if plan.NeedsBootstrap && deployed.BootstrapCompleted && !cfg.DryRun {
		ensureEndpointResolvable(cfg)

		kubeconfigMgr := talos.NewKubeconfigManager(talosClient, logger)
		if len(deployed.ControlPlanes) > 0 {
			cpIP := deployed.ControlPlanes[0].IP

			logger.Info("waiting for control plane readiness before kubeconfig fetch",
				zap.String("ip", cpIP.String()))
			if err := talosClient.WaitForReady(ctx, cpIP, types.RoleControlPlane); err != nil {
				logger.Warn("CP readiness wait timed out, attempting kubeconfig fetch anyway", zap.Error(err))
			}

			if err := kubeconfigMgr.FetchAndMerge(ctx, cpIP, cfg.ClusterName, cfg.ControlPlaneEndpoint); err != nil {
				logger.Warn("kubeconfig fetch failed (can retry later)", zap.Error(err))
			} else {
				if err := kubeconfigMgr.Verify(ctx, cfg.ClusterName); err != nil {
					logger.Warn("kubeconfig verification failed", zap.Error(err))
				}
			}
		}

		configureTalosctlEndpoints(cfg, deployed)
	}

	// Phase 6: Add workers (parallel, max 3 concurrent)
	if len(plan.AddWorkers) > 0 {
		logger.Info("adding workers", zap.Int("count", len(plan.AddWorkers)))

		g, gctx := errgroup.WithContext(ctx)
		sem := make(chan struct{}, 3)

		for _, vmid := range plan.AddWorkers {
			vmid, spec := vmid, desired[vmid]

			g.Go(func() error {
				sem <- struct{}{}
				defer func() { <-sem }()

				select {
				case <-gctx.Done():
					return gctx.Err()
				default:
				}

				if cfg.DryRun {
					logger.Info("would add worker",
						zap.Int("vmid", int(vmid)),
						zap.String("name", spec.Name))
					return nil
				}

				if _, err := deployNode(gctx, vmid, types.RoleWorker, deployed, stateMgr, scanner, talosClient); err != nil {
					return fmt.Errorf("add worker %d: %w", vmid, err)
				}
				return nil
			})
		}

		if err := g.Wait(); err != nil {
			return err
		}
	}

	// Phase 7: Update configs (apply changed configurations)
	if len(plan.UpdateConfigs) > 0 {
		logger.Info("updating configurations", zap.Int("count", len(plan.UpdateConfigs)))

		for _, vmid := range plan.UpdateConfigs {
			spec, exists := desired[vmid]
			if !exists {
				continue
			}

			if cfg.DryRun {
				logger.Info("would update config", zap.Int("vmid", int(vmid)))
				continue
			}

			// Find the node's current IP
			var nodeIP net.IP
			for _, cp := range deployed.ControlPlanes {
				if cp.VMID == vmid {
					nodeIP = cp.IP
					break
				}
			}
			if nodeIP == nil {
				for _, w := range deployed.Workers {
					if w.VMID == vmid {
						nodeIP = w.IP
						break
					}
				}
			}

			if nodeIP == nil {
				logger.Warn("cannot update config - node IP not found", zap.Int("vmid", int(vmid)))
				continue
			}

			// Regenerate config in case template changed
			if _, err := talosClient.GenerateNodeConfig(ctx, spec, cfg.SecretsDir); err != nil {
				logger.Warn("failed to regenerate config for node", zap.Int("vmid", int(vmid)), zap.Error(err))
				continue
			}

			configPath := stateMgr.NodeConfigPath(vmid, spec.Role)
			logger.Info("applying updated config", zap.Int("vmid", int(vmid)))

			// Apply without --insecure (node already has certs)
			if err := talosClient.ApplyConfig(ctx, nodeIP, configPath, false); err != nil {
				logger.Warn("failed to apply updated config", zap.Int("vmid", int(vmid)), zap.Error(err))
				continue
			}

			configHash, hashErr := talos.HashFile(configPath)
			if hashErr != nil {
				logger.Warn("failed to hash config file", zap.Int("vmid", int(vmid)), zap.Error(hashErr))
			}
			stateMgr.UpdateNodeState(deployed, vmid, nodeIP.String(), configHash, spec.Role)
		}
	}

	// Phase 8: Save final state
	if !cfg.DryRun {
		deployed.Timestamp = time.Now()
		if err := stateMgr.Save(ctx, deployed); err != nil {
			return fmt.Errorf("save state: %w", err)
		}
	}

	// Phase 9: Post-reconciliation verification
	if !cfg.DryRun && deployed.BootstrapCompleted {
		verifyCluster(ctx, talosClient, k8sClient, deployed)
	}

	// Populate session counters for SUMMARY.txt
	if session != nil {
		session.ControlPlanes = len(deployed.ControlPlanes)
		session.Workers = len(deployed.Workers)
		session.AddedNodes = len(plan.AddControlPlanes) + len(plan.AddWorkers)
		session.RemovedNodes = len(plan.RemoveControlPlanes) + len(plan.RemoveWorkers)
		session.UpdatedConfigs = len(plan.UpdateConfigs)
		session.BootstrapNeeded = plan.NeedsBootstrap
	}

	return nil
}

// ensureEndpointResolvable checks DNS for the control plane endpoint and
// adds a /etc/hosts entry (via sudo tee -a) if resolution fails or points
// to the wrong IP.
func ensureEndpointResolvable(cfg *types.Config) {
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
	const hostsFile = "/etc/hosts"

	data, err := os.ReadFile(hostsFile)
	if err != nil {
		logger.Warn("cannot read hosts file", zap.String("path", hostsFile), zap.Error(err))
		logger.Warn("add the following entry manually", zap.String("entry", entry))
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
		if err := writeHostsFileSudo(hostsFile, []byte(strings.Join(lines, "\n"))); err != nil {
			logger.Warn("failed to update hosts file (add manually)", zap.String("path", hostsFile), zap.String("entry", entry), zap.Error(err))
		} else {
			logger.Info("updated hosts entry", zap.String("entry", entry))
		}
		return
	}

	// Append new entry
	cmd := exec.Command("sudo", "tee", "-a", hostsFile)
	cmd.Stdin = strings.NewReader("\n" + entry + "\n")
	cmd.Stdout = nil
	if err := cmd.Run(); err != nil {
		logger.Warn("failed to append to hosts file (add manually)", zap.String("path", hostsFile), zap.String("entry", entry), zap.Error(err))
	} else {
		logger.Info("added hosts entry", zap.String("entry", entry))
	}
}

// writeHostsFileSudo writes the full hosts file content
func writeHostsFileSudo(hostsFile string, data []byte) error {
	// Try direct write first
	if err := os.WriteFile(hostsFile, data, 0644); err == nil {
		return nil
	}
	cmd := exec.Command("sudo", "tee", hostsFile)
	cmd.Stdin = strings.NewReader(string(data))
	cmd.Stdout = nil
	return cmd.Run()
}

// configureTalosctlEndpoints sets talosctl endpoints and nodes
func configureTalosctlEndpoints(cfg *types.Config, deployed *types.ClusterState) {
	// Set endpoint to HAProxy IP
	cmd := exec.Command("talosctl", "config", "endpoint", cfg.HAProxyIP.String())
	cmd.Env = append(os.Environ(), "TALOSCONFIG="+filepath.Join(cfg.SecretsDir, "talosconfig"))
	if output, err := cmd.CombinedOutput(); err != nil {
		logger.Warn("failed to set talosctl endpoint", zap.Error(err), zap.String("output", string(output)))
	}

	// Set node to first control plane
	if len(deployed.ControlPlanes) > 0 {
		cmd = exec.Command("talosctl", "config", "node", deployed.ControlPlanes[0].IP.String())
		cmd.Env = append(os.Environ(), "TALOSCONFIG="+filepath.Join(cfg.SecretsDir, "talosconfig"))
		if output, err := cmd.CombinedOutput(); err != nil {
			logger.Warn("failed to set talosctl node", zap.Error(err), zap.String("output", string(output)))
		}
	}
}

// verifyCluster performs post-reconciliation health checks
func verifyCluster(ctx context.Context, talosClient *talos.Client, k8sClient *kubectl.Client, deployed *types.ClusterState) {
	logger.Info("verifying cluster health")

	// Check Kubernetes API
	info, err := k8sClient.ClusterInfo(ctx)
	if err != nil {
		logger.Warn("cluster-info check failed", zap.Error(err))
	} else {
		logger.Info("kubernetes API accessible", zap.String("info", strings.TrimSpace(info)))
	}

	// List nodes
	nodes, err := k8sClient.GetNodes(ctx)
	if err != nil {
		logger.Warn("failed to get nodes", zap.Error(err))
	} else {
		logger.Info("cluster nodes:\n" + nodes)
	}

	// Check etcd health
	if len(deployed.ControlPlanes) > 0 {
		members, err := talosClient.GetEtcdMembers(ctx, deployed.ControlPlanes[0].IP)
		if err != nil {
			logger.Warn("failed to get etcd members", zap.Error(err))
		} else {
			logger.Info("etcd members healthy", zap.Int("count", len(members)))
		}
	}

	// Print success summary using box
	box := logging.NewBox(os.Stderr, cfg.NoColor)
	fmt.Fprintln(os.Stderr)
	box.Header("BOOTSTRAP SUCCESSFUL")
	box.Row("Cluster", deployed.ClusterName)
	box.Row("Control Planes", fmt.Sprintf("%d", len(deployed.ControlPlanes)))
	box.Row("Workers", fmt.Sprintf("%d", len(deployed.Workers)))
	box.Divider()
	box.Section("Quick Start")
	box.Item("$", "kubectl get nodes")
	box.Item("$", "talosctl dashboard")
	box.Item("$", "talosctl etcd members")
	box.Footer()
	fmt.Fprintln(os.Stderr)
}
