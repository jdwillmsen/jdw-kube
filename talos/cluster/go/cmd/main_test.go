package main

import (
	"github.com/jdw/talos-bootstrap/pkg/types"
	"testing"
)

func TestVMIDType(t *testing.T) {
	vmid := types.VMID(201)
	if vmid.String() != "201" {
		t.Errorf("VMID.String() = %s, want 201", vmid.String())
	}
}

func TestDefaultConfig(t *testing.T) {
	cfg := types.DefaultConfig()
	if cfg.ClusterName != "cluster" {
		t.Errorf("Default cluster name = %s, want cluster", cfg.ClusterName)
	}
}

func TestReconcilePlanEmpty(t *testing.T) {
	plan := &types.ReconcilePlan{}
	if !plan.IsEmpty() {
		t.Error("Empty plan should be empty")
	}

	plan.AddControlPlanes = []types.VMID{201}
	if plan.IsEmpty() {
		t.Error("Plan with additions should not be empty")
	}
}
