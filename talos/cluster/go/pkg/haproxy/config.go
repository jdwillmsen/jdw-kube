package haproxy

import (
	"bytes"
	"fmt"
	"net"
	"text/template"

	"github.com/jdw/talos-bootstrap/pkg/types"
)

// Backend represents a control plane backend server in HAProxy
type Backend struct {
	VMID types.VMID
	IP   net.IP
}

// Config holds all data needed to generate an HAProxy configuration
type Config struct {
	HAProxyIP     net.IP
	StatsUser     string
	StatsPassword string
	ControlPlanes []Backend
}

const haproxyTemplate = `global
    log /dev/log local0
    maxconn 4096
    daemon

defaults
    mode tcp
    log global
    option tcplog
    timeout connect 5000
    timeout client 50000
    timeout server 50000
    retries 3

frontend k8s-apiserver
    bind {{ .HAProxyIP }}:6443
    default_backend k8s-controlplane

frontend stats
    mode http
    bind {{ .HAProxyIP }}:9000
	stats enable
	stats uri /
{{- if and .StatsUser .StatsPassword }}
	stats auth {{ .StatsUser }}:{{ .StatsPassword }}
{{- end }}

frontend talos-apiserver
   bind {{ .HAProxyIP }}:50000
   default_backend talos-controlplane

backend k8s-controlplane
    balance roundrobin
    option tcp-check
{{- range .ControlPlanes }}
	server talos-cp-{{ .VMID }} {{ .IP }}:6443 check inter 5s fall 3 rise 2
{{- end }}

backend talos-controlplane
    balance roundrobin
	option tcp-check
{{- range .ControlPlanes }}
	server talos-cp-{{ .VMID }} {{ .IP }}:50000 check inter 5s fall 3 rise 2
{{- end }}
`

// Generate renders the HAProxy configuration from the template
func (c *Config) Generate() (string, error) {
	if c.HAProxyIP == nil {
		return "", fmt.Errorf("HAProxy IP is required")
	}
	if len(c.ControlPlanes) == 0 {
		return "", fmt.Errorf("at least one control plane backend is required")
	}

	tmpl, err := template.New("haproxy").Parse(haproxyTemplate)
	if err != nil {
		return "", fmt.Errorf("parse template: %w", err)
	}

	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, c); err != nil {
		return "", fmt.Errorf("execute template: %w", err)
	}

	return buf.String(), nil
}

// ConfigFromClusterState builds an HAProxy Config from the current cluster state
func ConfigFromClusterState(cfg *types.Config, state *types.ClusterState) *Config {
	haConfig := &Config{
		HAProxyIP:     cfg.HAProxyIP,
		StatsUser:     cfg.HAProxyStatsUser,
		StatsPassword: cfg.HAProxyStatsPassword,
	}

	for _, cp := range state.ControlPlanes {
		haConfig.ControlPlanes = append(haConfig.ControlPlanes, Backend{
			VMID: cp.VMID,
			IP:   cp.IP,
		})
	}

	return haConfig
}
