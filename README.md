# Deploy AKS

The goal of this repo is providing a way of quickly deploying Azure Kubernetes Service with some of the features supported, so that users can easily test some of the features available in the service.

It essentially consists of two scripts: deployaks.sh and cleanupaks.sh

## Deploy AKS

It is recommended to run the script in the current shell (using source ./deployaks.sh), so that you will have access to the bash variables created during the script. You can access the help of the script with the flag -h:

```
$ ./deployaks.sh -h
Please run this script as "source ./deployaks.sh [--mode=kubenet|azure] [--network-policy=azure|calico|none] [--resource-group=yourrg] [--vnet-peering] [--kubernetes-version=x.x.x] [--windows] [--appgw]"
  -> Example: "source ./deployaks.sh -m=azure -p=azure -g=akstest"
```

Note that if you do not specify a resource group with the flag -g, the default resource group name where most resources will be provisioned is `akstest`.

## Clean up your test

You will probably want to remove the cluster after deploying it, in order to save costs. In most cases it would be enough removing the resource group where all resources are contained (`az remove group -n akstest -y --nowait`), but in some cases some extra operations might have to be performed (like when testing virtual node). For that case the script `clenaupaks.sh` should remove everything from the test, including the configurations in kube.config for the clusters.

