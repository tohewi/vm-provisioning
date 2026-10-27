// Example: Windows Server joined to Active Directory (delegated OU).
// One .bicepparam file = one VM. Secrets are NOT stored here: the local admin password
// is generated into Key Vault by the pipeline and the domain join password must already
// exist in Key Vault (secret name: domainJoinPasswordSecretName).
using '../../main.bicep'

param vmName = 'vmdevapp01'
param joinType = 'ActiveDirectory'
param vmSize = 'Standard_D2s_v5'
param adminUsername = 'azlocaladmin'
param subnetResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-network-dev/providers/Microsoft.Network/virtualNetworks/vnet-dev/subnets/snet-servers'

param keyVaultName = 'kv-vmprov-dev'

param domainFqdn = 'corp.contoso.com'
param domainJoinOuPath = 'OU=Servers,OU=Azure,DC=corp,DC=contoso,DC=com'
param domainJoinUserName = 'svc-azdomainjoin@corp.contoso.com'
param domainJoinPasswordSecretName = 'domain-join-password'
param createAdLoginGroups = true

param tags = {
  environment: 'dev'
  workload: 'app'
  managedBy: 'vm-provisioning'
}
