package main

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/spf13/cobra"
	"go.uber.org/zap"
	"golang.org/x/sync/errgroup"

	"github.com/jdw/talos-bootstrap/pkg/discovery"
	"github.com/jdw/talos-bootstrap/pkg/state"
	"github.com/jdw/talos-bootstrap/pkg/talos"
	"github.com/jdw/talos-bootstrap/pkg/types"
)

var (
	cfg    *types.Config
	logger *zap.Logger
)

func init() {
	cfg = types.DefaultConfig()
}

func main() {
	// Initialize logger
	var err error
	logger, err = zap.NewDevelopment()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to initialize logger: %v\n", err)
		os.Exit(1)
	}
	defer logger.Sync()

	rootCmd := &cobra.Command{
		Use:   "talos-bootstrap",
		Short: "Smart reconciliation for Talos clusters",
		PersistentPreRunE: func(cmd *cobra.Command, args []string) error {
			return initConfig(cmd)
		},
	}

	// Global flags
	rootCmd.PersistentFlags().StringVarP(&cfg.ClusterName, "cluster", "c", "cluster", "Cluster name")
	rootCmd.PersistentFlags().StringVar(&cfg.TerraformTFVars, "tfvars", "terraform.tfvars", "Path to terraform.tfvars")
	rootCmd.PersistentFlags().BoolVarP(&cfg.AutoApprove, "auto-approve", "a", false, "Skip confirmations")
	rootCmd.PersistentFlags().BoolVarP(&cfg.DryRun, "dry-run", "d", false, "Simulate only")
	rootCmd.PersistentFlags().BoolVarP(&cfg.SkipPreflight, "skip-preflight", "s", false, "Skip connectivity checks")
	rootCmd.PersistentFlags().StringVarP(&cfg.LogLevel, "log-level", "l", "info", "Log level (debug, info, warn, error)")

	rootCmd.AddCommand(
		bootstrapCmd(),
		reconcileCmd(),
		statusCmd(),
		resetCmd(),
	)

	if err := rootCmd.Execute(); err != nil {
		logger.Fatal("execute failed", zap.Error(err))
	}
}

func initConfig(cmd *cobra.Command) error {
	// Override with environment variables
	if v := os.Getenv("CLUSTER_NAME"); v != "" {
		cfg.ClusterName = v
		// Update SecretsDir when CLUSTER_NAME changes
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

	return nil
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

			clusterDir := fmt.Sprintf("clusters/%s", cfg.ClusterName)
			if err := os.RemoveAll(clusterDir); err != nil {
				return fmt.Errorf("remove cluster dir: %w", err)
			}
			fmt.Printf("Reset cluster %s\n", cfg.ClusterName)
			return nil
		},
	}
}

// runReconcile is the main orchestration logic
func runReconcile(ctx context.Context, cfg *types.Config) error {
	logger.Info("starting reconciliation",
		zap.String("cluster", cfg.ClusterName),
		zap.Bool("dry_run", cfg.DryRun),
		zap.Bool("plan_mode", cfg.PlanMode),
	)

	stateMgr := state.NewManager(cfg)
	scanner := discovery.NewScanner(cfg.ProxmoxSSHUser, cfg.ProxmoxNodeIPs)
	talosClient := talos.NewClient(cfg)

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
	logger.Info("loaded desired state", zap.Int("nodes", len(desired)))

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
	if err := executePlan(ctx, plan, desired, deployed, stateMgr, scanner, talosClient); err != nil {
		return fmt.Errorf("execute plan: %w", err)
	}

	logger.Info("reconciliation complete")
	return nil
}

func runStatus(ctx context.Context, cfg *types.Config) error {
	stateMgr := state.NewManager(cfg)

	desired, err := stateMgr.LoadDesiredState(ctx)
	if err != nil {
		return err
	}

	deployed, err := stateMgr.LoadDeployedState(ctx)
	if err != nil {
		return err
	}

	fmt.Printf("\n=== Cluster: %s ===\n\n", cfg.ClusterName)

	fmt.Printf("Desired State (Terraform):\n")
	fmt.Printf("  Control Planes: %d\n", countByRole(desired, types.RoleControlPlane))
	fmt.Printf("  Workers: %d\n", countByRole(desired, types.RoleWorker))

	fmt.Printf("\nDeployed State:\n")
	fmt.Printf("  Control Planes: %d\n", len(deployed.ControlPlanes))
	for _, cp := range deployed.ControlPlanes {
		fmt.Printf("    - VMID %d: %s\n", cp.VMID, cp.IP)
	}
	fmt.Printf("  Workers: %d\n", len(deployed.Workers))
	for _, w := range deployed.Workers {
		fmt.Printf("    - VMID %d: %s\n", w.VMID, w.IP)
	}
	fmt.Printf("  Bootstrap Completed: %v\n", deployed.BootstrapCompleted)

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
	fmt.Println("\n=== RECONCILIATION PLAN ===")
	if plan.NeedsBootstrap {
		fmt.Println("  [BOOTSTRAP] Cluster needs bootstrap")
	}
	if len(plan.AddControlPlanes) > 0 {
		fmt.Printf("  [ADD CP]    %d control plane(s): %v\n", len(plan.AddControlPlanes), plan.AddControlPlanes)
	}
	if len(plan.AddWorkers) > 0 {
		fmt.Printf("  [ADD WORK]  %d worker(s): %v\n", len(plan.AddWorkers), plan.AddWorkers)
	}
	if len(plan.RemoveControlPlanes) > 0 {
		fmt.Printf("  [REM CP]    %d control plane(s): %v\n", len(plan.RemoveControlPlanes), plan.RemoveControlPlanes)
	}
	if len(plan.RemoveWorkers) > 0 {
		fmt.Printf("  [REM WORK]  %d worker(s): %v\n", len(plan.RemoveWorkers), plan.RemoveWorkers)
	}
	if len(plan.UpdateConfigs) > 0 {
		fmt.Printf("  [UPDATE]    %d node(s): %v\n", len(plan.UpdateConfigs), plan.UpdateConfigs)
	}
	if len(plan.NoOp) > 0 {
		fmt.Printf("  [NOOP]      %d node(s) unchanged\n", len(plan.NoOp))
	}
	if plan.IsEmpty() {
		fmt.Println("  [NO CHANGES] Cluster matches desired state")
	}
	fmt.Println()
}

func executePlan(
	ctx context.Context,
	plan *types.ReconcilePlan,
	desired map[types.VMID]*types.NodeSpec,
	deployed *types.ClusterState,
	stateMgr *state.Manager,
	scanner *discovery.Scanner,
	talosClient *talos.Client,
) error {

	// Handle bootstrap first if needed
	if plan.NeedsBootstrap {
		logger.Info("executing bootstrap")

		if len(plan.AddControlPlanes) > 0 {
			firstVMID := plan.AddControlPlanes[0]
			spec := desired[firstVMID]

			liveNodes, err := scanner.DiscoverVMs(ctx, []types.VMID{firstVMID})
			if err != nil {
				return fmt.Errorf("discover first control plane: %w", err)
			}

			node, ok := liveNodes[firstVMID]
			if !ok || node.IP == nil {
				return fmt.Errorf("first control plane IP not discovered")
			}

			if !cfg.DryRun {
				configPath := stateMgr.NodeConfigPath(firstVMID, types.RoleControlPlane)

				if err := talosClient.ApplyConfig(ctx, node.IP, configPath, true); err != nil {
					return fmt.Errorf("apply config to first CP: %w", err)
				}

				newIP, err := scanner.RediscoverIP(ctx, firstVMID, node.MAC)
				if err != nil {
					return fmt.Errorf("rediscover IP after reboot: %w", err)
				}

				if err := talosClient.BootstrapEtcd(ctx, newIP); err != nil {
					return fmt.Errorf("bootstrap etcd: %w", err)
				}

				hash, _ := stateMgr.ComputeTerraformHash()
				stateMgr.UpdateNodeState(deployed, firstVMID, newIP.String(), hash, types.RoleControlPlane)
				deployed.BootstrapCompleted = true
			} else {
				logger.Info("would bootstrap first control plane",
					zap.Int("vmid", int(firstVMID)),
					zap.String("name", spec.Name),
				)
			}
		}
	}

	// Add remaining control planes (sequential for etcd safety)
	if len(plan.AddControlPlanes) > 0 {
		logger.Info("adding control planes", zap.Int("count", len(plan.AddControlPlanes)))

		for _, vmid := range plan.AddControlPlanes {
			if plan.NeedsBootstrap && vmid == plan.AddControlPlanes[0] {
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

			liveNodes, err := scanner.DiscoverVMs(ctx, []types.VMID{vmid})
			if err != nil {
				return fmt.Errorf("discover VM %d: %w", vmid, err)
			}

			node, ok := liveNodes[vmid]
			if !ok || node.IP == nil {
				return fmt.Errorf("VM %d IP not discovered", vmid)
			}

			configPath := stateMgr.NodeConfigPath(vmid, types.RoleControlPlane)
			if err := talosClient.ApplyConfig(ctx, node.IP, configPath, true); err != nil {
				return fmt.Errorf("apply config to CP %d: %w", vmid, err)
			}

			newIP, err := scanner.RediscoverIP(ctx, vmid, node.MAC)
			if err != nil {
				return fmt.Errorf("rediscover IP for CP %d: %w", vmid, err)
			}

			if err := talosClient.WaitForReady(ctx, newIP, types.RoleControlPlane); err != nil {
				return fmt.Errorf("wait for CP %d ready: %w", vmid, err)
			}

			hash, _ := stateMgr.ComputeTerraformHash()
			stateMgr.UpdateNodeState(deployed, vmid, newIP.String(), hash, types.RoleControlPlane)
		}
	}

	// Add workers (parallel)
	if len(plan.AddWorkers) > 0 {
		logger.Info("adding workers", zap.Int("count", len(plan.AddWorkers)))

		g, ctx := errgroup.WithContext(ctx)
		sem := make(chan struct{}, 3)

		for _, vmid := range plan.AddWorkers {
			vmid, spec := vmid, desired[vmid]

			g.Go(func() error {
				sem <- struct{}{}
				defer func() { <-sem }()

				select {
				case <-ctx.Done():
					return ctx.Err()
				default:
				}

				if cfg.DryRun {
					logger.Info("would add worker",
						zap.Int("vmid", int(vmid)),
						zap.String("name", spec.Name),
					)
					return nil
				}

				liveNodes, err := scanner.DiscoverVMs(ctx, []types.VMID{vmid})
				if err != nil {
					return fmt.Errorf("discover worker %d: %w", vmid, err)
				}

				node, ok := liveNodes[vmid]
				if !ok || node.IP == nil {
					return fmt.Errorf("worker %d IP not discovered", vmid)
				}

				configPath := stateMgr.NodeConfigPath(vmid, types.RoleWorker)
				if err := talosClient.ApplyConfig(ctx, node.IP, configPath, true); err != nil {
					return fmt.Errorf("apply config to worker %d: %w", vmid, err)
				}

				newIP, err := scanner.RediscoverIP(ctx, vmid, node.MAC)
				if err != nil {
					return fmt.Errorf("rediscover IP for worker %d: %w", vmid, err)
				}

				if err := talosClient.WaitForReady(ctx, newIP, types.RoleWorker); err != nil {
					return fmt.Errorf("wait for worker %d ready: %w", vmid, err)
				}

				hash, _ := stateMgr.ComputeTerraformHash()
				stateMgr.UpdateNodeState(deployed, vmid, newIP.String(), hash, types.RoleWorker)

				return nil
			})
		}

		if err := g.Wait(); err != nil {
			return err
		}
	}

	// Remove workers
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
				if err := talosClient.ResetNode(ctx, nodeIP, true); err != nil {
					logger.Warn("failed to reset worker", zap.Int("vmid", int(vmid)), zap.Error(err))
				}
			}

			stateMgr.RemoveNodeState(deployed, vmid, types.RoleWorker)
		}
	}

	// Remove control planes (with quorum check)
	if len(plan.RemoveControlPlanes) > 0 {
		logger.Info("removing control planes", zap.Int("count", len(plan.RemoveControlPlanes)))

		if len(deployed.ControlPlanes) > 0 {
			members, err := talosClient.GetEtcdMembers(ctx, deployed.ControlPlanes[0].IP)
			if err != nil {
				return fmt.Errorf("get etcd members for quorum check: %w", err)
			}

			currentMembers := len(members)
			removing := len(plan.RemoveControlPlanes)
			afterRemoval := currentMembers - removing
			quorum := (currentMembers / 2) + 1

			if afterRemoval < quorum {
				return fmt.Errorf("cannot remove %d control planes: would violate etcd quorum (current=%d, after=%d, quorum=%d)",
					removing, currentMembers, afterRemoval, quorum)
			}
		}

		for _, vmid := range plan.RemoveControlPlanes {
			if cfg.DryRun {
				logger.Info("would remove control plane", zap.Int("vmid", int(vmid)))
				continue
			}

			var nodeIP net.IP
			var memberID string
			for _, cp := range deployed.ControlPlanes {
				if cp.VMID == vmid {
					nodeIP = cp.IP
					break
				}
			}

			if nodeIP != nil && memberID != "" {
				if err := talosClient.RemoveEtcdMember(ctx, nodeIP, memberID); err != nil {
					logger.Warn("failed to remove etcd member", zap.Error(err))
				}

				if err := talosClient.ResetNode(ctx, nodeIP, true); err != nil {
					logger.Warn("failed to reset control plane", zap.Int("vmid", int(vmid)), zap.Error(err))
				}
			}

			stateMgr.RemoveNodeState(deployed, vmid, types.RoleControlPlane)
		}
	}

	// Update configs
	if len(plan.UpdateConfigs) > 0 {
		logger.Info("updating configurations", zap.Int("count", len(plan.UpdateConfigs)))
		for _, vmid := range plan.UpdateConfigs {
			logger.Info("would update config", zap.Int("vmid", int(vmid)))
		}
	}

	// Save final state
	if !cfg.DryRun {
		if err := stateMgr.Save(ctx, deployed); err != nil {
			return fmt.Errorf("save state: %w", err)
		}
	}

	return nil
}
