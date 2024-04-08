# JDW Kube
Repository for configuring JDW Kubernetes Cluster

## Microk8s
Currently, this is being hosted on Ubuntu Server 22 LTS and everything in microk8s folder is used to configure the setup.

## [Minikube](https://minikube.sigs.k8s.io/docs/)
To set up and run Kubernetes locally you can make use of minikube.

### Setup
To set up minikube you can simply run the following command.
```shell
minikube start
```

#### Multi-Node Cluster Setup
If you desire to set up a multi-node cluster you follow minikubes documentation.
Docs: https://minikube.sigs.k8s.io/docs/tutorials/multi_node/

I.e.
```shell
minikube start --nodes 3
```

## Addons
### Ingress
Minikube can enable ingress with the following command.
```shell
minikube addons enable ingress
```