# Overall variables
rg=akstest
location=westeurope
keyvaultname=myKeyvault # Here it is expected to find SPs and SSH public keys
vnet=aksVnet
vnetprefix=10.13.0.0/16
vmsize=Standard_B2ms
adminuser=lab-user
aks_rbac=yes
wait_interval=5s

# AKS cluster 
aksname=akscluster
aks_subnet_name=azurecni
aks_subnet_prefix=10.13.76.0/24
nwpolicy=azure
pip_name_prefix=azure-pip-
pip1_name="$pip_name_prefix"01
pip2_name="$pip_name_prefix"02

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
acr_name=myAcr
# DNS
dnszone=some.domain.that.you.own.com
# App Gateway
appgw_subnetname=aksappgw
appgw_subnetprefix=10.13.10.0/24
appgw_pipname=appgw-pip
appgw_name=appgw
appgw_dnsname=appgw$RANDOM
appgw_sku=Standard_v2
appgw_identity_name=appgwid
# Database
db_type=azuresql
db_server_name=myaksdbserver$RANDOM
db_server_username=sqladmin
db_server_location=$location
db_db_name=myaksdb
db_subnet_name=dbsubnet
db_subnet_prefix=10.13.50.0/24
db_cx_string_secret_name=dbCxString
# Extra node pool with ARM
arm_subnet_name=armpool
arm_subnet_prefix=10.13.79.0/24
arm_nodepool_name=armpool
