#!/bin/bash

###############################################################
# To Do:
# - Dev-spaces
# - AFD as alternative to TM
# - linkerd (ongoing)
# - Storage & private link (the FQDN needs to be the same)
# - Verify creating new AKV and new log analytics ws (ongoing)
# - nginx ingress controller (ongoing)
#   * with private IP
# - cert management:
#   * nginx ingress controller
#   * AGIC     
# - APIM
# - Add private IP frontend to the app gateway
# To test (note that running two tests at the same time might cause conflicts with kubectl contexts):
#   deployaks.sh --azfw --vm (AzFw->kuard, to test DNAT to kuard and correct egress filtering)
#   deployaks.sh --nginx-ingress (nginx->kuard)
#   deployaks.sh --nginx-ingress --azfw --no-acr --helm-version=3 (azfw->nginx->kuard)
#   deployaks.sh -l=northeurope,westeurope --azfw (TM->kuard)
#   deployaks.sh -l=northeurope,westeurope --nginx-ingress (TM->nginx->kuard)
#   deployaks.sh --linkerd
#   deployaks.sh --db --db-location=westus2 (to test new code for private link)
# Done:
# - separate subnet for ALB frontend IPs
# - AKS control plane ingress filtering
# - AKS egres s filtering (with AzFW)
# - Azure Policy
# - AzFw
#   * enable logging to azmon ws
#   * KQL from cli -> not supported
# - Traffic Manager
###############################################################

# Take the start time to calculate total running time
script_start_time=`date +%s`

# See which shell we are using, and determine whether the script is being sourced
if [[ $SHELL == *"zsh"* ]]
then
     array_base_index=1       # Arrays in zsh start with index=1
     if [[ $ZSH_EVAL_CONTEXT =~ :file$ ]]
     then
          script_sourced=yes
          script_name="$0"
          echo "It looks like you are running the $script_name script in sourced mode under zsh"
     else
          script_sourced=no
          script_name="$0"
          echo "It looks like you are running the $script_name script in non-sourced mode under zsh"
     fi
else
     if [[ $SHELL == *"bash"* ]]
     then
          array_base_index=0       # Arrays in bash start with index=0
          if [[ ${BASH_SOURCE[0]} == $0 ]]
          then
               script_sourced=no
               script_name="$0"
               echo "It looks like you are running the $script_name script in non-sourced mode under bash"
          else
               script_sourced=yes
               script_name="${BASH_SOURCE[0]}"
               echo "It looks like you are running the $script_name script in sourced mode under bash"
          fi
     else
          script_sourced=no
          script_name="$0"
          echo "Shell not recognized! Defaulting to script not sourced (script name $script_name)"
     fi
fi

# Check requirements
echo "Checking script dependencies..."
requirements=(az jq kubectl sed helm2 helm3)
for req in ${requirements[@]}
do
     if [[ -z $(which $req) ]]
     then
          echo "Please install $req to run this script"
          if [[ $script_sourced == "yes" ]]
          then
               return
          else
               exit
          fi
     else
          echo "- $req executable found in $(which $req)"
     fi
done

# Check for AKS preview CLI extension
echo "Checking that aks-preview extension is installed..."
found_aks_extension=$(az extension list -o tsv --query "[?name=='aks-preview'].name" 2>/dev/null)
if [[ -z "$found_aks_extension" ]]
then
     echo "Installing aks-preview Azure CLI extension..."
     az extension add -n aks-preview >/dev/null
else
     echo "aks-preview Azure CLI extension found"
fi

# Loading values for variables from a config file
variables_file="./deployaks_variables.sh"
source $variables_file

# Defaults (moving this to an external file like the variables would probably make sense)
k8s_version=latest
help=no
vnetpeering=no
create_appgw=no
deploy_nginx_ingress=no
enable_approuting_addon=no
create_azfw=no
crate_apim=no
flexvol=no
deploy_pod_identity=no
lb_outbound_rules=no
lb_sku_basic=no
lb_type=external
ilpip=no
create_db=no
create_vm=no
network_plugin=azure
deploy_linkerd=no
k8s_version_preview=yes
aks_api_fw=no
global_lb=tm
deploy_arc=no
deploy_ca=no
azure_policy=no
attach_acr=yes
helm_version=2
min_node_count=1
max_node_count=3
max_retries=10

# Format variables
normal="\e[0m"
underline="\e[4m"
red="\e[31m"
green="\e[32m"
yellow="\e[33m"

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
               k8s_version="${i#*=}"
               shift # past argument=value
               ;;
          -c=*|--node-count=*)
               min_node_count="${i#*=}"
               shift # past argument=value
               ;;
          --no-k8s-version-preview)
               k8s_version_preview=no
               shift # past argument with no value
               ;;
          -p=*|--network-policy=*)
               nw_policy="${i#*=}"
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
          --apim)
               create_apim=yes
               shift # past argument with no value
               ;;
          --app-routing)
               enable_approuting_addon=yes
               shift # past argument with no value
               ;;
          --nginx-ingress)
               deploy_nginx_ingress=yes
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
          --helm-version=*)
               helm_version="${i#*=}"
               shift # past argument=value
               ;;
          --extra-nodepool)
               deploy_extra_nodepool=yes
               shift # past argument with no value
               ;;
          --linkerd)
               deploy_linkerd=yes
               shift # past argument with no value
               ;;
          --aks-api-fw)
               aks_api_fw=yes
               shift # past argument with no value
               ;;
          --afd)
               global_lb=afd
               shift # past argument with no value
               ;;
          --arc)
               deploy_arc=yes
               shift # past argument with no value
               ;;
          --ca)
               deploy_ca=yes
               shift # past argument with no value
               ;;
          --policy)
               azure_policy=yes
               shift # past argument with no value
               ;;
          --no-acr)
               attach_acr=no
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
if [[ "$help" == "yes" ]]
then
     echo "Please run this script as \"$script_name [--network-plugin=kubenet|azure] [--resource-group=yourrg] [--location=yourlocation(s)]
         [--kubernetes-version=x.x.x] [--no-k8s-version-preview] [--vm]
         [--network-policy=azure|calico|none] [--vnet-peering] [--azfw] [--aks-api-fw] [--apim]
         [--windows] [--helm] [--helm-version=2|3] [--flexvol]
         [--db] [--db-location]
         [--lb-outbound-rules] [--lb-basic] [--ilpip] [--no-vmss] [--afd]
         [--extra-nodepool] [--policy] [--arc]
         [--linkerd] [--nginx-ingress] [--appgw] [--app-routing]
         [--virtual-node] [--flexvol] [--aad-pod-identity] [--ca]\""
     echo " -> Example: \"$script_name -n=azure -p=azure -g=akstest\""
     # Return if the script is sourced, exit if it is not
     #read -p "Press enter to continue"
     if [[ $script_sourced == "yes" ]]
     then
          return
     else
          exit
     fi
fi

# Variable for helm exec
if [[ "$helm_version" == "2" ]]
then
     helm_exec=helm2
else
     helm_exec=helm3
fi

# Identify if more than one location (comma-separated) was supplied (string splitting depending on shell)
if [[ $SHELL == *"zsh"* ]]
then
     location_list=("${(@s/,/)location}")
else
     IFS=',' read -r -a location_list <<< "$location"
fi
number_of_clusters=${#location_list[@]}
if [[ "$number_of_clusters" -gt 1 ]]
then
     echo "It looks like you are trying to create $number_of_clusters clusters in $location"
else
     echo "Starting deployment of $number_of_clusters cluster in ${location_list[$array_base_index]}"
fi

# Default to azure network policy
if [[ "$nw_policy" != "calico" ]]
then
     nw_policy="azure"
     echo "Defaulting to network policy $nw_policy"
fi

# Default to azure CNI plugin
if [[ "$network_plugin" != "kubenet" ]]
then
     network_plugin=azure
     echo "Defaulting to network CNI plugin $network_plugin"
fi

# Default to standard ALB
if [[ "$lb_sku_basic" == "yes" ]]
then
     lb_sku=basic
     echo "Using basic Azure Load Balancer"
else
     lb_sku=standard
     echo "Defaulting to standard Azure Load Balancer"
fi

# Only one ingress controller, defaulting to the AGIC
if [[ "$create_appgw" == "yes" ]]
then
     if [[ "$deploy_nginx_ingress" == "yes" ]] || [[ "$enable_approuting_addon" == "yes" ]]
     then
          echo "Only one ingress controller is supported, defaulting to the App Gateway Ingress Controller..."
          deploy_nginx_ingress=no
          enable_approuting_addon=no
     fi
fi

# AzFW not compatible with app gateway
if [[ "$create_appgw" == "yes" ]] && [[ "$create_azfw" == "yes" ]]
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
rg_location=$(RemoveNonPrintable ${location_list[$array_base_index]})
echo "Creating resource group $rg in $rg_location..."
az group create -n $rg -l $rg_location >/dev/null

# Get stuff from key vault
echo "Retrieving secrets from Azure Key Vault $keyvaultname..."
get_kvname=$(az keyvault list -o tsv --query "[?name=='$keyvaultname'].name")
if [[ "$get_kvname" == "$keyvaultname" ]]
then
     sshpublickey=$(az keyvault secret show -n surfaceSshPublicKey --vault-name $keyvaultname --query value -o tsv)
     default_password=$(az keyvault secret show -n defaultPassword --vault-name $keyvaultname --query value -o tsv)
     appid=$(az keyvault secret show -n aks-app-id --vault-name $keyvaultname --query value -o tsv)
     appsecret=$(az keyvault secret show -n aks-app-secret --vault-name $keyvaultname --query value -o tsv)
     echo "Got ssh public key and secret for sp $appid from Key Vault $keyvaultname"
else
     echo "Key Vault $keyvaultname not found! A keyvault with SSH public strings and AAS SP data is required."
     keyvault_rg_id=$(az group show -n $keyvault_rg -o tsv --query id 2>/dev/null)
     if [[ -z "$keyvault_rg_id" ]]
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
     if [[ -f "$sshpublickey_filename" ]]
     then
          sshpublickey=$(cat $sshpublickey_filename)
          az keyvault secret set -n surfaceSshPublicKey --value $sshpublickey --vault-name $keyvaultname >/dev/null
     else
          echo "SSH public key file $sshpublickey_filename not found. Exiting..."
          # Return if the script is sourced, exit if it is not
          if [[ $script_sourced == "yes" ]]
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
wsid=$(az resource list -g $monitor_rg -n $monitor_ws --query '[].id' -o tsv)
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
     wsid=$(az resource list -g $monitor_rg -n $monitor_ws --query '[].id' -o tsv)
     echo "ID for new workspace is $wsid"
else
     echo "Found ID for workspace $monitor_ws: $wsid"
fi

# Get ACR ID
echo "Getting ACR ID for $acr_name in resource group $acr_rg..."
get_acr_name=$(az acr list -o tsv --query "[?name=='$acr_name'].name")
if [[ "$get_acr_name" == "$acr_name" ]]
then
     acr_rg=$(az acr list -o tsv --query "[?name=='$acr_name'].resourceGroup")
     acr_id=$(az acr show -n erjositoAcr -g $acr_rg --query id -o tsv)
     acr_url=$(az acr show -n erjositoAcr -g $acr_rg --query loginServer -o tsv)
     echo "ID for existing ACR $acr_name is $acr_id, URL $acr_url"
else
     acr_rg=$rg
     az acr create -n $acr_name -g $acr_rg --sku Standard -l $rg_location 2>/dev/null
     acr_id=$(az acr show -n erjositoAcr -g $acr_rg --query id -o tsv)
     acr_url=$(az acr show -n erjositoAcr -g $acr_rg --query loginServer -o tsv)
     echo "ID for new ACR $acr_name is $acr_id, URL $acr_url"
fi

# Use a k8s version from the args, or get last supported k8s version. 'latest' keyword supported (default)
if [[ -z "$k8s_version" ]] || [[ "$k8s_version" == "latest" ]]
then
     echo 'Getting latest supported k8s version...'
     #k8s_version=$(az aks get-versions -l $rg_location -o tsv --query orchestrators[-1].orchestratorVersion)
     k8s_versions=$(az aks get-versions -l $rg_location -o json)
     if [[ "$k8s_version_preview" == "yes" ]]
     then
          k8s_version=$(echo $k8s_versions | jq '.orchestrators[]' | jq -rsc 'sort_by(.orchestratorVersion) | reverse[0] | .orchestratorVersion')
          echo "Latest supported k8s version in $rg_location is $k8s_version (in preview)"
     else
          k8s_version=$(echo $k8s_versions | jq '.orchestrators[] | select(.isPreview == null)' | jq -rsc 'sort_by(.orchestratorVersion) | reverse[0] | .orchestratorVersion')
          echo "Latest supported k8s version (not in preview) in $rg_location is $k8s_version"
     fi
else
     echo "Using k8s version $k8s_version"
fi

# Create vnet in each location
for this_location in "${location_list[@]}"
do
     this_vnet_name="$vnet"-"$this_location"
     echo "Creating vnet $this_vnet_name in $this_location..."
     az network vnet create -g $rg -n $this_vnet_name --address-prefix $vnetprefix -l $this_location >/dev/null

     # Create peered vnet (if specified in the options)
     if [[ "$vnetpeering" == "yes" ]]
     then
          $peer_vnet_name="$peervnet"-"$this_location"
          peer_vnet_location=$this_location
          echo "Creating vnet $peer_vnet_name to peer in $peer_vnet_location..."
          az network vnet create -g $rg -n $peer_vnet_name --address-prefix $peer_vnet_prefix -l $peer_vnet_location >/dev/null
          az network vnet peering create -g $rg -n AKSToPeer --vnet-name $this_vnet_name --remote-vnet $peer_vnet_name --allow-vnet-access     
          az network vnet peering create -g $rg -n PeerToAKS --vnet-name $peer_vnet_name --remote-vnet $this_vnet_name --allow-vnet-access     
     fi

     # Create subnet for ACI (virtual node)
     if [[ "$create_vnode" == "yes" ]]
     then
          echo "Creating subnet for AKS virtual node (ACI) in $this_location..."
          az network vnet subnet create -g $rg -n $subnet_aci --vnet-name $this_vnet_name --address-prefix $aci_subnet_prefix >/dev/null
     fi

done

# Define vmss options
if [[ "$no_vmss" == "yes" ]]
then
     echo "Using no VMSS or AZ options..."
     # vmss_options=""
     vmss_options="--vm-set-type AvailabilitySet"
else
     if [[ "$lb_sku_basic" == "yes" ]]
     then
          echo "Using VMSS option, no AZs..."
          # vmss_options="--enable-vmss --nodepool-name pool1"
          vmss_options="--vm-set-type VirtualMachineScaleSets --nodepool-name pool1"
     else
          echo "Using VMSS option and deploying to AZs 1, 2 and 3..."
          # vmss_options="--enable-vmss --node-zones 1 2 3 --nodepool-name pool1"
          vmss_options="--vm-set-type VirtualMachineScaleSets --nodepool-name pool1 --node-zones 1 2 3 "
     fi
fi

# Define additional windows options
if [[ "$windows" == "yes" ]]
then
     windows_options="--windows-admin-password "$default_password" --windows-admin-username $adminuser"
else
     windows_options=""
fi

# Define cluster-autoscaler options
if [[ "$deploy_ca" == "yes" ]]
then
     ca_options="--enable-cluster-autoscaler --min-count $min_node_count --max-count $max_node_count"
else
     ca_options=""
fi

# Define cluster-autoscaler options
if [[ "$attach_acr" == "yes" ]]
then
     acr_options="--attach-acr $acr_id"
else
     acr_options=""
fi

# Override some values that are not supported by kubenet
if [[ "$network_plugin" == "kubenet" ]]
then
     if [[ "$windows" == "yes" ]]
     then
          echo "Windows pools not supported by kubenet clusters"
          windows=no
          windows_options=""
     fi
     if [[ "$create_appgw" == "yes" ]]
     then
          echo "The app gateway ingress controller is not supported by kubenet clusters"
          create_appgw=no
     fi
     if [[ "$nw_policy" == "calico" ]] || [[ "$nw_policy" == "azure" ]]
     then
          echo "Kubernetes network policy is not supported by kubenet clusters"
          nw_policy=""
     fi

fi

# Create AKS cluster(s) and support infra (app gws, azfws, etc)

# Create vnet in each location
for this_location in "${location_list[@]}"
do
     this_vnet_name="${vnet}-${this_location}"
     this_aksname="${aksname}-${this_location}"
     this_vm_name="${vm_name}-${this_location}"
     this_appgw_name="${appgw_name}-${this_location}"
     this_appgw_dnsname="${this_appgw_name}${RANDOM}"
     this_appgw_pipname="${appgw_pipname}-${this_location}"
     this_azfw_name="${azfw_name}-${this_location}"
     this_azfw_pipname="${azfw_pipname}-${this_location}"
     this_apim_name="${apim_name}-${this_location}"

     # Subnet
     echo "Creating subnet for AKS cluster in $this_location..."
     az network vnet subnet create -g $rg -n $aks_subnet_name --vnet-name $this_vnet_name --address-prefix $aks_subnet_prefix >/dev/null
     az network vnet subnet create -g $rg -n $akslb_subnet_name --vnet-name $this_vnet_name --address-prefix $akslb_subnet_prefix >/dev/null
     subnetid=$(az network vnet subnet show -g $rg --vnet-name $this_vnet_name -n $aks_subnet_name --query id -o tsv)
     echo "The AKS subnet ID is $subnetid"
     # Cluster
     echo "Creating AKS cluster $this_aksname in resource group $rg..."
     if [[ $SHELL == *"zsh"* ]]  # If zsh we need to expand the variables with (z)
     then
          az aks create -g $rg -n $this_aksname -l $this_location \
               -c $min_node_count -s $vmsize -k $k8s_version \
               --service-principal $appid --client-secret $appsecret \
               --admin-username $adminuser --ssh-key-value "$sshpublickey" \
               --network-plugin $network_plugin --vnet-subnet-id $subnetid --service-cidr $aks_service_cidr \
               --enable-addons monitoring --workspace-resource-id $wsid \
               --network-policy "$nw_policy" \
               ${(z)vmss_options} ${(z)windows_options} ${(z)ca_options} ${(z)acr_options} \
               --load-balancer-sku $lb_sku \
               --node-resource-group "$this_aksname"-iaas-"$RANDOM" \
               --tags "$tag1_name"="$tag1_value" \
               --no-wait
     else
          az aks create -g $rg -n $this_aksname -l $this_location \
               -c $min_node_count -s $vmsize -k $k8s_version \
               --service-principal $appid --client-secret $appsecret \
               --admin-username $adminuser --ssh-key-value "$sshpublickey" \
               --network-plugin $network_plugin --vnet-subnet-id $subnetid --service-cidr $aks_service_cidr \
               --enable-addons monitoring --workspace-resource-id $wsid \
               --network-policy "$nw_policy" $vmss_options $windows_options $ca_options $acr_options \
               --load-balancer-sku $lb_sku \
               --node-resource-group "$this_aksname"-iaas-"$RANDOM" \
               --tags "$tag1_name"="$tag1_value" \
               --no-wait
     fi
     echo ""

     # Create Application Gateway
     if [[ "$create_appgw" == "yes" ]] && [[ "$network_plugin" == "azure" ]]
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
     if [[ "$create_azfw" == "yes" ]]
     then
          # Create AzFW subnet
          echo 'Creating subnet for Azure Firewall...'
          az network vnet subnet create -g $rg -n AzureFirewallSubnet --vnet-name $this_vnet_name --address-prefix $azfw_subnet_prefix >/dev/null
          # Create public IP
          echo "Creating public IP address $this_azfw_pipname for Azure Firewall..."
          az network public-ip create -g $rg -n $this_azfw_pipname --sku standard --allocation-method static -l $this_location >/dev/null
          azfw_ip=$(az network public-ip show -g $rg -n $this_azfw_pipname --query ipAddress -o tsv 2>/dev/null)
          # Create Azure Firewall
          echo "Creating Azure Firewall $this_azfw_name in $this_location..."
          az network firewall create -n $this_azfw_name -g $rg -l $this_location >/dev/null
          azfw_id=$(az network firewall show -n $this_azfw_name -g $rg -o tsv --query id)
          echo "Enabling logging for Azure Firewall $this_azfw_name to log analytics workspace $monitor_ws..."
          az monitor diagnostic-settings create -n mydiag --resource $azfw_id --workspace $wsid \
               --metrics '[{"category": "AllMetrics", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false }, "timeGrain": null}]' \
               --logs '[{"category": "AzureFirewallApplicationRule", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}, 
                        {"category": "AzureFirewallNetworkRule", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}]' >/dev/null
          echo "Updating IP configuration for firewall $this_azfw_name..."
          az network firewall ip-config create -f $this_azfw_name -n azfw-ipconfig -g $rg --public-ip-address $this_azfw_pipname --vnet-name $this_vnet_name >/dev/null
          az network firewall update -n $this_azfw_name -g $rg >/dev/null
          azfw_private_ip=$(az network firewall show -n $this_azfw_name -g $rg -o tsv --query 'ipConfigurations[0].privateIpAddress')
          echo "Azure Firewall $azfw_id created with public IP $azfw_ip and private IP $azfw_private_ip"
          # Rules
          echo "Adding network rules in Azure Firewall $this_azfw_name..."
          az network firewall network-rule create -f $this_azfw_name -g $rg -c VM-to-AKS --protocols Any --destination-addresses $aks_subnet_prefix --destination-ports '*' --source-addresses $vm_subnet_prefix -n Allow-VM-to-AKS --priority 210 --action Allow >/dev/null
          az network firewall network-rule create -f $this_azfw_name -g $rg -c WebTraffic --protocols Tcp --destination-addresses $azfw_ip --destination-ports 80 8080 443 --source-addresses '*' -n AllowWeb --priority 300 --action Allow >/dev/null
          az network firewall network-rule create -f $this_azfw_name -g $rg -c AKS-egress --protocols Udp --destination-addresses '*' --destination-ports 123 --source-addresses $aks_subnet_prefix -n NTP --priority 220 --action Allow >/dev/null
          # Eventually use dest addresses for NTP: 91.189.89.198, 91.189.89.199, 91.189.91.157, 91.189.94.4 (but this is risky if addresses change)
          echo "Adding application rules in Azure Firewall $this_azfw_name..."
          az network firewall application-rule create -f $this_azfw_name -g $rg -c Helper-tools --protocols Http=80 Https=443 --target-fqdns ifconfig.co --source-addresses $vnetprefix -n Allow-ifconfig --priority 200 --action Allow >/dev/null
          # Application rule: AKS-egress (https://docs.microsoft.com/en-us/azure/aks/limit-egress-traffic):
          # Creating rules takes a long time, hence it is better creating one with many FQDNs, than one per FQDN
          target_fqdns="*.azmk8s.io aksrepos.azurecr.io *.blob.core.windows.net mcr.microsoft.com *.cdn.mscr.io management.azure.com login.microsoftonline.com packages.azure.com acs-mirror.azureedge.net *.oms.opinsights.azure.com $acr_url gcr.io storage.googleapis.com dc.services.visualstudio.com"
          if [[ $SHELL == *"zsh"* ]]  # If zsh we need to expand the variables with (z)
          then
               az network firewall application-rule create -f $this_azfw_name -g $rg -c AKS-egress --protocols Https=443 --target-fqdns "${(z)target_fqdns}" --source-addresses $aks_subnet_prefix -n AKSegress --priority 220 --action Allow >/dev/null
          else
               az network firewall application-rule create -f $this_azfw_name -g $rg -c AKS-egress --protocols Https=443 --target-fqdns "$target_fqdns" --source-addresses $aks_subnet_prefix -n AKSegress --priority 220 --action Allow >/dev/null
          fi
     fi

     # Create APIM if required
     if [[ "$create_apim" == "yes" ]]
     then
          apim_sku=Developer  # For the time being, do not use the multi-region feature of the Premium sku, since no way to add region with CLI
          apim_vnet_type=External
          # Create subnet
          echo 'Creating subnet for Azure API Management...'
          az network vnet subnet create -g $rg -n $apim_subnet_name --vnet-name $this_vnet_name --address-prefix $apim_subnet_prefix >/dev/null
          # Create apim service - THIS TAKES QUITE A WHILE: CHANGE to ASYNC!
          echo "Creating $apim_sku API Management..."
          # CLI does not support at the time of this writing supplying the subnet ID
          # az apim create -n $this_apim_name -g $rg -l $this_location --sku-name $apim_sku -v $apim_vnet_type >/dev/null
          template_url=https://raw.githubusercontent.com/erjosito/deploy-aks/master/arm/apim.json
          deployment_name="apim"$this_location
          az group deployment create -n $deployment_name -g $rg --template-uri $template_url --parameters '{
               "apiManagementServiceName": {"value": "'$this_apim_name'"},
               "publisherName": {"value": "'$apim_publisher_name'"},
               "publisherEmail": {"value": "'$apim_publisher_email'"},
               "sku": {"value": "'$apim_sku'"},
               "skuCount": {"value": 1},
               "virtualNetworkType": {"value": "'$apim_vnet_type'"},
               "virtualNetworkName": {"value": "'$this_vnet_name'"},
               "subnetName": {"value": "'$apim_subnet_name'"},
               "location": {"value": "'$this_location'"}}' >/dev/null
          # Get service principal ID for MSI (required to enable read access to the AKV for the https certificate)
          apim_principal_id=$(az apim show -n $this_apim_name -g $rg --query identity.principalId -o tsv 2>/dev/null)
          apim_public_ip=$(az apim show -n $this_apim_name -g $rg --query publicIpAddresses[0] -o tsv 2>/dev/null)
          # Add user groups, users, product and subscription
          template_url=https://raw.githubusercontent.com/erjosito/deploy-aks/master/arm/apim-user.json
          deployment_name="apimuser"$this_location
          apim_product_name=kuard
          apim_user_group_name=contosogroup
          apim_user_first_name=Jose
          apim_user_last_name=Moreno
          apim_user_email="erjosito@hotmail.com"
          az group deployment create -n $deployment_name -g $rg --template-uri $template_url --parameters '{
               "apiManagementServiceName": {"value": "'$this_apim_name'"},
               "productName": {"value": "'$apim_product_name'"},
               "userGroupName": {"value": "'$apim_user_group_name'"},
               "userFirstName": {"value": "'$apim_user_first_name'"},
               "userLastName": {"value": "'$apim_user_last_name'"},
               "userEmail": {"value": "'$apim_user_email'"}}' >/dev/null
          # Add API to product group
          template_url=https://raw.githubusercontent.com/erjosito/deploy-aks/master/arm/apim-api.json
          deployment_name="apimapi"$this_location
          apim_api_name=kuard
          apim_api_url="https://myapi.com"
          apim_api_path=""
          apim_op_name="GETexample"
          apim_op_method="GET"
          apim_op_policy=""
          az group deployment create -n $deployment_name -g $rg --template-uri $template_url --parameters '{
               "apiManagementServiceName": {"value": "'$this_apim_name'"},
               "productName": {"value": "'$apim_product_name'"},
               "apiName": {"value": "'$apim_api_name'"},
               "apiUrl": {"value": "'$apim_api_url'"},
               "apiPath": {"value": "'$apim_api_path'"},
               "operationName": {"value": "'$apim_op_name'"},
               "operationMethod": {"value": "'$apim_op_method'"},
               "operationPolicy": {"value": "'$apim_op_policy'"}}' >/dev/null
     fi

     # Test VM
     # It is not created in --no-wait mode, since probably we need to wait for the creation of the AKS cluster any way....
     if [[ "$create_vm" == "yes" ]]
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
          if [[ "$create_azfw" == "yes" ]]
          then
               az network route-table create -n "$this_vm_name"-rt -g $rg -l $this_location >/dev/null
               vm_rt_id=$(az network route-table show -n "$this_vm_name"-rt -g $rg -o tsv --query id 2>/dev/null)
               if [[ -z "$vm_rt_id" ]]
               then
                    echo "Error when creating route-table "$this_vm_name"-rt"
               else
                    echo "Updating subnet $subnet_vm in vnet $this_vnet_name with route table $vm_rt_id"
                    az network vnet subnet update -g $rg --vnet-name $this_vnet_name -n $subnet_vm --route-table $vm_rt_id >/dev/null
                    az network route-table route create -n vnet --route-table-name "$this_vm_name"-rt -g $rg --next-hop-type VirtualAppliance --address-prefix $vnetprefix --next-hop-ip-address $azfw_private_ip >/dev/null
                    # No default route to the AzFw, otherwise no connectivity (or a DNAT rule would need to be created)
                    # az network route-table route create -n defaultRoute --route-table-name "$this_vm_name"-rt -g $rg --next-hop-type VirtualAppliance --address-prefix "0.0.0.0/0" --next-hop-ip-address $azfw_private_ip >/dev/null
               fi
          fi
     fi

done

# Create a key vault in the RG for the apps in the AKS cluster
if [[ "flexvol" == "yes" ]]
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

# Function to wait until a resource is provisioned:
# Arguments:
# - RG
# - deployment name
function WaitUntilArmFinished {
     arm_deployment_rg=$1
     arm_deployment_name=$2
     echo "Waiting for ARM deployment $arm_deploymnet_name in resource group $arm_deploymnet_rg to finish provisioning..."
     start_time=`date +%s`
     state=$(az group deployment show -n $arm_deployment_name -g $arm_deployment_rg --query 'properties.provisioningState' -o tsv 2>/dev/null)
     until [[ "$state" == "Succeeded" ]] || [[ "$state" == "Failed" ]] || [[ -z "$state" ]]
     do
          sleep $wait_interval
          state=$(az group deployment show -n $arm_deployment_name -g $arm_deployment_rg --query 'properties.provisioningState' -o tsv 2>/dev/null)
     done
     if [[ -z "$state" ]]
     then
          echo "Something happened, could not find out the provisioning state of deployment $arm_deployment_name in resource group $arm_deployment_rg..."
          if [[ $script_sourced == "yes" ]]
          then
               return
          else
               exit
          fi
     else
          run_time=$(expr `date +%s` - $start_time)
          ((minutes=${run_time}/60))
          ((seconds=${run_time}%60))
          echo "Resource $resource_name provisioning state is $state, wait time $minutes minutes and $seconds seconds"
     fi
}


# Function to wait until a resource is provisioned:
# Arguments:
# - resource id
function WaitUntilFinished {
     resource_id=$1
     resource_name=$(echo $resource_id | cut -d/ -f 9)
     echo "Waiting for resource $resource_name to finish provisioning..."
     start_time=`date +%s`
     state=$(az resource show --id $resource_id --query properties.provisioningState -o tsv)
     until [[ "$state" == "Succeeded" ]] || [[ "$state" == "Failed" ]] || [[ -z "$state" ]]
     do
          sleep $wait_interval
          state=$(az resource show --id $resource_id --query properties.provisioningState -o tsv)
     done
     if [[ -z "$state" ]]
     then
          echo "Something really bad happened..."
          if [[ $script_sourced == "yes" ]]
          then
               return
          else
               exit
          fi
     else
          run_time=$(expr `date +%s` - $start_time)
          ((minutes=${run_time}/60))
          ((seconds=${run_time}%60))
          echo "Resource $resource_name provisioning state is $state, wait time $minutes minutes and $seconds seconds"
     fi
}

# Wait for resource creation to finish
# Create vnet in each location
for this_location in "${location_list[@]}"
do
     this_aksname="${aksname}-${this_location}"
     this_vnet_name="${vnet}-${this_location}"
     this_aks_rt_name="${aks_rt_name}-${this_location}"
     this_appgw_name="${appgw_name}-${this_location}"
     this_pip1_name="${pip1_name}-${this_location}"
     this_pip2_name="${pip2_name}-${this_location}"
     this_appgw_identity_name="${appgw_identity_name}-${this_location}"
     this_flexvol_id_name="${flexvol_kv_name}-${this_location}"
     this_azfw_name="${azfw_name}-${this_location}"

     # AKS cluster
     resource_id=$(az aks show -n $this_aksname -g $rg --query id -o tsv)
     WaitUntilFinished $resource_id
     if [[ "$state" == "Failed" ]]
     then
          echo "Exiting..."
          # Return if the script is sourced, exit if it is not
          if [[ $script_sourced == "yes" ]]
          then
               return
          else
               exit
          fi
     fi
     echo "Getting credentials for cluster $this_aksname..."
     az aks get-credentials -g $rg -n $this_aksname --overwrite

     # Onboard to Azure Policy if required
     if [[ "$azure_policy" == "yes" ]]
     then
          # Enable addon
          echo "Configuring integration with Azure Policy..."
          az aks enable-addons --addons azure-policy -n $this_aksname -g $rg >/dev/null
          # Assign sample policy that rejects privileged pods: first see if the policy exists
          rgid=$(az group show -n $rg --query id -o tsv) 2>/dev/null
          assignment_name=sample-k8s-policy
          assignment_description="Sample kubernetes policy to reject privileged pods"
          policy_id='/providers/Microsoft.Authorization/policyDefinitions/7ce7ac02-a5c6-45d6-8d1b-844feb1c1531'
          policy_name=$(az policy definition list --query "[?id=='$policy_id'].name" -o tsv 2>/dev/null)
          policy_display_name=$(az policy definition list --query "[?id=='$policy_id'].displayName" -o tsv 2>/dev/null)
          if [[ -z "$policy_name" ]]
          then
               echo "Policy $policy_id not found!"
          else
               echo "Assigning sample policy $policy_display_name to scope $rgid..."
               az policy assignment create -n $assignment_name --display-name "$assignment_description" --scope "$rgid" --policy "$policy_name" -l $rg_location >/dev/null
          fi
          # Deploy sample manifest
          echo "Deploying sample pod with elevated privilege, it should be rejected by the policy"
          kubectl apply -f https://raw.githubusercontent.com/erjosito/deploy-aks/master/samples/privileged.yaml
     fi

     # Configure logging for the master nodes
     echo "Enabling logging for AKS master nodes in $this_aksname to log to analytics workspace $monitor_ws..."
     aks_id=$(az aks show -n $this_aksname -g $rg -o tsv --query id 2>/dev/null)
     az monitor diagnostic-settings create -n mydiag --resource $aks_id --workspace $wsid \
          --metrics '[{"category": "AllMetrics", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false }, "timeGrain": null}]' \
          --logs '[{"category": "kube-apiserver", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}, 
               {"category": "kube-controller-manager", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}, 
               {"category": "kube-scheduler", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}, 
               {"category": "kube-audit", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}, 
               {"category": "cluster-autoscaler", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}]' >/dev/null

     # If required, create outbound rules in the aks cluster
     if [[ "$lb_outbound_rules" == "yes" ]]
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

     # Configure allowed range of IPs
     if [[ "$aks_api_fw" == "yes" ]]
     then
          authorized_ips="$aks_service_cidr,$aks_subnet_prefix"
          if [[ "$lb_outbound_rules" == "yes" ]]
          then
               authorized_ips="$authorized_ips,${pip1_ip}/32,${pip2_ip}/32"
          fi
          if [[ "$create_azfw" == "yes" ]]
          then
               authorized_ips="$authorized_ips,${azfw_ip}/32"
          fi
          my_ip=$(curl -s4 ifconfig.co)
          authorized_ips="$authorized_ips,${my_ip}/32"
          echo "Setting API server authorized IP ranges to $authorized_ips..."
          az aks update -n $this_aksname -g $rg --api-server-authorized-ip-ranges $authorized_ips >/dev/null
          # Check
          echo "Configured the following authorized IP ranges: "
          az aks show -n $this_aksname -g $rg -o tsv --query apiServerAccessProfile.authorizedIpRanges
     fi

     # Extra node pool
     if [[ "$create_extra_nodepool" == "yes" ]]
     then
          echo "Creating extra node pool..."
          az network vnet subnet create -g $rg -n $arm_subnet_name --vnet-name $this_vnet_name --address-prefix $arm_subnet_prefix >/dev/null
          arm_subnet_id=$(az network vnet subnet show -g $rg --vnet-name $this_vnet_name -n $arm_subnet_name --query id -o tsv)
          template_url=https://raw.githubusercontent.com/erjosito/deploy-aks/master/arm/aks-nodepool.json
          if [[ $ilpip == "yes" ]]
          then
               enable_node_pip=true
          else
               enable_node_pip=false
          fi
          az group deployment create -n aksdeployment -g $rg --template-uri $template_url --parameters '{
               "clusterName": {"value": "'$this_aksname'"},
               "location": {"value": "'$this_location'"},
               "agentPoolName": {"value": "'$arm_nodepool_name'"},
               "orchestratorVersion": {"value": "'$k8s_version'"},
               "vnetSubnetId": {"value": "'$arm_subnet_id'"},
               "enableNodePublicIp": {"value": '$enable_node_pip'}}'
     else
          echo "No additional node pool to create for cluster $this_aksname"
     fi

     # ILPIP for VMSS-based pools (load balancer needs to be Basic)
     # THis is not recommended, hence the danger_zone check in the next line
     if [[ "$no_vmss" != "yes" ]] && [[ "$ilpip" == "yes" ]] && [[ "$lb_sku_basic" == "yes" ]] && [[ "$danger_zone" == "yes" ]]
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
     if [[ "$create_appgw" == "yes" ]]
     then
          appgw_id=$(az network application-gateway show -n $this_appgw_name -g $rg --query id -o tsv)
          WaitUntilFinished $appgw_id
     else
          echo "No need to wait for app gw to finish creating for cluster $this_aksname"
     fi

     # Enable diagnostics to log analytics for the App Gw
     if [[ "$create_appgw" == "yes" ]]
     then
          echo "Enabling logging for app gateway $this_appgw_name to log analytics workspace $monitor_ws..."
          az monitor diagnostic-settings create -n mydiag --resource $appgw_id --workspace $wsid \
               --metrics '[{"category": "AllMetrics", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false }, "timeGrain": null}]' \
               --logs '[{"category": "ApplicationGatewayAccessLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}, 
                    {"category": "ApplicationGatewayPerformanceLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}, 
                    {"category": "ApplicationGatewayFirewallLog", "enabled": true, "retentionPolicy": {"days": 0, "enabled": false}}]' >/dev/null
     else
          echo "No app gw to configure diagnostic settings for cluster $this_aksname"
     fi

     # Enable autoscaling for app gateway to reduce costs
     if [[ "$create_appgw" == "yes" ]]
     then
          echo "Enabling auto-scaling for app gateway $this_appgw_name to log analytics workspace $monitor_ws..."
          az network application-gateway update -n $this_appgw_name -g $rg \
               --set autoscaleConfiguration='{"minCapacity": 1, "maxCapacity": 2}' \
               --set sku='{"name": "Standard_v2","tier": "Standard_v2"}' >/dev/null
     else
          echo "No app gw to configure autoscaling for cluster $this_aksname"
     fi

     # Connect route-table to AKS cluster (only needed if we have an az fw or a kubenet cluster)
     if [[ "$create_azfw" == "yes" ]] || [[ "$network_plugin" == "kubenet" ]]
     then
          noderg=$(az aks show -g $rg -n $this_aksname --query nodeResourceGroup -o tsv) 2>/dev/null
          # Look for an existing route table (there should be one for kubenet clusters)
          aks_rt_id=$(az network route-table list -g $noderg --query [0].id -o tsv) 2>/dev/null
          # If none is found, create one
          if [[ -z "$aks_rt_id" ]]
          then
               echo "Creating route table ${this_aks_rt_name}..."
               az network route-table create -n ${this_aks_rt_name} -g ${noderg} -l ${this_location} >/dev/null
               aks_rt_id=$(az network route-table show -n ${this_aks_rt_name} -g ${noderg} -o tsv --query id)
          else
               echo "Found existing route table ${aks_rt_id}"
          fi
          # See if it is already associated to the aks subnet
          associated_rt_id=$(az network vnet subnet show --vnet-name $this_vnet_name -g $rg -n $aks_subnet_name -o tsv --query routeTable)
          # If no route table associated, associate the route table (either the one found, or the newly created one)
          if [[ -z "$associated_rt_id" ]]
          then
               echo "Associating AKS subnet $aks_subnet_name with route table $aks_rt_id..."
               az network vnet subnet update -g $rg --vnet-name $this_vnet_name -n $aks_subnet_name --route-table $aks_rt_id >/dev/null
          else
               echo "AKS subnet $aks_subnet_name already associated to route table $associated_rt_id"
          fi
          # Send vnet traffic to the firewall
          if [[ "$create_azfw" == "yes" ]]
          then
               # Rule with IP address for master node
               kubectl config use-context $this_aksname
               hcp_ip=$(kubectl get endpoints -o=jsonpath='{.items[?(@.metadata.name == "kubernetes")].subsets[].addresses[].ip}')
               echo "AKS API IP addresses seems to be $hcp_ip, adding to Azure Firewall..."
               az network firewall network-rule create -f $this_azfw_name -g $rg -c AKS-egress --protocols Tcp --destination-addresses $hcp_ip --destination-ports 22 443 9000 --source-addresses $aks_subnet_prefix -n ControlPlane >/dev/null

               # Find out the name of the route table (we only had the ID) and add the route
               # Not using $this_aks_rt_name because the route table name would be different for kubenet clusters
               retrieved_aks_rt_name=$(az network route-table list -g $noderg --query '[0].name' -o tsv 2>/dev/null)  # Searching for the ID would be more accurate
               az network route-table route create -n vnet --route-table-name $retrieved_aks_rt_name -g $noderg --next-hop-type VirtualAppliance --address-prefix $vnetprefix --next-hop-ip-address $azfw_private_ip >/dev/null
               az network route-table route create -n defaultRoute --route-table-name $retrieved_aks_rt_name -g $noderg --next-hop-type VirtualAppliance --address-prefix "0.0.0.0/0" --next-hop-ip-address $azfw_private_ip >/dev/null
          fi
     fi

     # Add Windows pool to AKS cluster if required
     if [[ "$windows" == "yes" ]]
     then
          echo "Adding windows pool to cluster $this_aksname..."
          az aks nodepool add -g $rg --cluster-name $this_aksname --os-type Windows -n winnp -c 1 -k $k8s_version >/dev/null
     else
          echo "No windows node pool to add for cluster $this_aksname"
     fi

     # Linkerd
     if [[ "$deploy_linkerd" == "yes" ]]
     then
          echo "Verifying presence of linkerd client in the system..."
          linkerd_client_path=$(which linkerd)
          if [[ -z "$linkerd_client_path" ]]
          then
               echo "Please install the linkerd client utility in order to deploy linkerd. Try running 'curl -sL https://run.linkerd.io/install | sh'"
               if [[ $script_sourced == "yes" ]]
               then
                    return
               else
                    exit
               fi
          else
               echo "linkerd client found in $linkerd_client_path"
          fi
          echo "Checking linkerd pre-requisites..."
          kubectl config use-context $this_aksname
          linkerd check --pre
          echo "Installing linkerd..."
          linkerd install | kubectl apply -f -
          # Other installation modes (see https://linkerd.io/2/reference/cli/install/):
          # linkerd install --proxy-auto-inject | kubectl apply -f -
          # linkerd install --proxy-cpu-request 100m --proxy-memory-request 50Mi | kubectl apply -f -
     fi


     # Set Azure identity for app gw and assign permissions
     if [[ "$create_appgw" == "yes" ]]
     then
          noderg=$(az aks show -g $rg -n $this_aksname --query nodeResourceGroup -o tsv) 2>/dev/null
          echo "Creating identity $this_appgw_identity_name in RG $noderg..."
          az identity create -g $noderg -n $this_appgw_identity_name  >/dev/null
          appgw_identity_id=$(az identity show -g $noderg -n $this_appgw_identity_name --query id -o tsv) 2>/dev/null
          appgw_identity_clientid=$(az identity show -g $noderg -n $this_appgw_identity_name --query clientId -o tsv) 2>/dev/null
          appgw_identity_principalid=$(az identity show -g $noderg -n $this_appgw_identity_name --query principalId -o tsv) 2>/dev/null
          appgw_id=$(az network application-gateway show -g $rg -n $this_appgw_name --query id -o tsv) 2>/dev/null
          # Contributor role on app gw
          role_name=Contributor
          echo "Adding role $role_name for identity $this_appgw_identity_name ($appgw_identity_principalid) to $this_apgw_name ($appgw_id)..."
          until az role assignment create --role $role_name --assignee $appgw_identity_principalid --scope $appgw_id >/dev/null
          do
               echo "There has been an error assigning the role. Retrying in $wait_interval"
               sleep $wait_interval
          done
          assigned_role=$(az role assignment list --scope $appgw_id -o tsv --query "[?principalId=='$appgw_identity_principalid'].roleDefinitionName")
          if [[ "$assigned_role" == "$role_name" ]]
          then
               echo "Role $role_name assigned successfully"
          else
               echo "It looks like the role assignment did not work, the assigned role seems to be $assigned_role instead of $role_name"
          fi
          # Reader role on RG
          rgid=$(az group show -n $rg --query id -o tsv) 2>/dev/null
          role_name=Reader
          echo "Adding role Reader for identity $this_appgw_identity_name ($appgw_identity_principalid) to $rg ($rgid)..."
          until az role assignment create --role $role_name --assignee $appgw_identity_principalid --scope $rgid >/dev/null
          do
               echo "There has been an error assigning the role. Retrying in $wait_interval"
               sleep $wait_interval
          done
          assigned_role=$(az role assignment list --scope $rgid -o tsv --query "[?principalId=='$appgw_identity_principalid'].roleDefinitionName")
          if [[ "$assigned_role" == "$role_name" ]]
          then
               echo "Role $role_name assigned successfully"
          else
               echo "It looks like the role assignment did not work, the assigned role seems to be $assigned_role instead of $role_name"
          fi
     fi

     # Install Pod Identity
     if [[ "$create_appgw" == "yes" ]] || [[ "$flexvol" == "yes" ]] || [[ "$deploy_pod_identity" == "yes" ]]
     then
          if [[ "$aks_rbac" == "yes" ]]
          then
               echo "Enabling pod identity for RBAC cluster $this_aksname..."
               kubectl create -f https://raw.githubusercontent.com/Azure/aad-pod-identity/master/deploy/infra/deployment-rbac.yaml >/dev/null
          else
               echo "Enabling pod identity for non-RBAC cluster $this_aksname..."
               kubectl create -f https://raw.githubusercontent.com/Azure/aad-pod-identity/master/deploy/infra/deployment.yaml >/dev/null
          fi
     fi

     # Enable Helm if explicitly requested, or if required by other apps (AGIC, nginx ingress, policy)
     if [[ "$helm_version" == "2" ]]
     then
          if [[ "$enable_helm" == "yes" ]] || [[ "$create_appgw" == "yes" ]] || [[ "$deploy_nginx_ingress" == "yes" ]] || [[ "$deploy_arc" == "yes" ]]
          then
               if [[ "$aks_rbac" == "yes" ]]
               then
                    echo "Enabling Helm for RBAC cluster $this_aksname..."
                    kubectl config use-context $this_aksname
                    kubectl create serviceaccount --namespace kube-system tiller-sa >/dev/null
                    kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller-sa >/dev/null
                    echo "Initializing helm2 with tiller..."
                    helm2 init --tiller-namespace kube-system --service-account tiller-sa >/dev/null
               else
                    echo "Enabling Helm for non-RBAC cluster $this_aksname..."
                    helm2 init >/dev/null
               fi
               # Check that tiller has deployed successfully
               retry_count=0
               until [[ "$(kubectl get deploy/tiller-deploy -n kube-system -o json | jq -rc '.status.readyReplicas')" == "1" ]]
               do
                    if [[ $retry_count -gt $max_retries ]]
                    then
                         "Maximum retries, tiller pod not ready, something went wrong..."
                         if [[ $script_sourced == "yes" ]]
                         then
                              return
                         else
                              exit
                         fi
                    fi
                    echo "Tiller pod not ready. Waiting $wait_interval..."
                    sleep $wait_interval
                    retry_count=$(( $retry_count + 1 ))
               done
               echo "Tiller pod ready in cluster $this_aksname"
          fi
     fi

     # Onboard to ARC if required (helm3 only)
     if [[ "$deploy_arc" == "yes" ]]
     then
          this_aksname_arc="$this_aksname"-arc
          echo "Deploying helm chart for ARC integration as connected cluster $this_aksname_arc in resource group $rg..."
          helm3 repo add haikupreview https://haikupreview.azurecr.io/helm/v1/repo >/dev/null
          helm3 fetch haikupreview/haiku-agents >/dev/null
          helm3 upgrade haiku haiku-agents-0.1.6.tgz --install --set global.subscriptionId=${subid},global.resourceGroupName=${rg},global.resourceName=${this_aksname_arc},global.location=${this_location},global.tenantId=${tenantid},global.clientId=${id},global.clientSecret=${appsecret} >/dev/null
     fi

     # Add helm repo for App GW Ingress Controller
     if [[ "$create_appgw" == "yes" ]]
     then
          echo "Adding helm repos for AGIC in cluster $this_aksname..."
          $helm_exec repo add application-gateway-kubernetes-ingress https://appgwingress.blob.core.windows.net/ingress-azure-helm-package/ >/dev/null
          $helm_exec repo update >/dev/null
          kubectl config use-context $this_aksname
          master_ip=$(kubectl cluster-info | grep master | cut -d/ -f3 | cut -d: -f 1 2>/dev/null)
          echo "Installing helm chart for AGIC for master IP address $master_ip with helm version $helm_version..."
          wget https://raw.githubusercontent.com/Azure/application-gateway-kubernetes-ingress/master/docs/examples/sample-helm-config.yaml -O helm-config.yaml 2>/dev/null
          sed -i "s|<subscriptionId>|${subid}|g" helm-config.yaml
          sed -i "s|<resourceGroupName>|${rg}|g" helm-config.yaml
          sed -i "s|<applicationGatewayName>|${this_appgw_name}|g" helm-config.yaml
          sed -i "s|<identityResourceId>|${appgw_identity_id}|g" helm-config.yaml
          sed -i "s|<identityClientId>|${appgw_identity_clientid}|g" helm-config.yaml
          sed -i "s|<aks-api-server-address>|${master_ip}|g" helm-config.yaml
          sed -i "s|enabled: false|enabled: true|g" helm-config.yaml
          agic_chart_name=agic
          if [[ "$helm_version" == "2" ]]
          then
               $helm_exec install -f helm-config.yaml application-gateway-kubernetes-ingress/ingress-azure -n $agic_chart_name >/dev/null
               retry_count=0
               until [[ $(helm2 list --output json | jq -rc '.Releases[] | select(.Name == "'$agic_chart_name'") | .Status') == "DEPLOYED" ]]
               do
                    if [[ $retry_count -gt $max_retries ]]
                    then
                         "Maximum retries, AGIC chart not ready, something went wrong..."
                         if [[ $script_sourced == "yes" ]]
                         then
                              return
                         else
                              exit
                         fi
                    fi
                    echo "AGIC chart not ready. Waiting $wait_interval..."
                    sleep $wait_interval
                    retry_count=$(( $retry_count + 1 ))
               done
               echo -e "AGIC chart status is ${green}DEPLOYED${normal}"
          else
               $helm_exec install $agic_chart_name -f helm-config.yaml application-gateway-kubernetes-ingress/ingress-azure >/dev/null
          fi
     fi

     # Enable virtual node (verify that CNI plugin is Azure?)
     if [[ "$create_vnode" == "yes" ]]
     then
          if [[ "$network_plugin" == "azure" ]]
          then
               echo "Enabling Virtual Node add-on in cluster $this_aksname..."
               az aks enable-addons -g $rg -n $this_aksname --addons virtual-node --subnet-name $subnet_aci
          else
               echo "Virtual Node can only be enabled in Azure CNI clusters"
          fi
     fi

     # If the app routing addon to the Azure cluster or the kubenet cluster
     # Note that a previous check verified that only one ingress controller is selected, defaulting to the AGIC
     if [[ "$enable_approuting_addon" == "yes" ]]
     then
          echo "Enabling application routing addon for cluster $this_aksname..."
          az aks enable-addons -g $rg -n $this_aksname --addons http_application_routing >/dev/null
     fi

     # If the nginx ingress controller is to be deployed
     # More details in https://kubernetes.github.io/ingress-nginx/deploy/, https://docs.microsoft.com/azure/aks/ingress-internal-ip
     if [[ "$deploy_nginx_ingress" == "yes" ]]
     then
          echo "Deploying nginx ingress controller for cluster $this_aksname..."
          kubectl config use-context $this_aksname
          kubectl create namespace $nginx_ingress_ns_name
          if [[ $helm_version == "3" ]]      # In helm3, with no helm init, the stable repo must be initialized (see https://github.com/helm/helm/issues/6359)
          then
               $helm_exec repo add stable https://kubernetes-charts.storage.googleapis.com
               $helm_exec repo update >/dev/null
          fi
          # Decide if external or internal IP, for the time being based on whether an AzFw is being deployed too
          if [[ "$create_azfw" == "yes" ]]
          then
               # Internal ingress controller (requires an additional file with the internal IP address to use)
               manifest_url=https://raw.githubusercontent.com/erjosito/deploy-aks/master/helpers/nginx-ingress-internal.yaml
               manifest_filename=nginx-ingress-internal.yaml
               wget $manifest_url -O $manifest_filename 2>/dev/null
               sed -i "s|<lb_private_ip>|${nginx_ingress_private_ip}|g" $manifest_filename
               $helm_exec install nginx stable/nginx-ingress --namespace $nginx_ingress_ns_name -f $manifest_filename \
                         --set controller.replicaCount=2 --set controller.nodeSelector."beta\.kubernetes\.io/os"=linux \
                         --set defaultBackend.nodeSelector."beta\.kubernetes\.io/os"=linux >/dev/null
          else
               # External ingress controller (default for helm)
               $helm_exec install nginx stable/nginx-ingress --namespace $nginx_ingress_ns_name \
                         --set controller.replicaCount=2 --set controller.nodeSelector."beta\.kubernetes\.io/os"=linux \
                         --set defaultBackend.nodeSelector."beta\.kubernetes\.io/os"=linux >/dev/null
          fi
          # Verify IP address
          nginx_ingress_svc_name=$(kubectl get svc -n $nginx_ingress_ns_name -o json | jq -r '.items[] | select(.spec.type == "LoadBalancer") | .metadata.name')
          if [[ -z ${nginx_ingress_svc_name} ]]
          then
               echo "Could not retrieve the name for the service of the nginx ingress controller"
          else
               echo "Trying to get IP address of service ${nginx_ingress_svc_name} in namespace ${nginx_ingress_svc_name}..."
               nginx_ingress_ip=$(kubectl get svc/$nginx_ingress_svc_name -n $nginx_ingress_ns_name -o json | jq -rc '.status.loadBalancer.ingress[0].ip' 2>/dev/null)
               while [[ "$nginx_ingress_ip" == "null" ]]
               do
                    echo "Waiting $wait_interval for service $nginx_ingress_svc_name to get a LoadBalancer IP address..."
                    sleep $wait_interval
                    nginx_ingress_ip=$(kubectl get svc/$nginx_ingress_svc_name -n $nginx_ingress_ns_name -o json | jq -rc '.status.loadBalancer.ingress[0].ip' 2>/dev/null)
               done
          fi
     fi

     # AKV flexvol
     if [[ "$flexvol" == "yes" ]]
     then
          # AKV control plane
          echo "Installing AKV flexvol components in the cluster..."
          kubectl create -f https://raw.githubusercontent.com/Azure/kubernetes-keyvault-flexvol/master/deployment/kv-flexvol-installer.yaml >/dev/null
          # Managed identity and permissions
          echo "Creating managed identity for AKV Flexvol $this_flexvol_id_name..."
          az identity create -g $rg -n $this_flexvol_id_name >/dev/null
          flexvol_id_id=$(az identity show -g $rg -n $this_flexvol_id_name --query id -o tsv 2>/dev/null)
          flexvol_id_clientid=$(az identity show -g $rg -n $this_flexvol_id_name --query clientId -o tsv 2>/dev/null)
          flexvol_id_principalid=$(az identity show -g $rg -n $this_flexvol_id_name --query principalId -o tsv 2>/dev/null)
          echo "Assigning Reader permissions for the new identity $this_flexvol_id_name (principal IP $flexvol_id_principalid) on the Azure KeyVault $flexvol_kv_id..."
          role_name=Reader
          until az role assignment create --role $role_name --assignee $flexvol_id_principalid --scope $flexvol_kv_id >/dev/null
          do
               echo "There has been an error. Retrying in $wait_interval"
               sleep $wait_interval
          done
          # Verify
          assigned_role=$(az role assignment list --scope $flexvol_kv_id -o tsv --query "[?principalId=='$flexvol_id_principalid'].roleDefinitionName" 2>/dev/null)
          if [[ "$assigned_role" == "$role_name" ]]
          then
               echo "Role $role_name assigned successfully"
          else
               echo "It looks like the role assignment did not work, the assigned role seems to be $assigned_role instead of $role_name"
          fi
          az keyvault set-policy -n $flexvol_kv_name --secret-permissions get --spn $flexvol_id_clientid >/dev/null
          # Create aadpod identity and identitybinding k8s objects
          echo "Deploying k8s pod identity for flexvol access..."
          kubectl config use-context $this_aksname
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
          if [[ "$returned_secret_value" == "$flexvol_secret_value" ]]
          then
               echo "It worked!"
          fi
     fi
done

# Create SQL DB with private link endpoint
# https://docs.microsoft.com/en-us/azure/private-link/create-private-endpoint-cli
if [[ "$create_db" == "yes" ]]
then
     if [[ "$db_type" == "azuresql" ]]
     then
          # Variables
          sql_endpoint_name=sqlPrivateEndpoint
          private_zone_name=privatelink.database.windows.net
          # Create **one** SQL Server in a certain location (see variables)
          echo "Creating Azure SQL server and database"
          az sql server create -n $db_server_name -g $rg -l $sql_server_location --admin-user $db_server_username --admin-password $default_password >/dev/null
          db_server_id=$(az sql server show -n $db_server_name -g $rg -o tsv --query id) 2>/dev/null
          az sql db create -n $db_db_name -s $db_server_name -g $rg -e Basic -c 5 --no-wait >/dev/null
          echo "Creating subnets for database private endpoint..."
          for this_location in "${location_list[@]}"
          do
               this_vnet_name="$vnet"-"$this_location"
               # Create subnet for private endpoint
               echo "Creating subnet $db_subnet_name in vnet $this_vnet_name..."
               az network vnet subnet create -g $rg -n $db_subnet_name --vnet-name $this_vnet_name --address-prefix $db_subnet_prefix >/dev/null
               az network vnet subnet update -n $db_subnet_name -g $rg --vnet-name $this_vnet_name --disable-private-endpoint-network-policies true >/dev/null
               echo "Creating private endpoint for Azure SQL Server in subnet $db_subnet_name..."
               az network private-endpoint create -n $sql_endpoint_name -g $rg --vnet-name $this_vnet_name --subnet $db_subnet_name --private-connection-resource-id $db_server_id --group-ids sqlServer --connection-name sqlConnection >/dev/null
               endpoint_nic_id=$(az network private-endpoint show -n $sql_endpoint_name -g $rg --query 'networkInterfaces[0].id' -o tsv)
               endpoint_nic_ip=$(az resource show --ids $endpoint_nic_id --api-version 2019-04-01 -o tsv --query properties.ipConfigurations[0].properties.privateIPAddress)
               # Create private DNS zone (one per location), link to vnet and create DNS records
               echo "Creating private DNS zone $private_zone_name"
               az network private-dns zone create -g $rg -n "$private_zone_name" >/dev/null
               az network private-dns link vnet create -g $rg --zone-name "$private_zone_name" -n MyDNSLink --virtual-network $this_vnet_name --registration-enabled false  >/dev/null
               # Before creating the recordset verify if it was automatically created by private link?
               found_record_set=$(az network private-dns record-set a show -n $db_server_name --zone-name $private_zone_name -g $rg -o tsv --query name 2>/dev/null)
               if [[ "$found_record_set" == "$db_server_name" ]]
               then
                    echo "Recordset $db_server_name already exists in DNS zone $private_zone_name, no need to create it"
               else
                    echo "Creating recordset $db_server_name in DNS zone $private_zone_name pointing to IP $endpoint_nic_ip..."
                    az network private-dns record-set a create --name $db_server_name --zone-name $private_zone_name -g $rg >/dev/null
                    az network private-dns record-set a add-record --record-set-name $db_server_name --zone-name $private_zone_name -g $rg -a $endpoint_nic_ip >/dev/null
               fi
          done
          # Waiting to finish the db creation
          db_db_id=$(az sql db show -n $db_db_name -s $db_server_name -g $rg -o tsv --query id) 2>/dev/null
          if [[ -z "$db_db_id" ]]
          then
               echo "There was a problem creating the database, not able to retrieve its ID..."
          else
               WaitUntilFinished $db_db_id
          fi
     fi
fi

# Deploy sample apps, depending of the scenario
echo "Installing sample apps..."

# Decide if using a DNS zone to publish names (if the one specified in the variables exists) or use nip.io
zonename=$(az network dns zone list -o tsv --query "[?name=='$dnszone'].name" 2>/dev/null)
if [[ "$zonename" == "$dnszone" ]]
then
     dnsrg=$(az network dns zone list -o tsv --query "[?name=='$dnszone'].resourceGroup")
     echo "Azure DNS zone $dnszone found in resource group $dnsrg, using Azure DNS for app names"
     use_azure_dns=yes
else
     echo "Azure DNS zone $dnszone not found in subscription, using public zone $ingress_ip.nip.io for app names"
     use_azure_dns=no
     zonename="$ingress_ip".nip.io
fi


# Create Azure Traffic Manager profile if there is an ingress controller and there is more than one location
# In order to test, having an ingress controller should not be a requirement...
if [[ "$number_of_clusters" -gt 1 ]]
then
     if [[ "$create_appgw" == "yes" ]] || [[ "$enable_approuting_addon" == "yes" ]] || [[ "$deploy_nginx_ingress" == "yes" ]]
     then
          if [[ "$global_lb" == "tm" ]]
          then
               echo "Creating Traffic Manager profiles for multi-region apps (kuard and aspnet, see later)..."
               # kuard
               app_name=kuard
               kuard_tm_dns="$app_name""$RANDOM"
               kuard_tm_fqdn="$kuard_tm_dns".trafficmanager.net
               az network traffic-manager profile create -n $kuard_tm_dns -g $rg --routing-method $tm_routing --unique-dns-name $kuard_tm_dns >/dev/null
               echo -e "Created Traffic Manager profile on ${yellow}${kuard_tm_fqdn}${normal} with routing type $tm_routing"
               if [[ "$use_azure_dns" == "yes" ]]
               then
                    echo "Adding DNS CNAME $app_name in zone $dnszone for FQDN $kuard_tm_fqdn..."
                    # Remove any existing A recordset if required
                    record_set_name=$(az network dns record-set a show -z $dnszone -g $dnsrg -n $app_name --query name -o tsv 2>/dev/null)
                    if [[ -n "$record_set_name" ]]
                    then
                         echo "Deleting existing A recordset $record_set_name before being able to add CNAME recordset..."
                         az network dns record-set a delete -z $dnszone -g $dnsrg -n $app_name -y >/dev/null
                    fi
                    az network dns record-set cname create -g $dnsrg -z $dnszone -n $app_name >/dev/null
                    az network dns record-set cname set-record -g $dnsrg -z $dnszone -n $app_name -c $kuard_tm_fqdn >/dev/null
               fi
               # aspnet
               app_name=aspnet
               aspnet_tm_dns="$app_name""$RANDOM"
               aspnet_tm_fqdn="$aspnet_tm_dns".trafficmanager.net
               az network traffic-manager profile create -n $aspnet_tm_dns -g $rg --routing-method $tm_routing --unique-dns-name $aspnet_tm_dns >/dev/null
               echo -e "Created Traffic Manager profile on ${yellow}${aspnet_tm_fqdn}${normal} with routing type $tm_routing"
               if [[ "$use_azure_dns" == "yes" ]]
               then
                    echo "Adding DNS CNAME $app_name in zone $dnszone for FQDN $aspnet_tm_fqdn..."
                    # Remove any existing A recordset if required
                    record_set_name=$(az network dns record-set a show -z $dnszone -g $dnsrg -n $app_name --query name -o tsv 2>/dev/null)
                    if [[ -n "$record_set_name" ]]
                    then
                         echo "Deleting existing A recordset $record_set_name before being able to add CNAME recordset..."
                         az network dns record-set a delete -z $dnszone -g $dnsrg -n $app_name -y >/dev/null
                    fi
                    az network dns record-set cname create -g $dnsrg -z $dnszone -n $app_name >/dev/null
                    az network dns record-set cname set-record -g $dnsrg -z $dnszone -n $app_name -c $aspnet_tm_fqdn >/dev/null
               fi
          else
               # Azure Front Door: https://docs.microsoft.com/en-us/cli/azure/ext/front-door/network/front-door?view=azure-cli-latest
               echo "Azure Front Door not implemented yet!"
          fi
     else
          # If no ingress controller, it will be a simple kuard deployment, optionally with an Azure Firewall in front of it
          echo "Creating Traffic Manager profiles for multi-region apps (kuard and aspnet, see later)..."
          # kuard
          app_name=kuard
          kuard_tm_dns="$app_name""$RANDOM"
          kuard_tm_fqdn="$tm_dns".trafficmanager.net
          az network traffic-manager profile create -n $kuard_tm_dns -g $rg --routing-method $tm_routing --unique-dns-name $kuard_tm_dns >/dev/null
          echo "Created Traffic Manager profile on $kuard_tm_fqdn with routing type $tm_routing"
     fi
fi

# Needs to be done on a per location basis, because the domain is different
for this_location in "${location_list[@]}"
do
     this_vnet_name="$vnet"-"$this_location"
     this_aksname="$aksname"-"$this_location"
     this_appgw_name="$appgw_name"-"$this_location"
     this_appgw_pipname="$appgw_pipname"-"$this_location"
     this_azfw_name="$azfw_name"-"$this_location"
     this_azfw_pipname="$azfw_pipname"-"$this_location"

     # Identify if appgw, nginx or http app routing ingress controller
     if [[ "$create_appgw" == "yes" ]] || [[ "$enable_approuting_addon" == "yes" ]] || [[ "$deploy_nginx_ingress" == "yes" ]]
     then
          if [[ "$create_appgw" == "yes" ]] || [[ "$deploy_nginx_ingress" == "yes" ]]
          then
               # Either app gateway or nginx
               if [[ "$deploy_nginx_ingress" == "yes" ]]
               then
                    ingress_class=azure/nginx
                    # What if the nginx controller is frontended by a firewall? The IP address should be that of the AzFw...
                    if [[ "$create_azfw" == "yes" ]]
                    then
                         ingress_ip=$(az network public-ip show -g $rg -n $this_azfw_pipname --query ipAddress -o tsv 2>/dev/null)
                         echo "Region $this_location seems to be configured with an Azure Firewall in front of ngnix, with public IP $ingress_ip"
                    else
                         nginx_ingress_svc_name=ingress-nginx-ingress-controller
                         ingress_ip=$(kubectl get svc/$nginx_ingress_svc_name -o json | jq -rc '.status.loadBalancer.ingress[0].ip' 2>/dev/null)
                         echo "Region $this_location seems to be configured with an nginx ingress controller, with IP $ingress_ip"
                    fi
               fi
               if [[ "$create_appgw" == "yes" ]]
               then
                    ingress_class=azure/application-gateway
                    ingress_ip=$(az network public-ip show -g $rg -n $this_appgw_pipname --query ipAddress -o tsv)
                    echo "Region $this_location seems to be configured with an app gateway ingress controller, with IP $ingress_ip"
               fi
          else
               ingress_class=addon-http-application-routing
               use_azure_dns=no
               zonename=$(az aks show -g $rg -n $this_aksname --query addonProfiles.httpApplicationRouting.config.HTTPApplicationRoutingZoneName -o tsv)
               echo "The AKS application routing add on uses its own DNS zone for DNS, in this case the zone $zonename was created"
          fi
     fi

     # Select the right k8s context
     kubectl config use-context $this_aksname

     # kuard, port 8080, ingress (there has to be an ingress controller)
     if [[ "$create_appgw" == "yes" ]] || [[ "$enable_approuting_addon" == "yes" ]] || [[ $deploy_nginx_ingress == "yes" ]]
     then
          app_name=kuard
          # If we are routing with TM, the FQDN for each cluster should be the same
          if [[ "$number_of_clusters" -gt 1 ]]
          then
               app_fqdn=$app_name.$zonename
               this_app_name="$app_name"
          else
               this_app_name="$app_name"-"$this_location"
               app_fqdn=$this_app_name.$zonename
          fi
          # Download, modify and deploy manifest
          sample_filename=sample-kuard-ingress.yaml
          wget https://raw.githubusercontent.com/erjosito/deploy-aks/master/samples/kuard-ingress.yaml -O $sample_filename 2>/dev/null
          sed -i "s|<host_fqdn>|${app_fqdn}|g" $sample_filename
          sed -i "s|<ingress_class>|${ingress_class}|g" $sample_filename
          sed -i "s|<private_ip>|false|g" $sample_filename
          echo "Applying manifest $sample_filename to cluster $this_aksname for FQDN $app_fqdn..."
          kubectl apply -f $sample_filename
          # If >1 clusters no need to do DNS for the individual clusters, TM will do the name resolution
          if [[ "$use_azure_dns" == "yes" ]] && [[ "$number_of_clusters" == "1" ]]
          then
               if [[ $create_azfw == "yes" ]]
               then
                    # DNAT needs to be created
                    azfw_ip=$(az network public-ip show -g $rg -n $this_azfw_pipname --query ipAddress -o tsv 2>/dev/null)
                    public_ip=$azfw_ip
                    if [[ $deploy_nginx_ingress == "yes" ]]
                    then
                         nginx_ingress_svc_name=$(kubectl get svc -n $nginx_ingress_ns_name -o json | jq -r '.items[] | select(.spec.type == "LoadBalancer") | .metadata.name')
                         private_ip=$(kubectl get svc/$nginx_ingress_svc_name -n $nginx_ingress_ns_name -o json | jq -rc '.status.loadBalancer.ingress[0].ip' 2>/dev/null)
                    else
                         echo "Logic for retrieve the private IP of an app gw or an app routing addon missing!"
                    fi
                    echo "Creating DNAT rule in Azure Firewall to translate from $azfw_ip to $private_ip on port 80..."
                    az network firewall nat-rule create -n kuard-ingress -f $this_azfw_name -g $rg --destination-addresses $public_ip --destination-ports 80 --protocols Tcp --source-addresses '*' --translated-address $private_ip --translated-port 80 -c AKS-Services --priority 200 --action Dnat >/dev/null
               else
                    if [[ "$create_appgw" == "yes" ]]
                    then
                         public_ip=$appgw_ip
                    else
                         public_ip=$nginx_ingress_ip
                    fi
               fi
               echo "Adding DNS name $app_fqdn for public IP $public_ip..."
               az network dns record-set a create -g $dnsrg -z $dnszone -n $this_app_name >/dev/null
               az network dns record-set a add-record -g $dnsrg -z $dnszone -n $this_app_name -a $public_ip >/dev/null
          fi
          echo "You can access the sample app $this_app_name on ${app_fqdn}"
          # Traffic manager
          if [[ "$number_of_clusters" -gt 1 ]]
          then
               if [[ "$global_lb" == "tm" ]]
               then
                    echo "Creating endpoint for $ingress_ip in Traffic Manager profile $kuard_tm_fqdn..."
                    if [[ "$tm_routing" == "Weighted" ]]
                    then
                         az network traffic-manager endpoint create -n $this_location --profile-name $kuard_tm_dns -g $rg -t externalEndPoints --target $ingress_ip --weight 1 --custom-headers host=$app_fqdn >/dev/null
                    else
                         echo "Traffic Manager routing algorithm $tm_routing not supported by this script yet!"
                    fi
               else
                    echo "AFD not implemented yet!!"
               fi
          fi
     fi

     # kuard, port 8080, public/internal ALB, local externalTrafficPolicy
     # only if no ingress controller
     if [[ "$create_appgw" != "yes" ]] && [[ "$enable_approuting_addon" != "yes" ]] && [[ "$deploy_nginx_ingress" != "yes" ]]
     then
          if [[ "$lb_type" == "external" ]] && [[ "$create_azfw" != "yes" ]]
          then
               sample_filename=sample-kuard-alb.yaml
               wget https://raw.githubusercontent.com/erjosito/deploy-aks/master/samples/kuard-alb.yaml -O $sample_filename 2>/dev/null
               app_name=kuard-alb
          else
               sample_filename=sample-kuard-ilb.yaml
               wget https://raw.githubusercontent.com/erjosito/deploy-aks/master/samples/kuard-ilb.yaml -O $sample_filename 2>/dev/null
               sed -i "s|<ilb-subnet>|${akslb_subnet_name}|g" $sample_filename
               app_name=kuard-ilb
          fi
          echo "Applying manifest $sample_filename to cluster $this_aksname..."
          kubectl apply -f $sample_filename
          # echo "${app_name} deployed, run 'kubectl config use-context $this_aksname && kubectl get svc' to find out its public IP"
          kuard_alb_ip=$(kubectl get svc/$app_name -o json | jq -rc '.status.loadBalancer.ingress[0].ip' 2>/dev/null)
          while [[ "$kuard_alb_ip" == "null" ]]
          do
               echo "Waiting $wait_interval for service $app_name to get a LoadBalancer IP address..."
               sleep $wait_interval
               kuard_alb_ip=$(kubectl get svc/$app_name -o json | jq -rc '.status.loadBalancer.ingress[0].ip' 2>/dev/null)
          done
          echo "${app_name} deployed, reachable under the IP address $kuard_alb_ip"
          tm_endpoint_ip=$kuard_alb_ip # This is preliminary, the variable tm_endpoint_ip might be overwritten if there is an AzFw
          # Create AzFw DNAT rule
          if [[ "$create_azfw" == "yes" ]]
          then
               azfw_ip=$(az network public-ip show -g $rg -n $this_azfw_pipname --query ipAddress -o tsv 2>/dev/null)
               echo "Creating DNAT rule in Azure Firewall to translate from $azfw_ip to $kuard_alb_ip on port 8080..."
               az network firewall nat-rule create -n kuard-alb -f $this_azfw_name -g $rg --destination-addresses $azfw_ip --destination-ports 8080 --protocols Tcp --source-addresses '*' --translated-address $kuard_alb_ip --translated-port 8080 -c AKS-Services --priority 200 --action Dnat >/dev/null
               tm_endpoint_ip=$azfw_ip
          fi
          # Traffic manager (or AFD, in the future)
          if [[ "$number_of_clusters" -gt 1 ]]
          then
               if [[ "$lb_type" == "external" ]] || [[ "$create_azfw" == "yes" ]]
               then
                    if [[ "$global_lb" == "tm" ]]
                    then
                         echo "Creating endpoint for $app_fqdn in Traffic Manager profile $aspnet_tm_fqdn..."
                         if [[ "$tm_routing" == "Weighted" ]]
                         then
                              az network traffic-manager endpoint create -n $this_location --profile-name $aspnet_tm_dns -g $rg -t externalEndPoints --target $tm_endpoint_ip --weight 1 >/dev/null
                         else
                              echo "Traffic Manager routing algorithm $tm_routing not supported by this script yet!"
                         fi
                    else
                         echo "AFD not implemented yet!!"
                    fi
               fi
          fi

     fi

     # sample aspnet app, port 80, ingress (there has to be an ingress controller)
     if [[ "$create_appgw" == "yes" ]] || [[ "$enable_approuting_addon" == "yes" ]]
     then
          app_name=aspnet
          # If we are routing with TM, the FQDN for each cluster should be the same
          if [[ "$number_of_clusters" -gt 1 ]]
          then
               app_fqdn=$app_name.$zonename
               this_app_name="$app_name"
          else
               app_fqdn=$this_app_name.$zonename
               this_app_name="$app_name"-"$this_location"
          fi
          # Download, modify and deploy manifest
          sample_filename=sample-aspnet-ingress.yaml
          wget https://raw.githubusercontent.com/erjosito/deploy-aks/master/samples/aspnet-ingress.yaml -O $sample_filename 2>/dev/null 
          sed -i "s|<host_fqdn>|${app_fqdn}|g" $sample_filename
          sed -i "s|<ingress_class>|${ingress_class}|g" $sample_filename
          echo "Applying manifest $sample_filename to cluster $this_aksname..."
          kubectl apply -f $sample_filename

          # If >1 clusters no need to do DNS for the individual clusters, TM will do the name resolution
          if [[ "$use_azure_dns" == "yes" ]] && [[ "$number_of_clusters" == "1" ]]
          then
               echo "Adding DNS name $app_fqdn for public IP $appgw_ip..."
               az network dns record-set a create -g $dnsrg -z $dnszone -n $this_app_name >/dev/null
               az network dns record-set a add-record -g $dnsrg -z $dnszone -n $this_app_name -a $appgw_ip >/dev/null
          fi
          echo "You can access the sample app $this_app_name on ${app_fqdn}"
          # Traffic manager
          if [[ "$number_of_clusters" -gt 1 ]]
          then
               if [[ "$global_lb" == "tm" ]]
               then
                    echo "Creating endpoint for $ingress_ip in Traffic Manager profile $aspnet_tm_fqdn..."
                    if [[ "$tm_routing" == "Weighted" ]]
                    then
                         az network traffic-manager endpoint create -n $this_location --profile-name $aspnet_tm_dns -g $rg -t externalEndPoints --target $ingress_ip --weight 1 --custom-headers host=$app_fqdn >/dev/null
                    else
                         echo "Traffic Manager routing algorithm $tm_routing not supported by this script yet!"
                    fi
               else
                    echo "AFD not implemented yet!!"
               fi
          fi
     fi

     # pythonsql to verify access to the database over private link
     # PRIVATE REPO!! Move to dockerhub?
     if [[ "$create_db" == "yes" ]]
     then
          if [[ "$db_type" == "azuresql" ]]
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
if [[ "$create_vm" == "yes" ]]
then
     echo "To connect to the test VM (or use it as jump host for the k8s nodes):"
     for this_location in "${location_list[@]}"
     do
          this_vm_name="$vm_name"-"$this_location"
          this_vm_pip_name="$this_vm_name"-pip
          this_vm_pip_ip=$(az network public-ip show -g $rg -n $this_vm_pip_name --query ipAddress -o tsv)
          # No user required, since uisng publich SSH key auth
          echo -e "  ${green}ssh "$this_vm_pip_ip"${normal}"
     done
fi

# Print info to troubleshoot the firewall with the log analytics extension
echo "Checking that log-analytics extension is installed..."
found_log_extension=$(az extension list -o tsv --query "[?name=='log-analytics'].name" 2>/dev/null)
if [[ -z "$found_aks_extension" ]]
then
     echo "Installing log-analytics Azure CLI extension..."
     az extension add -n log-analytics >/dev/null
else
     echo "log-analytics Azure CLI extension found"
fi
ws_customerid=$(az monitor log-analytics workspace show -n $monitor_ws -g $monitor_rg --query customerId -o tsv 2>/dev/null)
query='AzureDiagnostics 
| where ResourceType == "AZUREFIREWALLS" 
| where Category == "AzureFirewallApplicationRule" 
| where TimeGenerated >= ago(4m) 
| project Protocol=split(msg_s, " ")[0], From=split(msg_s, " ")[iif(split(msg_s, " ")[0]=="HTTPS",3,4)], To=split(msg_s, " ")[iif(split(msg_s, " ")[0]=="HTTPS",5,6)], Action=trim_end(".", tostring(split(msg_s, " ")[iif(split(msg_s, " ")[0]=="HTTPS",7,8)])), Rule_Collection=iif(split(msg_s, " ")[iif(split(msg_s, " ")[0]=="HTTPS",10,11)]=="traffic.", "AzureInternalTraffic", iif(split(msg_s, " ")[iif(split(msg_s, " ")[0]=="HTTPS",10,11)]=="matched.","NoRuleMatched",trim_end(".",tostring(split(msg_s, " ")[iif(split(msg_s, " ")[0]=="HTTPS",10,11)])))), Rule=iif(split(msg_s, " ")[11]=="Proceeding" or split(msg_s, " ")[12]=="Proceeding","DefaultAction",split(msg_s, " ")[12]), msg_s 
| where Rule_Collection != "AzureInternalTraffic" 
| where Action == "Deny" 
| take 100'
az monitor log-analytics query -w $ws_customerid --analytics-query $query -o tsv


# Calculate script run time
script_run_time=$(expr `date +%s` - $script_start_time)
((minutes=${script_run_time}/60))
((seconds=${script_run_time}%60))
echo "Total script run time was $minutes minutes and $seconds seconds"

