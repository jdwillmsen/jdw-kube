# Start Minikube
minikube start \
  --profile=jdw-cluster \
  --addons=default-storageclass,ingress,ingress-dns \
  --nodes=5

kubectl apply -f argocd/argocd-namespace.yaml && \
kubectl apply -f argocd/argocd.yaml -n argocd && \
kubectl apply -f argocd/argocd-application.yaml

export ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d) && \
echo "${ARGOCD_PASSWORD}"