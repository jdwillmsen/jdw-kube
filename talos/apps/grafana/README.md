# 📊 Grafana – JDW Platform Observability

This directory contains everything needed to deploy **Grafana** for visualization and monitoring on the JDW Platform
using the [`grafana/grafana`](https://artifacthub.io/packages/helm/grafana/grafana) Helm chart.

---

## 📁 Contents

- **values.yaml**  
  Helm values overrides for the `grafana` chart (v9.5.1)
- **Ingress Manifest**
    - `ingress-grafana.yaml` — Expose Grafana UI
- **commands.sh**  
  Helper script for port-forwarding Grafana

---

## 🚀 Installation via Helm

1. **Add Helm repo**
   ```bash
   helm repo add grafana https://grafana.github.io/helm-charts
   helm repo update
   ```

2. **Create namespace**
   ```bash
   kubectl create namespace observability
   ```

3. **Deploy Grafana**
   ```bash
   helm upgrade --install grafana grafana/grafana \
     --namespace observability \
     --version 9.5.1 \
     -f values.yaml
   ```

4. **Apply Ingress**
   ```bash
   kubectl apply -f ingress-grafana.yaml -n observability
   ```

---

## 🔧 Usage

- **Port-forward** (via `commands.sh`):
  ```bash
  ./commands.sh port-forward
  # Grafana UI → http://localhost:3000
  ```
- **Access Ingress**:
    - Grafana at `grafana.<your-domain>`

---

## ⚙️ values.yaml Highlights

| Key                                   | Description                                             |
|---------------------------------------|---------------------------------------------------------|
| `grafana.adminPassword`               | Grafana admin password (secret)                         |
| `grafana.adminUser`                   | Grafana admin username                                  |
| `grafana.service.type`                | Grafana service type (e.g., ClusterIP, LoadBalancer)    |
| `grafana.ingress.enabled`             | Enable/disable Grafana Ingress                          |
| `grafana.resources.requests`          | CPU & memory requests for Grafana                       |
| `grafana.persistence.enabled`         | Enable/disable persistent storage for Grafana           |
| `grafana.sidecar.datasources.enabled` | Enable/disable the sidecar for auto-loading datasources |

---

## 📊 Dashboards & Data Sources

- **Pre-built Dashboards**: Grafana comes with a set of pre-configured dashboards for common monitoring use cases. You
  can import additional dashboards as needed.
- **Data Sources**: Configure Grafana to connect to data sources like Prometheus, Loki, or other monitoring systems to
  visualize your metrics.

---

## 🚨 Authentication

- Set up **Grafana authentication** by modifying `grafana.adminUser` and `grafana.adminPassword` in the `values.yaml`
  file.
- Grafana supports a variety of authentication methods, including **LDAP**, **OAuth**, and **SSO** integrations.

---

Maintained by **JDW Platform Infra Team** 🚀📊  
