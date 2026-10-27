// Example: production Windows Server joined to Active Directory (delegated OU).
using '../../main.bicep'

param vmName = 'vmprdapp01'
param joinType = 'ActiveDirectory'
param vmSize = 'Standard_D4s_v5'
param zone = '1'
param licenseType = 'Windows_Server'
param adminUsername = 'azlocaladmin'
param subnetResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-network-prod/providers/Microsoft.Network/virtualNetworks/vnet-prod/subnets/snet-servers'

param keyVaultName = 'kv-vmprov-prod'

param domainFqdn = 'corp.contoso.com'
param domainJoinOuPath = 'OU=Servers,OU=Azure,DC=corp,DC=contoso,DC=com'
param domainJoinUserName = 'svc-azdomainjoin@corp.contoso.com'
param domainJoinPasswordSecretName = 'domain-join-password'
param adGroupsOuPath = 'OU=ServerAccess,OU=Groups,OU=Azure,DC=corp,DC=contoso,DC=com'
param createAdLoginGroups = true

param tags = {
  environment: 'prod'
  workload: 'app'
  managedBy: 'vm-provisioning'
}
