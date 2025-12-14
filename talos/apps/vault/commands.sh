# Run the following on the server
kind: Secret
apiVersion: v1
metadata:
  name: vault
data:
  token: token_here
type: Opaque

kubectl create secret generic vault \
  --from-literal=token=<VAULT_TOKEN> \
  -n vault

kubectl create secret generic vault-token \
  -n external-secrets \
  --from-literal=token=<VAULT_TOKEN>

# cluster-secret-store.yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200E"
      path: "kv"
      version: "v2"
      auth:
        tokenSecretRef:
          name: vault-token
          namespace: external-secrets
          key: token

kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=1 \
  -key-threshold=1
kubectl exec -n vault vault-1 -- vault operator raft join http://vault-0.vault-internal:8200
kubectl exec -n vault vault-2 -- vault operator raft join http://vault-0.vault-internal:8200

