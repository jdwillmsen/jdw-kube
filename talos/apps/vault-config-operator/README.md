# ⚙️ Vault Config Operator – JDW Platform

This directory deploys the [Vault Config Operator](https://github.com/redhat-cop/vault-config-operator) into your Kubernetes cluster using Helm. This operator simplifies automated configuration of Vault resources like policies, secrets engines, auth methods, and more—directly from Kubernetes manifests.

---

## 📁 Directory Structure

- **values.yaml**  
  Configuration for installing the operator via Helm.

---

## 🚀 Deployment Steps

### 1. Add the Helm Repository

```bash
helm repo add vault-config-operator https://redhat-cop.github.io/vault-config-operator
helm repo update
```

> 📌 If not available as a Helm chart, this may be installed from static manifests. This setup assumes you’ve mirrored it as a Helm chart.

---

### 2. Install the Operator

```bash
kubectl create namespace vault-config-operator

helm upgrade --install vault-config-operator vault-config-operator/vault-config-operator \
  -n vault-config-operator \
  -f values.yaml
```

---

## 🎯 Use Cases

- Automate creation of Vault roles, policies, auth methods, and engines.
- Manage Vault configurations declaratively via GitOps.
- Integrate Vault configuration lifecycle into your Argo CD workflows.

---

## 💡 Tips

- Ensure Vault is accessible and properly initialized.
- Leverage Kubernetes service accounts for auth method setup.
- Use CRDs like `VaultPolicy`, `VaultAuthMethod`, and `VaultSecret` for declarative control.

---

## 🔒 Security

- Limit the operator's RBAC permissions to only what’s necessary.
- Store sensitive configurations (like tokens) via Kubernetes secrets.

---

Maintained by **JDW Platform Infra Team** 🛡️  
