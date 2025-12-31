# 🐮 Longhorn – JDW Platform Distributed Storage

This directory contains the Helm values overrides to deploy **Longhorn**, a cloud-native distributed block storage system, on the **JDW Platform**. Longhorn provides reliable, replicated storage for stateful workloads running in Kubernetes.

---

## 📁 Contents

- **values.yaml**  
  Custom Helm values for the Longhorn chart (v1.6.x).

---

## 🚀 Installation via Helm

1. **Add the Longhorn repo**
   ```bash
   helm repo add longhorn https://charts.longhorn.io
   helm repo update
   ```

2. **Create namespace**
   ```bash
   kubectl create namespace longhorn-system
   ```

3. **Deploy Longhorn**
   ```bash
   helm upgrade --install longhorn longhorn/longhorn \\
   --namespace longhorn-system \\
   --version 1.6.2 \\
   -f values.yaml
   ```

---

## ⚙️ values.yaml Highlights

| Key | Description |
|-----|-------------|
| `longhornManager.image.tag` | Longhorn manager container image tag |
| `longhornDriver.image.tag` | CSI driver image tag |
| `defaultSettings.replicaCount` | Default number of volume replicas |
| `defaultSettings.defaultDataPath` | Host path used for Longhorn data storage |
| `defaultSettings.storageOverProvisioningPercentage` | Allowed over-provisioning (%) |
| `defaultSettings.defaultReplicaAutoBalance` | Automatic replica rebalancing mode |
| `persistence.defaultClass` | Whether Longhorn is the default StorageClass |
| `persistence.defaultFsType` | Default filesystem for volumes (e.g. `ext4`, `xfs`) |
| `resources.requests` | CPU & memory requests for Longhorn components |
| `tolerations` | Node tolerations for storage scheduling |
| `nodeSelector` | Restrict Longhorn pods to storage-capable nodes |

---

## 🛠️ Usage

### 📦 StorageClass

Longhorn installs a default StorageClass automatically (if enabled in `values.yaml`):

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
name: longhorn
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
```

---

### 📄 PersistentVolumeClaim

Deploy a PVC using the Longhorn StorageClass:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
name: demo-pvc
spec:
accessModes:
- ReadWriteOnce
storageClassName: longhorn
resources:
requests:
storage: 10Gi
```

```bash
kubectl apply -f demo-pvc.yaml
```

---

### 🔍 Verification

Check volume and replica status:

```bash
kubectl get pvc,pv
kubectl get volumes.longhorn.io -n longhorn-system
kubectl get nodes.longhorn.io -n longhorn-system
```

Access the Longhorn UI (via port-forward or ingress):

```bash
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
```

Then open:  
👉 http://localhost:8080

---

## ⚠️ Platform Notes

- Ensure **dedicated disks or partitions** are used for Longhorn data paths
- Avoid using OS/root disks for production replicas
- Replica count should match failure domain requirements (typically `3`)
- Works well with:
    - CloudNativePG
    - Prometheus / Thanos
    - Loki
    - Application databases (Postgres, MySQL, Redis)

---

Maintained by **JDW Platform Infra Team** 🛡️✨
