# Run the following on the server
kind: Secret
apiVersion: v1
metadata:
  name: vault
data:
  token: token_here
type: Opaque