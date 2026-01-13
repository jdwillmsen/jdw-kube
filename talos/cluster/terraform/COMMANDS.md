# Command Reference Guide

## Terraform Commands

### Initial Setup

```bash
# Initialize provider (first time only)
terraform init

# Validate configuration
terraform validate

# Format code
terraform fmt
```

### Plan & Apply

```bash
# Create execution plan
terraform plan -var-file="terraform.tfvars"

# Save plan to file
terraform plan -var-file="terraform.tfvars" -out=tfplan

# Apply plan
terraform apply tfplan

# Direct apply (interactive)
terraform apply -var-file="terraform.tfvars"
```

### State Management

```bash
# List all resources
terraform state list

# Show current state
terraform show

# Refresh state from Proxmox
terraform refresh -var-file="terraform.tfvars"

# Show specific resource
terraform state show proxmox_virtual_environment_vm.controlplane[\"talos-cp-01\"]
```

### Destroy Resources

```bash
# Destroy entire cluster
terraform destroy -var-file="terraform.tfvars"

# Destroy specific VM
terraform destroy -target=proxmox_virtual_environment_vm.controlplane[\"talos-cp-02\"]

# Destroy all workers only
terraform destroy -target=proxmox_virtual_environment_vm.worker
```

### Debugging

```bash
# Enable debug logging
export TF_LOG=DEBUG
terraform apply -var-file="terraform.tfvars"

# Show dependency graph
terraform graph | dot -Tpng > graph.png

# Check provider version
terraform providers
```

### Proxmox Commands

#### Via SSH (run on any PVE node)

```bash
# List all VMs on node
ssh root@pve1 "qm list"

# Start VM
ssh root@pve1 "qm start 100"

# Stop VM
ssh root@pve1 "qm stop 100"

# Get VM config
ssh root@pve1 "qm config 100"

# Get network info (requires QEMU agent)
ssh root@pve1 "qm guest cmd 100 network-get-interfaces"

# View VM console (exit with Ctrl+O, Q)
ssh root@pve1 "qm terminal 100"

# Take snapshot
ssh root@pve1 "qm snapshot 100 pre-bootstrap"

# Delete snapshot
ssh root@pve1 "qm delsnapshot 100 pre-bootstrap"
```

#### Via Proxmox UI

1. Get VM IP: Click VM → Console → Note IP in Talos maintenance screen
2. Edit VM: Click VM → Hardware → Adjust CPU/Memory/Disk
3. Start/Stop: Right-click VM → Start/Shutdown
4. Migrate: Click VM → Migrate (for live migration between nodes)
5. Snapshots: Click VM → Snapshots → Take Snapshot

### Scaling Commands

#### Add Nodes

1. Edit `terraform.tfvars`: 
```bash
talos_control_configuration = [
  { node_name = "pve1", vm_name = "talos-cp-01", ... },
  { node_name = "pve2", vm_name = "talos-cp-02", ... }  # Add this
]
``` 
2. Run:
```bash
terraform apply -var-file="terraform.tfvars"
```

#### Modify Existing Nodes

```bash
# Change memory for a specific node
terraform apply -target=proxmox_virtual_environment_vm.controlplane[\"talos-cp-01\"]
```

### File Management

```bash
# Backup state
cp terraform.tfstate terraform.tfstate.backup

# Lock files (auto-created, do not edit)
.terraform.lock.hcl
.terraform.tfstate.lock.info

# Sensitive files (gitignored)
terraform.tfvars
*.secret
*.key
```

### Git Workflow

```bash
# Initialize repo
git init

# Add files
git add 00-providers.tf 01-variables.tf 02-control-nodes.tf 03-worker-nodes.tf

# Commit
git commit -m "Initial cluster config"

# Never commit these
# - terraform.tfvars (secrets)
# - terraform.tfstate (state)
# - .terraform directory
```

### Useful Variables

```bash
# Override variables via environment
export TF_VAR_pm_api_token_secret="your-secret"

# Or via CLI
terraform apply -var="pm_api_token_secret=your-secret"

# Override node count for quick test
terraform apply -var='talos_control_configuration=[{node_name="pve1",vm_name="test-cp",vmid=999,cpu_cores=1,memory=2048,disk_size=10}]'
```

### Troubleshooting

#### Terraform Errors

```bash
# Clear cache if provider issues
rm -rf .terraform

# State lock stuck
terraform force-unlock <LOCK_ID>

# Corrupt state (restore from backup)
cp terraform.tfstate.backup terraform.tfstate
```

#### Proxmox API Errors

```bash
# Test API access
curl -k -H "Authorization: PVEAPIToken=$pm_api_token_id=$pm_api_token_secret" \
  https://pve-cluster-1:8006/api2/json/cluster/resources

# Check token permissions
ssh root@pve1 "pvesh get /access/users/terraform@pve"
```

#### VM Boot Issues

```bash
# Check VM logs
ssh root@pve1 "qm status 100"
ssh root@pve1 "qm monitor 100"  # Type 'info' then 'quit'

# Force stop if stuck
ssh root@pve1 "qm stop 100 --skiplock"

# Check storage
ssh root@pve1 "zfs list"  # If using ZFS
ssh root@pve1 "lvs"      # If using LVM
```