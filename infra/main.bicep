// Entry point: deploys one Windows Server VM that is either joined to Active Directory
// (into a delegated OU) or to Microsoft Entra ID, and configures login groups.
//
// Secrets (local admin password, domain join password) are NEVER parameters of this
// template. They are read from Key Vault with getSecret() and passed to @secure()
// module parameters, so they do not appear in pipeline variables, command lines,
// deployment history or logs.

targetScope = 'resourceGroup'

@description('VM / computer name. Max 15 characters (NetBIOS limit).')
@minLength(1)
@maxLength(15)
param vmName string

@description('Azure region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Identity to join the VM to.')
@allowed([
  'ActiveDirectory'
  'EntraID'
])
param joinType string

@description('VM size.')
param vmSize string = 'Standard_D2s_v5'

@description('Marketplace image reference.')
param imageReference object = {
  publisher: 'MicrosoftWindowsServer'
  offer: 'WindowsServer'
  sku: '2022-datacenter-azure-edition'
  version: 'latest'
}

@description('OS disk storage SKU.')
@allowed([
  'Standard_LRS'
  'StandardSSD_LRS'
  'Premium_LRS'
  'StandardSSD_ZRS'
  'Premium_ZRS'
])
param osDiskType string = 'Premium_LRS'

@description('Resource ID of the existing subnet. For AD join it must have line of sight to the domain controllers.')
param subnetResourceId string

@description('Availability zone ("" for no zone).')
@allowed([
  ''
  '1'
  '2'
  '3'
])
param zone string = ''

@description('Azure Hybrid Benefit license type ("" or "Windows_Server").')
@allowed([
  ''
  'Windows_Server'
])
param licenseType string = ''

@description('Enable encryption at host (requires the EncryptionAtHost feature on the subscription).')
param encryptionAtHost bool = false

@description('Local administrator account name. Must not be "admin" or "administrator".')
param adminUsername string

// ---------- Key Vault holding the secrets ----------

@description('Name of the existing Key Vault (enabledForTemplateDeployment = true).')
param keyVaultName string

@description('Resource group of the Key Vault.')
param keyVaultResourceGroupName string = resourceGroup().name

@description('Subscription of the Key Vault.')
param keyVaultSubscriptionId string = subscription().subscriptionId

@description('Key Vault secret name holding the local admin password (created by scripts/Set-LocalAdminPasswordSecret.ps1).')
param localAdminPasswordSecretName string = '${vmName}-localadmin'

// ---------- Login groups ----------

@description('Prefix of the login group names: <prefix>-<VMNAME>-Admins / -Users. Must match the PowerShell naming convention.')
param loginGroupPrefix string = 'SRV'

@description('Name of the group granted administrator login.')
param adminGroupName string = '${loginGroupPrefix}-${toUpper(vmName)}-Admins'

@description('Name of the group granted user (RDP) login.')
param userGroupName string = '${loginGroupPrefix}-${toUpper(vmName)}-Users'

// ---------- Active Directory ----------

@description('AD domain FQDN, e.g. corp.contoso.com. Required when joinType = ActiveDirectory.')
param domainFqdn string = ''

@description('DN of the delegated OU for the computer object. Required when joinType = ActiveDirectory.')
param domainJoinOuPath string = ''

@description('Domain join account (UPN or DOMAIN\\user). Required when joinType = ActiveDirectory.')
param domainJoinUserName string = ''

@description('Key Vault secret name holding the domain join account password.')
param domainJoinPasswordSecretName string = 'domain-join-password'

@description('DN of the OU where AD login groups live. Defaults to the computer OU.')
param adGroupsOuPath string = domainJoinOuPath

@description('Create missing AD login groups. When false the groups must already exist.')
param createAdLoginGroups bool = true

// ---------- Microsoft Entra ID ----------

@description('Object IDs of Entra groups granted "Virtual Machine Administrator Login".')
param entraAdminGroupObjectIds string[] = []

@description('Object IDs of Entra groups granted "Virtual Machine User Login".')
param entraUserGroupObjectIds string[] = []

@description('Optional Intune MDM application ID for automatic enrollment ("" to skip).')
param entraMdmId string = ''

@description('Tags applied to all resources.')
param tags object = {}

var isActiveDirectory = joinType == 'ActiveDirectory'
var isEntraId = joinType == 'EntraID'

resource keyVault 'Microsoft.KeyVault/vaults@2025-05-01' existing = {
  name: keyVaultName
  scope: resourceGroup(keyVaultSubscriptionId, keyVaultResourceGroupName)
}

module vm 'modules/windowsVm.bicep' = {
  name: '${deployment().name}-vm'
  params: {
    vmName: vmName
    location: location
    vmSize: vmSize
    imageReference: imageReference
    osDiskType: osDiskType
    subnetResourceId: subnetResourceId
    adminUsername: adminUsername
    adminPassword: keyVault.getSecret(localAdminPasswordSecretName)
    zone: zone
    licenseType: licenseType
    encryptionAtHost: encryptionAtHost
    tags: tags
  }
}

module domainJoin 'modules/domainJoin.bicep' = if (isActiveDirectory) {
  name: '${deployment().name}-domainjoin'
  dependsOn: [
    vm
  ]
  params: {
    vmName: vmName
    location: location
    domainFqdn: domainFqdn
    ouPath: domainJoinOuPath
    domainJoinUserName: domainJoinUserName
    domainJoinPassword: keyVault.getSecret(domainJoinPasswordSecretName)
    tags: tags
  }
}

module adLoginGroups 'modules/adLoginGroups.bicep' = if (isActiveDirectory) {
  name: '${deployment().name}-adlogingroups'
  dependsOn: [
    domainJoin
  ]
  params: {
    vmName: vmName
    location: location
    groupsOuPath: adGroupsOuPath
    adminGroupName: adminGroupName
    userGroupName: userGroupName
    createGroups: createAdLoginGroups
    domainUserName: domainJoinUserName
    domainPassword: keyVault.getSecret(domainJoinPasswordSecretName)
    tags: tags
  }
}

module entraJoin 'modules/entraJoin.bicep' = if (isEntraId) {
  name: '${deployment().name}-entrajoin'
  dependsOn: [
    vm
  ]
  params: {
    vmName: vmName
    location: location
    adminGroupObjectIds: entraAdminGroupObjectIds
    userGroupObjectIds: entraUserGroupObjectIds
    mdmId: entraMdmId
    tags: tags
  }
}

output vmResourceId string = vm.outputs.vmResourceId
output vmName string = vm.outputs.vmName
output vmPrincipalId string = vm.outputs.principalId
output privateIpAddress string = vm.outputs.privateIpAddress
output joinType string = joinType
output adminGroupName string = adminGroupName
output userGroupName string = userGroupName
@description('Name (not value) of the Key Vault secret holding the local admin credential.')
output localAdminSecretName string = localAdminPasswordSecretName
