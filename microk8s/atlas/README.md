## 📖 Overview

The **Atlas** directory contains the Helm values file for deploying
the [Atlas Kubernetes Operator](https://github.com/ariga/atlas-operator) into your cluster. The Atlas Operator enables
you to manage your database schema as code—defining desired state in Kubernetes CRDs and letting the operator apply
migrations automatically.

---

## ⚙️ Chart Configuration

This directory houses a single file:

- `values.yaml` – overrides for the `charts/atlas-operator` Helm chart (version 0.4.4) from the `ghcr.io/ariga` OCI
  registry.

The corresponding ApplicationSet entry:

```yaml
- chart: charts/atlas-operator
  name: atlas
  repo: ghcr.io/ariga
  revision: 0.4.4
  namespace: atlas
  postInstall: true
  syncWave: 1
```

---

## 🚀 Installation

### 1. Add the Chart Repository

If you haven’t already added the Ariga charts registry:

```bash
helm repo add ariga https://ghcr.io/ariga/charts
helm repo update
```  

This makes the `atlas-operator` chart available locally.

### 2. Create Namespace

```bash
kubectl create namespace atlas
```

### 3. Deploy via Helm

```bash
helm upgrade --install atlas-operator ariga/atlas-operator \
  -n atlas \
  -f values.yaml
```  

This installs the operator CRDs and controller to manage `AtlasMigration` and `AtlasSchema` resources.

---

## 🔍 How It Works

1. **CRD Definitions**  
   The operator registers CRDs such as `AtlasSchema` and `AtlasMigration`.
2. **Desired Schema as Code**  
   You declare your desired database schema in an `AtlasSchema` custom resource.
3. **Automated Migrations**  
   When the desired schema changes, the operator computes a diff and applies migrations to your database, ensuring
   drift-free schema management.

---

## 📝 values.yaml Highlights

| Key                                  | Description                                                 |
|--------------------------------------|-------------------------------------------------------------|
| `image.tag`                          | Operator controller image tag (matches chart version)       |
| `metrics.enabled`                    | Enable Prometheus metrics endpoint                          |
| `webhook.enabled`                    | Enable admission webhook for validating schema CRs          |
| `serviceAccount.create`              | Create a dedicated ServiceAccount for the operator          |
| `rbac.create`                        | Generate RBAC roles/rolebindings for namespace-scoped usage |
| `resources.requests.cpu` / `.memory` | Operator pod resource requests                              |

---

## 📚 References

- Atlas Operator GitHub: declarative DB migrations via Kubernetes CRDs
- Helm install instructions for Atlas Operator
- Quickstart guide on local clusters (Minikube/MicroK8s)

---

Maintained by **JDW Platform Infra Team** ✨  
