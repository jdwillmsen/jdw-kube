mkdir ~/certs
cd ~/certs

tee openssl.cnf <<EOF
[ req ]
default_bits        = 2048
distinguished_name  = req_distinguished_name
string_mask         = utf8only
default_md          = sha256
x509_extensions     = server_cert
prompt			    = no

[ req_distinguished_name ]
commonName          = localhost

[ server_cert ]
basicConstraints = CA:FALSE
nsCertType = server
nsComment = "OpenSSL Generated Server Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer:always
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = *
EOF

# generate both key and certificate in one step
openssl req -nodes -newkey rsa:2048 -keyout dashboard.key -new -x509 -days 3650 -out dashboard.crt -extensions server_cert -config openssl.cnf

microk8s kubectl -n kube-system delete secret kubernetes-dashboard-certs
microk8s kubectl -n kube-system create secret generic kubernetes-dashboard-certs --from-file=dashboard.crt --from-file=dashboard.key