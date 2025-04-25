# 🌐 CloudNative PG Operator – JDW Platform

This directory contains manifests and Helm values for deploying the CloudNative PostgreSQL Operator (cloudnative-pg) on
the JDW Platform. The operator manages production-grade PostgreSQL clusters via Kubernetes Custom Resources.

---

## 📁 Contents

- **crd.yaml**  
  CustomResourceDefinition for the CloudNativePG `Cluster` resource.
- **values.yaml**  
  Helm values override for the `cloudnative-pg` chart (v0.20.2).

---

## 🔍 What Is CloudNative PG?

The CloudNative PostgreSQL Operator automates provisioning, scaling, backup, and recovery of Postgres clusters in
Kubernetes. It exposes a `Cluster` CRD to define your database topology, high-availability, and storage.

---

## 🚀 Installation via Helm

1. **Add the Helm repo**
   ```bash
   helm repo add cloudnative-pg https://cloudnative-pg.github.io/charts
   helm repo update
   ```
2. **Create namespace**
   ```bash
   kubectl create namespace cnpg-system
   ```
3. **Install CRD**
   ```bash
   kubectl apply -f crd.yaml
   ```
4. **Deploy the operator**
   ```bash
   helm upgrade --install cloudnative-operator cloudnative-pg/cloudnative-pg \
     -n cnpg-system \
     -f values.yaml
   ```

---

## ⚙️ values.yaml Highlights

| Key                       | Description                                     |
|---------------------------|-------------------------------------------------|
| `image.tag`               | Operator controller image tag                   |
| `replicaCount`            | Number of operator replicas for HA              |
| `resources.requests`      | CPU & memory for operator pods                  |
| `backup.schedule`         | Cron schedule for automated backups             |
| `backup.persistentVolume` | PVC settings for backup storage                 |
| `postgresql.resources`    | Default resource requests for Postgres clusters |

---

## 📝 Defining a PostgreSQL Cluster

After installation, create a `Cluster` CR:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: my-db-cluster
  namespace: cnpg-system
spec:
  instances: 3
  storage:
    size: 10Gi
    storageClass: openebs-hostpath
  backup:
    schedule: "@every 1h"
  postgresql:
    version: "15"
```

```bash
kubectl apply -f my-db-cluster.yaml
```

---

## 🧪 Validation

- Check operator pods:
  ```bash
  kubectl get pods -n cnpg-system -l app=cloudnative-pg
  ```
- Inspect Cluster status:
  ```bash
  kubectl describe cluster my-db-cluster -n cnpg-system
  ```

---

Maintained by **JDW Platform Infra Team** 🚀🔒  
