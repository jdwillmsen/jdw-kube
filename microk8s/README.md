# ⚙️ MicroK8s Manifests - JDW Platform

This directory contains Kubernetes manifests, Helm values, and setup configurations used to deploy and manage the JDW
Platform on a [MicroK8s](https://microk8s.io/) cluster.

## 🧭 Overview

This is the **core production-ready deployment layer** for JDW Platform infrastructure. It is built to work
with [ArgoCD ApplicationSets](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/) and is
structured to support GitOps-driven Kubernetes clusters.

### 📁 Structure

Each folder typically represents either:

- 📦 A Helm chart release (`values.yaml` for overrides)
- 📄 A set of raw Kubernetes manifests
- 🛠️ A custom internal chart (see `helm-charts/`)

ArgoCD consumes `config.yaml` to bootstrap the cluster.

### 📌 Notable Files

- `config.yaml`: Main configuration list of all apps to deploy.
- `bootstrap.yaml`: ArgoCD `ApplicationSet` CRD that generates applications from `config.yaml`.
- `commands.sh`: Scripts for setup or utilities per resource.

## 🚀 Bootstrap Flow

The `bootstrap.yaml` ArgoCD ApplicationSet CRD reads `config.yaml` and renders apps using the matrix generator and Helm
values files. This enables modular, declarative deployment.

🔧 **Example App Config:**

```yaml
apps:
  - chart: vault
    name: vault
    repo: https://helm.releases.hashicorp.com
    revision: 0.28.0
    namespace: vault
    postInstall: true
    syncWave: 1
```

## 🧰 Requirements

- 🐧 MicroK8s with required addons (`helm3`, `dns`, etc.)
- 🎯 ArgoCD installed and configured
- 🔐 External Secrets, Vault, and Ingress Controller
- 💾 Optional: OpenEBS, Prometheus, cert-manager, Metrics Server

## ➕ Adding a New App

1. ✍️ Add an app config entry to `config.yaml`
2. 📂 Create a folder under `microk8s/<app-name>/`
3. 📝 Add a `values.yaml` file (Helm override)
4. 🧩 (Optional) Add manifests or templates as needed
5. 🔄 ArgoCD will auto-discover and apply

## 🧱 Helm Charts

Custom charts live in `helm-charts/`.  
Example: `porkbun-webhook` is a locally defined chart with templates.

🛠️ **To use a local chart:**

```yaml
chart: porkbun-webhook
repo: ""
```

## 🧪 Dev Notes

- 📑 Subfolders can contain their own `README.md` for deeper breakdown.
- ⏱️ `syncWave` helps orchestrate the right install order.
- 🎯 `postInstall` enables additional resource syncing after Helm install.

---

🛡️ **Maintained by [@jdwillmsen](https://github.com/jdwillmsen)**
