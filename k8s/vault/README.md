# HashiCorp Vault
Vault provides organizations with identity-based security to automatically authenticate and authorize access to 
secrets and other sensitive data.

## Setup
### Helm
Vault can be setup using helm.
https://developer.hashicorp.com/vault/docs/platform/k8s/helm

### [Minikube TLS Setup](https://developer.hashicorp.com/vault/tutorials/kubernetes/kubernetes-minikube-tls)
In order to set up Vault with TLS you can run the following commands.

#### Create the certificate
1. Create a working directory
```shell
mkdir /tmp/vault
```
2. Export the working directory location and naming variables.
```shell
export VAULT_K8S_NAMESPACE="vault" \
export VAULT_HELM_RELEASE_NAME="vault" \
export VAULT_SERVICE_NAME="vault-internal" \
export K8S_CLUSTER_NAME="cluster.local" \
export WORKDIR=/tmp/vault
```
3. Generate the private key.
```shell
openssl genrsa -out ${WORKDIR}/vault.key 2048
```

#### Create the Certificate Signing Request (CSR)
1. Create the CSR configuration file.
```shell
cat > ${WORKDIR}/vault-csr.conf <<EOF
[req]
default_bits = 2048
prompt = no
encrypt_key = yes
default_md = sha256
distinguished_name = kubelet_serving
req_extensions = v3_req
[ kubelet_serving ]
O = system:nodes
CN = system:node:*.${VAULT_K8S_NAMESPACE}.svc.${K8S_CLUSTER_NAME}
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = *.${VAULT_SERVICE_NAME}
DNS.2 = *.${VAULT_SERVICE_NAME}.${VAULT_K8S_NAMESPACE}.svc.${K8S_CLUSTER_NAME}
DNS.3 = *.${VAULT_K8S_NAMESPACE}
IP.1 = 127.0.0.1
EOF
```
2. Generate the CSR
```shell
openssl req -new -key ${WORKDIR}/vault.key -out ${WORKDIR}/vault.csr -config ${WORKDIR}/vault-csr.conf
```

#### Issue the Certificate
1. Create the CSR yaml file to send it to Kubernetes
```shell
cat > ${WORKDIR}/csr.yaml <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
   name: vault.svc
spec:
   signerName: kubernetes.io/kubelet-serving
   expirationSeconds: 8640000
   request: $(cat ${WORKDIR}/vault.csr|base64|tr -d '\n')
   usages:
   - digital signature
   - key encipherment
   - server auth
EOF
```
2. Send the CSR to Kubernetes.
```shell
kubectl create -f ${WORKDIR}/csr.yaml
```
3. Approve the CSR in Kubernetes.
```shell
kubectl certificate approve vault.svc
```
4. Confirm the certificate was issued.
```shell
kubectl get csr vault.svc
```

#### Store the certificates and Key in the Kubernetes secrets store
1. Retrieve the certificate
```shell
kubectl get csr vault.svc -o jsonpath='{.status.certificate}' | openssl base64 -d -A -out ${WORKDIR}/vault.crt
```
2. Retrieve Kubernetes CA certificate
```shell
kubectl config view \
--raw \
--minify \
--flatten \
-o jsonpath='{.clusters[].cluster.certificate-authority-data}' \
| base64 -d > ${WORKDIR}/vault.ca
```
3. Create the Kubernetes namespace
```shell
kubectl create namespace $VAULT_K8S_NAMESPACE
```
4. Create the TLS secret
```shell
kubectl create secret generic vault-ha-tls \
   -n $VAULT_K8S_NAMESPACE \
   --from-file=vault.key=${WORKDIR}/vault.key \
   --from-file=vault.crt=${WORKDIR}/vault.crt \
   --from-file=vault.ca=${WORKDIR}/vault.ca
```

#### Deploy the vault cluster via helm with overrides
1. Create the overrides.yaml file (There is already a modified version for use within the repository. `1-node-overrides.yaml`)
2. Deploy the cluster.
```shell
# Need to run this from inside the vault directory else change path to file
helm install -n $VAULT_K8S_NAMESPACE $VAULT_HELM_RELEASE_NAME hashicorp/vault -f 1-node-overrides.yaml
```
3. Display the pods in the namespace that you created for vault
```shell
kubectl -n $VAULT_K8S_NAMESPACE get pods
```
4. Initialize `vault-0` with one key share and one key threshold.
```shell
kubectl exec -n $VAULT_K8S_NAMESPACE vault-0 -- vault operator init \
    -key-shares=1 \
    -key-threshold=1 \
    -format=json > ${WORKDIR}/cluster-keys.json
```
5. Display the unseal key found in `cluster-keys.json`.
```shell
jq -r ".unseal_keys_b64[]" ${WORKDIR}/cluster-keys.json
```
6. Create a variable named `VAULT_UNSEAL_KEY` to capture the Vault unseal key.
```shell
VAULT_UNSEAL_KEY=$(jq -r ".unseal_keys_b64[]" ${WORKDIR}/cluster-keys.json)
```
7. Unseal Vault running on the `vault-0` pod.
```shell
kubectl exec -n $VAULT_K8S_NAMESPACE vault-0 -- vault operator unseal $VAULT_UNSEAL_KEY
```

#### Join `vault-1` and `vault2` pods to the Raft cluster
1. Start an interactive shell session on the `vault-1` pod.
```shell
kubectl exec -n $VAULT_K8S_NAMESPACE -it vault-1 -- //bin/sh
```
2. Join the `vault-1` pod to the Raft cluster.
```shell
vault operator raft join -address=https://vault-1.vault-internal:8200 -leader-ca-cert="$(cat /vault/userconfig/vault-ha-tls/vault.ca)" -leader-client-cert="$(cat /vault/userconfig/vault-ha-tls/vault.crt)" -leader-client-key="$(cat /vault/userconfig/vault-ha-tls/vault.key)" https://vault-0.vault-internal:8200
```
3. Exit the `vault-1` pod.
```shell
exit
```
4. Unseal `vault-1` pod.
```shell
kubectl exec -n $VAULT_K8S_NAMESPACE -ti vault-1 -- vault operator unseal $VAULT_UNSEAL_KEY
```
5. Start an interactive shell session on the `vault-2` pod.
```shell
kubectl exec -n $VAULT_K8S_NAMESPACE -it vault-2 -- //bin/sh
```
6. Join the `vault-2` pod to the Raft cluster.
```shell
vault operator raft join -address=https://vault-2.vault-internal:8200 -leader-ca-cert="$(cat /vault/userconfig/vault-ha-tls/vault.ca)" -leader-client-cert="$(cat /vault/userconfig/vault-ha-tls/vault.crt)" -leader-client-key="$(cat /vault/userconfig/vault-ha-tls/vault.key)" https://vault-0.vault-internal:8200
```
7. Exit the `vault-2` pod.
```shell
exit
```
8. Unseal `vault-2`.
```shell
kubectl exec -n $VAULT_K8S_NAMESPACE -ti vault-2 -- vault operator unseal $VAULT_UNSEAL_KEY
```
9. Export the cluster root token.
```shell
export CLUSTER_ROOT_TOKEN=$(cat ${WORKDIR}/cluster-keys.json | jq -r ".root_token")
```
10. Login to `vault-0` with the root token.
```shell
kubectl exec -n $VAULT_K8S_NAMESPACE vault-0 -- vault login $CLUSTER_ROOT_TOKEN
```
11. List the raft peers.
```shell
kubectl exec -n $VAULT_K8S_NAMESPACE vault-0 -- vault operator raft list-peers
```
12. Print the HA status
```shell
kubectl exec -n $VAULT_K8S_NAMESPACE vault-0 -- vault status
```

#### Create a secret
1. Start an interactive shell session on the `vault-0` pod.
```shell
kubectl exec -n $VAULT_K8S_NAMESPACE -it vault-0 -- //bin/sh
```
2. Enable the kv-v2 secrets engine.
```shell
vault secrets enable -path=secret kv-v2
```
3. Create a secret at the path `secret/tls/apitest` with a `username` and a `password`.
```shell
vault kv put secret/tls/apitest username="apiuser" password="supersecret"
```
4. Verify that the secret is defined at the path `secret/tls/apitest`
```shell
vault kv get secret/tls/apitest
```
5. Exit the `vault-0` pod.
```shell
exit
```

#### Expose the vault service and retrieve the secret via the API
1. Confirm the vault service configuration.
```shell
kubectl -n $VAULT_K8S_NAMESPACE get service vault
```
2. In another terminal, port forward the vault service.
```shell
kubectl -n vault port-forward service/vault 8200:8200
```
3. In the original terminal, perform a `HTTPS` curl request to retrieve the secret you created in the previous section.
```shell
curl -k --cacert $WORKDIR/vault.ca \
   --header "X-Vault-Token: $CLUSTER_ROOT_TOKEN" \
   https://127.0.0.1:8200/v1/secret/data/tls/apitest | jq .data.data
```