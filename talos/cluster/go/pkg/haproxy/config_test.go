package haproxy

import (
	"net"
	"testing"

	"github.com/jdw/talos-bootstrap/pkg/types"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestConfigGenerate(t *testing.T) {
	tests := []struct {
		name        string
		config      *Config
		wantErr     bool
		errContains string
		validate    func(t *testing.T, output string)
	}{
		{
			name: "valid config with single backend",
			config: &Config{
				HAProxyIP:     net.ParseIP("192.168.1.199"),
				StatsUser:     "admin",
				StatsPassword: "secret123",
				ControlPlanes: []Backend{
					{VMID: 201, IP: net.ParseIP("192.168.1.201")},
				},
			},
			wantErr: false,
			validate: func(t *testing.T, output string) {
				assert.Contains(t, output, "bind 192.168.1.199:6443")
				assert.Contains(t, output, "server talos-cp-201 192.168.1.201:6443")
				assert.Contains(t, output, "stats auth admin:secret123")
				assert.Contains(t, output, "bind 192.168.1.199:50000")
				assert.Contains(t, output, "server talos-cp-201 192.168.1.201:50000")
			},
		},
		{
			name: "valid config with multiple backends",
			config: &Config{
				HAProxyIP:     net.ParseIP("10.0.0.1"),
				StatsUser:     "stats",
				StatsPassword: "pass",
				ControlPlanes: []Backend{
					{VMID: 201, IP: net.ParseIP("10.0.0.11")},
					{VMID: 202, IP: net.ParseIP("10.0.0.12")},
					{VMID: 203, IP: net.ParseIP("10.0.0.13")},
				},
			},
			wantErr: false,
			validate: func(t *testing.T, output string) {
				assert.Contains(t, output, "server talos-cp-201 10.0.0.11:6443")
				assert.Contains(t, output, "server talos-cp-202 10.0.0.12:6443")
				assert.Contains(t, output, "server talos-cp-203 10.0.0.13:6443")
				assert.Contains(t, output, "balance leastconn")
			},
		},
		{
			name: "config without stats auth",
			config: &Config{
				HAProxyIP:     net.ParseIP("192.168.1.199"),
				StatsUser:     "",
				StatsPassword: "",
				ControlPlanes: []Backend{
					{VMID: 201, IP: net.ParseIP("192.168.1.201")},
				},
			},
			wantErr: false,
			validate: func(t *testing.T, output string) {
				assert.Contains(t, output, "stats enable")
				assert.NotContains(t, output, "stats auth")
			},
		},
		{
			name: "missing HAProxy IP",
			config: &Config{
				HAProxyIP:     nil,
				ControlPlanes: []Backend{{VMID: 201, IP: net.ParseIP("192.168.1.201")}},
			},
			wantErr:     true,
			errContains: "HAProxy IP is required",
		},
		{
			name: "no control planes",
			config: &Config{
				HAProxyIP:     net.ParseIP("192.168.1.199"),
				ControlPlanes: []Backend{},
			},
			wantErr:     true,
			errContains: "at least one control plane backend is required",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			output, err := tt.config.Generate()

			if tt.wantErr {
				require.Error(t, err)
				if tt.errContains != "" {
					assert.Contains(t, err.Error(), tt.errContains)
				}
				return
			}

			require.NoError(t, err)
			if tt.validate != nil {
				tt.validate(t, output)
			}
		})
	}
}

func TestConfigFromClusterState(t *testing.T) {
	cfg := &types.Config{
		HAProxyIP:            net.ParseIP("192.168.1.199"),
		HAProxyStatsUser:     "admin",
		HAProxyStatsPassword: "secret",
	}

	state := &types.ClusterState{
		ControlPlanes: []types.NodeState{
			{VMID: 201, IP: net.ParseIP("192.168.1.201")},
			{VMID: 202, IP: net.ParseIP("192.168.1.202")},
		},
	}

	haConfig := ConfigFromClusterState(cfg, state)

	assert.Equal(t, cfg.HAProxyIP, haConfig.HAProxyIP)
	assert.Equal(t, cfg.HAProxyStatsUser, haConfig.StatsUser)
	assert.Equal(t, cfg.HAProxyStatsPassword, haConfig.StatsPassword)
	assert.Len(t, haConfig.ControlPlanes, 2)

	// Verify backends are correctly mapped
	backends := haConfig.ControlPlanes
	assert.Equal(t, types.VMID(201), backends[0].VMID)
	assert.Equal(t, "192.168.1.201", backends[0].IP.String())
	assert.Equal(t, types.VMID(202), backends[1].VMID)
	assert.Equal(t, "192.168.1.202", backends[1].IP.String())
}

func TestBackendStruct(t *testing.T) {
	backend := Backend{
		VMID: types.VMID(201),
		IP:   net.ParseIP("192.168.1.201"),
	}

	assert.Equal(t, types.VMID(201), backend.VMID)
	assert.Equal(t, "192.168.1.201", backend.IP.String())
}

func TestGeneratedConfigValidity(t *testing.T) {
	// Test that generated config contains all required sections
	config := &Config{
		HAProxyIP:     net.ParseIP("192.168.1.199"),
		StatsUser:     "admin",
		StatsPassword: "secret",
		ControlPlanes: []Backend{
			{VMID: 201, IP: net.ParseIP("192.168.1.201")},
		},
	}

	output, err := config.Generate()
	require.NoError(t, err)

	// Check for required HAProxy sections
	requiredSections := []string{
		"global",
		"defaults",
		"frontend k8s-apiserver",
		"listen stats",
		"frontend talos-apiserver",
		"backend k8s-controlplane",
		"backend talos-controlplane",
		"mode tcp",
		"balance leastconn",
		"option tcp-check",
	}

	for _, section := range requiredSections {
		assert.Contains(t, output, section, "Generated config missing required section: %s", section)
	}
}
