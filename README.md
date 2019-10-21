# Deploy AKS

The goal of this repo is providing a way of quickly deploying Azure Kubernetes Service with some of the features supported, so that users can easily test some of the features available in the service.

It essentially consists of two scripts: deployaks.sh and cleanupaks.sh.

**Note**: this script assumes that you have some infrastructure already there, such as an Azure Key Vault with specific secrets, an Azure Monitor workspace for logging or an Azure Container Registry for your container images. Future versions of this script might remove some of these requirements.

## Deploy AKS

It is recommended to run the script in the current shell (using source ./deployaks.sh), so that you will have access to the bash variables created during the script. You can access the help of the script with the flag -h:

```
$ ./deployaks.sh -h
Please run this script as "source ./deployaks.sh [--mode=kubenet|azure] [--network-policy=azure|calico|none] [--resource-group=yourrg] [--vnet-peering] [--kubernetes-version=x.x.x] [--windows] [--appgw] [--vm]"
  -> Example: "source ./deployaks.sh -m=azure -p=azure -g=akstest"
```

Note that if you do not specify a resource group with the flag -g, the default resource group name where most resources will be provisioned is `akstest`.

## Clean up your test

You will probably want to remove the cluster after deploying it, in order to save costs. In most cases it would be enough removing the resource group where all resources are contained (`az remove group -n akstest -y --nowait`), but in some cases some extra operations might have to be performed (like when testing virtual node). For that case the script `clenaupaks.sh` should remove everything from the test, including the configurations in kube.config for the clusters.

## What can be tested?

Here some examples of which scenarios can be built with this script:

* Compare Azure CNI with kubenet: you can use the script to create Azure CNI clusters or kubenet clusters (both in your own vnet)
* Access from inside of the vnet (similar to accessing the cluster from onprem): use the flag `--vm`
* Global vnet peering to AKS: use the flag `--vnet-peering`
* Increasing ephemeral ports for egress connections to the Internet: the Azure CNI cluster is created with the standard LB and configures two additional public IP address for outbound rules in the standard ALB.
* Test windows pools: use the flag `--windows`
* Test kubernetes network policies: use the flag `--network-policy=azure|calico|none`
* Application Gateway as Ingress Controller: use the flag `--appgw`
