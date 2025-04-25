# 🧪 Minikube Environment – JDW Platform

This directory sets up a local development and testing environment for the **JDW Platform** using [Minikube](https://minikube.sigs.k8s.io/). It provides a curated set of Helm charts, configurations, and manifests to simulate a production-like Kubernetes cluster locally.

---

## 📁 Directory Overview

Each subdirectory represents a key infrastructure or application component:

| Directory                 | Description |
|--------------------------|-------------|
| `argocd/`                | Argo CD setup for GitOps-based app delivery |
| `atlas/`                 | Helm config for Atlas schema management operator |
| `cert-manager/`          | Cluster issuers, certificates, and secrets for TLS management |
| `cloudnative-operator/`  | CRDs and Helm values for CloudNativePG configuration |
| `external-secrets/`      | External Secrets Operator values for secrets sync |
| `kube-prometheus-stack/` | Full Prometheus + Grafana observability stack |
| `kubernetes-dashboard/`  | Secure, minimal Kubernetes Dashboard installation |
| `postgresql-cluster-non/`| CloudNativePG PostgreSQL cluster + Atlas schema configs |
| `vault/`                 | HashiCorp Vault setup including ingress and bootstrap job |
| `vault-config-operator/` | Helm values for Vault Config Operator deployment |

Additional files:

- `bootstrap.yaml`: Argo CD ApplicationSet bootstrap config
- `config.yaml`: Defines Helm apps and their sync specs
- `projects.yaml`: Optional Argo CD project definitions
- `commands.sh`: Helper script for repeatable setup actions

---

## 🚀 Usage

1. **Start Minikube**

   ```bash
   minikube start --cpus=4 --memory=8192 --addons=ingress
   ```

2. **Apply Bootstrap Config**

   This uses Argo CD's ApplicationSet to install and sync all components:

   ```bash
   kubectl apply -f bootstrap.yaml
   ```

3. **Monitor Argo CD UI**

   Port-forward the Argo CD server or access via Ingress once ready.

---

## ✅ Requirements

- Minikube v1.31+
- Helm v3.x
- kubectl
- Optional: Argo CD CLI (`argocd`)

---

## 📌 Notes

- This setup is designed for **local testing only** and may differ from production setups.
- You can easily extend this with new charts via `config.yaml`.

---

Maintained by **JDW Platform Infra Team**
