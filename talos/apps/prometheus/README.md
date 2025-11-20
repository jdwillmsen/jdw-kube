# 📊 Prometheus – JDW Platform Monitoring

This directory contains everything needed to deploy **Prometheus** for monitoring and alerting on the JDW Platform using
the [`prometheus-community/prometheus`](https://artifacthub.io/packages/helm/prometheus-community/prometheus) Helm
chart.

---

## 📁 Contents

- **values.yaml**  
  Helm values overrides for the `prometheus` chart (v15.2.0)
- **Ingress Manifest**
    - `ingress-prometheus.yaml` — Expose Prometheus UI
- **commands.sh**  
  Helper script for port-forwarding Prometheus

---

## 🚀 Installation via Helm

1. **Add Helm repo**
   ```bash
   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
   helm repo update
   ```

2. **Create namespace**
   ```bash
   kubectl create namespace monitoring
   ```

3. **Deploy Prometheus**
   ```bash
   helm upgrade --install prometheus prometheus-community/prometheus \
     --namespace monitoring \
     --version 15.2.0 \
     -f values.yaml
   ```

4. **Apply Ingress**
   ```bash
   kubectl apply -f ingress-prometheus.yaml -n monitoring
   ```

---

## 🔧 Usage

- **Port-forward** (via `commands.sh`):
  ```bash
  ./commands.sh port-forward
  # Prometheus UI → http://localhost:9090
  ```
- **Access Ingress**:
    - Prometheus at `prometheus.<your-domain>`

---

## ⚙️ values.yaml Highlights

| Key                               | Description                                                 |
|-----------------------------------|-------------------------------------------------------------|
| `server.global.scrape_interval`   | Global scrape interval for Prometheus                       |
| `server.global.scrape_timeout`    | Global scrape timeout for Prometheus                        |
| `server.ingress.enabled`          | Enable/disable Prometheus Ingress                           |
| `server.resources.requests`       | CPU & memory requests for Prometheus                        |
| `alertmanager.enabled`            | Enable/disable Alertmanager for handling alerts             |
| `alertmanager.resources.requests` | CPU & memory requests for Alertmanager                      |
| `server.retention`                | Data retention period for Prometheus time series            |
| `server.persistentVolume.enabled` | Enable/disable persistent storage for Prometheus            |
| `server.service.type`             | Service type for Prometheus (e.g., ClusterIP, LoadBalancer) |

---

## 📥 Metrics Collection & Alerts

- **Prometheus** scrapes metrics from your Kubernetes cluster and applications, collecting valuable time-series data for
  visualization and alerting.
- Configure **Alertmanager** to handle Prometheus alerts, and route them to your desired destinations (email, Slack,
  etc.).
- Set custom scrape intervals and retention policies as needed to suit your monitoring needs.

---

## 🚨 Alerting

- **Alertmanager** is integrated to handle alerts and notifications for Prometheus metrics.
- Customize alert rules in the `prometheus.prometheusSpec.alerting` section within the `values.yaml` file.

---

## 🧪 Custom Metrics

- Create additional **ServiceMonitor** or **PodMonitor** CRs to scrape custom application metrics from your Kubernetes
  applications.
- Example CRD:
  ```yaml
  apiVersion: monitoring.coreos.com/v1
  kind: ServiceMonitor
  metadata:
    name: custom-monitor
  spec:
    selector:
      matchLabels:
        app: my-app
    endpoints:
      - port: http
        interval: 15s
  ```

---

Maintained by **JDW Platform Infra Team** 🚀📊  
