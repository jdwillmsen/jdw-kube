# Prod
# Get service account password
kubectl get secret -n database postgresql-cluster-prd-app -o jsonpath='{.data.password}' | base64 --decode
# Default username: app
# Default database: app
# Service: postgresql-cluster-prd-rw.database.svc
# Get superuser account password
kubectl get secret -n database postgresql-cluster-prd-superuser -o jsonpath='{.data.password}' | base64 --decode
# Default username: postgres
# Default database: * - Can leave empty
# Service: postgresql-cluster-prd-rw.database.svc
# Create jdw database
CREATE DATABASE jdw_prd;

# Non
# Get service account password
kubectl get secret -n database postgresql-cluster-non-app -o jsonpath='{.data.password}' | base64 --decode
# Default username: app
# Default database: app
# Service: postgresql-cluster-non-rw.database.svc
# Get superuser account password
kubectl get secret -n database postgresql-cluster-non-superuser -o jsonpath='{.data.password}' | base64 --decode
# Default username: postgres
# Default database: * - Can leave empty
# Service: postgresql-cluster-non-rw.database.svc
# Create jdw database
CREATE DATABASE jdw_dev;
CREATE DATABASE jdw_uat;