# Process arguments
for i in "$@"
do
     case $i in
          -g=*|--resource-group=*)
               rg="${i#*=}"
               shift # past argument=value
               ;;
          -n=*|--name=*)
               aksname="${i#*=}"
               shift # past argument=value
               ;;
     esac
done
set -- "${POSITIONAL[@]}"

# Check we have all the arguments we need
if [ -z "$rg" ] || [ -z "$aksname" ]
then
     echo "Please use this script as $0 -n=aks_name -g=resource_group"
     exit
fi

# Get the existing IPs
auth_ips=($(az aks show -n $aksname -g $rg -o tsv --query apiServerAccessProfile.authorizedIpRanges))
new_auth_ips=""
for ip in "${auth_ips[@]}"
do
    new_auth_ips="$new_auth_ips""$ip",
done
my_ip=$(curl -s4 ifconfig.co)
echo "It looks like your IP address is $my_ip"
new_auth_ips="$new_auth_ips""$my_ip""/32"

# Modify cluster
echo "Modifying cluster $aksname in resource group $rg with list of authorized IPs $new_auth_ips..."
az aks update -n $aksname -g $rg --api-server-authorized-ip-ranges $new_auth_ips >/dev/null
