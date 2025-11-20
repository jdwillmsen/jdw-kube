# 🖥️ Kubernetes Dashboard – JDW Platform

This directory contains everything needed to deploy and secure the Kubernetes Dashboard UI on your cluster, including
Helm overrides, TLS ingress, and helper scripts.

---

## 📁 Contents

- **values.yaml**  
  Helm values overrides for the `kubernetes-dashboard` chart (v7.3.2).
- **tls-dashboard-ingress.yaml**  
  Ingress manifest (TLS) to expose the Dashboard securely.
- **commands.sh**  
  Helper script for port-forwarding or quick access.
- **old/**  
  Legacy ingress manifests:
    - `tls-dashboard-ingress-old.yaml`
    - `tls-dashboard-ingress.yaml`

---

## 🚀 Installation (Helm)

1. **Add the Dashboard repo**
   ```bash
   helm repo add kubernetes-dashboard https://kubernetes.github.io/dashboard/
   helm repo update
   ```
2. **Create namespace**
   ```bash
   kubectl create namespace kubernetes-dashboard
   ```
3. **Deploy Dashboard**
   ```bash
   helm upgrade --install kubernetes-dashboard kubernetes-dashboard/kubernetes-dashboard \
     --namespace kubernetes-dashboard \
     --version 7.3.2 \
     -f values.yaml
   ```
4. **Apply TLS Ingress**
   ```bash
   kubectl apply -f tls-dashboard-ingress.yaml -n kubernetes-dashboard
   ```

---

## 🔑 Accessing the UI

### Port-Forward

Use the helper script:

```bash
./commands.sh port-forward
# Then browse to http://localhost:8443
```

### Ingress

Once the ingress is up, access via your DNS name (configured in `tls-dashboard-ingress.yaml`).

---

## ⚙️ values.yaml Highlights

| Key                         | Description                                       |
|-----------------------------|---------------------------------------------------|
| `fullnameOverride`          | Override release name                             |
| `service.type`              | Service type (ClusterIP / NodePort)               |
| `ingress.enabled`           | Enable/disable ingress                            |
| `ingress.hosts[0].host`     | Dashboard hostname                                |
| `ingress.tls[0].secretName` | TLS secret for Dashboard TLS                      |
| `resources.requests`        | CPU & memory for dashboard pods                   |
| `rbac.clusterAdminRole`     | Grant cluster-admin to service account (optional) |

---

## 🔄 Legacy Ingress

The `old/` folder contains previous ingress configurations. You can compare or migrate settings:

```bash
# legacy ingress
old/tls-dashboard-ingress-old.yaml  
old/tls-dashboard-ingress.yaml  
```

---

## 🛠️ Customization

- Edit **values.yaml** to tweak UI settings (e.g. enable metrics, change service type).
- Update **tls-dashboard-ingress.yaml** to match your domain and TLS secret.

---

Maintained by **JDW Platform Infra Team** 🚧✨  
