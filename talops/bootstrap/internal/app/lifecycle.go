package app

import (
	"context"
	"fmt"

	"github.com/jdwlabs/infrastructure/bootstrap/internal/kubectl"
	"github.com/jdwlabs/infrastructure/bootstrap/internal/state"
	"go.uber.org/zap"
)

func (app *App) RunUp(ctx context.Context, skipInfra bool) error {
	if !skipInfra {
		tfDir, err := app.ResolveTerraformDir()
		if err != nil {
			return err
		}
		if err := app.RunInfraDeploy(ctx, tfDir, false); err != nil {
			return fmt.Errorf("up: infrastructure deploy failed: %w", err)
		}
	}

	if err := app.RunReconcile(ctx); err != nil {
		app.Logger.Error("up: bootstrap failed; infrastructure is up",
			zap.String("hint", "run 'talops reconcile' to retry"))
		return fmt.Errorf("up: cluster bootstrap failed: %w", err)
	}
	return nil
}

func (app *App) RunDown(ctx context.Context, skipDrain, force bool) error {
	if !app.Cfg.AutoApprove {
		fmt.Fprint(app.Session.Console, "This will DESTROY the cluster. Type \"yes\": ")
		var resp string
		fmt.Scanln(&resp)
		fmt.Fprintln(app.Session.ConsoleFile, resp)
		if resp != "yes" {
			app.Logger.Info("cancelled by user")
			return nil
		}
	}

	if !skipDrain {
		if err := app.drainAllNodes(ctx); err != nil {
			app.Logger.Warn("drain failed; continuing with destroy", zap.Error(err))
		}
	}

	tfDir, err := app.ResolveTerraformDir()
	if err != nil {
		return err
	}
	if err := app.RunInfraDestroy(ctx, tfDir, force, true); err != nil {
		return fmt.Errorf("down: destroy failed: %w", err)
	}
	return nil
}

func (app *App) drainAllNodes(ctx context.Context) error {
	stateMgr := state.NewManager(app.Cfg, app.Logger)
	if err := stateMgr.ResolveTFVarsPath(); err != nil {
		return fmt.Errorf("resolve tfvars: %w", err)
	}
	if err := stateMgr.LoadTerraformExtras(ctx); err != nil {
		return fmt.Errorf("load terraform extras: %w", err)
	}

	deployed, err := stateMgr.LoadDeployedState(ctx)
	if err != nil {
		return fmt.Errorf("load deployed state: %w", err)
	}

	k8sClient := kubectl.NewClient(app.Logger)
	k8sClient.SetContext(app.Cfg.ClusterName)

	var failCount int

	// Drain workers first, then control planes
	allNodes := append(deployed.Workers, deployed.ControlPlanes...)
	for _, node := range allNodes {
		if node.IP == nil {
			continue
		}
		nodeName, err := k8sClient.GetNodeNameByIP(ctx, node.IP)
		if err != nil {
			app.Logger.Warn("could not resolve node name", zap.Int("vmid", int(node.VMID)), zap.Error(err))
			failCount++
			continue
		}
		app.Logger.Info("draining node", zap.String("node", nodeName), zap.Int("vmid", int(node.VMID)))
		if err := k8sClient.DrainNode(ctx, nodeName); err != nil {
			app.Logger.Warn("drain failed", zap.String("node", nodeName), zap.Error(err))
			failCount++
		}
	}

	if failCount > 0 {
		return fmt.Errorf("%d node(s) failed to drain", failCount)
	}
	return nil
}
