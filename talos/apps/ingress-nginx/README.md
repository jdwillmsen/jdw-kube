# 🌐 ingress-nginx – JDW Platform Ingress Controller

This folder holds the Helm values file for deploying the official NGINX Ingress Controller via the `ingress-nginx`
chart (v4.11.3). The chart bootstraps an NGINX-based Kubernetes ingress controller to manage external HTTP/S traffic :
contentReference[oaicite:0]{index=0}.

---

## 📁 Contents

- **values.yaml**  
  Custom overrides for the `ingress-nginx` Helm chart.

---

## 🚀 Installation via Helm

1. **Add the Ingress-NGINX repo**
   ```bash
   helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
   helm repo update
   ```

2. **Create namespace**
   ```bash
   kubectl create namespace ingress-nginx
   ```

3. **Install the chart**
   ```bash
   helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
     --namespace ingress-nginx \
     --version 4.11.3 \
     -f values.yaml
   ```  
   This deploys the NGINX controller Deployment, Service, ConfigMap, RBAC, and CRDs as defined by the chart :
   contentReference[oaicite:1]{index=1}.

---

## ⚙️ values.yaml Highlights

| Key                                        | Description                                      |
|--------------------------------------------|--------------------------------------------------|
| `controller.replicaCount`                  | Number of controller replicas for HA             |
| `controller.image.tag`                     | NGINX Ingress Controller image tag (v1.12.1)     |
| `controller.config.use-forwarded-headers`  | Enable `X-Forwarded-For` header processing       |
| `controller.metrics.enabled`               | Expose Prometheus metrics                        |
| `controller.service.externalTrafficPolicy` | Retain client source IP (`Local` vs `Cluster`)   |
| `controller.resources.requests`            | CPU / memory requests for the controller pod     |
| `tcp` / `udp`                              | Port mappings for TCP/UDP services               |
| `networkPolicy.enabled`                    | Enable NetworkPolicy for ingress controller pods |

Refer to the upstream values reference for full details :contentReference[oaicite:2]{index=2}.

---

## 🔄 SyncWave & PostInstall

In your ApplicationSet:

```yaml
- chart: ingress-nginx
  name: ingress-nginx
  repo: https://kubernetes.github.io/ingress-nginx
  revision: 4.11.3
  namespace: ingress-nginx
  postInstall: false
  syncWave: 1
```

- **postInstall: false** – no extra manifests after chart deploy
- **syncWave: 1** – early in sync order to ensure ingress is available for other apps

---

## 🧪 Testing

1. Create a sample Ingress:
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: test-ingress
     namespace: default
     annotations:
       kubernetes.io/ingress.class: "nginx"
   spec:
     rules:
       - host: example.local
         http:
           paths:
             - path: /
               pathType: Prefix
               backend:
                 service:
                   name: your-service
                   port:
                     number: 80
   ```
2. Apply and verify:
   ```bash
   kubectl apply -f test-ingress.yaml
   kubectl get ingress -n default
   ```

---

Maintained by **JDW Platform Infra Team** 🚧🔒  
