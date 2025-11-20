# 🚀 Argo CD – GitOps for JDW Platform

This folder contains everything you need to bootstrap and configure Argo CD in your MicroK8s or Kubernetes cluster.

---

## 📂 Contents

- **README.md** – This guide
- **argocd-namespace.yaml** – Namespace for Argo CD
- **argocd.yaml** – Core Argo CD installation manifests
- **argocd-application.yaml** – Sample Application resource to deploy your apps
- **argocd-ingress.yaml** – Ingress configuration for external access
- **oci-helm-secret.yaml** – Secret for pulling OCI Helm charts
- **values.yaml** – Helm values (if installing via Helm chart)

---

## 🛠️ Quickstart (MicroK8s)

```shell
microk8s kubectl apply -f argocd-namespace.yaml      # 1️⃣ Create namespace  
microk8s kubectl apply -f argocd.yaml -n argocd      # 2️⃣ Install Argo CD core  
microk8s kubectl apply -f argocd-application.yaml    # 3️⃣ Deploy sample Application  
```

---

## 🐳 Quickstart (Any Kubernetes)

```shell
kubectl create namespace argocd                       # 1️⃣ Namespace  
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml  
                                                     # 2️⃣ Core install  
```

---

## 🔓 Accessing the UI & API

### Service-Type LoadBalancer

```shell
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'
```  

🔗 Then browse to the external IP.

### Ingress

See 👉 https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/

### Port-Forward

```shell
kubectl port-forward svc/argocd-server -n argocd 8080:443  
```  

🎯 Access at <http://localhost:8080>

---

## 🔑 Login via CLI

1. Get the initial admin password:
   ```shell
   argocd admin initial-password -n argocd  
   ```
2. Login:
   ```shell
   argocd login <ARGOCD_SERVER>  
   ```
3. Change your password:
   ```shell
   argocd account update-password  
   ```

---

## ⚙️ Customization

### Exclude/Include Resources

Edit the main config map to tweak resource filtering:

```shell
kubectl edit configmap argocd-cm -n argocd  
```

### OCI Helm Secret

If you need private OCI Helm charts, apply:

```shell
kubectl apply -f oci-helm-secret.yaml -n argocd  
```

### values.yaml

Use when installing Argo CD via Helm:

```shell
helm repo add argo https://argoproj.github.io/argo-helm  
helm install argocd argo/argo-cd -n argocd -f values.yaml  
```

---

Maintained by **JDW Platform Infra Team** 🌐🔧  
