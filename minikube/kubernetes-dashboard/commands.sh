# Generate access token
kubectl create token dashboard-admin-sa --duration 525600m -n kubernetes-dashboard
