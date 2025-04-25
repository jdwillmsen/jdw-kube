# 📦 helm-charts – JDW Platform Custom Helm Releases

This folder contains custom Helm chart definitions and ApplicationSet bootstrapping for your in-repo charts. It lets
Argo CD deploy both local and upstream charts in a GitOps-native way.

---

## 📁 Contents

- **config.yaml**  
  Lists chart apps to bootstrap (name, path, namespace, values files).
- **bootstrap.yaml**  
  An Argo CD `ApplicationSet` that reads `config.yaml` and generates one Application per chart.
- **porkbun-webhook/**  
  A custom in-repo Helm chart:
    - `Chart.yaml`
    - `values.yaml`
    - `templates/…` (K8s manifests & helpers)

---

## 🚀 Bootstrapping In-Repo Charts

Argo CD uses `bootstrap.yaml` to dynamically create Applications from `config.yaml`.

1. **Ensure Argo CD is installed** in the `argocd` namespace.
2. **Apply the ApplicationSet**:
   ```bash
   kubectl apply -f helm-charts/bootstrap.yaml
   ```
3. Argo CD will read `config.yaml` and deploy each chart under the specified namespace.

---

## ⚙️ config.yaml Format

```yaml
apps:
  - name: porkbun-webhook
    helmPath: microk8s/helm-charts/porkbun-webhook
    namespace: porkbun-webhook
    values:
      - values.yaml
```

- **name**: Argo CD Application name
- **helmPath**: path to chart directory in repo
- **namespace**: target Kubernetes namespace
- **values**: list of value files (relative to chart path)

---

## 🛠️ Adding a New Chart

1. Create a new subfolder under `helm-charts/` (e.g. `my-service/`) with standard Helm chart structure (`Chart.yaml`,
   `templates/`, `values.yaml`).
2. Add an entry to `config.yaml`:
   ```yaml
   apps:
     - name: my-service
       helmPath: microk8s/helm-charts/my-service
       namespace: my-service-namespace
       values:
         - values.yaml
   ```
3. Commit and push — Argo CD will automatically detect and deploy.

---

## 🔄 Sync & Self-Heal

- **Automated sync** with `prune: true` & `selfHeal: true` ensures drift correction.
- **CreateNamespace=true** auto-creates target namespaces.
- **PruneLast=true** ensures cleanup after sync.

---

Maintained by **JDW Platform Infra Team** 🛡️✨  
