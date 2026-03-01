package talos

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"text/template"

	"github.com/jdw/talos-bootstrap/pkg/types"
)

// NodeConfig handles generation and management of Talos node configurations
type NodeConfig struct {
	cfg *types.Config
}

// NewNodeConfig creates a new NodeConfig generator
func NewNodeConfig(cfg *types.Config) *NodeConfig {
	return &NodeConfig{cfg: cfg}
}

const controlPlaneTemplate = `version: v1alpha1
persist: true
machine:
  type: controlplane
  install:
    disk: /dev/{{ .DefaultDisk }}
    image: {{ .InstallerImage }}
    extraKernelArgs:
      - console=tty0
	  - console=ttyS0
  network:
    hostname: {{ .Hostname }}
	interfaces:
	  - interface: {{ .DefaultNetworkInterface }}
		dhcp: true
	extraHostEntries:
	  - ip: {{ .HAProxyIP }}
        aliases:
		  - {{ .ControlPlaneEndpoint }}
  sysctls:
    vm.nr_hugepages: "1024"
  kubelet:
    extraArgs:
	  rotate-server-certificates: "true"
  kernel:
	modules:
      - name: nvme_tcp
      - name: vfio_pci
      - name: zfs
cluster:
  clusterName: {{ .ClusterName }}
  controlPlane:
    endpoint: https://{{ .ControlPlaneEndpoint }}:6443
  extraManifests:
    - https://raw.githubusercontent.com/alex1989hu/kubelet-serving-cert-approver/main/deploy/standalone-install.yaml
    - https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  allowSchedulingOnControlPlane: false
  apiServer:
    certSANs:
      - {{ .ControlPlaneEndpoint }}
	  - {{ .HAProxyIP }}
      - 127.0.0.1
`

const workerTemplate = `version: v1alpha1
persist: true
machine:
  type: worker
  install:
    disk: /dev/{{ .DefaultDisk }}
    image: {{ .InstallerImage }}
    extraKernelArgs:
      - console=tty0
	  - console=ttyS0
  network:
    hostname: {{ .Hostname }}
	interfaces:
	  - interface: {{ .DefaultNetworkInterface }}
		dhcp: true
	extraHostEntries:
	  - ip: {{ .HAProxyIP }}
        aliases:
		  - {{ .ControlPlaneEndpoint }}
  sysctls:
    vm.nr_hugepages: "1024"
  kubelet:
    extraArgs:
	  rotate-server-certificates: "true"
    extraMounts:
      - destination: /var/local
        type: bind
     	source: /var/local
		options:
		  - bind
		  - rshared
		  - rw
  kernel:
	modules:
      - name: nvme_tcp
      - name: vfio_pci
      - name: zfs
cluster:
  clusterName: {{ .ClusterName }}
  controlPlane:
    endpoint: https://{{ .ControlPlaneEndpoint }}:6443
`

// templateData holds the values for config template rendering
type templateData struct {
	Hostname                string
	DefaultDisk             string
	DefaultNetworkInterface string
	HAProxyIP               string
	ControlPlaneEndpoint    string
	InstallerImage          string
	ClusterName             string
}

// Generate creates a Talos node config for the given spec, write it to disk,
// and returns the SHA256 hash of the config for change detection.
func (nc *NodeConfig) Generate(spec types.NodeSpec, outputDir string) (string, error) {
	data := templateData{
		Hostname:                spec.Name,
		DefaultDisk:             nc.cfg.DefaultDisk,
		DefaultNetworkInterface: nc.cfg.DefaultNetworkInterface,
		HAProxyIP:               nc.cfg.HAProxyIP.String(),
		ControlPlaneEndpoint:    nc.cfg.ControlPlaneEndpoint,
		InstallerImage:          nc.cfg.InstallerImage,
		ClusterName:             nc.cfg.ClusterName,
	}

	var tmplStr string
	switch spec.Role {
	case types.RoleControlPlane:
		tmplStr = controlPlaneTemplate
	case types.RoleWorker:
		tmplStr = workerTemplate
	default:
		return "", fmt.Errorf("unknown node role: %s", spec.Role)
	}

	tmpl, err := template.New("nodeConfig").Parse(tmplStr)
	if err != nil {
		return "", fmt.Errorf("parse template: %w", err)
	}

	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, data); err != nil {
		return "", fmt.Errorf("execute template: %w", err)
	}

	configBytes := buf.Bytes()

	// Ensure output directory exists
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		return "", fmt.Errorf("create output directory: %w", err)
	}

	// Write config to file
	filename := fmt.Sprintf("node-%s-%d.yaml", spec.Role, spec.VMID)
	outputPath := filepath.Join(outputDir, filename)
	if err := os.WriteFile(outputPath, configBytes, 0600); err != nil {
		return "", fmt.Errorf("write config file: %w", err)
	}

	// Compute SHA256 hash of the config for change detection
	hash := sha256.Sum256(configBytes)
	return hex.EncodeToString(hash[:]), nil
}

// ConfigPath returns the expected path for a node's config file based on the output directory, VMID, and role.
func (nc *NodeConfig) ConfigPath(outputDir string, vmid types.VMID, role types.Role) string {
	filename := fmt.Sprintf("node-%s-%d.yaml", role, vmid)
	return filepath.Join(outputDir, filename)
}

// HashFile computes the SHA256 hash of an existing config file for drift detection
func HashFile(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:]), nil
}
