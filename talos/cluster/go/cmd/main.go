package main

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/signal"
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
	cfg = types.DefaultConfig()

	// Override with environment variables
	if v := os.Getenv("CLUSTER_NAME"); v != "" {
		cfg.ClusterName = v
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

	// Initialize components
	stateMgr := state.NewManager(cfg)
	scanner := discovery.NewScanner(cfg.ProxmoxSSHUser, cfg.ProxmoxNodeIPs)
	talosClient := talos.NewClient(cfg)

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

	// Display plan
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
	if err := executePlan(ctx, plan, desired, stateMgr, scanner, talosClient); err != nil {
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
	stateMgr *state.Manager,
	scanner *discovery.Scanner,
	talosClient *talos.Client,
) error {

	// Handle bootstrap first if needed
	if plan.NeedsBootstrap {
		logger.Info("executing bootstrap")
		// Bootstrap logic here
	}

	// Remove workers (safe to do anytime)
	if len(plan.RemoveWorkers) > 0 {
		logger.Info("removing workers", zap.Int("count", len(plan.RemoveWorkers)))
		for _, vmid := range plan.RemoveWorkers {
			logger.Info("would remove worker", zap.Int("vmid", int(vmid)))
		}
	}

	// Remove control planes (check quorum!)
	if len(plan.RemoveControlPlanes) > 0 {
		logger.Info("removing control planes", zap.Int("count", len(plan.RemoveControlPlanes)))
		for _, vmid := range plan.RemoveControlPlanes {
			logger.Info("would remove control plane", zap.Int("vmid", int(vmid)))
		}
	}

	// Update configs
	if len(plan.UpdateConfigs) > 0 {
		logger.Info("updating configurations", zap.Int("count", len(plan.UpdateConfigs)))
		for _, vmid := range plan.UpdateConfigs {
			logger.Info("would update config", zap.Int("vmid", int(vmid)))
		}
	}

	// Add control planes (sequential for etcd safety)
	if len(plan.AddControlPlanes) > 0 {
		logger.Info("adding control planes", zap.Int("count", len(plan.AddControlPlanes)))
		for _, vmid := range plan.AddControlPlanes {
			spec := desired[vmid]
			logger.Info("would add control plane",
				zap.Int("vmid", int(vmid)),
				zap.String("name", spec.Name),
			)
		}
	}

	// Add workers (can be parallel)
	if len(plan.AddWorkers) > 0 {
		logger.Info("adding workers", zap.Int("count", len(plan.AddWorkers)))

		g, ctx := errgroup.WithContext(ctx)
		sem := make(chan struct{}, 3) // Max parallel workers

		for _, vmid := range plan.AddWorkers {
			vmid, spec := vmid, desired[vmid]
			g.Go(func() error {
				sem <- struct{}{}
				defer func() { <-sem }()

				logger.Info("would add worker",
					zap.Int("vmid", int(vmid)),
					zap.String("name", spec.Name),
				)
				return nil
			})
		}

		if err := g.Wait(); err != nil {
			logger.Warn("some workers failed to add", zap.Error(err))
		}
	}

	return nil
}
