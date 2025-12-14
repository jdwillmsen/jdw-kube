# 🏃 ARC Runner Set 2 – JDW Platform Custom Agents

This folder contains the configuration for **ARC Runner Set 2**, providing custom self-hosted GitHub Actions runners for the JDW Platform. It builds on the default settings but injects a JDW-specific agent image and environment.

---

## 📋 Configuration

```yaml
# GitHub URL where runners will register
githubConfigUrl: "https://github.com/jdwillmsen/jdw"

# Kubernetes secret holding your GitHub App or PAT credentials
githubConfigSecret: jdwillmsen-github-app

# How many runner pods to scale between
maxRunners: 5
minRunners: 1

# Name of this runner scale set
runnerScaleSetName: "ubuntu-jdw-custom"

# Container mode: use Kubernetes pods for each job
containerMode:
  type: "kubernetes"
  kubernetesModeWorkVolumeClaim:
    accessModes: ["ReadWriteOnce"]
    storageClassName: "openebs-loki-localpv"
    resources:
      requests:
        storage: 8Gi

# Runner pod spec overrides with custom JDW agent image & env
template:
  spec:
    containers:
      - name: runner
        image: ghcr.io/jdwillmsen/jdw-agent:latest
        command: ["/home/runner/run.sh"]
        env:
          - name: ACTIONS_RUNNER_REQUIRE_JOB_CONTAINER
            value: "true"
          - name: JDW_ENV
            value: "platform"
          - name: JDW_CUSTOM_AGENT
            value: "enabled"
        volumeMounts:
          - name: work
            mountPath: /home/runner/_work
    volumes:
      - name: work
        emptyDir: {}

# (Optional) service account for the ARC controller
controllerServiceAccount:
  namespace: arc-system
  name: gha-rs-controller
```

---

## 🚀 Usage

1. **Install or upgrade** Runner Set 2 via Helm or ArgoCD:
   ```bash
   helm upgrade --install arc-runner-set-2 oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
     -n arc-runners \
     -f arc-runner-set-2-values.yaml
   ```
2. **Confirm** runners appear in your GitHub organization under **Settings → Actions → Runners**.

---

## 🔒 Security

- Credentials are stored securely in the `jdwillmsen-github-app` Kubernetes secret.
- The custom agent image does not expose any sensitive data.

---

## 🧪 Testing & Monitoring

- List pods:
  ```bash
  kubectl get pods -n arc-runners -l actions.github.com/scale-set-name=ubuntu-jdw-custom
  ```
- Tail logs:
  ```bash
  kubectl logs -f <runner-pod> -n arc-runners
  ```
- Verify custom env vars inside a runner pod:
  ```bash
  kubectl exec -it <runner-pod> -n arc-runners -- env | grep JDW_
  ```

---

Maintained by the **JDW Platform Infra Team** 🚧✨  
