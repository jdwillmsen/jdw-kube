# Proxmox Authentication
variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox API endpoint (e.g., https://192.168.1.100:8006/api2/json)"
}

variable "proxmox_api_token_id" {
  type        = string
  description = "API Token ID: terraform@pve!token-name"
  sensitive   = true
}

variable "proxmox_api_token_secret" {
  type        = string
  description = "API Token Secret"
  sensitive   = true
}

# Infrastructure Settings
variable "storage_pool" {
  type    = string
  default = "local-lvm"
}

variable "talos_iso" {
  type    = string
  default = "local:iso/nocloud-amd64.iso"
}

# CONTROL PLANE CONFIGURATION
# This is a LIST of objects - add more objects to scale up
variable "talos_control_configuration" {
  description = "List of control plane node configs"
  type = list(object({
    node_name = string
    vm_name   = string
    vmid      = number
    cpu_cores = number
    memory    = number
    disk_size = number
  }))
}

# WORKER CONFIGURATION
# This is a LIST of objects - add more objects to scale up
variable "talos_worker_configuration" {
  description = "List of worker node configs"
  type = list(object({
    node_name = string
    vm_name   = string
    vmid      = number
    cpu_cores = number
    memory    = number
    disk_size = number
  }))
}