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

# Create databases
CREATE DATABASE jdw_prd;
CREATE DATABASE dbtech_prd;

# Setup roles - dbtech_prd
DO $$
  BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app') THEN
      CREATE ROLE app;
    END IF;
  END
$$;

GRANT USAGE ON SCHEMA public TO app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app;

# Setup roles - jdw_prd
DO $$
  BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app') THEN
      CREATE ROLE app;
    END IF;
  END
$$;

GRANT USAGE ON SCHEMA auth TO app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA auth TO app;
ALTER DEFAULT PRIVILEGES IN SCHEMA auth GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app;
