# 🚀 Porkbun Webhook – JDW Platform

This folder contains everything needed to deploy and configure the **Porkbun Webhook** on a **Talos Linux** Kubernetes cluster.

Talos is an immutable, API-driven OS, so some installation steps differ from traditional Linux distros.

---

## 📂 Contents

- **README.md** – This guide
- **Chart.yaml** – Helm chart metadata
- **values.yaml** – Default Helm values
- **templates/** – Kubernetes manifests templates
    - **deployment.yaml** – Webhook deployment
    - **service.yaml** – Service exposing the webhook
    - **apiservice.yaml** – APIService registration
    - **pki.yaml** – TLS/PKI manifests
    - **rbac.yaml** – RBAC manifests
    - **_helpers.tpl** – Helm template helpers
    - **NOTES.txt** – Helm post-install notes

---

## 🛠️ Quickstart on Talos

### 1️⃣ Get Your Cluster Kubeconfig
Talos does not use kubeconfig files by default — generate one:

```bash
talosctl kubeconfig .
export KUBECONFIG=./kubeconfig
```

---

### 2️⃣ Deploy the Porkbun Webhook via Helm

```bash
helm repo add jdw https://charts.jdwkube.com
helm install porkbun-webhook ./porkbun-webhook \
  -n porkbun-webhook --create-namespace \
  -f values.yaml
```

---

## 🔑 Vault Secrets Setup

The webhook requires secrets stored in **Vault** for authentication. You can create them in a single command:

```bash
kubectl exec -n vault vault-0 -- sh -c "vault login $VAULT_TOKEN && vault kv put kv/porkbun api-key=$PORKBUN_API_KEY secret-key=$PORKBUN_SECRET_KEY"
```

> Make sure your environment variables `$VAULT_TOKEN`, `$PORKBUN_API_KEY`, and `$PORKBUN_SECRET_KEY` are set locally before running the command.

To verify that the secrets were stored correctly:

```bash
kubectl exec -n vault vault-0 -- vault kv get kv/porkbun
```

---

## ⚙️ Customization

You can override default Helm values in `values.yaml`:

- **replicaCount** – Number of webhook replicas
- **image.repository/tag** – Docker image to use
- **service.type/port** – Service configuration
- **pki/tls** – Certificate and key configuration
- **rbac.enabled** – Enable or disable RBAC

Apply changes by running:

```bash
helm upgrade porkbun-webhook ./porkbun-webhook -f values.yaml -n porkbun-webhook
```

---

## 🛡️ Notes for Talos Users

- Talos nodes are immutable; **do not SSH** — use `talosctl`.
- Kubernetes networking depends on your CNI (Cilium, Flannel, etc.).
- TLS certificates should be provided via PKI manifests or external Vault integration.

---

Maintained by **JDW Platform Infra Team** 🌐🔧
