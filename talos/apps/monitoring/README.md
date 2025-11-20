# 📊 K8s Monitoring – JDW Platform Observability

This directory contains everything needed to deploy **K8s Monitoring** for Kubernetes clusters on the JDW Platform using
the [`grafana/k8s-monitoring`](https://artifacthub.io/packages/helm/grafana/k8s-monitoring) Helm chart.

---

## 📁 Contents

- **values.yaml**  
  Helm values overrides for the `k8s-monitoring` chart (v0.5.0)
- **Ingress Manifest**
    - `ingress-k8s-monitoring.yaml` — Expose K8s Monitoring UI
- **commands.sh**  
  Helper script for port-forwarding K8s Monitoring

---

## 🚀 Installation via Helm

1. **Add Helm repo**
   ```bash
   helm repo add grafana https://grafana.github.io/helm-charts
   helm repo update
   ```

2. **Create namespace**
   ```bash
   kubectl create namespace monitoring
   ```

3. **Deploy K8s Monitoring**
   ```bash
   helm upgrade --install k8s-monitoring grafana/k8s-monitoring \
     --namespace monitoring \
     --version 0.5.0 \
     -f values.yaml
   ```

4. **Apply Ingress**
   ```bash
   kubectl apply -f ingress-k8s-monitoring.yaml -n monitoring
   ```

---

## 🔧 Usage

- **Port-forward** (via `commands.sh`):
  ```bash
  ./commands.sh port-forward
  # K8s Monitoring UI → http://localhost:3000
  ```
- **Access Ingress**:
    - K8s Monitoring at `k8s-monitoring.<your-domain>`

---

## ⚙️ values.yaml Highlights

| Key                             | Description                                         |
|---------------------------------|-----------------------------------------------------|
| `prometheus.enabled`            | Enable/disable Prometheus deployment                |
| `prometheus.resources.requests` | CPU & memory requests for Prometheus                |
| `grafana.enabled`               | Enable/disable Grafana deployment                   |
| `grafana.adminPassword`         | Grafana admin password (secret)                     |
| `serviceMonitor.enabled`        | Enable/disable ServiceMonitor for scraping          |
| `alertmanager.enabled`          | Enable/disable Alertmanager                         |
| `resources.requests`            | CPU & memory for Prometheus, Grafana & Alertmanager |

---

## 📅 Monitoring Setup

- This setup integrates **Prometheus**, **Grafana**, and **Alertmanager** for comprehensive Kubernetes cluster
  monitoring.
- Customize the scraping intervals, retention policies, and alerting configurations based on your cluster's needs.
- **ServiceMonitors** are enabled by default to scrape relevant metrics from various Kubernetes components.

---

## 🚨 Alerting

- **Alertmanager** configuration can be customized via the `values.yaml` to route alerts based on severity, and
  notifications can be sent to email, Slack, or other destinations.
- Create custom alert rules as needed to monitor the health and performance of your cluster.

---

Maintained by **JDW Platform Infra Team** 🚀📊  
