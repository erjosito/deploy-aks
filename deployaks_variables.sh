# Overall variables
rg=akstest
location=westeurope
keyvaultname=erjositoKeyvault
keyvault_rg=myKeyvault
vmsize=Standard_B2ms
adminuser=jose
aks_rbac=yes
wait_interval=5s
# Vnet
vnet=aksVnet
vnetprefix=10.13.0.0/16
vm_subnet_prefix=10.13.1.0/24
appgw_subnetprefix=10.13.10.0/24
azfw_subnet_prefix=10.13.11.0/24
db_subnet_prefix=10.13.50.0/24
aks_subnet_prefix=10.13.76.0/24
akslb_subnet_prefix=10.13.77.0/24
arm_subnet_prefix=10.13.79.0/24
aci_subnet_prefix=10.13.100.0/24
# Traffic Manager
tm_routing=Weighted
# Peered Vnet
peervnet=aksPeerVnet
peer_vnet_prefix=172.16.100.0/24
peer_vnet_location=westeurope
# AKS cluster 
aksname=akscluster
aks_subnet_name=aks
akslb_subnet_name=akslb
nwpolicy=azure
pip_name_prefix=aks-pip-
pip1_name="$pip_name_prefix"01
pip2_name="$pip_name_prefix"02
aks_rt_name=aks-routes
# Virtual node
subnet_aci=aci
# Tags
tag1_name=mytag
tag1_value=myvalue
# Test VM
vm_name=testvm
subnet_vm=vm
vm_image=ubuntults
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
appgw_pipname=appgw-pip
appgw_name=appgw
appgw_sku=Standard_v2
appgw_identity_name=appgwid
# Azure Firewall
azfw_name=azfw
azfw_pipname=azfw-pip
# Azure API Management
apim_name=aksapim
apim_subnet_name=apim
apim_publisher_name=John
apim_publisher_email="john.doe@contoso.com"
# Database
db_type=azuresql
db_server_name=myaksdbserver$RANDOM
db_server_username=sqladmin
db_server_location=$location
db_db_name=myaksdb
db_subnet_name=dbsubnet
db_cx_string_secret_name=dbCxString
# Extra node pool with ARM
arm_subnet_name=armpool
arm_nodepool_name=armpool