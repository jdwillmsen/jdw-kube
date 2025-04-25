# 🧪 JDW Platform – `test/` Directory

The `test/` directory serves as a sandbox for experimentation, validation, and prototyping within the **JDW Platform**.
It contains configuration files, Helm values, sample manifests, and test deployments to verify cluster behaviors,
policies, and integrations.

---

## 📁 Directory Structure

| Directory          | Purpose                                                                      |
|--------------------|------------------------------------------------------------------------------|
| `config.yaml`      | Test-specific Argo CD ApplicationSet config                                  |
| `ingress/`         | Minimal ingress controller test setup with values and scripts                |
| `ingress-nginx/`   | Example resources to test Ingress routes and behaviors (apple, banana, etc.) |
| `java-app-resize/` | Sample Java app resources to test HPA/vertical scaling policies              |
| `manifests/`       | Generic Kubernetes manifests for miscellaneous tests                         |
| `nginx-ingress/`   | Alternate test values for validating nginx ingress behaviors                 |

---

## ✅ Use Cases

- Test ingress rules and ConfigMap overrides
- Prototype scaling policies using Java app deployments
- Validate `ingress-nginx` path routing and resource behavior
- Develop and iterate on new Helm chart values before promotion

---

## 🧰 Usage Tips

- Apply individual files with `kubectl apply -f <file>`
- Run `commands.sh` in relevant directories for setup/reset
- Test Argo CD integration with `config.yaml` if needed

---

## ⚠️ Disclaimer

This directory is **not for production**. Use it strictly for development, local testing, and temporary experimentation.

---

Maintained by: **JDW Platform Infra Team**  
Happy testing! 🧪
