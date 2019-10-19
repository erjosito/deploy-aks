#!/bin/bash

# Variables
rg=akstest
aksname_azure=azurecnicluster
aksname_kubenet=kubenetcluster
vnet=aksVnet
subnet_aci=aci

# Argument parsing (can overwrite the previously intialized variables)
for i in "$@"
do
case $i in
    -g=*|--resource-group=*)
    rg="${i#*=}"
    shift # passed argument=value
    ;;
esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

# Message
echo "Please run this script as \"source ./cleanupaks.sh [--resource-group=yourrg]\""

# Remove subnet delegation for ACI in the Azure CNI cluster
echo "Looking for network profiles in resource group $rg"
nw_profileid=$(az network profile list -g $rg --query [0].id -o tsv)
# Remove blanks and new line characters
nw_profileid=${nw_profileid//[$'\t\r\n']}
if [[ ! -z "{$nw_profileid}" ]]
then
    echo "Deleting Network Profile ID $nw_profileid"
    az network profile delete --ids $nw_profileid -y
else
    echo "No network profile found"
fi
sal_id=$(az network vnet subnet show -g $rg --vnet-name $vnet -n $subnet_aci --query id -o tsv)/providers/Microsoft.ContainerInstance/serviceAssociationLinks/default
check_sal_id=$(az resource show --ids $sal_id --query id --api-version 2018-07-01 -o tsv)
if [[ ! -z "{$check_sal_id}" ]]
then
    echo "Deleting Service Association Link $check_sal_id"
    az resource delete --ids $sal_id --api-version 2018-07-01
    echo "Removing delegations for subnet $subnet_aci"
    az network vnet subnet update -g $rg --vnet-name $vnet -n $subnet_aci --remove delegations 0
else
    echo "No Service Association Links found in subnet $subnet_aci"
fi

# Remove RG
echo "Deleting RG $rg..."
az group delete -n $rg -y --no-wait

# Cleanup kubeconfig - Azure CNI
echo "Delete kube config for cluster $aksname_azure"
kubectl config delete-context $aksname_azure
kubectl config delete-cluster $aksname_azure
kubectl config unset users.clusterUser_"$rg"_"$aksname_azure"

# Cleanup kubeconfig - Kubenet
echo "Delete kube config for cluster $aksname_kubenet"
kubectl config delete-context $aksname_kubenet
kubectl config delete-cluster $aksname_kubenet
kubectl config unset users.clusterUser_"$rg"_"$aksname_kubenet"
