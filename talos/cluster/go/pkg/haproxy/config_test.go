package haproxy

import (
	"net"
	"strings"
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
			name: "config with only stats user (no password)",
			config: &Config{
				HAProxyIP:     net.ParseIP("192.168.1.199"),
				StatsUser:     "admin",
				StatsPassword: "",
				ControlPlanes: []Backend{
					{VMID: 201, IP: net.ParseIP("192.168.1.201")},
				},
			},
			wantErr: false,
			validate: func(t *testing.T, output string) {
				// Template requires both user and password
				assert.NotContains(t, output, "stats auth")
			},
		},
		{
			name: "config with only stats password (no user)",
			config: &Config{
				HAProxyIP:     net.ParseIP("192.168.1.199"),
				StatsUser:     "",
				StatsPassword: "secret",
				ControlPlanes: []Backend{
					{VMID: 201, IP: net.ParseIP("192.168.1.201")},
				},
			},
			wantErr: false,
			validate: func(t *testing.T, output string) {
				// Template requires both user and password
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
		{
			name: "nil control planes slice",
			config: &Config{
				HAProxyIP:     net.ParseIP("192.168.1.199"),
				ControlPlanes: nil,
			},
			wantErr:     true,
			errContains: "at least one control plane backend is required",
		},
		{
			name: "backend with nil IP",
			config: &Config{
				HAProxyIP: net.ParseIP("192.168.1.199"),
				ControlPlanes: []Backend{
					{VMID: 201, IP: nil},
				},
			},
			wantErr: false,
			validate: func(t *testing.T, output string) {
				// Should still generate but with <nil> IP (Go's default string representation)
				assert.Contains(t, output, "server talos-cp-201 <nil>:6443")
			},
		},
		{
			name: "backend with IPv6",
			config: &Config{
				HAProxyIP: net.ParseIP("::1"),
				ControlPlanes: []Backend{
					{VMID: 201, IP: net.ParseIP("2001:db8::1")},
				},
			},
			wantErr: false,
			validate: func(t *testing.T, output string) {
				assert.Contains(t, output, "bind ::1:6443")
				assert.Contains(t, output, "server talos-cp-201 2001:db8::1:6443")
			},
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
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
	tests := []struct {
		name     string
		cfg      *types.Config
		state    *types.ClusterState
		expected *Config
	}{
		{
			name: "single control plane",
			cfg: &types.Config{
				HAProxyIP:            net.ParseIP("192.168.1.199"),
				HAProxyStatsUser:     "admin",
				HAProxyStatsPassword: "secret",
			},
			state: &types.ClusterState{
				ControlPlanes: []types.NodeState{
					{VMID: 201, IP: net.ParseIP("192.168.1.201")},
				},
			},
			expected: &Config{
				HAProxyIP:     net.ParseIP("192.168.1.199"),
				StatsUser:     "admin",
				StatsPassword: "secret",
				ControlPlanes: []Backend{
					{VMID: 201, IP: net.ParseIP("192.168.1.201")},
				},
			},
		},
		{
			name: "multiple control planes",
			cfg: &types.Config{
				HAProxyIP:            net.ParseIP("10.0.0.1"),
				HAProxyStatsUser:     "stats",
				HAProxyStatsPassword: "pass123",
			},
			state: &types.ClusterState{
				ControlPlanes: []types.NodeState{
					{VMID: 201, IP: net.ParseIP("10.0.0.11")},
					{VMID: 202, IP: net.ParseIP("10.0.0.12")},
					{VMID: 203, IP: net.ParseIP("10.0.0.13")},
				},
			},
			expected: &Config{
				HAProxyIP:     net.ParseIP("10.0.0.1"),
				StatsUser:     "stats",
				StatsPassword: "pass123",
				ControlPlanes: []Backend{
					{VMID: 201, IP: net.ParseIP("10.0.0.11")},
					{VMID: 202, IP: net.ParseIP("10.0.0.12")},
					{VMID: 203, IP: net.ParseIP("10.0.0.13")},
				},
			},
		},
		{
			name: "empty control planes",
			cfg: &types.Config{
				HAProxyIP:            net.ParseIP("192.168.1.199"),
				HAProxyStatsUser:     "admin",
				HAProxyStatsPassword: "secret",
			},
			state: &types.ClusterState{
				ControlPlanes: []types.NodeState{},
			},
			expected: &Config{
				HAProxyIP:     net.ParseIP("192.168.1.199"),
				StatsUser:     "admin",
				StatsPassword: "secret",
				ControlPlanes: []Backend{},
			},
		},
		{
			name: "nil control planes in state",
			cfg: &types.Config{
				HAProxyIP:            net.ParseIP("192.168.1.199"),
				HAProxyStatsUser:     "admin",
				HAProxyStatsPassword: "secret",
			},
			state: &types.ClusterState{
				ControlPlanes: nil,
			},
			expected: &Config{
				HAProxyIP:     net.ParseIP("192.168.1.199"),
				StatsUser:     "admin",
				StatsPassword: "secret",
				ControlPlanes: nil,
			},
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			result := ConfigFromClusterState(tt.cfg, tt.state)

			assert.Equal(t, tt.expected.HAProxyIP, result.HAProxyIP)
			assert.Equal(t, tt.expected.StatsUser, result.StatsUser)
			assert.Equal(t, tt.expected.StatsPassword, result.StatsPassword)
			assert.Equal(t, len(tt.expected.ControlPlanes), len(result.ControlPlanes))

			for i, expectedBackend := range tt.expected.ControlPlanes {
				if i < len(result.ControlPlanes) {
					assert.Equal(t, expectedBackend.VMID, result.ControlPlanes[i].VMID)
					assert.Equal(t, expectedBackend.IP.String(), result.ControlPlanes[i].IP.String())
				}
			}
		})
	}
}

func TestBackendStruct(t *testing.T) {
	tests := []struct {
		name     string
		backend  Backend
		wantVMID types.VMID
		wantIP   string
	}{
		{
			name:     "standard backend",
			backend:  Backend{VMID: 201, IP: net.ParseIP("192.168.1.201")},
			wantVMID: 201,
			wantIP:   "192.168.1.201",
		},
		{
			name:     "large VMID",
			backend:  Backend{VMID: 999999, IP: net.ParseIP("10.0.0.1")},
			wantVMID: 999999,
			wantIP:   "10.0.0.1",
		},
		{
			name:     "zero VMID",
			backend:  Backend{VMID: 0, IP: net.ParseIP("127.0.0.1")},
			wantVMID: 0,
			wantIP:   "127.0.0.1",
		},
		{
			name:     "IPv6 backend",
			backend:  Backend{VMID: 201, IP: net.ParseIP("2001:db8::1")},
			wantVMID: 201,
			wantIP:   "2001:db8::1",
		},
		{
			name:     "nil IP",
			backend:  Backend{VMID: 201, IP: nil},
			wantVMID: 201,
			wantIP:   "<nil>",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			assert.Equal(t, tt.wantVMID, tt.backend.VMID)
			assert.Equal(t, tt.wantIP, tt.backend.IP.String())
		})
	}
}

func TestGeneratedConfigValidity(t *testing.T) {
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

	// Verify structure - global should come before defaults
	globalIdx := strings.Index(output, "global")
	defaultsIdx := strings.Index(output, "defaults")
	assert.Less(t, globalIdx, defaultsIdx, "global section should come before defaults")

	// Verify no empty lines at start (template formatting check)
	trimmed := strings.TrimSpace(output)
	assert.True(t, strings.HasPrefix(trimmed, "#"), "Config should start with a comment")
}

func TestGeneratedConfigOrdering(t *testing.T) {
	// Ensure backends are generated in the same order as input
	config := &Config{
		HAProxyIP: net.ParseIP("192.168.1.199"),
		ControlPlanes: []Backend{
			{VMID: 203, IP: net.ParseIP("192.168.1.203")},
			{VMID: 201, IP: net.ParseIP("192.168.1.201")},
			{VMID: 202, IP: net.ParseIP("192.168.1.202")},
		},
	}

	output, err := config.Generate()
	require.NoError(t, err)

	// Find positions of server declarations
	pos203 := strings.Index(output, "server talos-cp-203")
	pos201 := strings.Index(output, "server talos-cp-201")
	pos202 := strings.Index(output, "server talos-cp-202")

	// Verify order is preserved (203 before 201 before 202 in k8s backend)
	assert.Less(t, pos203, pos201, "VMID 203 should appear before 201")
	assert.Less(t, pos201, pos202, "VMID 201 should appear before 202")
}

// Benchmarks
func BenchmarkConfigGenerate(b *testing.B) {
	config := &Config{
		HAProxyIP:     net.ParseIP("192.168.1.199"),
		StatsUser:     "admin",
		StatsPassword: "secret",
		ControlPlanes: []Backend{
			{VMID: 201, IP: net.ParseIP("192.168.1.201")},
			{VMID: 202, IP: net.ParseIP("192.168.1.202")},
			{VMID: 203, IP: net.ParseIP("192.168.1.203")},
		},
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = config.Generate()
	}
}

func BenchmarkConfigFromClusterState(b *testing.B) {
	cfg := &types.Config{
		HAProxyIP:            net.ParseIP("192.168.1.199"),
		HAProxyStatsUser:     "admin",
		HAProxyStatsPassword: "secret",
	}

	state := &types.ClusterState{
		ControlPlanes: []types.NodeState{
			{VMID: 201, IP: net.ParseIP("192.168.1.201")},
			{VMID: 202, IP: net.ParseIP("192.168.1.202")},
			{VMID: 203, IP: net.ParseIP("192.168.1.203")},
		},
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = ConfigFromClusterState(cfg, state)
	}
}
