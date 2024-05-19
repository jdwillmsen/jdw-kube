# Start Minikube - 5 Node
minikube start \
  --driver=hyperv \
  --profile=jdw-cluster \
  --addons=default-storageclass,ingress,ingress-dns \
  --nodes=5
# --driver (options) | docker, ssh, hyperv

# Start Minikube - 1 Node Extra Memory + CPU
minikube start \
  --driver=hyperv \
  --profile=jdw-cluster \
  --addons=default-storageclass,ingress,ingress-dns \
  --nodes=1 \
  --memory=6000mb \
  --cpus=4

# Start Minikube DA - 1 Node Extra Memory + CPU
minikube start \
  --driver=hyperv \
  --profile=jdw-cluster-da \
  --addons=default-storageclass,ingress,ingress-dns \
  --nodes=1 \
  --memory=6000mb \
  --cpus=4

# Status Minikube
minikube status \
  --profile=jdw-cluster

# Restart Minikube
minikube start \
  --profile=jdw-cluster

# Enable Minikube Add Ons
minikube --profile=jdw-cluster addons enable ingress
minikube --profile=jdw-cluster addons enable ingress-dns
minikube --profile=jdw-cluster addons enable default-storageclass

# Get Minikube IP
minikube --profile=jdw-cluster ip

# Powershell admin
Add-DnsClientNrptRule -Namespace ".jdw.com" -NameServers "$(minikube -p jdw-cluster ip)"
Get-DnsClientNrptRule | Where-Object {$_.Namespace -eq '.jdw.com'} | Remove-DnsClientNrptRule -Force; Add-DnsClientNrptRule -Namespace ".test" -NameServers "$(minikube -p jdw-cluster ip)"

# Setup ArgoCD
kubectl apply -f argocd/argocd-namespace.yaml && \
kubectl apply -f argocd/argocd.yaml -n argocd && \
kubectl apply -f argocd/argocd-application.yaml

export ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d) && \
echo "${ARGOCD_PASSWORD}"

# Apply bootstrap config - All other apps/infrastructure
kubectl apply -f bootstrap.yaml
