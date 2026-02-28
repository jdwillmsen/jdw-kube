package types

import (
	"encoding/json"
	"fmt"
	"net"
	"path/filepath"
	"time"
)

// VMID is a typed integer to prevent mixing up VM IDs with other ints
type VMID int

func (v VMID) String() string {
	return fmt.Sprintf("%d", v)
}

// Role distinguishes control plane from worker
type Role string

const (
	RoleControlPlane Role = "control-plane"
	RoleWorker       Role = "worker"
)

// NodeSpec represents what Terraform wants (your DESIRED_*_VMIDS)
type NodeSpec struct {
	VMID   VMID   `json:"vmid" hcl:"vmid"`
	Name   string `json:"name" hcl:"vm_name"`
	Node   string `json:"node" hcl:"node_name"` // Proxmox node name (pve1, pve2, etc.)
	CPU    int    `json:"cpu" hcl:"cpu_cores"`
	Memory int    `json:"memory" hcl:"memory"`  // MB
	Disk   int    `json:"disk" hcl:"disk_size"` // GB
	Role   Role   `json:"role"`
}

// NodeState represents what we know is deployed (your DEPLOYED_*_IPS)
type NodeState struct {
	VMID       VMID      `json:"vmid"`
	IP         net.IP    `json:"ip,omitempty"`
	ConfigHash string    `json:"config_hash,omitempty"`
	MAC        string    `json:"mac,omitempty"` // For IP rediscovery
	LastSeen   time.Time `json:"last_seen"`
}

// MarshalJSON customizes JSON serialization for NodeState
func (n NodeState) MarshalJSON() ([]byte, error) {
	type Alias NodeState
	return json.Marshal(&struct {
		IP string `json:"ip,omitempty"`
		*Alias
	}{
		IP:    n.IP.String(),
		Alias: (*Alias)(&n),
	})
}

// UnmarshalJSON customizes JSON deserialization for NodeState
func (n *NodeState) UnmarshalJSON(data []byte) error {
	type Alias NodeState
	aux := &struct {
		IP string `json:"ip,omitempty"`
		*Alias
	}{
		Alias: (*Alias)(n),
	}
	if err := json.Unmarshal(data, &aux); err != nil {
		return err
	}
	if aux.IP != "" {
		n.IP = net.ParseIP(aux.IP)
	}
	return nil
}

// LiveNode represents current reality from Proxmox/Talos (your LIVE_NODE_*)
type LiveNode struct {
	VMID         VMID       `json:"vmid"`
	IP           net.IP     `json:"ip"`
	MAC          string     `json:"mac"`
	Status       NodeStatus `json:"status"`
	TalosVersion string     `json:"talos_version,omitempty"`
	K8sVersion   string     `json:"k8s_version,omitempty"`
	DiscoveredAt time.Time  `json:"discovered_at"`
}

type NodeStatus string

const (
	StatusDiscovered NodeStatus = "discovered"
	StatusJoined     NodeStatus = "joined" // In Talos cluster
	StatusReady      NodeStatus = "ready"  // Kubernetes ready
	StatusNotFound   NodeStatus = "not_found"
	StatusRebooting  NodeStatus = "rebooting" // Transient state
)

// ClusterState is your bootstrap-state.json as a typed struct
type ClusterState struct {
	Timestamp            time.Time   `json:"timestamp"`
	TerraformHash        string      `json:"terraform_hash"`
	ClusterName          string      `json:"cluster_name"`
	BootstrapCompleted   bool        `json:"bootstrap_completed"`
	FirstControlPlane    VMID        `json:"first_control_plane_vmid,omitempty"`
	ControlPlanes        []NodeState `json:"control_planes"`
	Workers              []NodeState `json:"workers"`
	HAProxyIP            net.IP      `json:"haproxy_ip"`
	ControlPlaneEndpoint string      `json:"control_plane_endpoint"`
	KubernetesVersion    string      `json:"kubernetes_version"`
	TalosVersion         string      `json:"talos_version"`
}

// ReconcilePlan replaces your PLAN_* arrays
type ReconcilePlan struct {
	NeedsBootstrap      bool   `json:"needs_bootstrap"`
	AddControlPlanes    []VMID `json:"add_control_planes"`
	AddWorkers          []VMID `json:"add_workers"`
	RemoveControlPlanes []VMID `json:"remove_control_planes"`
	RemoveWorkers       []VMID `json:"remove_workers"`
	UpdateConfigs       []VMID `json:"update_configs"`
	NoOp                []VMID `json:"noop"`
}

// IsEmpty returns true if no operations are planned
func (p *ReconcilePlan) IsEmpty() bool {
	return !p.NeedsBootstrap &&
		len(p.AddControlPlanes) == 0 &&
		len(p.AddWorkers) == 0 &&
		len(p.RemoveControlPlanes) == 0 &&
		len(p.RemoveWorkers) == 0 &&
		len(p.UpdateConfigs) == 0
}

// Config represents your terraform.tfvars + environment variables
type Config struct {
	ClusterName             string `json:"cluster_name"`
	TerraformTFVars         string `json:"terraform_tfvars"`
	ControlPlaneEndpoint    string `json:"control_plane_endpoint"`
	HAProxyIP               net.IP `json:"haproxy_ip"`
	HAProxyLoginUser        string `json:"haproxy_login_username"`
	HAProxyStatsUser        string `json:"haproxy_stats_username"`
	HAProxyStatsPassword    string `json:"haproxy_stats_password"`
	KubernetesVersion       string `json:"kubernetes_version"`
	TalosVersion            string `json:"talos_version"`
	InstallerImage          string `json:"installer_image"`
	DefaultNetworkInterface string `json:"default_network_interface"`
	DefaultDisk             string `json:"default_disk"`
	SecretsDir              string `json:"secrets_dir"`

	// Proxmox connection
	ProxmoxSSHUser     string            `json:"proxmox_ssh_user"`
	ProxmoxSSHHost     string            `json:"proxmox_ssh_host"`
	ProxmoxNodeIPs     map[string]net.IP `json:"proxmox_node_ips"` // pve1 -> 192.168.1.200
	ProxmoxTokenID     string            `json:"proxmox_token_id,omitempty"`
	ProxmoxTokenSecret string            `json:"proxmox_token_secret,omitempty"`

	// Runtime flags
	AutoApprove      bool   `json:"auto_approve"`
	DryRun           bool   `json:"dry_run"`
	PlanMode         bool   `json:"plan_mode"`
	SkipPreflight    bool   `json:"skip_preflight"`
	ForceReconfigure bool   `json:"force_reconfigure"`
	LogLevel         string `json:"log_level"`

	// Internal
	TerraformHash string `json:"-"` // Computed, not serialized
}

// DefaultConfig returns a config with sensible defaults
func DefaultConfig() *Config {
	cfg := &Config{
		ClusterName:             "cluster",
		TerraformTFVars:         "terraform.tfvars",
		ControlPlaneEndpoint:    "cluster.jdwlabs.com",
		HAProxyIP:               net.ParseIP("192.168.1.199"),
		HAProxyLoginUser:        "jake",
		HAProxyStatsUser:        "admin",
		HAProxyStatsPassword:    "admin",
		KubernetesVersion:       "v1.35.1",
		TalosVersion:            "v1.12.3",
		InstallerImage:          "factory.talos.dev/nocloud-installer/b553b4a25d76e938fd7a9aaa7f887c06ea4ef75275e64f4630e6f8f739cf07df:v1.12.3",
		DefaultNetworkInterface: "eth0",
		DefaultDisk:             "sda",
		ProxmoxSSHUser:          "root",
		ProxmoxSSHHost:          "192.168.1.199",
		ProxmoxNodeIPs: map[string]net.IP{
			"pve1": net.ParseIP("192.168.1.200"),
			"pve2": net.ParseIP("192.168.1.201"),
			"pve3": net.ParseIP("192.168.1.202"),
			"pve4": net.ParseIP("192.168.1.203"),
		},
		LogLevel: "info",
	}
	// Set SecretsDir based on ClusterName
	cfg.SecretsDir = filepath.Join("clusters", cfg.ClusterName, "secrets")
	return cfg
}
