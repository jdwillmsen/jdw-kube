# 🐘 PostgreSQL Cluster (Prod) – JDW Platform

This directory provisions the production PostgreSQL cluster for the JDW Platform using
the [CloudNativePG](https://cloudnative-pg.io/) Helm chart. It includes schema bootstrapping using Atlas ConfigMaps and
test manifests for validation.

---

## 📁 Directory Structure

- **values.yaml**  
  Helm values for the production-grade PostgreSQL deployment.
- **atlas-schema-*.yaml**  
  ConfigMaps defining database schemas using [Atlas](https://atlasgo.io/) for different production environments.
- **commands.sh**  
  Handy CLI scripts (e.g., `psql` connect, backups).
- **test/dbui.yaml**  
  Temporary Adminer UI deployment for read-only inspection.

---

## 🚀 Deployment Steps

### 1. Add the Helm Repo

```bash
helm repo add cloudnative-pg https://cloudnative-pg.github.io/charts
helm repo update
```

### 2. Create the Namespace

```bash
kubectl create namespace database
```

### 3. Apply Atlas Schema ConfigMaps

```bash
kubectl apply -f atlas-schema-configmap-jdw.yaml
kubectl apply -f atlas-schema-prd.yaml
kubectl apply -f atlas-schema-dbtech.yaml
kubectl apply -f atlas-schema-dbtech-prd.yaml
```

### 4. Install the Cluster

```bash
helm upgrade --install postgresql-cluster-prd cloudnative-pg/cluster \
  -n database \
  --version 0.0.8 \
  -f values.yaml
```

---

## ⚙️ Helm Values Overview

| Key                  | Description                             |
|----------------------|-----------------------------------------|
| `replicaCount`       | Number of PostgreSQL instances          |
| `storage.size`       | Volume size per instance (e.g., `50Gi`) |
| `postgresql.version` | Target PostgreSQL version (e.g., `15`)  |
| `resources`          | CPU & memory requests/limits            |
| `tls.enabled`        | Enforce TLS encryption                  |
| `backups.enabled`    | Backup config with storage integration  |
| `monitoring.enabled` | Enable metrics via Prometheus exporters |

---

## 🧪 Optional Test UI

Use Adminer to verify production schema (read-only access recommended):

```bash
kubectl apply -f test/dbui.yaml
```

Then port-forward or expose via Ingress to access the web UI.

---

## 🔒 Security Notes

- **Schema Management:** Uses Atlas for declarative schema versioning.
- **Access:** Use Vault or sealed secrets for DB credentials.
- **Monitoring:** Integrate with Prometheus via `kube-prometheus-stack`.

---

Maintained by **JDW Platform Infra Team** ☁️🛡️  
For issues, please open a ticket or ping in `#platform-infra`.
