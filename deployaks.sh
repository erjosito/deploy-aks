#!/bin/bash

# Variable initialization
rg=akstest
location=westeurope
keyvaultname=erjositoKeyvault
vnet=aksVnet
vnetprefix=10.13.0.0/16
vmsize=Standard_B2ms
adminuser=jose
aks_rbac=yes
# AKS cluster (Azure CNI)
aksname_azure=azurecnicluster
subnet_azure=azurecni
subnetprefix_azure=10.13.76.0/24
nwpolicy=calico
pip_name_prefix=azure-pip-
pip1_name="$pip_name_prefix"01
pip2_name="$pip_name_prefix"02
# AKS cluster (kubenet)
aksname_kubenet=kubenetcluster
subnetprefix_kubenet=10.13.77.0/24
subnet_kubenet=kubenet
podcidr_kubenet=192.168.0.0/16
# Virtual node
subnet_aci=aci
subnetprefix_aci=10.13.100.0/24
# Tags
tag1_name=mytag
tag1_value=myvalue
# Test VM
vm_name=testvm
subnet_vm=vm
vm_image=ubuntults
subnetprefix_vm=10.13.1.0/24
# Vnet peering
peervnet=aksPeerVnet
peer_vnet_prefix=172.16.100.0/24
peer_vnet_location=westeurope
# Monitoring workspace
monitor_rg=logtest
monitor_ws=logtest1138
# ACR
acr_rg=myAcr
acr_name=erjositoAcr
# DNS
dnszone=cloudtrooper.net
# App Gateway
appgw_subnetname=aksappgw
appgw_subnetprefix=10.13.10.0/24
appgw_pipname=appgw-pip
appgw_name=appgw
appgw_dnsname=appgw$RANDOM
appgw_sku=Standard_v2
appgw_identity_name=appgwid

# Check interval to wait for operations to finish
wait_interval=5s

# Argument parsing (can overwrite the previously intialized variables)
for i in "$@"
do
     case $i in
          -g=*|--resource-group=*)
               rg="${i#*=}"
               shift # past argument=value
               ;;
          -k=*|--kubernetes-version=*)
               k8sversion="${i#*=}"
               shift # past argument=value
               ;;
          -p=*|--network-policy=*)
               nwpolicy="${i#*=}"
               shift # past argument=value
               ;;
          -m=*|--mode=*)
               mode="${i#*=}"
               shift # past argument=value
               ;;
          --vnet-peering)
               vnetpeering=yes
               shift # past argument with no value
               ;;
          -w|--windows)
               windows=yes
               shift # past argument with no value
               ;;
          --vm)
               create_vm=yes
               shift # past argument with no value
               ;;
          --appgw)
               create_appgw=yes
               shift # past argument with no value
               ;;
          --virtual-node)
               create_vnode=yes
               shift # past argument with no value
               ;;
          --help|-h)
               help=yes
               shift # past argument with no value
               ;;
          *)
                    # unknown option
               ;;
     esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

# Validate arguments
if [ "$nwpolicy" != "calico" ] && [ "$nwpolicy" != "azure" ]
then
     nwpolicy=""
fi

# Default to azure
if [ "$mode" == "kubenet" ]
then
     create_azure=no
     create_kubenet=yes
else
     create_azure=yes
     create_kubenet=no
fi


# If the --help flag was issued, show help message and stop right here
if [ "$help" == "yes" ]
then
     echo "Please run this script as \"source $0 [--mode=kubenet|azure] [--network-policy=azure|calico|none] [--resource-group=yourrg] [--vnet-peering] [--kubernetes-version=x.x.x] [--windows] [--appgw] [--vm] [--virtual-node]\""
     echo " -> Example: \"source $0 -m=azure -p=azure -g=akstest2\""
     exit
fi

# Message on subscription
echo 'Getting information about Azure subscription...'
subname=$(az account show --query name -o tsv)
subid=$(az account show --query id -o tsv)
echo "Working on subscription $subname ($subid)"

# Create resource group
echo "Creating RG $rg..."
az group create -n $rg -l $location >/dev/null

# Get stuff from key vault
get_kvname=$(az keyvault list -o tsv --query "[?name=='$keyvaultname'].name")
if [ "$get_kvname" == "$keyvaultname" ]
then
     echo "Retrieving secrets from Azure Key Vault $keyvaultname..."
     sshpublickey=$(az keyvault secret show -n surfaceSshPublicKey --vault-name $keyvaultname --query value -o tsv)
     default_password=$(az keyvault secret show -n defaultPassword --vault-name $keyvaultname --query value -o tsv)
     appid=$(az keyvault secret show -n aks-app-id --vault-name $keyvaultname --query value -o tsv)
     appsecret=$(az keyvault secret show -n aks-app-secret --vault-name $keyvaultname --query value -o tsv)
     echo "Got ssh public key and secret for sp $appid from Key Vault $keyvaultname"
else
     echo "Key Vault $keyvaultname not found! A keyvault with SSH public strings and AAS SP data is required!"
     exit 1
fi

# Get monitoring workspace
echo "Getting workspace ID for monitoring for workspace $monitor_ws in resource group $monitor_rg..."
wsid=$(az resource list -g $monitor_rg -n $monitor_ws --query [].id -o tsv)
if [[ -z "$wsid" ]]
then
     echo "Could not find log analytics workspace $monitor_ws in resource group $monitor_rg! Exiting..."
else
     echo "Found ID for workspace $monitor_ws: $wsid"
fi

# Get ACR ID
echo "Getting ACR ID for $acr_name in resource group $acr_rg..."
get_acr_name=$(az acr list -o tsv --query "[?name=='$acr_name'].name")
if [ "$get_acr_name" == "$acr_name" ]
then
     acr_rg=$(az acr list -o tsv --query "[?name=='$acr_name'].resourceGroup")
     acr_id=$(az acr show -n erjositoAcr -g $acr_rg --query id -o tsv)
     echo "ID for existing ACR $acr_name is $acr_id"
else
     acr_rg=$rg
     az acr create -n $acr_name -g $acr_rg --sku Standard -l $location 2>/dev/null
     acr_id=$(az acr show -n erjositoAcr -g $acr_rg --query id -o tsv)
     echo "ID for new ACR $acr_name is $acr_id"
fi

# Use a k8s version from the args, or get last supported k8s version. 'latest' keyword supported
if [[ -z "$k8sversion" ]] || [[ "$k8sversion" == "latest" ]]
then
     echo 'Getting latest supported k8s version...'
     k8sversion=$(az aks get-versions -l $location -o tsv --query orchestrators[-1].orchestratorVersion)
     # Filter for non-preview?
     # k8sversion=$(az aks get-versions -l $location -o tsv --query [?orchestrators.isPreview==false].orchestratorVersion)
     echo "Latest supported k8s version in $location is $k8sversion"
else
     echo "Using k8s version $k8sversion"
fi

# Create vnet
echo "Creating vnet $vnet..."
az network vnet create -g $rg -n $vnet --address-prefix $vnetprefix >/dev/null

# Create peered vnet (if specified in the options)
if [ "$vnetpeering" == "yes" ]
then
     echo "Creating vnet $peervnet to peer in $peer_vnet_location..."
     az network vnet create -g $rg -n $peervnet --address-prefix $peer_vnet_prefix -l $peer_vnet_location >/dev/null
     az network vnet peering create -g $rg -n AKSToPeer --vnet-name $vnet --remote-vnet $peervnet --allow-vnet-access     
     az network vnet peering create -g $rg -n PeerToAKS --vnet-name $peervnet --remote-vnet $vnet --allow-vnet-access     
fi

# Create subnet for ACI (virtual node)
if [ "$create_vnode" == "yes" ]
then
     echo 'Creating subnet for ACI...'
     az network vnet subnet create -g $rg -n $subnet_aci --vnet-name $vnet --address-prefix $subnetprefix_aci >/dev/null
fi

# Create Kubenet cluster
# Virtual node CLI extension needs to be installed for this command to work:
#    az extension add --source https://aksvnodeextension.blob.core.windows.net/aks-virtual-node/aks_virtual_node-0.2.0-py2.py3-none-any.whl
if [ "$create_kubenet" == "yes" ]
then
     echo 'Creating subnet for kubenet cluster...'
     az network vnet subnet create -g $rg -n $subnet_kubenet --vnet-name $vnet --address-prefix $subnetprefix_kubenet >/dev/null
     subnetid=$(az network vnet subnet show -g $rg --vnet-name $vnet -n $subnet_kubenet --query id -o tsv)
     echo "Subnet ID is $subnetid"
     echo "Creating kubenet cluster $aksname_kubenet in resource group $rg..."
     # Virtual node only supported for Azure CNI
     az aks create -g $rg -n $aksname_kubenet -c 2 -s $vmsize -k $k8sversion  \
          --service-principal $appid --client-secret $appsecret \
          --admin-username $adminuser --ssh-key-value "$sshpublickey" \
          --network-plugin kubenet --vnet-subnet-id $subnetid \
          --pod-cidr $podcidr_kubenet \
          --enable-addons monitoring --workspace-resource-id $wsid \
          --tags "$tag1_name"="$tag1_value" \
          --no-wait
fi

# Create Azure CNI cluster
if [ "$create_azure" == "yes" ]
then
     # Public IPs for egress
     echo 'Creating public IP addresses for outbound traffic...'
     az network public-ip create -g $rg -n $pip1_name --sku standard >/dev/null
     az network public-ip create -g $rg -n $pip2_name --sku standard >/dev/null
     pip1_id=$(az network public-ip show -g $rg -n $pip1_name --query id -o tsv)
     pip2_id=$(az network public-ip show -g $rg -n $pip2_name --query id -o tsv)
     pip1_ip=$(az network public-ip show -g $rg -n $pip1_name --query ipAddress -o tsv)
     pip2_ip=$(az network public-ip show -g $rg -n $pip2_name --query ipAddress -o tsv)
     echo "Created IP addresses: $pip1_ip and $pip2_ip"
     # Subnet
     echo 'Creating subnet for Azure CNI cluster...'
     az network vnet subnet create -g $rg -n $subnet_azure --vnet-name $vnet --address-prefix $subnetprefix_azure >/dev/null
     subnetid=$(az network vnet subnet show -g $rg --vnet-name $vnet -n $subnet_azure --query id -o tsv)
     echo "Subnet ID is $subnetid"
     # Cluster
     echo "Creating Azure CNI cluster $aksname_azure in resource group $rg..."
     az aks create -g $rg -n $aksname_azure -c 1 -s $vmsize -k $k8sversion \
          --service-principal $appid --client-secret $appsecret \
          --admin-username $adminuser --ssh-key-value "$sshpublickey" \
          --network-plugin azure --vnet-subnet-id $subnetid \
          --enable-addons monitoring --workspace-resource-id $wsid \
          --network-policy "$nwpolicy" \
          --enable-vmss --node-zones 1 2 3 --nodepool-name pool1 --load-balancer-sku standard \
          --windows-admin-password "$default_password" --windows-admin-username $adminuser \
          --attach-acr "$acr_id" \
          --load-balancer-sku standard --load-balancer-outbound-ips "$pip1_id","$pip2_id" \
          --node-resource-group "$aksname_azure"-iaas-"$RANDOM" \
          --tags "$tag1_name"="$tag1_value" \
          --no-wait
     echo ""
fi

# Create app gateway
if [ "$create_appgw" == "yes" ] && [ "$create_azure" == "yes" ]
then

     # Create App Gw subnet
     echo 'Creating subnet for application gateway...'
     az network vnet subnet create -g $rg -n $appgw_subnetname --vnet-name $vnet --address-prefix $appgw_subnetprefix >/dev/null
     # Create public IP
     echo 'Creating public IP address for application gateway...'
     az network public-ip create -g $rg -n $appgw_pipname --sku Standard --dns-name $appgw_dnsname >/dev/null
     appgw_ip=$(az network public-ip show -g $rg -n $appgw_pipname --query ipAddress -o tsv)
     # Create App Gw
     echo "Creating app gateway $appgw_name..."
     az network application-gateway create -g $rg -n $appgw_name \
               --capacity 2 --sku $appgw_sku --frontend-port 80 \
               --routing-rule-type basic --http-settings-port 80 \
               --http-settings-protocol Http --public-ip-address $appgw_pipname \
               --vnet-name $vnet --subnet $appgw_subnetname \
               --servers "dummy.abc.com" --no-wait
fi

# Test VM (should we create it no --no-wait mode too?)
if [ "$create_vm" == "yes" ]
then
     echo 'Creating subnet for test VM...'
     az network vnet subnet create -g $rg -n $subnet_vm --vnet-name $vnet --address-prefix $subnetprefix_vm >/dev/null
     echo 'Creating NSG for test VM...'
     az network nsg create -n $vm_name-nsg -g $rg >/dev/null
     # Get the ipv4 public IP
     my_ip=$(curl -s4 ifconfig.co)
     echo Adding our public IP "$my_ip" to the NSG...
     az network nsg rule create -g $rg --nsg-name $vm_name-nsg -n SSHfromHome --priority 500 --source-address-prefixes $my_ip/32 --destination-port-ranges 22 --destination-address-prefixes '*' --access Allow --protocol Tcp --description "Allow SSH from home" >/dev/null
     echo "Creating test VM $vm_name (will take a few minutes)..."
     start_time=`date +%s`
     az vm create --image $vm_image -g $rg -n $vm_name --authentication-type ssh --ssh-key-value "$sshpublickey" --public-ip-address $vm_name-pip --vnet-name $vnet --subnet $subnet_vm --os-disk-size 30 --storage-sku "Standard_LRS" --nsg $vm_name-nsg >/dev/null
     echo VM time creation was $(expr `date +%s` - $start_time) s
     public_ip=$(az network public-ip show -n $vm_name-pip -g $rg --query ipAddress -o tsv)
fi

# Some final comments
# Virtual node CLI extension needs to be installed for this command to work:
#    az extension add --source https://aksvnodeextension.blob.core.windows.net/aks-virtual-node/aks_virtual_node-0.2.0-py2.py3-none-any.whl
# virtual-node cannot be apparently enabled at creation time, --subnet-name is not recognized as argument

# Function to wait until a resource is provisioned:
# Arguments:
# - resource id
function WaitUntilFinished {
     resource_id=$1
     resource_name=$(echo $resource_id | cut -d/ -f 9)
     echo "Waiting for resource $resource_name to finish provisioning..."
     start_time=`date +%s`
     state=$(az resource show --id $resource_id --query properties.provisioningState -o tsv)
     until [ "$state" == "Succeeded" ] || [ "$state" == "Failed" ] || [ -z "$state" ]
     do
          sleep $wait_interval
          state=$(az resource show --id $resource_id --query properties.provisioningState -o tsv)
     done
     if [ -z "$state" ]
     then
          echo "Something bad happened..."
     else
          echo "Resource $resource_name provisioning state is $state, wait time $(expr `date +%s` - $start_time) seconds"
          if [ "$state" == "Failed" ]
          then
               echo "Exiting..."
               exit 1
          fi
     fi
}

# Wait for Azure cluster to finish
if [ "$create_azure" == "yes" ]
then
     resource_id=$(az aks show -n $aksname_azure -g $rg --query id -o tsv)
     WaitUntilFinished $resource_id
fi

# Wait for Kubenet cluster to finish
if [ "$create_kubenet" == "yes" ]
then
     resource_id=$(az aks show -n $aksname_kubenet -g $rg --query id -o tsv)
     WaitUntilFinished $resource_id
fi

# Wait for app gw to finish
if [ "$create_appgw" == "yes" ]
then
     resource_id=$(az network application-gateway show -n $appgw_name -g $rg --query id -o tsv)
     WaitUntilFinished $resource_id
fi

# Enable diagnostics to log analytics for the App Gw
if [ "$create_appgw" == "yes" ]
then
     echo "Enabling logging for app gateway to log analytics workspace $monitor_ws..."
     appgw_id=$(az network application-gateway show -g $rg -n $appgw_name --query id -o tsv) 2>/dev/null
     az monitor diagnostic-settings create -n mydiag --resource $appgw_id --workspace $wsid \
          --metrics '[{"category": "AllMetrics", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false }, "timeGrain": null}]' \
          --logs '[{"category": "ApplicationGatewayAccessLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}, 
                   {"category": "ApplicationGatewayPerformanceLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}, 
                   {"category": "ApplicationGatewayFirewallLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}]' >/dev/null
fi

# Connect route-table to kubenet cluster
# This should not be required any more !!!
if [ "$create_kubenet" == "yes" ]
then
     noderg_kubenet=$(az aks show -g $rg -n $aksname_kubenet --query nodeResourceGroup -o tsv) 2>/dev/null
     rtid=$(az network route-table list -g $noderg_kubenet --query [0].id -o tsv) 2>/dev/null
     az network vnet subnet update -g $rg --vnet-name $vnet -n $subnet_kubenet --route-table $rtid
fi

# Add Windows pool to Azure cluster if required
if [ "$windows" == "yes" ] && [ "$create_azure" == "yes" ]
then
     echo "Adding windows pool to cluster $aksname_azure..."
     az aks nodepool add -g $rg --cluster-name $aksname_azure --os-type Windows -n winnp -c 1 -k $k8sversion >/dev/null
fi

# Get credentials (first for kubenet, then for azure, in case both are deployed default will be azure cni)
if [ "$create_kubenet" == "yes" ]
then
     echo "Getting credentials for cluster $aksname_kubenet..."
     az aks get-credentials -g $rg -n $aksname_kubenet --overwrite
fi
if [ "$create_azure" == "yes" ]
then
     echo "Getting credentials for cluster $aksname_azure..."
     az aks get-credentials -g $rg -n $aksname_azure --overwrite
fi

# Set Azure identity for app gw
if [ "$create_appgw" == "yes" ]
then
     echo "Creating identity $appgw_identity_name in RG $noderg_azure..."
     noderg_azure=$(az aks show -g $rg -n $aksname_azure --query nodeResourceGroup -o tsv) 2>/dev/null
     az identity create -g $noderg_azure -n $appgw_identity_name  >/dev/null
     # echo "Waiting for $wait_interval for identity to propagate to AAD..."
     # sleep $wait_interval
     appgw_identity_id=$(az identity show -g $noderg_azure -n $appgw_identity_name --query id -o tsv) 2>/dev/null
     appgw_identity_clientid=$(az identity show -g $noderg_azure -n $appgw_identity_name --query clientId -o tsv) 2>/dev/null
     appgw_identity_principalid=$(az identity show -g $noderg_azure -n $appgw_identity_name --query principalId -o tsv) 2>/dev/null
     appgw_id=$(az network application-gateway show -g $rg -n $appgw_name --query id -o tsv) 2>/dev/null
     echo "Adding role Contributor for $appgw_identity_principalid to $appgw_id..."
     until az role assignment create --role Contributor --assignee $appgw_identity_principalid --scope $appgw_id >/dev/null
     do
          echo "There has been an error. Retrying in $wait_interval"
          sleep $wait_interval
     done
     assigned_role=$(az role assignment list -o tsv --query "[?principalId=='$appgw_identity_principalid' && scope=='$appgw_id'].roleDefinitionName")
     if [ "$assigned_role" == "Contributor" ]
     then
          echo "Role assigned successfully"
     else
          echo "It looks like it did not work..."
     fi
     rgid=$(az group show -n $rg --query id -o tsv) 2>/dev/null
     echo "Adding role Reader for $appgw_identity_principalid to $rgid..."
     az role assignment create --role Reader --assignee $appgw_identity_principalid --scope $rgid >/dev/null
     assigned_role=$(az role assignment list -o tsv --query "[?principalId=='$appgw_identity_principalid' && scope=='$rgid'].roleDefinitionName")
     if [ "$assigned_role" == "Reader" ]
     then
          echo "Role assigned successfully"
     else
          echo "It looks like it did not work..."
     fi
fi

# Install Pod Identity
if [ "$aks_rbac" == "yes" ]
then
     echo "Enabling pod identity for RBAC cluster..."
     kubectl create -f https://raw.githubusercontent.com/Azure/aad-pod-identity/master/deploy/infra/deployment-rbac.yaml >/dev/null
     # wget https://raw.githubusercontent.com/Azure/aad-pod-identity/master/deploy/demo/aadpodidentity.yaml -O aadpodidentity.yaml 2>/dev/null
     # sed -i "s|RESOURCE_ID|${appgw_identity_id}|g" aadpodidentity.yaml
     # sed -i "s|CLIENT_ID|${appgw_identity_clientid}|g" aadpodidentity.yaml
     # kubectl apply -f aadpodidentity.yaml
     # wget https://raw.githubusercontent.com/Azure/aad-pod-identity/master/deploy/demo/aadpodidentitybinding.yaml -o aadpodidentitybinding.yaml
else
     echo "Enabling pod identity for non-RBAC cluster..."
     kubectl create -f https://raw.githubusercontent.com/Azure/aad-pod-identity/master/deploy/infra/deployment.yaml >/dev/null
fi


# Enable Helm
if [ "$aks_rbac" == "yes" ]
then
     echo "Enabling Helm for RBAC cluster..."
     kubectl create serviceaccount --namespace kube-system tiller-sa >/dev/null
     kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller-sa >/dev/null
     helm init --tiller-namespace kube-system --service-account tiller-sa >/dev/null
else
     echo "Enabling Helm for non-RBAC cluster..."
     helm init >/dev/null
fi

# Add helm repo for App GW Ingress Controller
if [ "$create_appgw" == "yes" ]
then
     echo "Adding helm repos for AGIC..."
     helm repo add application-gateway-kubernetes-ingress https://appgwingress.blob.core.windows.net/ingress-azure-helm-package/ >/dev/null
     helm repo update >/dev/null
     echo "Installing helm chart for AGIC..."
     wget https://raw.githubusercontent.com/Azure/application-gateway-kubernetes-ingress/master/docs/examples/sample-helm-config.yaml -O helm-config.yaml 2>/dev/null
     sed -i "s|<subscriptionId>|${subid}|g" helm-config.yaml
     sed -i "s|<resourceGroupName>|${rg}|g" helm-config.yaml
     sed -i "s|<applicationGatewayName>|${appgw_name}|g" helm-config.yaml
     sed -i "s|<identityResourceId>|${appgw_identity_id}|g" helm-config.yaml
     sed -i "s|<identityClientId>|${appgw_identity_clientid}|g" helm-config.yaml
     master_ip=$(kubectl cluster-info | grep master | cut -d/ -f3 | cut -d: -f 1)
     sed -i "s|<aks-api-server-address>|${master_ip}|g" helm-config.yaml
     sed -i "s|enabled: false|enabled: true|g" helm-config.yaml
     helm install -f helm-config.yaml application-gateway-kubernetes-ingress/ingress-azure >/dev/null
fi

# Enable virtual node
if [ "$create_azure" == "yes" ] && [ "$create_vnode" == "yes" ]
then
     echo "Enabling Virtual Node add-on in cluster $aksname_azure..."
     az aks enable-addons -g $rg -n $aksname_azure --addons virtual-node --subnet-name $subnet_aci
fi

# If the ingress controller is not the app gateway, add the app routing addon to the Azure cluster or the kubenet cluster
if [ "$create_appgw" != "yes" ] && [ "$create_azure" == "yes"  ]
then
     az aks enable-addons -g $rg -n $aksname_azure --addons http_application_routing 2>/dev/null
fi
if [ "$create_appgw" != "yes" ] && [ "$create_kubenet" == "yes"  ]
then
     az aks enable-addons -g $rg -n $aksname_kubenet --addons http_application_routing 2>/dev/null
fi

# Deploy sample apps, depending of the scenario
echo "Installing sample apps..."
# If both azure cni and kubenet, default to azure cni
if [ "$create_azure" == "yes" ]
then
     aksname=$aksname_azure
else
     aksname=$aksname_kubenet
fi
# Identify if appgw or http app routing ingress controller
if [ "$create_appgw" == "yes" ]
then
     ingress_class=azure/application-gateway
     # Decide if using DNS zones or use nip.io
     zonename=$(az network dns zone list -o tsv --query "[?name=='$dnszone'].name")
     if [ "$zonename" == "$dnszone" ]
     then
          dnsrg=$(az network dns zone list -o tsv --query "[?name=='$dnszone'].resourceGroup")
          echo "Azure DNS zone $dnszone found in resource group $dnsrg"
          use_azure_dns=yes
     else
          echo "Azure DNS zone not found in subscription, using public nip.io"
          use_azure_dns=no
          zonename="$appgw_ip".nip.io
     fi
else
     use_azure_dns=no
     ingress_class=addon-http-application-routing
     zonename=$(az aks show -g $rg -n $aksname --query addonProfiles.httpApplicationRouting.config.HTTPApplicationRoutingZoneName -o tsv)
fi

# kuard, port 8080
sample_filename=sample-kuard-ingress.yaml
wget https://raw.githubusercontent.com/erjosito/deploy-aks/master/samples/kuard-ingress.yaml -O $sample_filename 2>/dev/null
app_fqdn=kuard.$zonename
sed -i "s|<host_fqdn>|${app_fqdn}|g" $sample_filename
sed -i "s|<ingress_class>|${ingress_class}|g" $sample_filename
kubectl apply -f $sample_filename >/dev/null
if [ "$use_azure_dns" == "yes" ]
then
     echo "Adding DNS name $app_fqdn for public IP $appgw_ip..."
     az network dns record-set a create -g $dnsrg -z $dnszone -n $app_dnsname >/dev/null
     az network dns record-set a add-record -g $dnsrg -z $dnszone -n $app_dnsname -a $appgw_ip >/dev/null
else
     appgw_fqdn=$(az network public-ip show -g $rg -n $appgw_pipname --query dnsSettings.fqdn -o tsv)
fi
echo "You can access the sample kuard on ${app_fqdn}"

# sample aspnet app, port 80
sample_filename=sample-aspnet-ingress.yaml
wget https://raw.githubusercontent.com/erjosito/deploy-aks/master/samples/aspnet-ingress.yaml -O $sample_filename 2>/dev/null 
app_fqdn=aspnet.$zonename
sed -i "s|<host_fqdn>|${app_fqdn}|g" $sample_filename
sed -i "s|<ingress_class>|${ingress_class}|g" $sample_filename
kubectl apply -f $sample_filename >/dev/null
if [ "$use_azure_dns" == "yes" ]
then
     echo "Adding DNS name $app_fqdn for public IP $appgw_ip..."
     az network dns record-set a create -g $dnsrg -z $dnszone -n $app_dnsname >/dev/null
     az network dns record-set a add-record -g $dnsrg -z $dnszone -n $app_dnsname -a $appgw_ip >/dev/null
else
     appgw_fqdn=$(az network public-ip show -g $rg -n $appgw_pipname --query dnsSettings.fqdn -o tsv)
fi
echo "You can access the sample aspnet app on ${app_fqdn}"

# Print info to connect to test VM
if [ "$create_vm" == "yes" ]
then
     echo "To connect to the test VM (or use it as jump host for the k8s nodes):"
     echo "  ssh $public_ip" 
fi

