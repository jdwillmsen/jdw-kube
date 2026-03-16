package main

import (
	"context"
	"fmt"

	"github.com/jdw/talos-bootstrap/pkg/logging"
	"github.com/jdw/talos-bootstrap/pkg/state"
	"github.com/jdw/talos-bootstrap/pkg/types"
	"go.uber.org/zap"
)

func runStatus(ctx context.Context, cfg *types.Config) error {
	stateMgr := state.NewManager(cfg, logger)

	// Resolve and load additional fields from terraform.tfvars
	if err := stateMgr.ResolveTFVarsPath(); err != nil {
		logger.Warn("could not locate terraform.tfvars", zap.Error(err))
	}
	if err := stateMgr.LoadTerraformExtras(ctx); err != nil {
		logger.Warn("could not load terraform extras", zap.String("path", cfg.TerraformTFVars), zap.Error(err))
	}

	desired, err := stateMgr.LoadDesiredState(ctx)
	if err != nil {
		logger.Error("failed to load desired state", zap.Error(err))
		return err
	}

	deployed, err := stateMgr.LoadDeployedState(ctx)
	if err != nil {
		logger.Error("failed to load deployed state", zap.Error(err))
		return err
	}

	box := logging.NewBox(session.Console, cfg.NoColor)
	box.Header(fmt.Sprintf("CLUSTER STATUS: %s", cfg.ClusterName))

	box.Label("Desired State (Terraform)")
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
				box.Row("Terraform Hash", fmt.Sprintf("%s (unchanged)", deployed.TerraformHash))
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
