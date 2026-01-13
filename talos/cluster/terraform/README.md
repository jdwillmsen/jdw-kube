# Talos Kubernetes Cluster on Proxmox

Terraform-based Infrastructure-as-Code for deploying highly-available Talos Kubernetes clusters on Proxmox VE.
## 📁 File Structure

```
talos-cluster/
├── 00-providers.tf          # Terraform & Proxmox provider configuration
├── 01-variables.tf           # Variable definitions
├── 02-control-nodes.tf       # Control plane VM resources
├── 03-worker-nodes.tf        # Worker VM resources
├── terraform.tfvars          # ⚠️ YOUR CLUSTER CONFIGURATION (edit this!)
├── .gitignore               # Git ignore rules (excludes secrets)
├── scripts/
│   ├── validate.sh          # ⭐ Pre-flight validation (run first!)
│   ├── deploy.sh            # ⭐ Deploy/update/scale cluster
│   └── destroy.sh           # ⭐ Destroy cluster with safety checks
├── backups/                 # Auto-created state/config backups
└── COMMANDS.md              # Detailed command reference
```

## 🚀 Quick Start

### Step 1: Create Proxmox API Token (One-Time)

1. **Create User**:
    - Proxmox UI → Datacenter → Permissions → Users → Add
    - User name: `terraform`
    - Realm: `pve`

2. **Create API Token**:
    - Datacenter → API Tokens → Add
    - User: `terraform@pve`
    - Token ID: `cluster`
    - **Copy the secret immediately!** (shown only once)

3. **Grant Permissions**:
    - Datacenter → Permissions → Add → User Permission
    - User: `terraform@pve`
    - Path: `/`
    - Role: `Administrator`

### Step 2: Configure Your Cluster

Edit `terraform.tfvars` with your values:

```hcl
# --- REQUIRED: Proxmox Connection ---
proxmox_endpoint    = "https://pve-cluster-1:8006/api2/json"
pm_api_token_id     = "terraform@pve!cluster"
pm_api_token_secret = "paste-your-secret-token-here"

# --- REQUIRED: Storage Configuration ---
storage_pool = "local-lvm"
talos_iso    = "local:iso/nocloud-amd64.iso"

# Control Plane Nodes (minimum 1, recommended 3 for HA)
talos_control_configuration = [
   {
      node_name = "pve1"
      vm_name   = "talos-cp-01"
      vmid      = 200
      cpu_cores = 4
      memory    = 4096
      disk_size = 100
   },
   # Add more for HA: { vmid = 201, ... }, { vmid = 202, ... }
]

# Worker Nodes
talos_worker_configuration = [
   {
      node_name = "pve1"
      vm_name   = "talos-worker-01"
      vmid      = 300
      cpu_cores = 2
      memory    = 4096
      disk_size = 100
   },
   # Scale by adding more objects: { vmid = 301, ... }
]
```

### Step 3: Deploy

```bash
# Make scripts executable (first time only)
chmod +x scripts/*.sh

# 1. Validate configuration
./scripts/validate.sh

# 2. Deploy cluster
./scripts/deploy.sh
```

### Step 4: Verify Deployment

```bash
# List created VMs
terraform state list

# Show VM details
terraform show

# Get VM IPs (from Proxmox UI)
# Go to each VM → Console → Note the IP in Talos maintenance mode
```

## 📊 Scaling the Cluster

* To add nodes: Edit `terraform.tfvars` → add objects to lists → run `./scripts/deploy.sh`
* To remove nodes: Edit `terraform.tfvars` → remove objects from lists → run `./scripts/deploy.sh`
* No separate scaling script needed - Terraform handles it automatically.

## 🛡️ Safety Features

* **Automatic Backups**: Every deploy/destroy creates timestamped backups in `backups/`
* **Pre-flight Validation**: `validate.sh` catches misconfigurations before deployment
* **Double Confirmation**: `destroy.sh` requires typing "DESTROY" to prevent accidents
* **ISO Check**: Validates ISO exists in Proxmox before attempting deployment
* **API Validation**: Tests Proxmox connectivity and permissions
* **VM ID Uniqueness**: Prevents ID conflicts

## 🔧 Manual Commands

See `COMMANDS.md` for detailed command reference.

## 🗑️ Cleanup

```bash
# Safe destruction (with backups)
./scripts/destroy.sh

# Manual cleanup (if needed)
rm -rf backups/ terraform.tfstate* .terraform/
```

## 📚 References

* [Talos on Proxmox Guide](https://docs.siderolabs.com/talos/v1.12/platform-specific-installations/virtualized-platforms/proxmox)
* [Terraform Proxmox Provider](https://registry.terraform.io/providers/bpg/proxmox/latest/docs)
* [Talos System Requirements](https://docs.siderolabs.com/talos/v1.12/platform-specific-installations/virtualized-platforms/proxmox#recommended-baseline-vm-configuration)


## ⚠️ Important Notes

* Never commit `terraform.tfstate` or `terraform.tfvars` to git
* Always run `validate.sh` before deploying
* VM IDs must be unique across your entire Proxmox cluster
* Control plane VMs should not be scaled down after bootstrapping (etcd requirement)
* Worker nodes can be added/removed freely
