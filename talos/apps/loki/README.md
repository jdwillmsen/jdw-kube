# 📜 Loki – JDW Platform Logging

This directory contains everything needed to deploy the Loki logging stack on the JDW Platform using
the [`grafana/loki`](https://artifacthub.io/packages/helm/grafana/loki) Helm chart.

---

## 📁 Contents

- **values.yaml**  
  Helm values overrides for the `loki` chart (v5.43.3)
- **Ingress Manifest**
    - `ingress-loki.yaml` — Expose Loki HTTP API
- **commands.sh**  
  Helper script for port-forwarding Loki

---

## 🚀 Installation via Helm

1. **Add Helm repo**
   ```bash
   helm repo add grafana https://grafana.github.io/helm-charts
   helm repo update
   ```

2. **Create namespace**
   ```bash
   kubectl create namespace logging
   ```

3. **Deploy Loki**
   ```bash
   helm upgrade --install loki grafana/loki \
     --namespace logging \
     --version 5.43.3 \
     -f values.yaml
   ```

4. **Apply Ingress**
   ```bash
   kubectl apply -f ingress-loki.yaml -n logging
   ```

---

## 🔧 Usage

- **Port-forward** (via `commands.sh`):
  ```bash
  ./commands.sh port-forward
  # Loki API → http://localhost:3100
  ```
- **Access Ingress**:
    - Loki at `loki.<your-domain>`

---

## ⚙️ values.yaml Highlights

| Key                         | Description                                  |
|------------------------------|----------------------------------------------|
| `loki.config.schema_config`  | Schema configuration for indexing           |
| `loki.config.storage_config` | Backend storage settings (e.g., S3, filesystem) |
| `loki.auth_enabled`          | Enable/disable authentication               |
| `loki.ingester.lifecycle_stage` | Control ingester write/read mode         |
| `resources.requests`         | CPU & memory requests for Loki              |
| `service.type`               | Service type (e.g., ClusterIP, LoadBalancer) |

---

## 📥 Log Collection Setup

- Configure your log collectors (e.g., **Promtail**, **Fluent Bit**) to push logs to Loki.
- Example target:
  ```
  http://loki.logging.svc.cluster.local:3100/loki/api/v1/push
  ```

---

Maintained by **JDW Platform Infra Team** 🚀📜  
