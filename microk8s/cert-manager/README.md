# 🔐 cert-manager – TLS Automation for JDW Platform

This directory contains everything needed to install and configure cert-manager in your cluster to automatically
provision and renew TLS certificates.

---

## 📁 Contents

- **values.yaml**  
  Helm values overrides for the Jetstack cert-manager chart (v1.14.4)
- **cluster-issuer-ss.yaml**  
  ClusterIssuer for Self-Signed testing
- **old/**  
  Legacy manifests (pre-Helm) including production & staging issuers and sample Certificates

---

## 🛠️ Prerequisites

- Kubernetes v1.19+
- Helm 3.x

---

## 🚀 Installation via Helm

1. **Add Jetstack repo**
   ```bash
   helm repo add jetstack https://charts.jetstack.io
   helm repo update
   ```

2. **Create namespace**
   ```bash
   kubectl create namespace cert-manager
   ```

3. **Install CRDs**
   ```bash
   kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.crds.yaml
   ```

4. **Deploy cert-manager**
   ```bash
   helm upgrade --install cert-manager jetstack/cert-manager \
     --namespace cert-manager \
     -f values.yaml
   ```

---

## ⚙️ Configuration Highlights

| Key                        | Description                    |
|----------------------------|--------------------------------|
| `replicaCount`             | Number of controller replicas  |
| `image.repository`         | cert-manager image             |
| `clusterResourceNamespace` | Namespace for Issuer secrets   |
| `webhook.replicaCount`     | Admission webhook replicas     |
| `resources.requests`       | CPU/memory requests for pods   |
| `rbac.enabled`             | Create ClusterRoles & bindings |
| `servicemonitor.enabled`   | Export Prometheus metrics      |

---

## 🎛️ Cluster Issuers

- **Self-Signed**  
  Apply the self-signed issuer for testing:
  ```bash
  kubectl apply -f cluster-issuer-ss.yaml
  ```

- **Legacy ACME**  
  Production & staging ACME issuers are in `old/cluster-issuer-prod.yaml` and `old/cluster-issuer-staging.yaml`.

---

## 🧪 Testing

Create a test Certificate resource:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-cert
  namespace: cert-manager
spec:
  secretName: test-tls
  dnsNames:
    - example.com
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
```

Then:

```bash
kubectl apply -f old/certificates.yaml
kubectl describe certificate test-cert -n cert-manager
```

---

Maintained by **JDW Platform Infra Team** ✨  
