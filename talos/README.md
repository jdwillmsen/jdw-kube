# JDW Kubernetes Infrastructure

This repository contains the full **infrastructure-as-code** configuration for a Kubernetes cluster running on **Talos Linux**, managed using a **GitOps workflow** powered by **Argo CD** and **Helm**.

The layout emphasizes:

- Config-driven application management
- Minimal hard-coding
- Easy addition or removal of components
- Modular and environment-agnostic structure
- Clear separation between cluster bootstrap, cluster configuration, and application layers

---

## 📁 Repository Structure

```
.
├── apps/                     # GitOps-managed applications (Helm values, manifests, per-app configs)
│   └── <app-name>/           # Each app isolated in its own directory
│       ├── values.yaml
│       ├── README.md
│       └── *.yaml/*.sh/etc.
│
├── bootstrap/                # Argo CD & GitOps bootstrap layer
│   ├── argocd/               # Namespace, installation, ingress, secrets, projects
│   ├── bootstrap.yaml        # Bootstrap entrypoint applied manually once
│   ├── config.yaml           # Environment-level configuration
│   └── projects.yaml         # Argo CD project definitions
│
├── cluster/                  # Talos cluster configuration layer
│   ├── controlplane*.yaml    # Control-plane configs / patches
│   ├── worker*.yaml          # Worker node configs
│   ├── secrets.yaml          # Talos secrets bundle
│   ├── talosconfig           # Local talosctl config for accessing the cluster
│   └── commands.sh           # Helper & lifecycle scripts
│
└── helm-charts/              # Local reusable Helm charts
    ├── <chart-name>/         # Each chart lives in its own directory
    ├── config.yaml           # Shared values common across charts
    └── bootstrap.yaml        # Chart-level bootstrap configuration
```

This layout allows you to add/remove apps or charts **purely by adding/removing folders**, with no README or code needing to change.

---

## 🚀 Bootstrapping a New Cluster

### 1️⃣ Apply Talos Control Plane Configuration
```sh
talosctl apply-config --nodes <cp-ip> --file cluster/controlplane.yaml --insecure
```

### 2️⃣ Bootstrap the Control Plane
```sh
talosctl bootstrap --nodes <one-cp-ip>
```

### 3️⃣ Apply Worker Configuration
```sh
talosctl apply-config --nodes <worker-ip> --file cluster/worker.yaml --insecure
```

### 4️⃣ Pull Kubeconfig for Local Access
```sh
talosctl kubeconfig .
export KUBECONFIG=$(pwd)/kubeconfig
```

---

## 🧩 GitOps Initialization (Argo CD)

Once the cluster is healthy, install Argo CD:

```sh
kubectl apply -f bootstrap/argocd/argocd-namespace.yaml
kubectl apply -f bootstrap/argocd/argocd.yaml
kubectl apply -f bootstrap/argocd/argocd-application.yaml
```

Argo CD will:

- Manage itself
- Sync all apps under `apps/`
- Sync all Helm charts under `helm-charts/`
- Respect the definitions in `bootstrap/projects.yaml`

No manual installation is required after bootstrap.

---

## 📦 Application Deployment Model

The repo is designed so every application is **fully declarative** and **self-contained**.

### Adding an Application
1. Create a new folder under `apps/<app-name>/`
2. Add `values.yaml`, manifests, or your Helm chart overrides
3. Commit and push  
   Argo CD automatically deploys it.

### Removing an Application
1. Delete or rename the app directory
2. Commit and push  
   Argo CD automatically removes it from the cluster.

**No update to the README or global configs required.**

---

## 🔐 Secrets & Security

This repository uses:

- **Talos encrypted secrets** for cluster bootstrap
- **Vault and/or External Secrets Operator** for runtime secrets
- Declarative secret references stored safely in Git
- No plaintext secrets checked into version control

Secret sources are controlled by your apps, not the repo layout.

---

## 📊 Monitoring & Observability

Monitoring and logging are app-driven and live entirely inside `apps/`.  
Common components include (but are not required):

- Prometheus
- Grafana
- Loki
- Dashboard tooling
- Ingress metrics
- Storage and database operators

Because the repo is config-driven, adding or removing observability tools is non-breaking.

---

## 🧰 Node, Cluster & Lifecycle Commands

Useful Talos operations:

Reboot all nodes:
```sh
talosctl reboot --nodes <ips> --insecure
```

Upgrade Talos:
```sh
talosctl upgrade --nodes <ips> \
  --image ghcr.io/siderolabs/installer:<version> \
  --preserve --insecure
```

Check node health:
```sh
talosctl health
```

---

## 🧩 Philosophy

This repository follows these principles:

- **Everything is declarative**
- **Every component is isolated**
- **Apps and charts are fully config-driven**
- **No repo maintenance required when growing**
- **Talos for immutable infrastructure**
- **Argo CD for GitOps reconciliation**
- **Helm for packaging and templating**
- **Simple, portable, cluster-agnostic layout**

---

## 📝 Contributing / Extending

To add new:

- clusters
- environments
- Helm charts
- applications
- operators
- storage classes

…simply create a new directory under the appropriate folder.  
Argo CD will handle the rest.

No changes to this README are necessary.

---

## 🏗 Architecture Overview

The JDW Kubernetes platform is built on three major pillars:

1. **Talos Linux** — Immutable, secure-by-default Kubernetes operating system
2. **Argo CD GitOps** — Declarative cluster and application reconciliation
3. **Helm** — Packaging and configuration templating

The repository is structured so that all changes flow from Git → Argo CD → Cluster, with no mutable state or imperative commands required beyond initial bootstrap.

### High-Level Architecture Diagram

```
                        +-------------------------+
                        |        GitHub Repo      |
                        |-------------------------|
                        | cluster/                |
                        | bootstrap/              |
                        | apps/                   |
                        | helm-charts/            |
                        +-----------+-------------+
                                    |
                                    | GitOps Sync
                                    v
               +-----------------------------------------------+
               |                     Argo CD                   |
               |-----------------------------------------------|
               | ApplicationSets   | Projects | Helm Sources   |
               +-----------------------------------------------+
                                    |
                                    | Reconcile Apps
                                    v
         +-------------------------------------------------------------+
         |                        Kubernetes Cluster                   |
         |-------------------------------------------------------------|
         | Control Plane Nodes (Talos)  |   Worker Nodes (Talos)       |
         | etcd | API Server | Scheduler|   Apps, Operators, Ingress  |
         +-------------------------------------------------------------+
```

### Layered Architecture

```
+---------------------------------------------------------------+
|                      Application Layer                        |
|  apps/<app>/values.yaml, manifests, ingress, config, etc.     |
+---------------------------------------------------------------+
|              GitOps / Continuous Reconciliation Layer         |
|         Argo CD, ApplicationSets, Helm, Projects              |
+---------------------------------------------------------------+
|               Cluster Operations & Bootstrap Layer            |
|       bootstrap/, cluster/, helm-charts/ (local charts)       |
+---------------------------------------------------------------+
|                       Talos Linux OS Layer                    |
|     Immutable nodes, API-driven OS, encrypted secrets         |
+---------------------------------------------------------------+
```

### Declarative Flow (Push → Reconcile → Apply)

```
Developer Commit →
  GitHub →
    Argo CD →
      Kubernetes API →
        Node / Pod Lifecycle →
          Apps Running
```

### Secret Flow (Vault + External Secrets)

```
Git (no secrets)
     ↓
External Secrets Operator
     ↓ fetch
Vault (source of truth)
     ↓ inject
Kubernetes Secret objects (ephemeral & rotated)
```
