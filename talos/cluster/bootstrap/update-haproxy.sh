#!/bin/bash
set -euo pipefail

HAPROXY_HOST="jake@192.168.1.237"
HAPROXY_CONFIG="/etc/haproxy/haproxy.cfg"

if [ $# -eq 0 ]; then
    echo "Usage: $0 <IP1> [IP2] [IP3] ..."
    exit 1
fi

# Build server lists
K8S_SERVERS=""
TALOS_SERVERS=""
for i in "$@"; do
    server_name="talos-cp-${i##*.}"
    K8S_SERVERS="${K8S_SERVERS}    server ${server_name} ${i}:6443 check\n"
    TALOS_SERVERS="${TALOS_SERVERS}    server ${server_name} ${i}:50000 check\n"
done

echo "[INFO] Generating complete HAProxy configuration..."

# Generate FULL config
cat > /tmp/haproxy.cfg.complete <<EOFCFG
# ==================== GLOBAL ====================
global
    log /dev/log local0 info
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn 32000
    ulimit-n 65535
    nbthread 4
    cpu-map auto:1/1-4 0-3
    tune.ssl.default-dh-param 2048

# ==================== DEFAULTS ====================
defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    option tcp-smart-connect
    option redispatch
    option tcp-check
    retries 3
    timeout connect 5s
    timeout client 30s
    timeout server 30s
    timeout check 5s
    maxconn 32000

# ==================== STATS PAGE ====================
listen stats
    bind 192.168.1.237:9000
    mode http
    stats enable
    stats uri /
    stats refresh 5s
    stats show-legends
    stats admin if TRUE
    stats auth admin:talos-lb-admin

# ==================== KUBERNETES API ====================
frontend k8s-apiserver
    bind 192.168.1.237:6443
    mode tcp
    option tcplog
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    default_backend k8s-controlplane

backend k8s-controlplane
    mode tcp
    balance leastconn
    option tcp-check
    tcp-check connect port 6443
    default-server inter 5s fall 3 rise 2
$(printf "${K8S_SERVERS}")

# ==================== TALOS API ====================
frontend talos-apiserver
    bind 192.168.1.237:50000
    mode tcp
    option tcplog
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    default_backend talos-controlplane

backend talos-controlplane
    mode tcp
    balance leastconn
    option tcp-check
    tcp-check connect port 50000
    timeout connect 10s
    timeout server 60s
    default-server inter 5s fall 3 rise 2
$(printf "${TALOS_SERVERS}")
EOFCFG

echo "[INFO] Copying to HAProxy server..."
scp /tmp/haproxy.cfg.complete "${HAPROXY_HOST}:/tmp/haproxy.cfg.new"

echo "[INFO] Installing configuration..."
ssh "${HAPROXY_HOST}" "sudo cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.backup.$(date +%Y%m%d_%H%M%S)"
ssh "${HAPROXY_HOST}" "sudo mv /tmp/haproxy.cfg.new /etc/haproxy/haproxy.cfg"
ssh "${HAPROXY_HOST}" "sudo haproxy -c -f /etc/haproxy/haproxy.cfg"
ssh "${HAPROXY_HOST}" "sudo systemctl reload haproxy || sudo systemctl start haproxy"

if [ $? -eq 0 ]; then
    echo "✓ HAProxy updated successfully!"
    echo "✓ Verify at: http://192.168.1.237:9000"
    rm -f /tmp/haproxy.cfg.complete
else
    echo "✗ Failed to update HAProxy"
    exit 1
fi