# Run the following on the server
kind: Secret
apiVersion: v1
metadata:
  name: vault
data:
  token: token_here
type: Opaque

# Delete existing secrets
kubectl delete secret vault-token -n vault
kubectl delete secret vault-token -n external-secrets
kubectl delete secret vault-token -n non
kubectl delete secret vault-token -n prd

kubectl create secret generic vault-token \
  --from-literal=token=$VAULT_TOKEN \
  -n vault

kubectl create secret generic vault-token \
  -n external-secrets \
  --from-literal=token=$VAULT_TOKEN

kubectl create secret generic vault-token \
  --from-literal=token=$VAULT_TOKEN \
  -n non

kubectl create secret generic vault-token \
  --from-literal=token=$VAULT_TOKEN \
  -n prd

# Vault unseal key
kubectl delete secret vault-unseal-keys -n vault

kubectl create secret generic vault-unseal-keys \
  --from-literal=unseal_key_0=$VAULT_UNSEAL_KEY_1 \
  -n vault

# cluster-secret-store.yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:8200"
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

