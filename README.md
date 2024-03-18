# JDW Kube
Repository for configuring JDW Kubernetes Cluster

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

## Design
For the most part the Cluster only needs ArgoCD setup. \
As primarily the applications/resources setup are done within ArgoCD with an Apps of Apps pattern.

Currently, this is being done in the following fashion.

```structure
jdw-kube
-- argocd
---- apps-of-apps-1
---- apps-of-apps-2
-- k8s
---- TBD
```

Where an apps-of-apps can be thought of as an entire domain or application team.
For instance currently there is just the jdw app/domain.
There is also a k8s folder for other resources that may be needed in future to be shared across all teams/app/domains.
As of now there is nothing there and the folder is not included in git.

## Addons
### Ingress
Minikube can enable ingress with the following command.
```shell
minikube addons enable ingress
```