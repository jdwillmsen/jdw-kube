# 📊 Kube-Prometheus-Stack – JDW Platform Monitoring

This directory contains everything needed to deploy the Prometheus-Grafana monitoring stack on the JDW Platform using
the `kube-prometheus-stack` Helm chart.

---

## 📁 Contents

- **values.yaml**  
  Helm values overrides for the `kube-prometheus-stack` chart (v58.2.1)
- **commands.sh**  
  Helper script for port-forwarding Grafana & Prometheus
- **CRDs**
    - `crd-*.yaml` — CustomResourceDefinitions for AlertmanagerConfigs, PodMonitors, Probes, Prometheuses,
      PrometheusRules, ScrapeConfigs, ServiceMonitors, ThanosRulers
- **Ingress Manifests**
    - `ingress-grafana.yaml` — Expose Grafana UI
    - `ingress-prometheus.yaml` — Expose Prometheus UI
- **prometheusrule.yaml**  
  Sample cluster-wide alerting rules

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

3. **Install CRDs**
   ```bash
   kubectl apply -f crd-alertmanagers.yaml \
                 -f crd-servicemonitors.yaml \
                 -f crd-podmonitors.yaml \
                 -f crd-prometheusrules.yaml \
                 -f crd-thanosrulers.yaml \
                 -f crd-prometheuses.yaml \
                 -f crd-scrapeconfigs.yaml \
                 -f crd-probes.yaml \
                 -f crd-alertmanagerconfigs.yaml \
                 -f crd-prometheusagents.yaml
   ```

4. **Deploy the stack**
   ```bash
   helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
     --namespace monitoring \
     --version 58.2.1 \
     -f values.yaml
   ```

5. **Apply Ingress**
   ```bash
   kubectl apply -f ingress-grafana.yaml -n monitoring
   kubectl apply -f ingress-prometheus.yaml -n monitoring
   ```

---

## 🔧 Usage

- **Port-forward** (via `commands.sh`):
  ```bash
  ./commands.sh port-forward
  # Grafana → http://localhost:3000
  # Prometheus → http://localhost:9090
  ```
- **Access Ingress**:
    - Grafana at `grafana.<your-domain>`
    - Prometheus at `prometheus.<your-domain>`

---

## ⚙️ values.yaml Highlights

| Key                                       | Description                                         |
|-------------------------------------------|-----------------------------------------------------|
| `prometheus.prometheusSpec.replicas`      | Number of Prometheus server replicas                |
| `alertmanager.alertmanagerSpec.replicas`  | Number of Alertmanager replicas                     |
| `grafana.enabled`                         | Enable Grafana deployment                           |
| `grafana.adminUser`                       | Grafana admin username                              |
| `grafana.adminPassword`                   | Grafana admin password (secret)                     |
| `serviceMonitor.interval`                 | Default scrape interval for ServiceMonitors         |
| `resources.requests`                      | CPU & memory for Prometheus, Alertmanager & Grafana |
| `thanos.ruler.enabled`                    | Enable Thanos Ruler for long-term storage           |
| `prometheusOperator.createCustomResource` | Install all required CRDs                           |

---

## 🧪 Custom Alerts & Metrics

- **prometheusrule.yaml** defines cluster-wide alerts (e.g., instance down, high CPU).
  ```bash
  kubectl apply -f prometheusrule.yaml -n monitoring
  ```
- Create additional `ServiceMonitor` or `PodMonitor` CRs to scrape custom application metrics.

---

Maintained by **JDW Platform Infra Team** 🚀🔒  
