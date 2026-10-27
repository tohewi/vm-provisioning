// Joins an existing VM to Microsoft Entra ID (requires a system-assigned identity on the VM)
// and grants Entra security groups the built-in VM login roles on the VM scope.

@description('Name of the existing VM.')
param vmName string

@description('Azure region.')
param location string

@description('Object IDs of Entra groups granted "Virtual Machine Administrator Login".')
param adminGroupObjectIds string[]

@description('Object IDs of Entra groups granted "Virtual Machine User Login".')
param userGroupObjectIds string[]

@description('Optional Intune MDM application ID for automatic enrollment ("" to skip).')
param mdmId string

@description('Tags applied to the extension.')
param tags object

// Built-in role definition IDs (identical in every tenant).
var vmAdminLoginRoleId = '1c0163c0-47e6-4577-8991-ea5c82e286e4'
var vmUserLoginRoleId = 'fb879df8-f326-4884-b1cf-06f3ad86be52'

resource vm 'Microsoft.Compute/virtualMachines@2025-04-01' existing = {
  name: vmName
}

resource entraLogin 'Microsoft.Compute/virtualMachines/extensions@2025-04-01' = {
  parent: vm
  name: 'AADLoginForWindows'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.0'
    autoUpgradeMinorVersion: true
    settings: empty(mdmId) ? null : {
      mdmId: mdmId
    }
  }
}

resource adminLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for groupId in adminGroupObjectIds: {
    name: guid(vm.id, groupId, vmAdminLoginRoleId)
    scope: vm
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vmAdminLoginRoleId)
      principalId: groupId
      principalType: 'Group'
      description: 'Entra ID administrator login to ${vmName}'
    }
  }
]

resource userLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for groupId in userGroupObjectIds: {
    name: guid(vm.id, groupId, vmUserLoginRoleId)
    scope: vm
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vmUserLoginRoleId)
      principalId: groupId
      principalType: 'Group'
      description: 'Entra ID user login to ${vmName}'
    }
  }
]
