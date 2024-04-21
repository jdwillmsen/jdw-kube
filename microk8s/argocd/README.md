# [Argo CD](https://argo-cd.readthedocs.io/en/stable/getting_started/)

## Setup within Microk8s cluster
```shell
microk8s kubectl apply -f argocd-namespace.yaml
microk8s kubectl apply -f argocd.yaml -n argocd
microk8s kubectl apply -f argocd-application.yaml
```

## Setup Within Kubernetes Cluster
Run the following command
```shell
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

This will first create the ArgoCD namespace and then all the ArgoCD resources.

## Accessing the Argo CD API Server
Service Type Load Balancer
```shell
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'
```

Ingress
https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/

Port Forwarding
```shell
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

## Login Using the CLI
Retrieve initial password.
```shell
argocd admin initial-password -n argocd
```
```shell
argocd login <ARGOCD_SERVER>
```
```shell
argocd account update-password
```
