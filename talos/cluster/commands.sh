 # Nodes
export NODE_1=192.168.1.221
export NODE_2=192.168.1.222
export NODE_3=192.168.1.223
export NODE_4=192.168.1.220

# Single Control Plane Setup
export CONTROL_PLANE_IP=${NODE_1}
export CLUSTER_NAME=cluster1
export DISK_NAME=nvme0n1
export WORKER_IP=("<worker-ip-1>" "<worker-ip-2>")

# Three Node Control Plane Setup
# https://docs.siderolabs.com/talos/v1.11/getting-started/prodnotes
export CONTROL_PLANE_IP=("${NODE_1}" "${NODE_2}" "${NODE_3}")
export WORKER_IP=("${NODE_4}")
export CLUSTER_NAME=cluster1
export YOUR_ENDPOINT=kube.cluster1.jdwkube.com
talosctl gen config --with-secrets secrets.yaml $CLUSTER_NAME https://$YOUR_ENDPOINT:6443

### Check network interfaces - Run this command to view all network interfaces on any node, whether control plane or worker.
talosctl --nodes <node-ip-address> get links --insecure
talosctl --nodes $NODE_1 get links --insecure
export NETWORK_ID=eno1

### Check available disks - Run this command to check all available disks on any node.
talosctl get disks --insecure --nodes <node-ip-address>
talosctl get disks -n $NODE_1
export DISK_NAME=nvme0n1

### Patch machine configuration - You can patch your worker and control plane machine configuration to reflect the correct network interface and disk of your control plane nodes.
touch controlplane-patch-1.yaml # For patching the control plane nodes configuration
touch worker-patch-1.yaml # For patching the worker nodes configuration
```
# controlplane-patch-1 file
machine:
  network:
    interfaces:
      - interface: <control-plane-network-interface>  # From control plane node
        dhcp: true
  install:
    disk: /dev/<control-plane-disk-name> # From control plane node
```
```
# worker-patch-1.yaml file
machine:
  network:
    interfaces:
      - interface: <worker-network-interface>  # From worker node
        dhcp: true
  install:
    disk: /dev/<worker-disk-name> # From worker node
```
### Apply the patch for control plane node
talosctl machineconfig patch controlplane.yaml --patch @controlplane-patch-1.yaml --output controlplane.yaml
talosctl machineconfig patch controlplane.yaml --patch @cp.yaml --output controlplane.yaml
talosctl machineconfig patch controlplane.yaml --patch @wp.yaml --output controlplane.yaml
### Apply the patch for the work node
talosctl machineconfig patch worker.yaml --patch @worker-patch-1.yaml --output worker.yaml
talosctl machineconfig patch worker.yaml --patch @wp.yaml --output worker.yaml

### Manage talos configuration file
talosctl config merge ./talosconfig

### Set endpoints of control plane nodes
talosctl config endpoint <control_plane_IP_1> <control_plane_IP_2> <control_plane_IP_3>
talosctl config endpoint $NODE_1 $NODE_2 $NODE_3

### Bootstrap Kubernetes cluster
talosctl bootstrap --nodes <control-plane-IP>
talosctl bootstrap --nodes $NODE_3

### Get Kubernetes access
talosctl kubeconfig --nodes <control-plane-IP>
talosctl kubeconfig --nodes $NODE_3

## Setup Hosts File
```
192.168.1.220 kube.cluster1.jdwkube.com
192.168.1.221 kube.cluster1.jdwkube.com
192.168.1.222 kube.cluster1.jdwkube.com
192.168.1.223 kube.cluster1.jdwkube.com
```

## Patch lb
```
for ip in "${CONTROL_PLANE_IP[@]}"; do
  echo "=== Applying configuration to node $ip ==="
  talosctl apply-config --insecure \
    --nodes $ip \
    --file controlplane.yaml
  echo "Configuration applied to $ip"
  echo ""
done
```

```
for ip in "${WORKER_IP[@]}"; do
  echo "=== Applying configuration to node $ip ==="
  talosctl apply-config --insecure \
    --nodes $ip \
    --file worker.yaml
  echo "Configuration applied to $ip"
  echo ""
done
```

## Patch lb secure
```
for ip in "${CONTROL_PLANE_IP[@]}"; do
  echo "=== Applying configuration to node $ip ==="
  talosctl apply-config \
    --nodes $ip \
    --file controlplane.yaml
  echo "Configuration applied to $ip"
  echo ""
done
```

## Upgrade Node (https://factory.talos.dev/)
talosctl upgrade --nodes $NODE_1 --image factory.talos.dev/metal-installer/bb69404eed88748ae3cfc1625b9561ff6a74f8e4ea7f8d1e715d999f127c8863:v1.11.5
