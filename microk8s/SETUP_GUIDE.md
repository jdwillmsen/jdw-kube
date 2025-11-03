# 🧩 MicroK8s Cluster Setup Guide

This document provides a **repeatable process** for setting up a **multi-node MicroK8s cluster** where all nodes already have MicroK8s installed.  
It’s designed for consistency, automation, and easy replication across environments.

---

## 🖥️ Overview

| Purpose | Description |
|----------|--------------|
| Cluster Type | Multi-node MicroK8s |
| OS Tested | Ubuntu 22.04+ |
| Example Nodes | `k8server1`, `k8server2`, `k8server3` |
| Channel Version | `1.31/stable` (update as needed) |

---

## 🧰 Prerequisites

- Ubuntu (or compatible Linux) installed on all nodes
- Static IPs or DHCP reservations for each node
- Unique hostnames (e.g. `k8server1`, `k8server2`, `k8server3`)
- SSH access between nodes (recommended)
- `sudo` privileges on all nodes

---

## ⚙️ 1. Install MicroK8s

Run the following on **each node**:

```bash
sudo snap install microk8s --classic --channel=1.31/stable
sudo usermod -aG microk8s $USER
sudo chown -f -R $USER ~/.kube
newgrp microk8s
microk8s status --wait-ready
```

> 💡 Update the version channel if needed, e.g. `--channel=1.34/stable`.

---

## 🌐 2. Configure Hostnames and Networking

Edit `/etc/hosts` on **all nodes** to include all other nodes:

```bash
sudo nano /etc/hosts
```

Example:
```
192.168.1.101 k8server1
192.168.1.102 k8server2
192.168.1.103 k8server3
```

Ensure each node’s hostname matches (`hostnamectl set-hostname k8serverX`).

---

## 🧱 3. Enable Core Add-ons (on the primary node)

On your **main control node** (e.g., `k8server1`):

```bash
microk8s enable dns storage
```

Optional but commonly useful:
```bash
microk8s enable dashboard
microk8s enable metrics-server
microk8s enable hostpath-storage
```

---

## 🤝 4. Join Other Nodes to the Cluster

### On the **primary node**:
```bash
microk8s add-node
```

You’ll see output similar to:
```
Join node with:
microk8s join 192.168.1.101:25000/9a3a5ccf8f9c8bf51bca2f5e25c34f12
```

### On each **secondary node**:
Run the command shown:
```bash
microk8s join 192.168.1.101:25000/9a3a5ccf8f9c8bf51bca2f5e25c34f12
```

If you lose the token, regenerate it:
```bash
microk8s add-node
```

---

## ✅ 5. Verify Cluster

Once all nodes are joined, verify from any node:

```bash
microk8s status
microk8s kubectl get nodes
```

Expected:
```
NAME         STATUS   ROLES    AGE   VERSION
k8server1    Ready    <none>   5m    v1.31.3
k8server2    Ready    <none>   3m    v1.31.3
k8server3    Ready    <none>   3m    v1.31.3
```

---

## 🔑 6. Export Kubeconfig (Optional)

If you want to use `kubectl` directly from your system:
```bash
microk8s config > ~/.kube/config
```

Or for system-wide access:
```bash
sudo microk8s config > /etc/kubernetes/admin.conf
```

---

## 🧩 7. Enable Optional Add-ons

```bash
microk8s enable ingress
microk8s enable rbac
microk8s enable metallb:192.168.1.240-192.168.1.250
```

> ⚠️ Update the MetalLB IP range to fit your network.

---

## 🧽 8. Reset or Remove Nodes

### Remove a node from the cluster (run on primary):
```bash
microk8s remove-node <node-name>
```

### Reset a node completely (run on that node):
```bash
microk8s leave
microk8s reset
```

---

## 🧭 9. Common Commands

| Purpose | Command |
|----------|----------|
| Check cluster info | `microk8s kubectl cluster-info` |
| View pods | `microk8s kubectl get pods -A` |
| Restart MicroK8s | `microk8s stop && microk8s start` |
| Inspect issues | `microk8s inspect` |
| Check systemd services | `sudo systemctl status snap.microk8s.daemon-*` |

---

## 🧰 10. Automate Node Setup

Create a helper script (optional):  
**`setup-microk8s.sh`**

```bash
#!/usr/bin/env bash
set -e

VERSION=${1:-1.31/stable}

echo "Installing MicroK8s version: $VERSION"
sudo snap install microk8s --classic --channel=$VERSION
sudo usermod -aG microk8s $USER
sudo chown -f -R $USER ~/.kube

newgrp microk8s <<EONG
microk8s status --wait-ready
microk8s enable dns storage
EONG

echo "✅ MicroK8s installed and ready."
```

Run it on any new node:
```bash
bash setup-microk8s.sh
```

---

## 📦 11. Cluster Summary

| Step | Description |
|------|--------------|
| 1 | Install MicroK8s on all nodes |
| 2 | Configure networking and hostnames |
| 3 | Enable base add-ons |
| 4 | Join nodes to cluster |
| 5 | Verify and test |
| 6 | Configure optional add-ons |
| 7 | Export kubeconfig for external tools |

---

## 🧾 Notes

- **Backup Configuration:**  
  Save the output of `microk8s config` and `microk8s add-node` commands for disaster recovery.

- **Version Upgrades:**  
  To upgrade:
  ```bash
  sudo snap refresh microk8s --channel=1.34/stable
  ```

- **Inspect Health:**
  ```bash
  microk8s inspect
  ```

---

## 🪄 Example Cluster Topology

| Node | Role | IP | Purpose |
|------|------|----|---------|
| k8server1 | Primary | 192.168.1.101 | Control plane / DNS |
| k8server2 | Worker | 192.168.1.102 | App workloads |
| k8server3 | Worker | 192.168.1.103 | App workloads |

---

**✅ Done!**  
You now have a reproducible MicroK8s cluster setup that can be replicated quickly on any future environment.

---

*Maintained as part of the JDW Platform Infrastructure Guides.*
