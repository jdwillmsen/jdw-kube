# 🏃 ARC Runner Set 3 - Dotablaze Tech Agents

This folder defines the Kubernetes configuration for **ARC Runner Set 3**, dedicated to handling GitHub Actions
workflows for the **Dotablaze Tech** technical projects under the JDW Platform.

## 📦 What's Inside

This set includes:

- 🧩 `values.yaml`: Custom Helm values for the runner set
- 🔐 Secrets and tokens handled via External Secrets and Vault

## 🧭 Purpose

This runner set is scoped specifically to the **Dotablaze** tech repos and CI/CD workflows.  
It ensures separation of runners across projects, allowing isolated concurrency, security, and scaling.

## 🚀 Key Features

- 🧠 Auto-registers with GitHub ARC using GitHub App credentials
- 📂 Scoped to **organization-level** runners only
- 📊 Uses `labels` for targeted workflows (e.g., `dotablaze-linux`, `self-hosted`)
- 🔄 Auto-scaled with `runnerReplicaCount`, ready for parallel jobs
- 🔒 Auth secrets resolved dynamically using External Secrets

## ⚙️ Configuration Highlights

```yaml
runnerScaleSetName: ubuntu-dotablaze-tech
githubConfigUrl: https://github.com/dotablaze-tech
runnerGroup: default
minRunners: 1
maxRunners: 3
```

## 🛡️ Security

- GitHub App credentials (`app_id`, `installation_id`, `private_key`) are securely injected via Vault-backed External
  Secrets.
- No tokens are stored in source control.

## 🧪 Testing

Verify active runners from GitHub's Actions settings in the organization dashboard.

## 📁 Naming Convention

- Namespace: `arc-runners`
- Runner Set Name: `ubuntu-dotablaze-tech`
- Used exclusively for: Dotablaze Tech organ & associated microservices

---

🛠️ Maintained by the JDW Platform Infra Team  
🔗 [Learn more about GitHub ARC](https://docs.github.com/en/actions/hosting-your-own-runners/about-self-hosted-runners)
