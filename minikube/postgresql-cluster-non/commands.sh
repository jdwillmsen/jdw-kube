# Get service account password
kubectl get secret -n database postgresql-cluster-non-app -o jsonpath='{.data.password}' | base64 --decode
# Default username: app
# Default database: app
# Service: postgresql-cluster-non-rw.database.svc
