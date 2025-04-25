# ☸️ JDW Kube

A structured and extensible Kubernetes deployment framework optimized for MicroK8s and Minikube environments. This project leverages tools like ArgoCD, External Secrets, Vault, Prometheus, Postgres, and more to support GitOps workflows and infrastructure-as-code deployments.

---

## 📁 Project Structure

- **microk8s/**: Deployment manifests and configurations tailored for a MicroK8s environment.
- **minikube/**: Equivalent deployment manifests for local Minikube setups.
- **test/**: Test-specific resources and configurations to validate deployments.

Each environment includes the following modules:

- **argocd/**: GitOps continuous delivery setup.
- **cert-manager/**: TLS management with various issuers.
- **external-secrets/**: Integration with external secret managers.
- **vault/** & **vault-config-operator/**: HashiCorp Vault-based secret storage and automation.
- **postgresql-cluster-***/: Postgres cluster setup for different environments (non-prod and prod).
- **kube-prometheus-stack/**: Monitoring and alerting infrastructure.
- **cloudnative-operator/**: Additional custom resources for app management.
- **kubernetes-dashboard/**: Web UI for Kubernetes.
- **metrics-server/**: Resource metrics collection.
- **ingress-nginx/**: Ingress controller and configs.
- **helm-charts/**: Custom Helm chart sources and templates.

---

## 🚀 Quick Start

```bash
# Clone the repo
git clone https://github.com/your-username/jdw-kube.git
cd jdw-kube

# Optional: start Minikube or MicroK8s
minikube start   # or microk8s start

# Apply core manifests (example)
kubectl apply -f minikube/bootstrap.yaml
```

> **Note**: Be sure to set up secret values and configure context-specific variables before applying manifests.

---

## 🧰 Tools Used

- **ArgoCD** - GitOps continuous delivery
- **Cert-Manager** - TLS automation
- **Vault** - Secret management
- **Prometheus/Grafana** - Monitoring and visualization
- **PostgreSQL Operator** - Managed Postgres clusters
- **Helm** - Templated Kubernetes configurations

---

## 🧪 Testing

The `test/` directory includes mock ingress setups, policy test cases, and minimal manifests for CI or local testing.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](./LICENSE) file for details.

---

## 📬 Contact

Maintained by [@jdwillmsen](https://github.com/jdwillmsen).

---

> Built with love for reproducible and scalable Kubernetes environments.

