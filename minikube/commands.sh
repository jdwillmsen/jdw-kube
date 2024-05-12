# Start Minikube
minikube start \
  --driver=hyperv \
  --profile=jdw-cluster \
  --addons=default-storageclass,ingress,ingress-dns \
  --nodes=5
# --driver (options) | docker, ssh, hyperv

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

# Powershell admin
Add-DnsClientNrptRule -Namespace ".jdw.com" -NameServers "$(minikube -p jdw-cluster ip)"
Get-DnsClientNrptRule | Where-Object {$_.Namespace -eq '.jdw.com'} | Remove-DnsClientNrptRule -Force; Add-DnsClientNrptRule -Namespace ".test" -NameServers "$(minikube -p jdw-cluster ip)"

kubectl apply -f argocd/argocd-namespace.yaml && \
kubectl apply -f argocd/argocd.yaml -n argocd && \
kubectl apply -f argocd/argocd-application.yaml

export ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d) && \
echo "${ARGOCD_PASSWORD}"