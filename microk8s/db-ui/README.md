# 🗄️ DB-UI – Adminer for JDW Platform

This directory contains the configuration to deploy **Adminer** (a lightweight database UI) as the DB-UI component of
the JDW Platform.

---

## 📁 Contents

- **values.yaml**  
  Helm values overrides for the Adminer chart (v0.2.1)
- **ingress.yaml**  
  Ingress manifest to expose Adminer UI
- **commands.sh**  
  Helper script for port-forwarding or quick tests
- **test/**
    - `deployment.yaml` & `service.yaml` for local test deployments

---

## 🚀 Installation via Helm

1. **Add the Helm repo**
   ```bash
   helm repo add cetic https://cetic.github.io/helm-charts
   helm repo update
   ```

2. **Create namespace**
   ```bash
   kubectl create namespace database
   ```

3. **Deploy Adminer**
   ```bash
   helm upgrade --install db-ui cetic/adminer \
     -n database \
     -f values.yaml
   ```

4. **Apply Ingress**
   ```bash
   kubectl apply -f ingress.yaml -n database
   ```

---

## 🔧 Usage

- **Port-forward** (via `commands.sh`):
  ```bash
  ./commands.sh port-forward
  # Then browse to http://localhost:8080
  ```

- **Test Deployment** (in `test/`):
  ```bash
  kubectl apply -f test/deployment.yaml -n database
  kubectl apply -f test/service.yaml -n database
  ```

---

## ⚙️ values.yaml Highlights

| Key                  | Description                         |
|----------------------|-------------------------------------|
| `adminer.image.tag`  | Adminer container image tag         |
| `service.type`       | Kubernetes Service type (ClusterIP) |
| `ingress.enabled`    | Enable Ingress for external access  |
| `ingress.hosts[0]`   | Hostname for Adminer UI             |
| `resources.requests` | CPU & memory for Adminer pod        |

---

Maintained by **JDW Platform Infra Team** 🛠️📊  
