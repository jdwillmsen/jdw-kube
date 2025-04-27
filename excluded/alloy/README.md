# 🎨 Alloy – JDW Platform Observability

This directory contains everything needed to deploy the **Grafana Alloy** observability stack on the JDW Platform using
the [`grafana/alloy`](https://artifacthub.io/packages/helm/grafana/alloy) Helm chart.

---

## 📁 Contents

- **values.yaml**  
  Helm values overrides for the `alloy` chart (v0.2.0)
- **Ingress Manifest**
    - `ingress-alloy.yaml` — Expose Alloy UI
- **commands.sh**  
  Helper script for port-forwarding Alloy

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

3. **Deploy Alloy**
   ```bash
   helm upgrade --install alloy grafana/alloy \
     --namespace observability \
     --version 0.2.0 \
     -f values.yaml
   ```

4. **Apply Ingress**
   ```bash
   kubectl apply -f ingress-alloy.yaml -n observability
   ```

---

## 🔧 Usage

- **Port-forward** (via `commands.sh`):
  ```bash
  ./commands.sh port-forward
  # Alloy UI → http://localhost:8080
  ```
- **Access Ingress**:
    - Alloy at `alloy.<your-domain>`

---

## ⚙️ values.yaml Highlights

| Key                        | Description                                  |
|----------------------------|----------------------------------------------|
| `alloy.ui.enabled`         | Enable/disable Alloy UI                      |
| `alloy.ui.replicas`        | Number of Alloy UI replicas                  |
| `alloy.analytics.enabled`  | Enable/disable Alloy analytics               |
| `alloy.logging.enabled`    | Enable/disable Alloy logging feature         |
| `alloy.resources.requests` | CPU & memory requests for Alloy components   |
| `alloy.auth.enabled`       | Enable/disable Alloy UI authentication       |
| `service.type`             | Service type (e.g., ClusterIP, LoadBalancer) |

---

## 📈 Analytics & Logs

- Enable the **Alloy Analytics** and **Logging** features to gather metrics and logs from various observability sources.
- Customize data retention, scraping intervals, and integration with other monitoring tools as needed.

---

Maintained by **JDW Platform Infra Team** 🚀🎨  
