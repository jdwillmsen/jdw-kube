# 🔧 ARC Systems – JDW Platform Runner Infrastructure

This directory contains the configuration and secrets definitions for the GitHub Actions Runner Controller (ARC) “systems” components—managing ExternalSecrets and Vault integration for all runner sets on the JDW Platform.

---

## 📁 What’s Inside

- **externalsecrets.yaml**  
  Kubernetes ExternalSecret CRD that pulls GitHub App credentials (or PAT) from Vault into a k8s Secret.

- **vault-secretstore.yaml**  
  Defines a SecretStore (Vault-backed) for ExternalSecrets to use. Configures connection to HashiCorp Vault.

- **values.yaml**  
  Helm values for the `gha-runner-system` chart, wiring together the SecretStore and ExternalSecret resources.

---

## 🔑 Secret Management Flow

1. **Vault SecretStore**  
   – Configured in `vault-secretstore.yaml`  
   – Points to your Vault server, auth method, and path where GitHub credentials live.

2. **ExternalSecret**  
   – Defined in `externalsecrets.yaml`  
   – References the SecretStore to sync secrets into a Kubernetes Secret named `jdwillmsen-github-app`.

3. **Runner Sets**  
   – All ARC Runner Sets (`arc-runner-set-1`, `arc-runner-set-2`, `arc-runner-set-3`) reference `jdwillmsen-github-app` secret for GitHub authentication.

---

## 🚀 Installation

Apply in this order:

```bash
kubectl apply -f vault-secretstore.yaml    # 1. Vault SecretStore
kubectl apply -f externalsecrets.yaml      # 2. ExternalSecret → creates k8s Secret
helm upgrade --install gha-runner-system oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-system \
  -n arc-systems \
  -f values.yaml                           # 3. Deploy system chart
```

---

## 🔒 Security

- Vault credentials (token or Kubernetes auth) must be pre-configured on the cluster.
- `vault-secretstore.yaml` uses a ServiceAccount with minimal Vault policies.
- No GitHub tokens are stored in plain text—ExternalSecrets sync from Vault only at runtime.

---

## 🧪 Validation & Troubleshooting

- **Check SecretStore**:
  ```bash
  kubectl get secretstore -n arc-systems
  kubectl describe secretstore vault-secretstore -n arc-systems
  ```

- **Verify ExternalSecret**:
  ```bash
  kubectl get externalsecret -n arc-systems
  kubectl describe externalsecret github-app-secret -n arc-systems
  kubectl get secret jdwillmsen-github-app -n arc-systems
  ```

- **Inspect Helm release**:
  ```bash
  helm status gha-runner-system -n arc-systems
  ```

---

Maintained by the **JDW Platform Infra Team** 🚧🔐  
