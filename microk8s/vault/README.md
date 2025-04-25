# 🔐 Vault – JDW Platform

This directory provisions [HashiCorp Vault](https://www.vaultproject.io/) into the `vault` namespace using the official
Helm chart. Vault is used as the core secrets manager across the JDW Platform, integrated with External Secrets and
Kubernetes workloads.

---

## 📁 Directory Structure

- **values.yaml**  
  Helm configuration for Vault installation.
- **vault-ingress.yaml**  
  Optional Ingress for web UI and API access.
- **job.yaml**  
  Initialization Job for Vault (e.g., unsealing or setup).
- **commands.sh**  
  Handy CLI scripts for interacting with Vault.

---

## 🚀 Deployment Steps

### 1. Add the Helm Repo

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

### 2. Create the Namespace

```bash
kubectl create namespace vault
```

### 3. Install Vault via Helm

```bash
helm upgrade --install vault hashicorp/vault \
  -n vault \
  --version 0.28.0 \
  -f values.yaml
```

### 4. (Optional) Expose via Ingress

```bash
kubectl apply -f vault-ingress.yaml
```

### 5. (Optional) Run Initialization Job

```bash
kubectl apply -f job.yaml
```

---

## ⚙️ Helm Values Highlights

| Key                  | Description                                   |
|----------------------|-----------------------------------------------|
| `server.dev.enabled` | Set to `false` for production mode            |
| `server.ha.enabled`  | Enables HA mode with Raft or external backend |
| `ui.enabled`         | Enables the Vault Web UI                      |
| `ingress.enabled`    | Managed externally in `vault-ingress.yaml`    |
| `auditLogs.enabled`  | Enable audit logging                          |

---

## 🛠 Useful Commands

```bash
# Port-forward the Vault UI locally
kubectl port-forward svc/vault-ui -n vault 8200:8200

# Initialize and unseal (if not using auto-unseal)
kubectl exec -n vault vault-0 -- vault operator init
kubectl exec -n vault vault-0 -- vault operator unseal
```

> 💡 Tip: Use KMS auto-unseal where possible for production-grade Vault.

---

## 🔒 Best Practices

- Use **Raft backend** with persistent volumes in production.
- Store root/unseal keys securely (e.g., offline or in HSM).
- Integrate with External Secrets for dynamic secret injection.
- Audit and restrict Vault policies with RBAC.

---

Maintained by **JDW Platform Infra Team** 🛡️  
