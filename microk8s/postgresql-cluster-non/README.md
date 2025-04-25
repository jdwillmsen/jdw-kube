# 🐘 PostgreSQL Cluster (Non-Prod) – JDW Platform

This directory configures a non-production (dev/uat) PostgreSQL cluster using the CloudNativePG Operator. It includes
schema bootstrapping via AtlasConfigMaps and test manifests.

---

## 📁 Contents

- **values.yaml**  
  Helm values for the CloudNativePG “cluster” chart (v0.0.8)
- **atlas-schema-*.yaml**  
  ConfigMaps containing Atlas schema definitions for various environments (dev, uat, dbtech)
- **commands.sh**  
  Helper scripts (e.g. connect, port-forward)
- **test/**
    - `dbui.yaml` – Adminer test UI
    - `postgres-ingress.yaml` – Ingress for test access
    - `postgres-storage-class.yaml` – StorageClass for dynamic PVCs
    - `push-secret.yaml` – Sample secret for image registry
    - `vault-secretstore.yaml` – Vault SecretStore for database credentials

---

## 🚀 Installation

1. **Add Helm repo**
   ```bash
   helm repo add cloudnative-pg https://cloudnative-pg.github.io/charts
   helm repo update
   ```

2. **Create namespace**
   ```bash
   kubectl create namespace database
   ```

3. **Deploy Atlas schema ConfigMaps**
   ```bash
   kubectl apply -f atlas-schema-configmap.yaml
   kubectl apply -f atlas-schema-dbtech-dev.yaml
   ```

4. **Install PostgreSQL cluster**
   ```bash
   helm upgrade --install postgresql-cluster-non cloudnative-pg/cluster \
     -n database \
     --version 0.0.8 \
     -f values.yaml
   ```

---

## ⚙️ values.yaml Highlights

| Key                    | Description                                      |
|------------------------|--------------------------------------------------|
| `instances`            | Number of Postgres instances (standby + primary) |
| `storage.size`         | PVC size per instance (e.g. `10Gi`)              |
| `storage.storageClass` | StorageClass for PVCs (e.g. `openebs-hostpath`)  |
| `postgresql.version`   | Postgres major version (e.g. `15`)               |
| `backup.schedule`      | Cron schedule for automated backups              |
| `backup.pvc.size`      | PVC size for backups                             |
| `resources.requests`   | CPU/memory for Postgres pods                     |
| `service.type`         | Service type (ClusterIP / LoadBalancer)          |

---

## 🛠️ Testing

In the `test/` folder:

1. **Deploy test StorageClass & SecretStore**
   ```bash
   kubectl apply -f test/postgres-storage-class.yaml
   kubectl apply -f test/vault-secretstore.yaml
   ```

2. **Deploy test DB UI**
   ```bash
   kubectl apply -f test/dbui.yaml
   ```

3. **Expose Postgres**
   ```bash
   kubectl apply -f test/postgres-ingress.yaml
   ```

4. **Connect via psql**
   ```bash
   ./commands.sh psql
   ```

---

Maintained by **JDW Platform Infra Team** 🚀🔒  
