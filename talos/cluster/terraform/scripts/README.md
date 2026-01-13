# Talos Cluster Scripts

## Workflow
1. **Validate**: `bash scripts/validate.sh`
2. **Deploy**: `bash scripts/deploy.sh`
3. **Destroy**: `bash scripts/destroy.sh`

## What Each Script Does

### validate.sh
Pre-flight checks:
- System dependencies (terraform, jq, curl)
- File structure
- Required variables
- Proxmox API connectivity
- ISO existence
- VM ID uniqueness
- Terraform version

### deploy.sh
Deploys or updates cluster:
- Backs up state & config
- Formats and validates
- Shows planned changes
- Prompts for confirmation
- Applies changes
- Shows VM summary

### destroy.sh
Safely destroys cluster:
- Shows what will be destroyed
- Warns about Kubernetes cluster
- Backs up state
- Double confirmation required
- Graceful or immediate destroy
- Verifies destruction

## Configuration
Edit `terraform.tfvars` to change:
- Proxmox connection settings
- VM resources (CPU, RAM, disk)
- Number of control plane/worker nodes
- VM IDs (200-299=CP, 300-399=Workers)