# 📈 Metrics Server – JDW Platform Resource Metrics

Metrics Server is a scalable, efficient source of container resource metrics for Kubernetes built-in autoscaling
pipelines. It collects CPU & memory usage from Kubelets and exposes them via the Metrics API for use by Horizontal Pod
Autoscaler, Vertical Pod Autoscaler, and `kubectl top` commands.

---

## 📁 Contents

- **values.yaml**  
  Custom overrides for the `metrics-server` Helm chart (v3.12.1).

---

## 🚀 Installation via Helm

1. **Add the Metrics-Server repo**
   ```bash
   helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
   helm repo update
   ```

2. **Create namespace**
   ```bash
   kubectl create namespace metrics-server
   ```

3. **Deploy the chart**
   ```bash
   helm upgrade --install metrics-server metrics-server/metrics-server \
     --namespace metrics-server \
     --version 3.12.1 \
     -f values.yaml
   ```

---

## ⚙️ values.yaml Highlights

| Key                         | Description                                                     |
|-----------------------------|-----------------------------------------------------------------|
| `args`                      | Extra CLI flags (e.g. `--kubelet-insecure-tls` for self-signed) |
| `resources.requests.cpu`    | CPU request per metrics-server pod (default: `100m`)            |
| `resources.requests.memory` | Memory request per pod (default: `200Mi`)                       |
| `tolerations`               | Tolerations to schedule on control-plane or tainted nodes       |
| `securityContext`           | FS group and runAsNonRoot settings for pods                     |

---

## 🧪 Verification

After deployment, confirm pods are running:

```bash
kubectl get pods -n metrics-server
```

Test the Metrics API and HPA:

```bash
kubectl top nodes
kubectl top pods --all-namespaces
```

If you see CPU/memory metrics, the Metrics Server is functioning correctly.

---

Maintained by **JDW Platform Infra Team** 🚀🔒
