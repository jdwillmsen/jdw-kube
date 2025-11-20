# 💾 OpenEBS – JDW Platform Dynamic Storage

This directory contains the Helm values overrides to deploy the OpenEBS Container Attached Storage (CAS) operator on the JDW Platform. OpenEBS provides dynamic, container-native block storage for stateful workloads.

---

## 📁 Contents

- **values.yaml**  
  Custom Helm values for the OpenEBS chart (v4.2.0).

---

## 🚀 Installation via Helm

1. **Add the OpenEBS repo**
   ```bash
   helm repo add openebs https://openebs.github.io/openebs
   helm repo update
   ```

2. **Create namespace**
   ```bash
   kubectl create namespace openebs
   ```

3. **Deploy OpenEBS**
   ```bash
   helm upgrade --install openebs openebs/openebs \
     --namespace openebs \
     --version 4.2.0 \
     -f values.yaml
   ```

---

## ⚙️ values.yaml Highlights

| Key                           | Description                                            |
|-------------------------------|--------------------------------------------------------|
| `openebsOperator.image.tag`   | OpenEBS operator container image tag                   |
| `ndm.enabled`                 | Enable Node Disk Manager for disk discovery            |
| `cstor.enabled`               | Enable cStor storage engine                            |
| `jiva.enabled`                | Enable Jiva storage engine (if required)               |
| `pool.provisioner`            | Type of storage pool (e.g. `cstor`, `jiva`, `local`)   |
| `persistence.storageClass`    | StorageClass name for backing volumes                  |
| `persistence.capacity`        | Default volume size for dynamic provisioning           |
| `resources.requests`          | CPU & memory for OpenEBS operator pods                 |
| `securityContext`             | Pod security settings (runAsUser, fsGroup, etc.)       |

---

## 🛠️ Usage

- **Create a StorageClass** (if not using default):
  ```yaml
  apiVersion: storage.k8s.io/v1
  kind: StorageClass
  metadata:
    name: openebs-cstor
  provisioner: openebs.io/provisioner-iscsi
  parameters:
    pool: cstor-pool
  ```
  ```bash
  kubectl apply -f openebs-storageclass.yaml
  ```

- **Deploy a PVC** using the OpenEBS StorageClass:
  ```yaml
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: demo-pvc
  spec:
    accessModes:
      - ReadWriteOnce
    storageClassName: openebs-cstor
    resources:
      requests:
        storage: 10Gi
  ```
  ```bash
  kubectl apply -f demo-pvc.yaml
  ```

- **Verify** volume creation and binding:
  ```bash
  kubectl get cspc,cvr,pvc,pv -n openebs
  ```

---

Maintained by **JDW Platform Infra Team** 🛡️✨  
