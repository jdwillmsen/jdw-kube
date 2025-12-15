# 🚀 Argo CD – GitOps for JDW Platform (Talos Edition)

This folder contains everything needed to bootstrap and configure **Argo CD** on a **Talos Linux** Kubernetes cluster.

Talos is an immutable, API-driven OS, so some installation steps differ from traditional Linux distros.

---

## 📂 Contents

- **README.md** – This guide
- **argocd-namespace.yaml** – Namespace for Argo CD
- **argocd.yaml** – Core Argo CD installation manifests
- **argocd-application.yaml** – Sample Application resource
- **argocd-ingress.yaml** – Ingress configuration
- **oci-helm-secret.yaml** – Secret for pulling OCI Helm charts
- **values.yaml** – Helm values (if installing via Helm chart)

---

## 🛠️ Quickstart on Talos

### 1️⃣ Get Your Cluster Kubeconfig
Talos does not use kubeconfig files by default — you generate one:

```shell
talosctl kubeconfig .
export KUBECONFIG=./kubeconfig
```

---

### 2️⃣ Apply Argo CD Core Manifests

```shell
kubectl apply -f argocd-namespace.yaml
kubectl apply -n argocd -f argocd.yaml
```

---

### 3️⃣ Deploy Sample Application

```shell
kubectl apply -f argocd-application.yaml
```

---

## 🐳 Installing Argo CD on Any Talos-based Kubernetes Cluster

Alternatively, install the official manifests:

```shell
kubectl create namespace argocd
kubectl apply -n argocd \
-f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

---

## 🔓 Accessing the UI & API

Talos doesn't use kube-proxy or traditional OS networking — but services work normally once deployed.

### Option A: LoadBalancer (preferred with Cilium or MetalLB)

If your Talos cluster uses **MetalLB**:

```shell
kubectl patch svc argocd-server -n argocd \
-p '{"spec": {"type": "LoadBalancer"}}'
```

Browse to the IP assigned by MetalLB.

---

### Option B: Ingress

If using an Ingress Controller (Traefik, NGINX, or Cilium Ingress):

```shell
kubectl apply -f argocd-ingress.yaml
```

Reference: https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/

---

### Option C: Talos Port Forwarding

```shell
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Access at:  
👉 http://localhost:8080

---

## 🔑 Logging In (CLI or UI)

### 1️⃣ Get Initial Admin Password

```shell
kubectl get secret argocd-initial-admin-secret -n argocd \
-o jsonpath="{.data.password}" | base64 -d
```

or:

```shell
argocd admin initial-password -n argocd
```

---

### 2️⃣ Login to Argo CD

```shell
argocd login <ARGOCD_SERVER>
```

---

### 3️⃣ Change Password

```shell
argocd account update-password
```

---

## ⚙️ Customization

### Exclusion/Filtering of Resources

```shell
kubectl edit configmap argocd-cm -n argocd
```

---

### OCI Helm Secrets

```shell
kubectl apply -f oci-helm-secret.yaml -n argocd
```

---

## 📦 Installing Argo CD via Helm (Optional)

Talos supports Helm normally once the cluster is up.

```shell
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd \
-n argocd \
-f values.yaml
```

---

## 🛡️ Notes for Talos Users

- Talos nodes are immutable; **do not SSH** — use `talosctl`.
- Kubernetes networking depends on your CNI (Cilium, Flannel, etc.).
- For TLS, certificates, or ingress controllers, configure them in the cluster config or via Kubernetes objects.
- GitOps is ideal for Talos — consider managing Argo CD **via MachineConfig patches** in the future.

---

## ♻️ Resetting Admin Password

```bash
kubectl -n argocd patch secret argocd-secret -p '{"data": {"admin.password": null, "admin.passwordMtime": null}}'
kubectl delete pods -n argocd -l app.kubernetes.io/name=argocd-server
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

---

## Updating Default Admin Password

```bash
export ARGOCD_SERVER=argocd.jdwkube.com
export NEW_PASSWORD=$ARGOCD_PASSWORD
export ARGOCD_INITIAL_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d) && \
argocd login $ARGOCD_SERVER --username admin --password $ARGOCD_INITIAL_PASSWORD --insecure && \
argocd account update-password --account admin --current-password $ARGOCD_INITIAL_PASSWORD --new-password $NEW_PASSWORD && \
unset ARGOCD_INITIAL_PASSWORD
unset ARGOCD_SERVER
unset NEW_PASSWORD
```

---

Maintained by **JDW Platform Infra Team** 🌐🔧
