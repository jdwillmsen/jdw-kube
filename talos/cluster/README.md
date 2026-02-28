# Talos Kubernetes Cluster on Proxmox

Terraform-based Infrastructure-as-Code for deploying highly-available Talos Kubernetes clusters on Proxmox VE.

## 📁 File Structure

```
talos-cluster/
├── 00-providers.tf          # Terraform & Proxmox provider configuration
├── 01-variables.tf          # Variable definitions
├── 02-control-nodes.tf      # Control plane VM resources
├── 03-worker-nodes.tf       # Worker VM resources
├── terraform.tfvars         # ⚠️ YOUR CLUSTER CONFIGURATION (edit this!)
├── .gitignore               # Git ignore rules (excludes secrets)
├── cluster.sh               # ⭐ Unified CLI - deploy, destroy, plan, status
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
# Make script executable (first time only)
chmod +x cluster.sh

# View execution plan (optional but recommended)
./cluster.sh plan

# Deploy cluster (interactive mode)
./cluster.sh deploy

# Or deploy without prompts (CI/CD friendly)
AUTO_APPROVE=true ./cluster.sh deploy
# OR
./cluster.sh deploy --auto-approve
```

### Step 4: Verify Deployment

```bash
# Show deployment status and resources
./cluster.sh status

# List created VMs
terraform state list

# Show detailed VM info
terraform show

# Get VM IPs (from Proxmox UI)
# Go to each VM → Console → Note the IP in Talos maintenance mode
```

## 🎮 Cluster.sh Commands

The cluster.sh script provides unified management with subcommands:

| Command                | Description                        | Flags                                        |
| ---------------------- | ---------------------------------- | -------------------------------------------- |
| `./cluster.sh plan`    | Preview changes without applying   | -                                            |
| `./cluster.sh deploy`  | Deploy or update cluster           | `--auto-approve`, `--dry-run`, `--skip-plan` |
| `./cluster.sh destroy` | Destroy cluster with safety checks | `--auto-approve`, `--force`                  |
| `./cluster.sh status`  | Show current deployment state      | -                                            |
| `./cluster.sh cleanup` | Remove generated files & state     | -                                            |

### Deployment Flags

* `auto-approve`: Skip all confirmation prompts (great for CI/CD)
* `dry-run`: Create plan but don't apply (verify changes first)
* `skip-plan`: Skip detailed change summary (faster execution)

### Destruction Flags

* `auto-approve`: Skip "Type DESTROY" confirmation
* `force`: Bypass Kubernetes cluster detection, provider refresh, and timeouts (use when Proxmox is unreachable)

## 📊 Scaling the Cluster

Terraform handles scaling automatically:

```bash
# 1. Edit terraform.tfvars
# Add/remove objects from talos_control_configuration or talos_worker_configuration

# 2. Apply changes
./cluster.sh deploy

# 3. Verify
./cluster.sh status
```

> **Important**: Control plane nodes should not be scaled down after bootstrapping (etcd quorum requirement). Worker nodes can be added/removed freely.

* To add nodes: Edit `terraform.tfvars` → add objects to lists → run `./scripts/deploy.sh`
* To remove nodes: Edit `terraform.tfvars` → remove objects from lists → run `./scripts/deploy.sh`
* No separate scaling script needed - Terraform handles it automatically.

## 🛡️ Safety Features

All safety features are built into cluster.sh:

* **Automatic Backups**: Every deploy/destroy creates timestamped backups in backups/
* **Pre-flight Validation**: Checks Terraform syntax, variables, and Proxmox connectivity before applying
* **ISO Validation**: Verifies Talos ISO exists in Proxmox storage before deployment
* **Double Confirmation**: Destroy requires typing "DESTROY" (unless --auto-approve)
* **K8s Cluster Detection**: Warns if active kubeconfig exists before destruction
* **Graceful Shutdown**: Option to stop VMs via SSH before destruction (cleaner than force-stop)
* **Retry Logic**: Automatically retries failed applies up to 3 times (handles transient network issues)
* **State Management**: Tracks deployment metadata in .tf-deploy-state/

## 🔧 Manual Commands (Advanced)

For manual Terraform operations:

```bash
# Initialize providers
terraform init

# Format code
terraform fmt

# Validate configuration
terraform validate

# Create plan manually
terraform plan -var-file=terraform.tfvars

# Apply specific resource
terraform apply -target=proxmox_virtual_environment_vm.controlplane
```

See `COMMANDS.md` for detailed command reference.

## 🗑️ Cleanup

### Safe Destruction

```bash
# Interactive destruction (with safety checks)
./cluster.sh destroy

# Immediate destruction (skips confirmations)
./cluster.sh destroy --auto-approve

# Force destruction (when Proxmox is unreachable)
./cluster.sh destroy --force
```

### Reset Everything

```bash
# Remove all Terraform state, backups, and generated files
./cluster.sh cleanup

# Remove everything including secrets (DANGER)
rm -rf .terraform/ backups/ .tf-deploy-state/ terraform.tfstate*
```

## 📚 References

* [Talos on Proxmox Guide](https://docs.siderolabs.com/talos/v1.12/platform-specific-installations/virtualized-platforms/proxmox)
* [Terraform Proxmox Provider](https://registry.terraform.io/providers/bpg/proxmox/latest/docs)
* [Talos System Requirements](https://docs.siderolabs.com/talos/v1.12/platform-specific-installations/virtualized-platforms/proxmox#recommended-baseline-vm-configuration)

## ⚠️ Important Notes

* Never commit `terraform.tfstate`, `terraform.tfvars`, or `backups/` to git
* Always run `./cluster.sh plan` before deploy to preview changes
* VM IDs must be unique across your entire Proxmox cluster
* Control plane VMs should not be scaled down after bootstrapping (etcd requirement)
* Worker nodes can be added/removed freely
* Use `--force` only when Proxmox is unreachable and normal destroy hangs
