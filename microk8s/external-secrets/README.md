# 🔑 External Secrets – JDW Platform

This directory configures the External Secrets operator to sync secrets from external secret stores into Kubernetes
Secrets.

---

## 📁 Contents

- **values.yaml**  
  Helm values overrides for the External Secrets chart (v0.15.0).
- **(no additional manifests)** — this chart deploys the operator and CRDs.

---

## 🚀 Installation via Helm

1. **Add External-Secrets repo**
   ```bash
   helm repo add external-secrets https://charts.external-secrets.io
   helm repo update
   ```

2. **Create namespace**
   ```bash
   kubectl create namespace external-secrets
   ```

3. **Install External Secrets operator**
   ```bash
   helm upgrade --install external-secrets external-secrets/external-secrets \
     -n external-secrets \
     -f values.yaml
   ```

---

## ⚙️ values.yaml Highlights

| Key                       | Description                                  |
|---------------------------|----------------------------------------------|
| `installCRDs`             | Whether to install CRDs (true/false)         |
| `securityContext.fsGroup` | Filesystem group for operator pods           |
| `resources.requests`      | CPU & memory for controller and webhook pods |
| `serviceAccount.create`   | Create dedicated ServiceAccount              |
| `metrics.enabled`         | Enable Prometheus metrics export             |

---

## 🛠️ Usage

After installation, define an `ExternalSecret` CR to pull data:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: my-db-creds
  namespace: external-secrets
spec:
  secretStoreRef:
    name: vault-secretstore
    kind: SecretStore
  target:
    name: db-credentials
  data:
    - secretKey: username
      remoteRef:
        key: database/credentials
        property: username
    - secretKey: password
      remoteRef:
        key: database/credentials
        property: password
```

Apply it:

```bash
kubectl apply -f my-external-secret.yaml
```

---

## 🔒 Security

- Secrets sync at runtime; no credentials are stored in Git.
- Access to external stores is controlled via `SecretStore` or `ClusterSecretStore` CRs.

---

Maintained by **JDW Platform Infra Team** 🔐✨  
