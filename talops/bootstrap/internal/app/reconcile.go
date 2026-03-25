package app

import (
	"context"
	"fmt"
	"net"
	"os"
	"time"

	"github.com/jdwlabs/infrastructure/bootstrap/internal/discovery"
	"github.com/jdwlabs/infrastructure/bootstrap/internal/haproxy"
	"github.com/jdwlabs/infrastructure/bootstrap/internal/kubectl"
	"github.com/jdwlabs/infrastructure/bootstrap/internal/state"
	"github.com/jdwlabs/infrastructure/bootstrap/internal/talos"
	"github.com/jdwlabs/infrastructure/bootstrap/internal/types"
	"go.uber.org/zap"
	"golang.org/x/sync/errgroup"
)

func (app *App) RunReconcile(ctx context.Context) error {
	cfg := app.Cfg
	stateMgr := state.NewManager(cfg, app.Logger)

	// Resolve terraform.tfvars path (tries configured path, then parent directory)
	if err := stateMgr.ResolveTFVarsPath(); err != nil {
		app.Logger.Warn("could not locate terraform.tfvars", zap.Error(err))
	}

	// Load additional fields from terraform.tfvars (cluster_name, proxmox tokens)
	if err := stateMgr.LoadTerraformExtras(ctx); err != nil {
		app.Logger.Warn("could not load terraform extras", zap.String("path", cfg.TerraformTFVars), zap.Error(err))
	}

	if err := cfg.Validate(); err != nil {
		app.Logger.Error("configuration incomplete", zap.Error(err))
		return fmt.Errorf("configuration incomplete: %w", err)
	}

	app.Logger.Info("starting reconciliation",
		zap.String("cluster", cfg.ClusterName),
		zap.Bool("dry_run", cfg.DryRun),
		zap.Bool("plan_mode", cfg.PlanMode),
	)

	if app.Session != nil && app.Session.AuditLog != nil {
		app.Session.AuditLog.WriteEntry("RECONCILE-START", fmt.Sprintf("cluster=%s dry_run=%v plan_mode=%v", cfg.ClusterName, cfg.DryRun, cfg.PlanMode))
	}

	if cfg.InsecureSSH {
		app.Logger.Warn("SSH host key verification is disabled (--insecure-ssh)")
	}
	scanner := discovery.NewScanner(cfg.ProxmoxSSHUser, cfg.ProxmoxNodeIPs, cfg.InsecureSSH)
	defer scanner.Close()
	talosClient := talos.NewClient(cfg)
	talosClient.SetLogger(app.Logger)
	if app.Session != nil && app.Session.AuditLog != nil {
		talosClient.SetAuditLogger(app.Session.AuditLog)
	}
	k8sClient := kubectl.NewClient(app.Logger)
	k8sClient.SetContext(cfg.ClusterName)

	// Configure SSH authentication for scanner
	if cfg.ProxmoxSSHKeyPath != "" {
		if err := scanner.SetPrivateKey(cfg.ProxmoxSSHKeyPath); err != nil {
			app.Logger.Warn("failed to set SSH private key for scanner", zap.String("key_path", cfg.ProxmoxSSHKeyPath), zap.Error(err))
		}
	}

	// Refresh Proxmox node IP map from the cluster
	if !cfg.SkipPreflight {
		app.Logger.Info("refreshing proxmox node IPs")
		scanner.RefreshProxmoxNodes(ctx)
	}

	// Initialize Talos client
	if err := talosClient.Initialize(ctx); err != nil {
		app.Logger.Error("failed to initialize talos client", zap.Error(err))
		return fmt.Errorf("initialize talos client: %w", err)
	}

	// Phase 1: Load states
	app.Logger.Info("loading desired state from terraform")
	desired, err := stateMgr.LoadDesiredState(ctx)
	if err != nil {
		app.Logger.Error("failed to load desired state", zap.Error(err))
		return fmt.Errorf("load desired state: %w", err)
	}
	if len(desired) == 0 {
		app.Logger.Error("no nodes defined in desired state")
		return fmt.Errorf("no nodes defined in desired state - check your terraform.tfvars")
	}
	app.Logger.Info("loaded desired state", zap.Int("nodes", len(desired)))

	// Generate node configs for any desired nodes missing configs
	for vmid, spec := range desired {
		configPath := stateMgr.NodeConfigPath(vmid, spec.Role)
		if _, err := os.Stat(configPath); os.IsNotExist(err) {
			app.Logger.Info("generating config for node", zap.Int("vmid", int(vmid)), zap.String("role", string(spec.Role)))
			if _, err := talosClient.GenerateNodeConfig(ctx, spec, cfg.SecretsDir); err != nil {
				app.Logger.Error("failed to generate node config", zap.Error(err))
				return fmt.Errorf("generate config for VMID %d: %w", vmid, err)
			}
		}
	}

	app.Logger.Info("loading deployed state")
	deployed, err := stateMgr.LoadDeployedState(ctx)
	if err != nil {
		app.Logger.Error("failed to load deployed state", zap.Error(err))
		return fmt.Errorf("load deployed state: %w", err)
	}

	// Phase 2: Discovery
	app.Logger.Info("discovering live state")
	vmids := make([]types.VMID, 0, len(desired))
	for vmid := range desired {
		vmids = append(vmids, vmid)
	}

	var live map[types.VMID]*types.LiveNode
	if !cfg.SkipPreflight {
		if err := scanner.RepopulateARP(ctx); err != nil {
			app.Logger.Warn("ARP repopulation failed", zap.Error(err))
		}
		live, err = scanner.DiscoverVMs(ctx, vmids)
		if err != nil {
			app.Logger.Error("failed to discover VMs", zap.Error(err))
			return fmt.Errorf("discover VMs: %w", err)
		}
		app.Logger.Info("discovered live state", zap.Int("found", len(live)))

		for vmid, node := range live {
			if node.IP != nil {
				app.Logger.Debug("discovered VM", zap.Int("vmid", int(vmid)), zap.String("ip", node.IP.String()), zap.String("status", string(node.Status)))
			} else {
				app.Logger.Debug("discovered VM (no IP)", zap.Int("vmid", int(vmid)), zap.String("mac", node.MAC), zap.String("status", string(node.Status)))
			}
		}

		// Mark nodes that are already joined Talos cluster members
		if deployed.BootstrapCompleted && len(deployed.ControlPlanes) > 0 {
			if members, err := talosClient.GetClusterMembers(ctx, deployed.ControlPlanes[0].IP); err == nil {
				scanner.MarkJoinedNodes(members, live)
			}
		}

		// Preflight: verify Talos API (port 50000) is reachable on discovered VMs
		app.Logger.Info("running Talos API preflight checks")
		for vmid, node := range live {
			if node.IP == nil {
				continue
			}
			addr := fmt.Sprintf("%s:50000", node.IP)
			conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
			if err != nil {
				app.Logger.Warn("Talos API not reachable on VM (may not be booted yet)",
					zap.Int("vmid", int(vmid)), zap.String("ip", node.IP.String()), zap.Error(err))
			} else {
				conn.Close()
				app.Logger.Debug("Talos API reachable", zap.Int("vmid", int(vmid)), zap.String("ip", node.IP.String()))
			}
		}
	} else {
		live = make(map[types.VMID]*types.LiveNode)
	}

	// Phase 3: Build plan
	app.Logger.Info("building reconciliation plan")
	plan, err := stateMgr.BuildReconcilePlan(ctx, desired, deployed, live)
	if err != nil {
		app.Logger.Error("failed to build reconciliation plan", zap.Error(err))
		return fmt.Errorf("build plan: %w", err)
	}

	app.DisplayPlan(plan)

	if cfg.PlanMode {
		app.Logger.Info("plan mode - exiting without changes")
		return nil
	}

	if plan.IsEmpty() {
		app.Logger.Info("no changes required")
		return nil
	}

	// Confirm if not auto-approved
	if !cfg.AutoApprove && !cfg.DryRun {
		if !app.PromptConfirm("Proceed with changes? [y/N]: ") {
			return nil
		}
	}

	// Phase 4: Execute
	if err := app.executePlan(ctx, plan, desired, deployed, live, stateMgr, scanner, talosClient, k8sClient); err != nil {
		app.Logger.Error("plan execution failed", zap.Error(err))
		if app.Session != nil && app.Session.AuditLog != nil {
			app.Session.AuditLog.WriteEntry("RECONCILE-END", fmt.Sprintf("cluster=%s status=failed error=%v", cfg.ClusterName, err))
		}
		return fmt.Errorf("execute plan: %w", err)
	}

	app.Logger.Info("reconciliation complete")
	if app.Session != nil && app.Session.AuditLog != nil {
		app.Session.AuditLog.WriteEntry("RECONCILE-END", fmt.Sprintf("cluster=%s status=success", cfg.ClusterName))
	}
	return nil
}

// deployNode handles the apply -> reboot -> wait -> hash flow for adding a node
func (app *App) deployNode(
	ctx context.Context,
	vmid types.VMID,
	role types.Role,
	live map[types.VMID]*types.LiveNode,
	deployed *types.ClusterState,
	stateMgr *state.Manager,
	scanner *discovery.Scanner,
	talosClient *talos.Client,
) (net.IP, error) {
	node, ok := live[vmid]
	if !ok || node.IP == nil {
		// Retry IP discovery up to 3 times with 10s intervals - VMs may still be booting
		const maxRetries = 3
		for attempt := 1; attempt <= maxRetries; attempt++ {
			app.Logger.Info("VM not in live map, re-discovering",
				zap.Int("vmid", int(vmid)),
				zap.Int("attempt", attempt),
				zap.Int("max_attempts", maxRetries))
			if err := scanner.RepopulateARP(ctx); err != nil {
				app.Logger.Warn("ARP repopulation failed", zap.Error(err))
			}
			liveNodes, err := scanner.DiscoverVMs(ctx, []types.VMID{vmid})
			if err != nil {
				app.Logger.Error("failed to discover VM", zap.Int("vmid", int(vmid)), zap.Error(err))
			} else {
				node, ok = liveNodes[vmid]
				if ok && node.IP != nil {
					break
				}
			}
			if attempt < maxRetries {
				app.Logger.Info("VM IP not yet available, waiting before retry",
					zap.Int("vmid", int(vmid)),
					zap.Duration("wait", 10*time.Second))
				select {
				case <-ctx.Done():
					return nil, fmt.Errorf("context cancelled waiting for VM %d IP: %w", vmid, ctx.Err())
				case <-time.After(10 * time.Second):
				}
			}
		}
		if !ok || node == nil || node.IP == nil {
			app.Logger.Error("VM IP not discovered after retries", zap.Int("vmid", int(vmid)))
			return nil, fmt.Errorf("VM %d IP not discovered after %d attempts", vmid, maxRetries)
		}
	}

	configPath := stateMgr.NodeConfigPath(vmid, role)
	app.Logger.Info("applying config", zap.Int("vmid", int(vmid)), zap.String("role", string(role)))
	if app.Session != nil && app.Session.AuditLog != nil {
		app.Session.AuditLog.WriteEntry("APPLY-CONFIG", fmt.Sprintf("vmid=%d role=%s ip=%s", vmid, role, node.IP))
	}
	if err := talosClient.ApplyConfigWithRetry(ctx, node.IP, configPath, role, 5); err != nil {
		app.Logger.Error("failed to apply config", zap.Int("vmid", int(vmid)), zap.String("role", string(role)), zap.Error(err))
		return nil, fmt.Errorf("apply config to %s %d: %w", role, vmid, err)
	}

	monitor := discovery.NewRebootMonitor(vmid, node.IP, node.MAC, scanner, app.Logger)
	newIP, err := monitor.WaitForReady(ctx, 5*time.Minute)
	if err != nil {
		app.Logger.Error("node reboot wait failed", zap.Int("vmid", int(vmid)), zap.String("role", string(role)), zap.Error(err))
		return nil, fmt.Errorf("wait for %s %d reboot: %w", role, vmid, err)
	}

	if err := talosClient.WaitForAPI(ctx, newIP); err != nil {
		app.Logger.Error("Talos API not reachable", zap.Int("vmid", int(vmid)), zap.String("role", string(role)), zap.Error(err))
		return nil, fmt.Errorf("wait for %s %d API: %w", role, vmid, err)
	}

	configHash, hashErr := talos.HashFile(configPath)
	if hashErr != nil {
		app.Logger.Warn("failed to hash config file", zap.Int("vmid", int(vmid)), zap.Error(hashErr))
	}
	stateMgr.UpdateNodeState(deployed, vmid, newIP.String(), configHash, role)

	app.Logger.Info("node deployed, Talos API responding", zap.Int("vmid", int(vmid)), zap.String("role", string(role)), zap.String("ip", newIP.String()))
	return newIP, nil
}

func (app *App) executePlan(
	ctx context.Context,
	plan *types.ReconcilePlan,
	desired map[types.VMID]*types.NodeSpec,
	deployed *types.ClusterState,
	live map[types.VMID]*types.LiveNode,
	stateMgr *state.Manager,
	scanner *discovery.Scanner,
	talosClient *talos.Client,
	k8sClient *kubectl.Client,
) error {
	cfg := app.Cfg

	// Populate session counters early so SUMMARY.txt has data even on error
	if app.Session != nil {
		app.Session.ControlPlanes = len(deployed.ControlPlanes)
		app.Session.Workers = len(deployed.Workers)
		app.Session.AddedNodes = len(plan.AddControlPlanes) + len(plan.AddWorkers)
		app.Session.RemovedNodes = len(plan.RemoveControlPlanes) + len(plan.RemoveWorkers)
		app.Session.UpdatedConfigs = len(plan.UpdateConfigs)
		app.Session.BootstrapNeeded = plan.NeedsBootstrap
	}

	var bootstrappedVMID types.VMID

	audit := func(tag, msg string) {
		if app.Session != nil && app.Session.AuditLog != nil {
			app.Session.AuditLog.WriteEntry(tag, msg)
		}
	}

	// Phase 0: Bootstrap first CP if needed
	if plan.NeedsBootstrap {
		app.Logger.Info("executing bootstrap")
		audit("BOOTSTRAP-START", fmt.Sprintf("control_planes=%d workers=%d", len(plan.AddControlPlanes), len(plan.AddWorkers)))

		if len(plan.AddControlPlanes) > 0 {
			firstVMID := plan.AddControlPlanes[0]
			bootstrappedVMID = firstVMID
			spec := desired[firstVMID]

			if cfg.DryRun {
				app.Logger.Info("would bootstrap first control plane",
					zap.Int("vmid", int(firstVMID)),
					zap.String("name", spec.Name))
			} else {
				newIP, err := app.deployNode(ctx, firstVMID, types.RoleControlPlane, live, deployed, stateMgr, scanner, talosClient)
				if err != nil {
					app.Logger.Error("bootstrap first control plane failed", zap.Int("vmid", int(firstVMID)), zap.Error(err))
					return fmt.Errorf("bootstrap first CP: %w", err)
				}

				app.Logger.Info("bootstrapping etcd on first control plane", zap.String("ip", newIP.String()), zap.Int("vmid", int(firstVMID)))
				if err := talosClient.BootstrapEtcd(ctx, newIP); err != nil {
					app.Logger.Error("etcd bootstrap failed", zap.String("ip", newIP.String()), zap.Int("vmid", int(firstVMID)), zap.Error(err))
					return fmt.Errorf("bootstrap etcd: %w", err)
				}

				if err := talosClient.WaitForEtcdHealthy(ctx, newIP, 5*time.Minute); err != nil {
					app.Logger.Error("etcd health check timed out", zap.String("ip", newIP.String()), zap.Int("vmid", int(firstVMID)), zap.Error(err))
					return fmt.Errorf("wait for etcd healthy: %w", err)
				}
				app.Logger.Info("first control plane ready (API + etcd)", zap.String("ip", newIP.String()), zap.Int("vmid", int(firstVMID)))
			}

			deployed.BootstrapCompleted = true
			if err := stateMgr.Save(ctx, deployed); err != nil {
				app.Logger.Error("failed to save state after bootstrap", zap.Error(err))
				return fmt.Errorf("save state after bootstrap: %w", err)
			}
		}
	} else if len(deployed.ControlPlanes) > 0 && !deployed.BootstrapCompleted {
		if cfg.DryRun {
			app.Logger.Info("would bootstrap etcd on existing first control plane",
				zap.Int("vmid", int(deployed.ControlPlanes[0].VMID)))
		} else {
			firstCP := deployed.ControlPlanes[0]
			app.Logger.Info("bootstrapping etcd on already-deployed control plane",
				zap.String("ip", firstCP.IP.String()), zap.Int("vmid", int(firstCP.VMID)))
			if err := talosClient.BootstrapEtcd(ctx, firstCP.IP); err != nil {
				app.Logger.Error("deferred etcd bootstrap failed", zap.String("ip", firstCP.IP.String()), zap.Int("vmid", int(firstCP.VMID)), zap.Error(err))
				return fmt.Errorf("deferred bootstrap etcd: %w", err)
			}

			if err := talosClient.WaitForEtcdHealthy(ctx, firstCP.IP, 5*time.Minute); err != nil {
				app.Logger.Error("failed to save state after deferred bootstrap", zap.Error(err))
				return fmt.Errorf("wait for etcd healthy: %w", err)
			}

			deployed.BootstrapCompleted = true
			if err := stateMgr.Save(ctx, deployed); err != nil {
				return fmt.Errorf("save state after deferred bootstrap: %w", err)
			}
		}
	}

	// Phase 1: Remove workers
	if len(plan.RemoveWorkers) > 0 {
		app.Logger.Info("removing workers", zap.Int("count", len(plan.RemoveWorkers)))
		audit("REMOVE-WORKERS", fmt.Sprintf("count=%d vmids=%v", len(plan.RemoveWorkers), plan.RemoveWorkers))

		for _, vmid := range plan.RemoveWorkers {
			if cfg.DryRun {
				app.Logger.Info("would remove worker", zap.Int("vmid", int(vmid)))
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
					app.Logger.Warn("failed to get node name for worker", zap.Int("vmid", int(vmid)), zap.Error(err))
				} else {
					if err := k8sClient.DrainNode(ctx, nodeName); err != nil {
						app.Logger.Warn("failed to drain worker", zap.String("node", nodeName), zap.Error(err))
					}
					if err := k8sClient.DeleteNode(ctx, nodeName); err != nil {
						app.Logger.Warn("failed to delete worker from Kubernetes", zap.String("node", nodeName), zap.Error(err))
					}
				}

				if err := talosClient.ResetNode(ctx, nodeIP, true); err != nil {
					app.Logger.Warn("graceful reset failed, trying forced reset", zap.Int("vmid", int(vmid)), zap.Error(err))
					if err := talosClient.ResetNode(ctx, nodeIP, false); err != nil {
						app.Logger.Warn("forced reset also failed", zap.Int("vmid", int(vmid)), zap.Error(err))
					}
				}
			}

			stateMgr.RemoveNodeState(deployed, vmid, types.RoleWorker)
		}
	}

	// Phase 2: Remove control planes (with quorum check)
	if len(plan.RemoveControlPlanes) > 0 {
		app.Logger.Info("removing control planes", zap.Int("count", len(plan.RemoveControlPlanes)))
		audit("REMOVE-CPS", fmt.Sprintf("count=%d vmids=%v", len(plan.RemoveControlPlanes), plan.RemoveControlPlanes))

		if len(deployed.ControlPlanes) > 0 && !cfg.DryRun {
			firstHealthyCP := deployed.ControlPlanes[0].IP
			remainingCPs := len(deployed.ControlPlanes)

			for i := range plan.RemoveControlPlanes {
				if err := talosClient.ValidateRemovalQuorum(ctx, firstHealthyCP, remainingCPs); err != nil {
					app.Logger.Error("quorum safety check failed", zap.Int("removal", i+1), zap.Int("total", len(plan.RemoveControlPlanes)), zap.Error(err))
					return fmt.Errorf("quorum safety check failed for removal %d/%d: %w", i+1, len(plan.RemoveControlPlanes), err)
				}
				remainingCPs--
			}

			app.Logger.Info("quorum safety check passed",
				zap.Int("current_cps", len(deployed.ControlPlanes)),
				zap.Int("removing", len(plan.RemoveControlPlanes)))
		}

		for _, vmid := range plan.RemoveControlPlanes {
			if cfg.DryRun {
				app.Logger.Info("would remove control plane", zap.Int("vmid", int(vmid)))
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
					app.Logger.Warn("could not find k8s node name for CP", zap.Int("vmid", int(vmid)), zap.Error(err))
				} else {
					if err := k8sClient.DrainNode(ctx, nodeName); err != nil {
						app.Logger.Warn("failed to drain control plane", zap.String("node", nodeName), zap.Error(err))
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
						app.Logger.Warn("failed to get etcd member ID", zap.Error(err))
					} else {
						if err := talosClient.RemoveEtcdMember(ctx, healthyEndpoint, memberID); err != nil {
							app.Logger.Warn("failed to remove etcd member", zap.Error(err))
						}
					}
				}

				if nodeName != "" {
					if err := k8sClient.DeleteNode(ctx, nodeName); err != nil {
						app.Logger.Warn("failed to delete CP from k8s", zap.Error(err))
					}
				}

				if err := talosClient.ResetNode(ctx, nodeIP, true); err != nil {
					app.Logger.Warn("graceful reset failed, trying forced", zap.Int("vmid", int(vmid)), zap.Error(err))
					if err := talosClient.ResetNode(ctx, nodeIP, false); err != nil {
						app.Logger.Warn("forced reset also failed", zap.Int("vmid", int(vmid)), zap.Error(err))
					}
				}
			}

			stateMgr.RemoveNodeState(deployed, vmid, types.RoleControlPlane)
		}
	}

	// Phase 3: Add remaining control planes (sequential for etcd safety)
	if len(plan.AddControlPlanes) > 0 {
		app.Logger.Info("adding control planes", zap.Int("count", len(plan.AddControlPlanes)))
		audit("ADD-CPS", fmt.Sprintf("count=%d vmids=%v", len(plan.AddControlPlanes), plan.AddControlPlanes))

		for _, vmid := range plan.AddControlPlanes {
			if plan.NeedsBootstrap && vmid == bootstrappedVMID {
				continue
			}

			spec := desired[vmid]

			if cfg.DryRun {
				app.Logger.Info("would add control plane",
					zap.Int("vmid", int(vmid)),
					zap.String("name", spec.Name),
				)
				continue
			}

			if _, err := app.deployNode(ctx, vmid, types.RoleControlPlane, live, deployed, stateMgr, scanner, talosClient); err != nil {
				app.Logger.Error("failed to add control plane", zap.Int("vmid", int(vmid)), zap.Error(err))
				return fmt.Errorf("add CP %d: %w", vmid, err)
			}
		}
	}

	// Phase 4: Update HAProxy after any CP membership changes
	if len(plan.AddControlPlanes) > 0 || len(plan.RemoveControlPlanes) > 0 || plan.NeedsBootstrap {
		if !cfg.DryRun && len(deployed.ControlPlanes) > 0 {
			haproxyConfig := haproxy.ConfigFromClusterState(cfg, deployed)
			configStr, err := haproxyConfig.Generate()
			if err != nil {
				app.Logger.Warn("failed to generate HAProxy config", zap.Error(err))
			} else {
				haproxyClient := haproxy.NewClient(cfg.HAProxyLoginUser, cfg.HAProxyIP.String(), app.Logger, cfg.InsecureSSH)
				haproxyKeyPath := cfg.HAProxySSHKeyPath
				if haproxyKeyPath == "" {
					haproxyKeyPath = cfg.HAProxySSHKeyPath
				}
				keyOK := true
				if haproxyKeyPath != "" {
					if err := haproxyClient.SetPrivateKey(haproxyKeyPath); err != nil {
						app.Logger.Error("failed to set SSH private key for HAProxy client", zap.String("key_path", haproxyKeyPath), zap.Error(err))
						if plan.NeedsBootstrap {
							return fmt.Errorf("HAProxy SSH key setup failed: %w", err)
						}
						app.Logger.Warn("skipping HAProxy update due to SSH key failure")
						keyOK = false
					}
				}
				if keyOK {
					if err := haproxyClient.Update(ctx, configStr); err != nil {
						if plan.NeedsBootstrap {
							app.Logger.Error("HAProxy update failed during bootstrap (fatal)", zap.Error(err))
							return fmt.Errorf("HAProxy update during bootstrap: %w", err)
						}
						app.Logger.Warn("HAProxy update failed", zap.Error(err))
					}
				}

				if cfg.ProxmoxSSHKeyPath != "" {
					if err := haproxyClient.SetPrivateKey(cfg.ProxmoxSSHKeyPath); err != nil {
						app.Logger.Warn("failed to set SSH private key for HAProxy client", zap.String("key_path", cfg.ProxmoxSSHKeyPath), zap.Error(err))
					}
				}
				if err := haproxyClient.Update(ctx, configStr); err != nil {
					if plan.NeedsBootstrap {
						app.Logger.Error("HAProxy update failed during bootstrap (fatal)", zap.Error(err))
						return fmt.Errorf("HAProxy update during bootstrap: %w", err)
					}
					app.Logger.Warn("HAProxy update failed", zap.Error(err))
				}
			}
		} else if cfg.DryRun {
			app.Logger.Info("would update HAProxy configuration", zap.Int("backends", len(deployed.ControlPlanes)))
		}
	}

	// Phase 5: Fetch kubeconfig after bootstrap
	if plan.NeedsBootstrap && deployed.BootstrapCompleted && !cfg.DryRun {
		app.EnsureEndpointResolvable()

		kubeconfigMgr := talos.NewKubeconfigManager(talosClient, app.Logger)
		if len(deployed.ControlPlanes) > 0 {
			cpIP := deployed.ControlPlanes[0].IP

			app.Logger.Info("waiting for control plane readiness before kubeconfig fetch",
				zap.String("ip", cpIP.String()))
			if err := talosClient.WaitForReady(ctx, cpIP, types.RoleControlPlane); err != nil {
				app.Logger.Warn("CP readiness wait timed out, attempting kubeconfig fetch anyway", zap.Error(err))
			}

			if err := kubeconfigMgr.FetchAndMerge(ctx, cpIP, cfg.ClusterName, cfg.ControlPlaneEndpoint); err != nil {
				if len(plan.AddWorkers) > 0 {
					app.Logger.Error("kubeconfig fetch failed during bootstrap with workers pending (fatal)", zap.Error(err))
					return fmt.Errorf("kubeconfig fetch during bootstrap: %w", err)
				}
				app.Logger.Warn("kubeconfig fetch failed (can retry later)", zap.Error(err))
			} else {
				if err := kubeconfigMgr.Verify(ctx, cfg.ClusterName); err != nil {
					if len(plan.AddWorkers) > 0 {
						app.Logger.Error("K8s API unreachable during bootstrap with workers pending (fatal)", zap.Error(err))
						return fmt.Errorf("K8s API verification during bootstrap: %w", err)
					}
					app.Logger.Warn("kubeconfig verification failed", zap.Error(err))
				}
			}
		}

		app.ConfigureTalosctlEndpoints(deployed)
	}

	// Phase 6: Add workers (parallel, max 3 concurrent)
	if len(plan.AddWorkers) > 0 {
		app.Logger.Info("adding workers", zap.Int("count", len(plan.AddWorkers)))
		audit("ADD-WORKERS", fmt.Sprintf("count=%d vmids=%v", len(plan.AddWorkers), plan.AddWorkers))

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
					app.Logger.Info("would add worker",
						zap.Int("vmid", int(vmid)),
						zap.String("name", spec.Name))
					return nil
				}

				if _, err := app.deployNode(gctx, vmid, types.RoleWorker, live, deployed, stateMgr, scanner, talosClient); err != nil {
					return fmt.Errorf("add worker %d: %w", vmid, err)
				}
				return nil
			})
		}

		if err := g.Wait(); err != nil {
			app.Logger.Error("worker deployment failed", zap.Error(err))
			return err
		}
	}

	// Phase 7: Update configs
	if len(plan.UpdateConfigs) > 0 {
		app.Logger.Info("updating configurations", zap.Int("count", len(plan.UpdateConfigs)))

		for _, vmid := range plan.UpdateConfigs {
			spec, exists := desired[vmid]
			if !exists {
				continue
			}

			if cfg.DryRun {
				app.Logger.Info("would update config", zap.Int("vmid", int(vmid)))
				continue
			}

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
				app.Logger.Warn("cannot update config - node IP not found", zap.Int("vmid", int(vmid)))
				continue
			}

			if _, err := talosClient.GenerateNodeConfig(ctx, spec, cfg.SecretsDir); err != nil {
				app.Logger.Warn("failed to regenerate config for node", zap.Int("vmid", int(vmid)), zap.Error(err))
				continue
			}

			configPath := stateMgr.NodeConfigPath(vmid, spec.Role)
			app.Logger.Info("applying updated config", zap.Int("vmid", int(vmid)))

			if err := talosClient.ApplyConfig(ctx, nodeIP, configPath, false); err != nil {
				app.Logger.Warn("failed to apply updated config", zap.Int("vmid", int(vmid)), zap.Error(err))
				continue
			}

			configHash, hashErr := talos.HashFile(configPath)
			if hashErr != nil {
				app.Logger.Warn("failed to hash config file", zap.Int("vmid", int(vmid)), zap.Error(hashErr))
			}
			stateMgr.UpdateNodeState(deployed, vmid, nodeIP.String(), configHash, spec.Role)
		}
	}

	// Phase 8: Save final state
	if !cfg.DryRun {
		deployed.Timestamp = time.Now()
		if err := stateMgr.Save(ctx, deployed); err != nil {
			app.Logger.Error("failed to save final state", zap.Error(err))
			return fmt.Errorf("save state: %w", err)
		}
	}

	// Phase 9: Post-reconciliation verification
	if !cfg.DryRun && deployed.BootstrapCompleted {
		app.VerifyCluster(ctx, talosClient, k8sClient, deployed)
	}

	// Update session counters with final deployed state
	if app.Session != nil {
		app.Session.ControlPlanes = len(deployed.ControlPlanes)
		app.Session.Workers = len(deployed.Workers)
	}

	return nil
}
