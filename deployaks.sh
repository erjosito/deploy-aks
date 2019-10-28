#!/bin/bash

###############################################################
# To Do:
# - AzFw (ongoing)
# - linkerd
# - Traffic Manager (ongoing)
# - AKS egress filtering
# - AKS control plane ingress filtering
# - Storage & private link
# - Verify creating new AKV and new log analytics ws
# - nginx ingress controller
# - separate subnet for ALB frontend IPs
###############################################################

# Check requirements
echo "Checking script dependencies..."
requirements=(az jq kubectl helm)
for req in ${requirements[@]}
do
     if [ -z $(which $req) ]
     then
          echo "Please install $req to run this script"
          return
     else
          echo "- $req executable found in $(which $req)"
     fi
done

# Loading values for variables from a config file
source ./deployaks_variables.sh

# Defaults
help=no
vnetpeering=no
create_appgw=no
create_azfw=no
flexvol=no
deploy_pod_identity=no
enable_approuting_addon=no
lb_outbound_rules=no
lb_sku_basic=no
lb_type=external
ilpip=no
create_db=no
create_vm=no
network_plugin=azure
deploy_linkerd=no

# Argument parsing (can overwrite the previously initialized variables)
for i in "$@"
do
     case $i in
          -g=*|--resource-group=*)
               rg="${i#*=}"
               shift # past argument=value
               ;;
          -l=*|--location=*)
               location="${i#*=}"
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
          -n=*|--network=*)
               network_plugin="${i#*=}"
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
          --azfw)
               create_azfw=yes
               shift # past argument with no value
               ;;
          --app-routing)
               enable_approuting_addon=yes
               shift # past argument with no value
               ;;
          --virtual-node)
               create_vnode=yes
               shift # past argument with no value
               ;;
          --flexvol|-f)
               flexvol=yes
               shift # past argument with no value
               ;;
          --aad-pod-identity)
               deploy_pod_identity=yes
               shift # past argument with no value
               ;;
          --db)
               create_db=yes
               shift # past argument with no value
               ;;
          --db-location=*)
               sql_server_location="${i#*=}"
               shift # past argument=value
               ;;
          --lb-outbound-rules)
               lb_outbound_rules=yes
               shift # past argument with no value
               ;;
          --lb-basic)
               lb_sku_basic=yes
               shift # past argument with no value
               ;;
          --ilb)
               lb_type=internal
               shift # past argument with no value
               ;;
          --no-vmss)
               no_vmss=yes
               shift # past argument with no value
               ;;
          --ilpip)
               ilpip=yes
               shift # past argument with no value
               ;;
          --helm)
               enable_helm=yes
               shift # past argument with no value
               ;;
          --extra-nodepool)
               deploy_extra_nodepool=yes
               shift # past argument with no value
               ;;
          --linkerd)
               deploy_linkerd=yes
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

# If the --help flag was issued, show help message and stop right here
if [ "$help" == "yes" ]
then
     if [[ "${BASH_SOURCE[0]}" != "${0}" ]]
     then
          #echo "This script seems to be sourced..."
          script_name="${BASH_SOURCE[0]}"
     else
          script_name=$0
     fi
     echo "Please run this script as \"$script_name [--network-plugin=kubenet|azure] [--resource-group=yourrg] [--location=yourlocation(s)]
         [--kubernetes-version=x.x.x] [--vm]
         [--network-policy=azure|calico|none] [--vnet-peering] [--azfw]
         [--windows] [--appgw] [--app-routing] [--helm]
         [--db] [--db-location]
         [--lb-outbound-rules] [--lb-basic] [--no-vmss] [--ilpip]
         [--extra-nodepool] [--linkerd]
         [--virtual-node] [--flexvol] [--aad-pod-identity]\""
     echo " -> Example: \"$script_name -n=azure -p=azure -g=akstest\""
     # Return if the script is sourced, exit if it is not
     #read -p "Press enter to continue"
     if [[ "${BASH_SOURCE[0]}" != "${0}" ]]
     then
          return
     else
          exit
     fi
fi

# Identify if more than one location (comma-separated) was supplied
IFS=',' read -r -a location_list <<< "$location"
number_of_clusters=${#location_list[@]}
if (( "$number_of_clusters" > 1 ))
then
     echo "It looks like you are trying to create $number_of_clusters clusters in $location"
else
     echo "Starting deployment of $number_of_clusters cluster in ${location_list[0]}"
fi

# Default to azure network policy
if [ "$nwpolicy" != "calico" ]
then
     nwpolicy="azure"
fi

# Default to azure CNI plugin
if [ "$network_plugin" != "kubenet" ]
then
     network_plugin=azure
fi

# Default to standard ALB
if [ "$lb_sku_basic" == "yes" ]
then
     lb_sku=basic
else
     lb_sku=standard
fi

# AzFW not compatible with app gateway
if [ "$create_appgw" == "yes" ] && [ "$create_azfw" == "yes" ]
then
     echo "The app gateway subnet does not take UDRs today, so it is not compatible with NVAs or the Azure Firewall. No Azure Firewall will be created"
     create_azfw=no
fi


# Function to remove non-printable characters from a string
function RemoveNonPrintable {
     result=$(echo $1 | tr -cd '[[:print:]]\n')
     echo $result
}

# Message on subscription
echo 'Getting information about Azure subscription...'
subname=$(az account show --query name -o tsv) 2>/dev/null
subid=$(az account show --query id -o tsv) 2>/dev/null
tenantid=$(az account show --query tenantId -o tsv) 2>/dev/null
echo "Working on subscription $subname ($subid) in tenant $tenantid"

# Create resource group in (first) location
rg_location=$(RemoveNonPrintable ${location_list[0]})
echo "Creating resource group $rg in $rg_location..."
az group create -n $rg -l $rg_location >/dev/null

# Get stuff from key vault
echo "Retrieving secrets from Azure Key Vault $keyvaultname..."
get_kvname=$(az keyvault list -o tsv --query "[?name=='$keyvaultname'].name")
if [ "$get_kvname" == "$keyvaultname" ]
then
     sshpublickey=$(az keyvault secret show -n surfaceSshPublicKey --vault-name $keyvaultname --query value -o tsv)
     default_password=$(az keyvault secret show -n defaultPassword --vault-name $keyvaultname --query value -o tsv)
     appid=$(az keyvault secret show -n aks-app-id --vault-name $keyvaultname --query value -o tsv)
     appsecret=$(az keyvault secret show -n aks-app-secret --vault-name $keyvaultname --query value -o tsv)
     echo "Got ssh public key and secret for sp $appid from Key Vault $keyvaultname"
else
     echo "Key Vault $keyvaultname not found! A keyvault with SSH public strings and AAS SP data is required."
     keyvault_rg_id=$(az group show -n $keyvault_rg -o tsv --query id 2>/dev/null)
     if [ -z "$keyvault_rg_id" ]
     then
          echo "Creating resource group $keyvault_rg in $rg_location..."
          az group create -n $keyvault_rg -l $rg_location >/dev/null
     fi
     echo "Creating Azure Key Vault $keyvaultname in resource group $keyvault_rg..."
     az keyvault create -n $keyvaultname -g $keyvault_rg >/dev/null
     # Creating service principal
     echo "Creating new service principal..."
     sp_json=$(az ad sp create-for-rbac --skip-assignment)
     appid=$(echo $sp_json | jq -r '.appId')
     az keyvault secret set -n aks-app-id --value $appid --vault-name $keyvaultname >/dev/null
     appsecret=$(echo $sp_json | jq -r '.password')
     az keyvault secret set -n aks-app-secret --value $appsecret --vault-name $keyvaultname >/dev/null
     echo "Assigning permissions to new service principal..."
     rgid=$(az group show -n $rg -o tsv --query id)
     echo "Assigning permissions to new app ID $appid..."
     until az role assignment create --assignee $appid --scope $rgid --role Contributor
     do
          echo "There has been an error. Retrying in $wait_interval"
          sleep $wait_interval
     done
     # Get SSH public key
     sshpublickey_filename='~/.ssh/id_rsa.pub'
     if [ -f "$sshpublickey_filename" ]
     then
          sshpublickey=$(cat $sshpublickey_filename)
          az keyvault secret set -n surfaceSshPublicKey --value $sshpublickey --vault-name $keyvaultname >/dev/null
     else
          echo "SSH public key file $sshpublickey_filename not found. Exiting..."
          # Return if the script is sourced, exit if it is not
          if [[ "${BASH_SOURCE[0]}" != "${0}" ]]
          then
               return
          else
               exit
          fi
     fi
     # Generate default password
     echo "Generating default password and storing it in key vault..."
     default_password=$(cat /dev/urandom | tr -dc a-zA-Z0-9 | fold -w 14 | head -n 1)
     az keyvault secret set -n defaultPassword --value $default_password --vault-name $keyvaultname >/dev/null
fi

# Get monitoring workspace
echo "Getting workspace ID for monitoring for workspace $monitor_ws in resource group $monitor_rg..."
wsid=$(az resource list -g $monitor_rg -n $monitor_ws --query [].id -o tsv)
if [[ -z "$wsid" ]]
then
     echo "Could not find log analytics workspace $monitor_ws in resource group $monitor_rg. Creating now..."
     # Verify if RG exists
     monitor_rg_id=$(az group show -n $monitor_rg --query id -o tsv 2>/dev/null)
     if [[ -z "$monitor_rg_id" ]]
     then
          echo "Creating resource group $monitor_rg in $rg_location..."
          az group create -n $monitor_rg -l $rg_location >/dev/null
     fi
     # Deploy ARM template
     echo "Creating Azure Monitor workspace $monitor_ws in resource group $monitor_rg..."
     template_url=https://raw.githubusercontent.com/erjosito/deploy-aks/master/arm/log_workspace.json
     az group deployment create -n aksdeployment -g $monitor_rg --template-uri $template_url --parameters '{
          "workspaceName": {"value": "'$monitor_ws'"},
          "location": {"value": "'$rg_location'"}}' >/dev/null
     # Retrieve ID of newly created workspace
     wsid=$(az resource list -g $monitor_rg -n $monitor_ws --query [].id -o tsv)
     echo "ID for new workspace is $wsid"
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
     az acr create -n $acr_name -g $acr_rg --sku Standard -l $rg_location 2>/dev/null
     acr_id=$(az acr show -n erjositoAcr -g $acr_rg --query id -o tsv)
     echo "ID for new ACR $acr_name is $acr_id"
fi

# Use a k8s version from the args, or get last supported k8s version. 'latest' keyword supported
if [[ -z "$k8sversion" ]] || [[ "$k8sversion" == "latest" ]]
then
     echo 'Getting latest supported k8s version...'
     k8sversion=$(az aks get-versions -l $rg_location -o tsv --query orchestrators[-1].orchestratorVersion)
     # Filter for non-preview?
     # k8sversion=$(az aks get-versions -l $rg_location -o tsv --query [?orchestrators.isPreview==false].orchestratorVersion)
     echo "Latest supported k8s version in $rg_location is $k8sversion"
else
     echo "Using k8s version $k8sversion"
fi

# Create vnet in each location
for this_location in "${location_list[@]}"
do
     this_vnet_name="$vnet"-"$this_location"
     echo "Creating vnet $this_vnet_name in $this_location..."
     az network vnet create -g $rg -n $this_vnet_name --address-prefix $vnetprefix -l $this_location >/dev/null

     # Create peered vnet (if specified in the options)
     if [ "$vnetpeering" == "yes" ]
     then
          $peer_vnet_name="$peervnet"-"$this_location"
          peer_vnet_location=$this_location
          echo "Creating vnet $peer_vnet_name to peer in $peer_vnet_location..."
          az network vnet create -g $rg -n $peer_vnet_name --address-prefix $peer_vnet_prefix -l $peer_vnet_location >/dev/null
          az network vnet peering create -g $rg -n AKSToPeer --vnet-name $this_vnet_name --remote-vnet $peer_vnet_name --allow-vnet-access     
          az network vnet peering create -g $rg -n PeerToAKS --vnet-name $peer_vnet_name --remote-vnet $this_vnet_name --allow-vnet-access     
     fi

     # Create subnet for ACI (virtual node)
     if [ "$create_vnode" == "yes" ]
     then
          echo "Creating subnet for AKS virtual node (ACI) in $this_location..."
          az network vnet subnet create -g $rg -n $subnet_aci --vnet-name $this_vnet_name --address-prefix $aci_subnet_prefix >/dev/null
     fi

done

# Define vmss options
if [ "$no_vmss" == "yes" ]
then
     echo "Using no VMSS or AZ options..."
     vmss_options=""
     # vmss_options="--vm-set-type AvailabilitySet"
else
     if [ "$lb_sku_basic" == "yes" ]
     then
          echo "Using VMSS option, no AZs..."
          vmss_options="--enable-vmss --nodepool-name pool1"
     else
          echo "Using VMSS option and deploying to AZs 1, 2 and 3..."
          vmss_options="--enable-vmss --node-zones 1 2 3 --nodepool-name pool1"
     fi
fi

# Define additional windows options
if [ "$windows" == "yes" ]
then
     windows_options="--windows-admin-password "$default_password" --windows-admin-username $adminuser"
fi

# Override some values that are not supported by kubenet
if [ "$network_plugin" == "kubenet" ]
then
     if [ "$windows" == "yes" ]
     then
          echo "Windows pools not supported by kubenet clusters"
          windows=no
          windows_options=""
     fi
     if [ "$create_appgw" == "yes" ]
     then
          echo "The app gateway ingress controller is not supported by kubenet clusters"
          create_appgw=no
     fi
     if [ "$nwpolicy" == "calico" ] || [ "$nwpolicy" == "azure" ]
     then
          echo "Kubernetes network policy is not supported by kubenet clusters"
          nwpolicy=""
     fi

fi

# Create AKS cluster(s)

# Create vnet in each location
for this_location in "${location_list[@]}"
do
     this_vnet_name="$vnet"-"$this_location"
     this_aksname="$aksname"-"$this_location"
     this_vm_name="$vm_name"-"$this_location"
     this_appgw_name="$appgw_name"-"$this_location"
     this_appgw_dnsname="$this_appgw_name""$RANDOM"
     this_appgw_pipname="$appgw_pipname"-"$this_location"
     this_azfw_name="$azfw_name"-"$this_location"
     this_azfw_pipname="$azfw_pipname"-"$this_location"

     # Subnet
     echo "Creating subnet for AKS cluster in $this_location..."
     az network vnet subnet create -g $rg -n $aks_subnet_name --vnet-name $this_vnet_name --address-prefix $aks_subnet_prefix >/dev/null
     az network vnet subnet create -g $rg -n $akslb_subnet_name --vnet-name $this_vnet_name --address-prefix $akslb_subnet_prefix >/dev/null
     subnetid=$(az network vnet subnet show -g $rg --vnet-name $this_vnet_name -n $aks_subnet_name --query id -o tsv)
     echo "The AKS subnet ID is $subnetid"
     # Cluster
     echo "Creating AKS cluster $this_aksname in resource group $rg..."
     az aks create -g $rg -n $this_aksname -c 1 -s $vmsize -k $k8sversion \
          --service-principal $appid --client-secret $appsecret \
          --admin-username $adminuser --ssh-key-value "$sshpublickey" \
          --network-plugin $network_plugin --vnet-subnet-id $subnetid \
          --enable-addons monitoring --workspace-resource-id $wsid \
          --network-policy "$nwpolicy" \
          $vmss_options \
          $windows_options \
          --attach-acr "$acr_id" \
          --load-balancer-sku $lb_sku \
          --node-resource-group "$this_aksname"-iaas-"$RANDOM" \
          --tags "$tag1_name"="$tag1_value" \
          --no-wait
     echo ""

     # Create Application Gateway
     if [ "$create_appgw" == "yes" ] && [ "$network_plugin" == "azure" ]
     then
          # Create App Gw subnet
          echo 'Creating subnet for application gateway...'
          az network vnet subnet create -g $rg -n $appgw_subnetname --vnet-name $this_vnet_name --address-prefix $appgw_subnetprefix >/dev/null
          # Create public IP
          echo "Creating public IP address $this_appgw_pipname for application gateway..."
          az network public-ip create -g $rg -n $this_appgw_pipname --sku Standard --dns-name $this_appgw_dnsname -l $this_location >/dev/null
          appgw_ip=$(az network public-ip show -g $rg -n $this_appgw_pipname --query ipAddress -o tsv)
          # Create App Gw
          echo "Creating app gateway $this_appgw_name..."
          az network application-gateway create -g $rg -n $this_appgw_name -l $this_location \
                    --capacity 2 --sku $appgw_sku --frontend-port 80 \
                    --routing-rule-type basic --http-settings-port 80 \
                    --http-settings-protocol Http --public-ip-address $this_appgw_pipname \
                    --vnet-name $this_vnet_name --subnet $appgw_subnetname \
                    --servers "dummy.abc.com" --no-wait
     fi

     # Create Azure Firewall
     if [ "$create_azfw" == "yes" ]
     then
          # Create AzFW subnet
          echo 'Creating subnet for Azure Firewall...'
          az network vnet subnet create -g $rg -n AzureFirewallSubnet --vnet-name $this_vnet_name --address-prefix $azfw_subnet_prefix >/dev/null
          # Create public IP
          echo "Creating public IP address $this_azfw_pipname for Azure Firewall..."
          az network public-ip create -g $rg -n $this_azfw_pipname --sku standard --allocation-method static -l $this_location >/dev/null
          azfw_ip=$(az network public-ip show -g $rg -n $this_azfw_pipname --query ipAddress -o tsv)
          # Create Azure Firewall
          echo "Creating Azure Firewall $this_azfw_name in $this_location"
          az network firewall create -n $this_azfw_name -g $rg -l $this_location >/dev/null
          az network firewall ip-config create -f $this_azfw_name -n azfw-ipconfig -g $rg --public-ip-address $this_azfw_pipname --vnet-name $this_vnet_name >/dev/null
          echo "Updating IP configuration for firewall $this_azfw_name..."
          az network firewall update -n $this_azfw_name -g $rg >/dev/null
          azfw_private_ip=$(az network firewall show -n $this_azfw_name -g $rg -o tsv --query ipConfigurations[0].privateIpAddress)
          azfw_id=$(az network firewall show -n $this_azfw_name -g $rg -o tsv --query id)
          echo "Azure Firewall $azfw_id created with public IP $azfw_ip and private IP $azfw_private_ip"
          # Rules
          echo "Adding sample rules to Azure Firewall..."
          az network firewall application-rule create -f $this_azfw_name -g $rg -c All-egress \
             --protocols Http=80 Https=443 --target-fqdns ifconfig.co --source-addresses $vnetprefix \
             -n Allow-ifconfig --priority 200 --action Allow >/dev/null
          az network firewall network-rule create -f $this_azfw_name -g $rg -c VM-to-AKS \
             --protocols Any --destination-addresses $aks_subnet_prefix --destination-ports '*' --source-addresses $vm_subnet_prefix \
             -n Allow-VM-to-AKS --priority 200 --action Allow >/dev/null
          # AKS egress rules (https://docs.microsoft.com/en-us/azure/aks/limit-egress-traffic)
          az network firewall application-rule create -f $this_azfw_name -g $rg -c AKS-egress \
             --protocols Http=80 Https=443 --target-fqdns ifconfig.co --source-addresses $aks_subnet_prefix \
             -n Allow-ifconfig --priority 200 --action Allow >/dev/null
     fi

     # Test VM
     # It is not created in --no-wait mode, since probably we need to wait for the creation of the AKS cluster any way....
     if [ "$create_vm" == "yes" ]
     then
          echo 'Creating subnet for test VM...'
          az network vnet subnet create -g $rg -n $subnet_vm --vnet-name $this_vnet_name --address-prefix $vm_subnet_prefix >/dev/null
          echo 'Creating NSG for test VM...'
          az network nsg create -n "$this_vm_name"-nsg -g $rg -l $this_location >/dev/null
          # Get the ipv4 public IP
          my_ip=$(curl -s4 ifconfig.co)
          echo Adding our public IP "$my_ip" to the NSG...
          # Add NSG rule
          az network nsg rule create -g $rg --nsg-name $this_vm_name-nsg -n SSHfromHome --priority 500 --source-address-prefixes $my_ip/32 --destination-port-ranges 22 --destination-address-prefixes '*' --access Allow --protocol Tcp --description "Allow SSH from home" >/dev/null
          # Create VM
          echo "Creating test VM $this_vm_name..."
          start_time=`date +%s`
          az vm create --image $vm_image -g $rg -n $vm_name --authentication-type ssh --ssh-key-value "$sshpublickey" \
                       --public-ip-address "$this_vm_name"-pip --vnet-name $this_vnet_name --subnet $subnet_vm \
                       --os-disk-size 30 --storage-sku "Standard_LRS" --nsg "$this_vm_name"-nsg -l $this_location >/dev/null
          echo VM time creation was $(expr `date +%s` - $start_time) s
          public_ip=$(az network public-ip show -n "$this_vm_name"-pip -g $rg --query ipAddress -o tsv)
          # If an Azure Firewall has been created, send traffic to it via UDR
          if [ "$create_azfw" == "yes" ]
          then
               az network route-table create -n "$this_vm_name"-rt -g $rg -l $this_location >/dev/null
               vm_rt_id=$(az network route-table show -n "$this_vm_name"-rt -o tsv --query id 2>/dev/null)
               if [ -z "$vm_rt_id" ]
               then
                    echo "Updating subnet $subnet_vm in vnet $this_vnet_name with route table $vm_rt_id"
                    az network vnet subnet update -g $rg --vnet-name $this_vnet_name -n $subnet_vm --route-table $vm_rt_id >/dev/null
                    az network route-table route create -n vnet --route-table-name "$this_vm_name"-rt -g $rg --next-hop-type VirtualAppliance \
                         --address-prefix $vnetprefix --next-hop-ip-address $azfw_private_ip >/dev/null
               else
                    echo "Error when creating route-table "$this_vm_name"-rt"
               fi
          fi
     fi

done


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
               # Return if the script is sourced, exit if it is not
               if [[ "${BASH_SOURCE[0]}" != "${0}" ]]
               then
                    return
               else
                    exit
               fi
          fi
     fi
}

# Create a key vault in the RG for the apps in the AKS cluster
if [ "flexvol" == "yes" ]
then
     # AKV and secret
     echo "Creating AKV in resource group $rg"
     flexvol_kv_name=flexvol$RANDOM
     az keyvault create -n $flexvol_kv_name -g $rg -l $rg_location >/dev/null
     flexvol_kv_id=$(az keyvault show -n $flexvol_kv_name -g $rg -o tsv --query id) 2>/dev/null
     echo "Key Vault $flexvol_kv_id created"
     flexvol_secret_name=flexvoltest
     flexvol_secret_value=helloworld!
     echo "Creating example secret in keyvault $flexvol_kv_name with value $flexvol_secret_value..."
     az keyvault secret set -n $flexvol_secret_name --value $flexvol_secret_value --vault-name $flexvol_kv_name >/dev/null
fi

# Wait for resource creation to finish
# Create vnet in each location
for this_location in "${location_list[@]}"
do
     this_aksname="$aksname"-"$this_location"
     this_vnet_name="$vnet"-"$this_location"
     this_aks_rt_name="$aks_rt_name"-"$this_location"
     this_appgw_name="$appgw_name"-"$this_location"
     this_pip1_name="$pip1_name"-"$this_location"
     this_pip2_name="$pip2_name"-"$this_location"
     this_appgw_identity_name="$appgw_identity_name"-"$this_location"
     this_flexvol_id_name="$flexvol_kv_name"-"$this_location"

     # AKS cluster
     resource_id=$(az aks show -n $this_aksname -g $rg --query id -o tsv)
     WaitUntilFinished $resource_id

     # If required, create outbound rules in the aks cluster
     if [ "$lb_outbound_rules" == "yes" ]
     then
          # Create Public IPs for egress
          echo 'Creating public IP addresses for outbound traffic...'
          az network public-ip create -g $rg -n $this_pip1_name --sku standard >/dev/null
          az network public-ip create -g $rg -n $this_pip2_name --sku standard >/dev/null
          pip1_id=$(az network public-ip show -g $rg -n $this_pip1_name --query id -o tsv)
          pip2_id=$(az network public-ip show -g $rg -n $this_pip2_name --query id -o tsv)
          pip1_ip=$(az network public-ip show -g $rg -n $this_pip1_name --query ipAddress -o tsv)
          pip2_ip=$(az network public-ip show -g $rg -n $this_pip2_name --query ipAddress -o tsv)
          echo "Created IP addresses: $pip1_ip and $pip2_ip"
          # Update cluster
          echo 'Updating cluster to use public IP addresses for egress...'
          az aks update -n $this_aksname -g $rg --load-balancer-outbound-ips "$pip1_id","$pip2_id" 
     else
          echo "No public IP addresses to create for cluster $this_aksname"
     fi

     # Extra node pool
     if [ "$create_extra_nodepool" == "yes" ]
     then
          echo "Creating extra node pool..."
          az network vnet subnet create -g $rg -n $arm_subnet_name --vnet-name $this_vnet_name --address-prefix $arm_subnet_prefix >/dev/null
          arm_subnet_id=$(az network vnet subnet show -g $rg --vnet-name $this_vnet_name -n $arm_subnet_name --query id -o tsv)
          template_url=https://raw.githubusercontent.com/erjosito/deploy-aks/master/arm/aks-nodepool.json
          if [ $ilpip == "yes" ]
          then
               enable_node_pip=true
          else
               enable_node_pip=false
          fi
          az group deployment create -n aksdeployment -g $rg --template-uri $template_url --parameters '{
               "clusterName": {"value": "'$this_aksname'"},
               "location": {"value": "'$this_location'"},
               "agentPoolName": {"value": "'$arm_nodepool_name'"},
               "orchestratorVersion": {"value": "'$k8sversion'"},
               "vnetSubnetId": {"value": "'$arm_subnet_id'"},
               "enableNodePublicIp": {"value": '$enable_node_pip'}}'
     else
          echo "No additional node pool to create for cluster $this_aksname"
     fi

     # ILPIP for VMSS-based pools (load balancer needs to be Basic)
     # THis is not recommended, hence the danger_zone check in the next line
     if [ "$no_vmss" != "yes" ] && [ "$ilpip" == "yes" ] && [ "$lb_sku_basic" == "yes" ] && [ "$danger_zone" == "yes" ]
     then
          echo "Adding instance-level public IP addresses to the VMSS..."
          noderg=$(az aks show -g $rg -n $this_aksname --query nodeResourceGroup -o tsv) 2>/dev/null
          vmss_name=$(az vmss list -g $noderg --query [0].name -o tsv)
          az vmss update -n $vmss_name -g $noderg --set virtualMachineProfile.networkProfile.networkInterfaceConfigurations[0].ipConfigurations[0].publicIpAddressConfiguration='{"name": "aksnodepip", "properties": {"idleTimeoutInMinutes": 15}}'
          az vmss update-instances -n $vmss_name -g $noderg --instance-ids "*"
          echo "Public IP addresses configured: "
          az vmss list-instance-public-ips -n $vmss_name -g $noderg -o table 2>/dev/null
     else
          echo "No modification to do in VMSS for cluster $this_aksname"
     fi

     # Wait for app gw to finish
     if [ "$create_appgw" == "yes" ]
     then
          appgw_id=$(az network application-gateway show -n $this_appgw_name -g $rg --query id -o tsv)
          WaitUntilFinished $appgw_id
     else
          echo "No need to wait for app gw to finish creating for cluster $this_aksname"
     fi

     # Enable diagnostics to log analytics for the App Gw
     if [ "$create_appgw" == "yes" ]
     then
          echo "Enabling logging for app gateway to log analytics workspace $monitor_ws..."
          az monitor diagnostic-settings create -n mydiag --resource $appgw_id --workspace $wsid \
               --metrics '[{"category": "AllMetrics", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false }, "timeGrain": null}]' \
               --logs '[{"category": "ApplicationGatewayAccessLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}, 
                    {"category": "ApplicationGatewayPerformanceLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}, 
                    {"category": "ApplicationGatewayFirewallLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}]' >/dev/null
     else
          echo "No app gw to configure diagnostic settings for cluster $this_aksname"
     fi

     # Enable autoscaling for app gateway to reduce costs
     if [ "$create_appgw" == "yes" ]
     then
          echo "Enabling auto-scaling for app gateway to log analytics workspace $monitor_ws..."
          az network application-gateway update -n $this_appgw_name -g $rg \
               --set autoscaleConfiguration='{"minCapacity": 1, "maxCapacity": 2}' \
               --set sku='{"name": "Standard_v2","tier": "Standard_v2"}' >/dev/null
     else
          echo "No app gw to configure autoscaling for cluster $this_aksname"
     fi

     # Connect route-table to AKS cluster
     noderg=$(az aks show -g $rg -n $this_aksname --query nodeResourceGroup -o tsv) 2>/dev/null
     # Look for an existing route table (there should be one for kubenet clusters)
     aks_rt_id=$(az network route-table list -g $noderg --query [0].id -o tsv) 2>/dev/null
     # If none is found, create one
     if [ -z "$aks_rt_id" ]
     then
          echo "Creating route table $this_aks_rt_name..."
          az network route-table create -n $this_aks_rt_name -g $noderg -l $this_location >/dev/null
          aks_rt_id=$(az network route-table show -n $this_aks_rt_name -g $rg -o tsv --query id)
     else
          echo "Found existing route table $aks_rt_id"
     fi
     # See if it is already associated to the aks subnet
     associated_rt_id=$(az network vnet subnet show --vnet-name $this_vnet_name -g $rg -n $aks_subnet_name -o tsv --query routeTable)
     # If no route table associated, associate the route table (either the one found, or the newly created one)
     if [ -z "$associated_rt_id" ]
     then
          echo "Associating AKS subnet $aks_subnet_name with route table $aks_rt_id..."
          az network vnet subnet update -g $rg --vnet-name $this_vnet_name -n $aks_subnet_name --route-table $aks_rt_id >/dev/null
     else
          echo "AKS subnet $aks_subnet_name already associated to route table $associated_rt_id"
     fi
     # Send vnet traffic to the firewall
     if [ "$create_azfw" == "yes" ]
     then
          # Find out the name (we only had the ID) and add the route
          aks_rt_name=$(az network route-table list -g $noderg --query [0].name -o tsv) 2>/dev/null
          az network route-table route create -n vnet --route-table-name $aks_rt_name -g $noderg --next-hop-type VirtualAppliance \
                    --address-prefix $vnetprefix --next-hop-ip-address $azfw_private_ip >/dev/null
     fi


     # Add Windows pool to AKS cluster if required
     if [ "$windows" == "yes" ]
     then
          echo "Adding windows pool to cluster $this_aksname..."
          az aks nodepool add -g $rg --cluster-name $this_aksname --os-type Windows -n winnp -c 1 -k $k8sversion >/dev/null
     else
          echo "No windows node pool to add for cluster $this_aksname"
     fi

     # Get credentials 
     echo "Getting credentials for cluster $this_aksname..."
     az aks get-credentials -g $rg -n $this_aksname --overwrite

     # Linkerd
     if [ "$deploy_linkerd" == "yes" ]
     then
          echo "Verifying presence of linkerd client in the system..."
          linkerd_client_path=$(which linkerd)
          if [ -z "$linkerd_client_path" ]
          then
               echo "Please install the linkerd client utility in order to deploy linkerd. Try running 'curl -sL https://run.linkerd.io/install | sh'"
               if [[ "${BASH_SOURCE[0]}" != "${0}" ]]
               then
                    return
               else
                    exit
               fi
          else
               echo "linkerd client found in $linkerd_client_path"
          fi
          echo "Checking linkerd pre-requisites..."
          linkerd check --pre
          echo "Installing linkerd..."
          linkerd install | kubectl apply -f -
          # Other installation modes (see https://linkerd.io/2/reference/cli/install/):
          # linkerd install --proxy-auto-inject | kubectl apply -f -
          # linkerd install --proxy-cpu-request 100m --proxy-memory-request 50Mi | kubectl apply -f -
     fi


     # Set Azure identity for app gw
     if [ "$create_appgw" == "yes" ]
     then
          noderg=$(az aks show -g $rg -n $this_aksname --query nodeResourceGroup -o tsv) 2>/dev/null
          echo "Creating identity $this_appgw_identity_name in RG $noderg..."
          az identity create -g $noderg -n $this_appgw_identity_name  >/dev/null
          appgw_identity_id=$(az identity show -g $noderg -n $this_appgw_identity_name --query id -o tsv) 2>/dev/null
          appgw_identity_clientid=$(az identity show -g $noderg -n $this_appgw_identity_name --query clientId -o tsv) 2>/dev/null
          appgw_identity_principalid=$(az identity show -g $noderg -n $this_appgw_identity_name --query principalId -o tsv) 2>/dev/null
          appgw_id=$(az network application-gateway show -g $rg -n $this_appgw_name --query id -o tsv) 2>/dev/null
          echo "Adding role Contributor for $appgw_identity_principalid to $appgw_id..."
          until az role assignment create --role Contributor --assignee $appgw_identity_principalid --scope $appgw_id >/dev/null
          do
               echo "There has been an error. Retrying in $wait_interval"
               sleep $wait_interval
          done
          assigned_role=$(az role assignment list --scope $appgw_id -o tsv --query "[?principalId=='$appgw_identity_principalid'].roleDefinitionName")
          if [ "$assigned_role" == "Contributor" ]
          then
               echo "Role assigned successfully"
          else
               echo "It looks like the role assignment did not work!"
          fi
          rgid=$(az group show -n $rg --query id -o tsv) 2>/dev/null
          echo "Adding role Reader for $appgw_identity_principalid to $rgid..."
          az role assignment create --role Reader --assignee $appgw_identity_principalid --scope $rgid >/dev/null
          assigned_role=$(az role assignment list --scope $rgid -o tsv --query "[?principalId=='$appgw_identity_principalid'].roleDefinitionName")
          if [ "$assigned_role" == "Reader" ]
          then
               echo "Role assigned successfully"
          else
               echo "It looks like the role assignment did not work!"
          fi
     fi

     # Install Pod Identity
     if [ "$create_appgw" == "yes" ] || [ "$flexvol" == "yes" ] || [ "$deploy_pod_identity" == "yes" ]
     then
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
     fi

     # Enable Helm
     if [ "$enable_helm" == "yes" ] || [ "$create_appgw" == "yes" ] 
     then
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
          sed -i "s|<applicationGatewayName>|${this_appgw_name}|g" helm-config.yaml
          sed -i "s|<identityResourceId>|${appgw_identity_id}|g" helm-config.yaml
          sed -i "s|<identityClientId>|${appgw_identity_clientid}|g" helm-config.yaml
          master_ip=$(kubectl cluster-info | grep master | cut -d/ -f3 | cut -d: -f 1)
          sed -i "s|<aks-api-server-address>|${master_ip}|g" helm-config.yaml
          sed -i "s|enabled: false|enabled: true|g" helm-config.yaml
          helm install -f helm-config.yaml application-gateway-kubernetes-ingress/ingress-azure >/dev/null
     fi

     # Enable virtual node (verify that CNI plugin is Azure?)
     if [ "$create_vnode" == "yes" ]
     then
          echo "Enabling Virtual Node add-on in cluster $this_aksname..."
          az aks enable-addons -g $rg -n $this_aksname --addons virtual-node --subnet-name $subnet_aci
     fi

     # If the ingress controller is not the app gateway, add the app routing addon to the Azure cluster or the kubenet cluster
     if [ "$create_appgw" != "yes" ] && [ "$enable_approuting_addon" == "yes" ]
     then
          echo "Enabling application routing addon for cluster $this_aksname..."
          az aks enable-addons -g $rg -n $this_aksname --addons http_application_routing >/dev/null
     fi

     # AKV flexvol
     if [ "flexvol" == "yes" ]
     then
          # AKV control plane
          echo "Installing AKV flexvol components in the cluster..."
          kubectl create -f https://raw.githubusercontent.com/Azure/kubernetes-keyvault-flexvol/master/deployment/kv-flexvol-installer.yaml >/dev/null
          # Managed identity and permissions
          echo "Creating managed identity for AKV Flexvol..."
          az identity create -g $rg -n $this_flexvol_id_name >/dev/null
          echo "Assigning permissions for the new identity..."
          flexvol_id_id=$(az identity show -g $rg -n $this_flexvol_id_name --query id -o tsv) 2>/dev/null
          flexvol_id_clientid=$(az identity show -g $rg -n $this_flexvol_id_name --query clientId -o tsv) 2>/dev/null
          flexvol_id_principalid=$(az identity show -g $rg -n $this_flexvol_id_name --query principalId -o tsv) 2>/dev/null
          until az role assignment create --role Reader --assignee $flexvol_id_principalid --scope $flexvol_kv_id >/dev/null
          do
               echo "There has been an error. Retrying in $wait_interval"
               sleep $wait_interval
          done
          az keyvault set-policy -n $flexvol_kv_name --secret-permissions get --spn $flexvol_id_clientid >/dev/null
          # aadpod identity and identitybinding
          echo "Deploying k8s pod identity for flexvol access..."
          src_file_url=https://raw.githubusercontent.com/erjosito/deploy-aks/master/helpers/flexvol-aadpodidentity.yaml
          dst_file_name=flexpod-aadpodidentity.yaml
          wget $src_file_url -O $dst_file_name 2>/dev/null
          k8s_id_name=flexvoltest
          sed -i "s|<id_name>|$k8s_id_name|g" $dst_file_name
          sed -i "s|<managed_identity_id>|${flexvol_id_id}|g" $dst_file_name
          sed -i "s|<client_id>|${flexvol_id_clientid}|g" $dst_file_name
          kubectl apply -f $dst_file_name >/dev/null
          echo "Deploying k8s pod identity binding..."
          flexvol_label=flexvol
          src_file_url=https://raw.githubusercontent.com/erjosito/deploy-aks/master/helpers/flexvol-aadpodidentitybinding.yaml
          dst_file_name=flexpod-aadpodidentitybinding.yaml
          wget $src_file_url -O $dst_file_name 2>/dev/null
          sed -i "s|<id_name>|$k8s_id_name|g" $dst_file_name
          sed -i "s|<label>|${flexvol_label}|g" $dst_file_name
          kubectl apply -f $dst_file_name >/dev/null
          # Test pod and verify access to secret
          echo "Deploying test pod..."
          flexvol_pod_name=kvtest
          src_file_url=https://raw.githubusercontent.com/erjosito/deploy-aks/master/samples/flexvol-test.yaml
          dst_file_name=sample-flexpod-test.yaml
          wget $src_file_url -O $dst_file_name 2>/dev/null
          sed -i "s|<tenant_id>|${tenantid}|g" $dst_file_name
          sed -i "s|<sub_id>|${subid}|g" $dst_file_name
          sed -i "s|<kv_rg>|${rg}|g" $dst_file_name
          sed -i "s|<kv_name>|${flexvol_kv_name}|g" $dst_file_name
          sed -i "s|<secret_name>|${flexvol_secret_name}|g" $dst_file_name
          sed -i "s|<flexvol_selector>|${flexvol_label}|g" $dst_file_name
          sed -i "s|<pod_name>|${flexvol_pod_name}|g" $dst_file_name
          kubectl apply -f $dst_file_name >/dev/null
          echo "Accessing content of file in pod..."
          returned_secret_value=$(kubectl exec -it $flexvol_pod_name cat /kvmnt/$flexvol_secret_name)
          echo $returned_secret_value
          if [ "$returned_secret_value" == "$flexvol_secret_value" ]
          then
               echo "It worked!"
          fi
     fi
done

# Create SQL DB with private link endpoint (NOT WORKING YET!!)
# https://docs.microsoft.com/en-us/azure/private-link/create-private-endpoint-cli
if [ "$create_db" == "yes" ]
then
     if [ "$db_type" == "azuresql" ]
     then
          # Variables
          sql_endpoint_name=sqlPrivateEndpoint
          private_zone_name=privatelink.database.windows.net
          # Start
          echo "Creating Azure SQL server and database"
          az sql server create -n $db_server_name -g $rg -l $sql_server_location --admin-user $db_server_username --admin-password $default_password >/dev/null
          db_server_id=$(az sql server show -n $db_server_name -g $rg -o tsv --query id) 2>/dev/null
          az sql db create -n $db_db_name -s $db_server_name -g $rg -e Basic -c 5 --no-wait >/dev/null
          db_db_id=$(az sql db show -n $db_db_name -s $db_server_name -g $rg -o tsv --query id) 2>/dev/null
          echo "Creating subnets for database private endpoint..."
          for this_location in "${location_list[@]}"
          do
               this_vnet_name="$vnet"-"$this_location"
               az network vnet subnet create -g $rg -n $db_subnet_name --vnet-name $this_vnet_name --address-prefix $db_subnet_prefix >/dev/null
               az network vnet subnet update -n $db_subnet_name -g $rg --vnet-name $this_vnet_name --disable-private-endpoint-network-policies true >/dev/null
               echo "Creating private endpoint for Azure SQL Server"
               az network private-endpoint create -n $sql_endpoint_name -g $rg --vnet-name $this_vnet_name --subnet $db_subnet_name --private-connection-resource-id $db_server_id --group-ids sqlServer --connection-name sqlConnection >/dev/null
               endpoint_nic_id=$(az network private-endpoint show -n $sql_endpoint_name -g $rg --query 'networkInterfaces[0].id' -o tsv)
               endpoint_nic_ip=$(az resource show --ids $endpoint_nic_id --api-version 2019-04-01 -o tsv --query properties.ipConfigurations[0].properties.privateIPAddress)
          done
          # Configure private DNS zone and create DNS records
          az network private-dns zone create -g $rg -n "$private_zone_name" >/dev/null
          for this_location in "${location_list[@]}"
          do
               this_vnet_name="$vnet"-"$this_location"
               az network private-dns link vnet create -g $rg --zone-name "$private_zone_name" -n MyDNSLink --virtual-network $this_vnet_name --registration-enabled false  >/dev/null
          done
          az network private-dns record-set a create --name $db_server_name --zone-name $private_zone_name -g $rg >/dev/null
          az network private-dns record-set a add-record --record-set-name $db_server_name --zone-name $private_zone_name -g $rg -a $endpoint_nic_ip >/dev/null
          # Waiting to finish the db creation
          WaitUntilFinished $db_db_id

     fi
fi

# Deploy sample apps, depending of the scenario
echo "Installing sample apps..."

# Create Azure Traffic manager if more than one location
if [ "$create_appgw" == "yes" ] || [ "$enable_approuting_addon" == "yes" ]
then
     if (( "$number_of_clusters" > 1 ))
     then
          echo "Creating Traffic Manager profiles for multi-region apps..."
          # kuard
          app_name=kuard
          kuard_tm_dns="$appname""$RANDOM"
          kuard_tm_fqdn="$tm_dns".trafficmanager.net
          az network traffic-manager profile create -n $kuard_tm_dns -g $rg --routing-method $tm_routing --unique-dns-name $kuard_tm_dns
          echo "Created Traffic Manager profile on $kuard_tm_fqdn with routing type $tm_routing"
          # aspnet
          app_name=aspnet
          aspnet_tm_dns="$appname""$RANDOM"
          aspnet_tm_fqdn="$tm_dns".trafficmanager.net
          az network traffic-manager profile create -n $aspnet_tm_dns -g $rg --routing-method $tm_routing --unique-dns-name $aspnet_tm_dns
          echo "Created Traffic Manager profile on $aspnet_tm_fqdn with routing type $tm_routing"
     fi
fi

# Needs to be done on a per location basis, because the domain is different
for this_location in "${location_list[@]}"
do
     this_vnet_name="$vnet"-"$this_location"
     this_aksname="$aksname"-"$this_location"
     this_appgw_name="$appgw_name"-"$this_location"
     this_appgw_pipname="$apggw_pipname"-"$this_location"

     # Identify if appgw or http app routing ingress controller
     if [ "$create_appgw" == "yes" ] || [ "$enable_approuting_addon" == "yes" ]
     then
          if [ "$create_appgw" == "yes" ]
          then
               ingress_class=azure/application-gateway
               # Decide if using DNS zones or use nip.io
               zonename=$(az network dns zone list -o tsv --query "[?name=='$dnszone'].name")
               if [ "$zonename" == "$dnszone" ]
               then
                    dnsrg=$(az network dns zone list -o tsv --query "[?name=='$dnszone'].resourceGroup")
                    echo "Azure DNS zone $dnszone found in resource group $dnsrg, using Azure DNS for app names"
                    use_azure_dns=yes
               else
                    echo "Azure DNS zone not found in subscription, using public nip.io for app names"
                    use_azure_dns=no
                    appgw_ip=$(az network public-ip show -g $rg -n $this_appgw_pipname --query ipAddress -o tsv)
                    zonename="$appgw_ip".nip.io
               fi
          else
               use_azure_dns=no
               ingress_class=addon-http-application-routing
               zonename=$(az aks show -g $rg -n $this_aksname --query addonProfiles.httpApplicationRouting.config.HTTPApplicationRoutingZoneName -o tsv)
               echo "The AKS application routing add on uses its own DNS zone for DNS, in this case the zone $zonename was created"
          fi
     fi

     # Select the right k8s context
     kubectl config set-context $this_aksname

     # kuard, port 8080, ingress (there has to be an ingress controller)
     if [ "$create_appgw" == "yes" ] || [ "$enable_approuting_addon" == "yes" ]
     then
          app_name=kuard
          this_app_name="$app_name"-"$this_location"
          sample_filename=sample-kuard-ingress.yaml
          wget https://raw.githubusercontent.com/erjosito/deploy-aks/master/samples/kuard-ingress.yaml -O $sample_filename 2>/dev/null
          app_fqdn=$this_app_name.$zonename
          sed -i "s|<host_fqdn>|${app_fqdn}|g" $sample_filename
          sed -i "s|<ingress_class>|${ingress_class}|g" $sample_filename
          kubectl apply -f $sample_filename >/dev/null
          if [ "$use_azure_dns" == "yes" ]
          then
               echo "Adding DNS name $app_fqdn for public IP $appgw_ip..."
               az network dns record-set a create -g $dnsrg -z $dnszone -n $this_app_name >/dev/null
               az network dns record-set a add-record -g $dnsrg -z $dnszone -n $this_app_name -a $appgw_ip >/dev/null
          fi
          echo "You can access the sample app $app_name on ${app_fqdn}"
          # Traffic manager
          echo "Creating endpoint for $app_fqdn in Traffic Manager profile $kuard_tm_fqdn..."
          az network traffic-manager endpoint create -n $this_app_name --profile-name $kuard_tm_dns -g $rg -t externalEndPoints --target $app_fqdn >/dev/null
     fi

     # kuard, port 8080, public ALB, local externalTrafficPolicy
     # only if no ingress controller
     if [ "$create_appgw" != "yes" ] && [ "$enable_approuting_addon" != "yes" ]
     then
          if [ "$lb_type" == "external" ] && [ "$create_azfw" != "yes" ]
          then
               sample_filename=sample-kuard-alb.yaml
               wget https://raw.githubusercontent.com/erjosito/deploy-aks/master/samples/kuard-alb.yaml -O $sample_filename 2>/dev/null
               app_name=kuard-alb
          else
               sample_filename=sample-kuard-ilb.yaml
               wget https://raw.githubusercontent.com/erjosito/deploy-aks/master/samples/kuard-ilb.yaml -O $sample_filename 2>/dev/null
               sed -i "s|<ilb-subnet>|${akslb_subnet_name}|g" $sample_filename
               app_name=kuard-alb
          fi
          kubectl apply -f $sample_filename >/dev/null
          echo "${app_name} deployed, run 'kubectl config use-context $this_aksname && kubectl get svc' to find out its public IP"
     fi


     # sample aspnet app, port 80, ingress (there has to be an ingress controller)
     if [ "$create_appgw" == "yes" ] || [ "$enable_approuting_addon" == "yes" ]
     then
          sample_filename=sample-aspnet-ingress.yaml
          wget https://raw.githubusercontent.com/erjosito/deploy-aks/master/samples/aspnet-ingress.yaml -O $sample_filename 2>/dev/null 
          app_name=aspnet
          this_app_name="$app_name"-"$this_location"
          app_fqdn=$this_app_name.$zonename
          sed -i "s|<host_fqdn>|${app_fqdn}|g" $sample_filename
          sed -i "s|<ingress_class>|${ingress_class}|g" $sample_filename
          kubectl apply -f $sample_filename >/dev/null
          if [ "$use_azure_dns" == "yes" ]
          then
               echo "Adding DNS name $app_fqdn for public IP $appgw_ip..."
               az network dns record-set a create -g $dnsrg -z $dnszone -n $app_name >/dev/null
               az network dns record-set a add-record -g $dnsrg -z $dnszone -n $app_name -a $appgw_ip >/dev/null
          fi
          echo "You can access the sample aspnet app on ${app_fqdn}"
          # Traffic manager
          echo "Creating endpoint for $app_fqdn in Traffic Manager profile $aspnet_tm_fqdn..."
          az network traffic-manager endpoint create -n $this_app_name --profile-name $aspnet_tm_dns -g $rg -t externalEndPoints --target $app_fqdn >/dev/null
     fi

     # pythonsql
     # PRIVATE REPO!! Move to dockerhub?
     if [ "$create_db" == "yes" ]
     then
          if [ "$db_type" == "azuresql" ]
          then
               # Create secrets
               db_server_fqdn=$db_server_name.$private_zone_name
               kubectl create secret generic sqlserver --from-literal=SQL_SERVER_FQDN=$db_server_fqdn \
                                                       --from-literal=SQL_SERVER_DB=$db_db_name \
                                                       --from-literal=SQL_SERVER_USERNAME=$db_server_username \
                                                       --from-literal=SQL_SERVER_PASSWORD=$default_password
          fi
     fi
done

# Print info to connect to test VM (jump host)
if [ "$create_vm" == "yes" ]
then
     echo "To connect to the test VM (or use it as jump host for the k8s nodes):"
     for this_location in "${location_list[@]}"
     do
          this_vm_name="$vm_name"-"$this_location"
          this_vm_pip_name="$this_vm_name"-pip
          this_vm_pip_ip=$(az network public-ip show -g $rg -n $this_vm_pip_name --query ipAddress -o tsv)
          echo "  ssh "$this_vm_pip_ip""
     done
fi

