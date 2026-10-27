// Active Directory join + AD login groups. Wrapper that resolves the domain join password
// from Key Vault *inside* this module, so the Key Vault reference only exists in a deployment
// that actually runs (main.bicep deploys this module only when joinType = ActiveDirectory).

@description('Name of the existing VM.')
param vmName string

@description('Azure region.')
param location string

@description('FQDN of the AD domain.')
param domainFqdn string

@description('Distinguished name of the delegated OU for the computer object.')
param ouPath string

@description('Domain join account (UPN or DOMAIN\\user).')
param domainJoinUserName string

@description('Name of the Key Vault holding the domain join password.')
param keyVaultName string

@description('Resource group of the Key Vault.')
param keyVaultResourceGroupName string

@description('Subscription of the Key Vault.')
param keyVaultSubscriptionId string

@description('Key Vault secret name holding the domain join account password.')
param domainJoinPasswordSecretName string

@description('Distinguished name of the OU where login groups are created.')
param groupsOuPath string

@description('AD group added to local Administrators.')
param adminGroupName string

@description('AD group added to local Remote Desktop Users.')
param userGroupName string

@description('Create missing AD login groups.')
param createGroups bool

@description('Tags applied to the resources.')
param tags object

resource keyVault 'Microsoft.KeyVault/vaults@2025-05-01' existing = {
  name: keyVaultName
  scope: resourceGroup(keyVaultSubscriptionId, keyVaultResourceGroupName)
}

module domainJoin 'domainJoin.bicep' = {
  name: '${deployment().name}-join'
  params: {
    vmName: vmName
    location: location
    domainFqdn: domainFqdn
    ouPath: ouPath
    domainJoinUserName: domainJoinUserName
    domainJoinPassword: keyVault.getSecret(domainJoinPasswordSecretName)
    tags: tags
  }
}

module adLoginGroups 'adLoginGroups.bicep' = {
  name: '${deployment().name}-groups'
  dependsOn: [
    domainJoin
  ]
  params: {
    vmName: vmName
    location: location
    groupsOuPath: groupsOuPath
    adminGroupName: adminGroupName
    userGroupName: userGroupName
    createGroups: createGroups
    domainUserName: domainJoinUserName
    domainPassword: keyVault.getSecret(domainJoinPasswordSecretName)
    tags: tags
  }
}
