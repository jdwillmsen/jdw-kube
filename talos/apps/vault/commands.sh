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
  --from-literal=token=s.xxxxxxxxx
