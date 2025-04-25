# 🏃 ARC Runner Set 1 – Self-Hosted JDW Platform

This folder contains the basic, mostly–default configuration for a self-hosted GitHub Actions Runner Controller (ARC)
scale-set on the JDW Platform.

---

## 📋 Configuration

```yaml
# GitHub URL where runners will register
githubConfigUrl: "https://github.com/jdwillmsen/jdw"

# Kubernetes secret holding your GitHub App or PAT credentials
githubConfigSecret: jdwillmsen-github-app

# How many runner pods to scale between
maxRunners: 10
minRunners: 0

# Name of this runner scale set
runnerScaleSetName: "ubuntu"

# Container mode: use Kubernetes pods for each job
containerMode:
  type: "kubernetes"
  kubernetesModeWorkVolumeClaim:
    accessModes: [ "ReadWriteOnce" ]
    storageClassName: "openebs-hostpath"
    resources:
      requests:
        storage: 4Gi

# Runner pod spec overrides
template:
  spec:
    containers:
      - name: runner
        image: ghcr.io/actions/actions-runner:2.323.0
        command: [ "/home/runner/run.sh" ]
        env:
          - name: ACTIONS_RUNNER_REQUIRE_JOB_CONTAINER
            value: "false"

# (Optional) service account for the ARC controller
controllerServiceAccount:
  namespace: arc-system
  name: gha-rs-controller
```

---

## 🚀 Usage

1. **Install the ARC controller** in your cluster (via Helm/ArgoCD).
2. **Apply this values file** to create Runner Set 1:
   ```bash
   helm upgrade --install arc-runner-set-1 oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
     -n arc-runners \
     -f arc-runner-set-1-values.yaml
   ```
3. **Verify** your runners appear under **Settings → Actions → Runners** in your GitHub org.

---

## 🔒 Security

- All credentials live in the Kubernetes secret `jdwillmsen-github-app`.
- No tokens are stored in plain text in source control.

---

## 🧪 Testing & Troubleshooting

- View runner pods:
  ```bash
  kubectl get pods -n arc-runners -l actions.github.com/scale-set-name=ubuntu
  ```
- Tail logs of a runner pod:
  ```bash
  kubectl logs -f <runner-pod-name> -n arc-runners
  ```
- Check GitHub Actions settings to ensure runners register successfully.

---

Maintained by the **JDW Platform Infra Team** 🚧✨  
