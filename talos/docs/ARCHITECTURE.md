# JDW Kubernetes Platform Architecture

This document provides a deep technical overview of how the JDW Kubernetes infrastructure is structured, deployed, and managed.

---

## 1. Goals

- Fully declarative cluster and application lifecycle
- Zero mutable state anywhere
- No manual Helm commands or kubectl apply loops
- Secure and immutable OS foundation (Talos)
- All deployments driven by GitOps
- Easy onboarding of new apps, charts, operators
- No need to modify documentation when adding new components

---

## 2. High-Level Architecture

```
                        GitHub Repository
         --------------------------------------------------
         | cluster/     | bootstrap/ | apps/ | helm-charts|
         --------------------------------------------------
                                 |
                                 v
                        Argo CD GitOps Engine
         --------------------------------------------------
         | AppSets | Projects | Helm Sources | Self-Manage |
         --------------------------------------------------
                                 |
                                 v
                        Kubernetes API Server
         --------------------------------------------------
         | Control Plane (Talos) | Worker Nodes (Talos)   |
         --------------------------------------------------
                                 |
                                 v
                          Applications & Operators
```

---

## 3. Node-Level Architecture (Talos)

```
+-----------------------------------------------------------+
|                           Node                            |
+-----------------------------------------------------------+
| Talos Linux (immutable, API-only, read-only root FS)      |
| kernel | containerd | CRI | networking | storage           |
+-----------------------------------------------------------+
| kubelet (runs workloads)                                  |
| Talos API (configuration engine)                          |
+-----------------------------------------------------------+
| Pods | CNI | CSI | Ingress | Daemonsets | Controllers     |
+-----------------------------------------------------------+
```

### Why Talos?

- No SSH
- No interactive shell
- OS configured only via declarative YAML
- OS updates are atomic and transactional
- Built-in encryption for machine secrets
- Ties perfectly into GitOps workflow
- Greatly reduces attack surface

---

## 4. GitOps Architecture (Argo CD)

```
+----------------------------------------------------------+
|                        Argo CD                           |
+----------------------------------------------------------+
| Reconciler | Diff Engine | Self-Healing | Rollbacks      |
+----------------------------------------------------------+
| ApplicationSets → generate applications from templates   |
| Projects        → RBAC, boundaries, namespace controls   |
| Helm Sources    → charts & values rendering              |
+----------------------------------------------------------+
```

### Reconciliation Flow

```
1. Git commit
2. Argo CD detects change
3. Render Helm templates
4. Apply diffs to cluster
5. Verify health
6. Self-heal drift
```

---

## 5. Repository Model

### 5.1 cluster/

Cluster-level configuration:

```
cluster/
├── controlplane*.yaml    # Talos machine configs & patches
├── worker*.yaml          # Worker node configs
├── secrets.yaml          # Encrypted Talos secrets bundle
├── talosconfig           # Local client config
└── commands.sh
```

### 5.2 bootstrap/

Bootstrap metadata:

```
bootstrap/
├── argocd/               # Argo install logic
├── bootstrap.yaml
├── config.yaml
└── projects.yaml
```

### 5.3 apps/

Each app in its own folder, completely isolated:

```
apps/
└── <app-name>/
     ├── values.yaml
     ├── README.md
     └── manifests...
```

Nothing outside the folder must reference the app.

### 5.4 helm-charts/

Locally maintained Helm charts:

```
helm-charts/
└── <chart-name>/
     ├── Chart.yaml
     ├── templates/
     └── values.yaml
```

---

## 6. Bootstrap Process (Talos + Argo)

### 6.1 Talos OS bootstrap

```
talosctl apply-config (control planes)
talosctl bootstrap
talosctl apply-config (workers)
```

### 6.2 Install Argo CD (GitOps engine)

```
kubectl apply -f bootstrap/argocd/*
```

### 6.3 Argo takes over

```
Argo reads bootstrap.yaml → config.yaml → apps/
```

Cluster now becomes **fully declarative**.

---

## 7. Secret Management Architecture

### External Secrets + Vault Flow

```
Git (ExternalSecret YAML only)
       |
       v
External Secrets Operator
       |
       v
Vault as the backend
       |
       v
Kubernetes Secrets generated
```

### No secrets ever enter Git.

Talos’s own bootstrap secrets are encrypted by default.

---

## 8. Storage Architecture (optional components)

If OpenEBS is enabled:

```
+------------------------+
| LocalPV / ZFS / LVM    |
+------------------------+
| RWX & RWO volumes      |
+------------------------+
| PVCs used by apps      |
```

---

## 9. Networking Architecture

Ingress stack (e.g., nginx):

```
Client → Ingress → Service → Pod
```

MetalLB (if used):

```
Load Balancer IP Pool → Node → Service
```

---

## 10. Deployment Lifecycle

### Add an app

```
mkdir apps/new-app
git add .
git commit -m "add new-app"
git push
```

Argo CD automatically creates and deploys it.

### Remove an app

```
rm -rf apps/old-app
git commit
git push
```

Argo CD prunes it cleanly.

---

## 11. Design Principles

- Everything is a folder
- No secrets in Git
- No repo updates required to add/remove apps
- No imperative Helm commands
- No kubectl admin loops
- Everything declarative from day 1
- Everything GitOps-managed after bootstrap

---

## 12. Future Extensions

- Multiple clusters under `/clusters/<name>/`
- Multi-region GitOps
- Workload identity + SPIFFE/SPIRE
- GitHub ARC runners fully automated
- Production/non-production separated via overlays
