// Ensures AD security groups for VM login exist (created in the delegated OU if missing)
// and adds them to the local Administrators / Remote Desktop Users groups on the VM.
// Implemented as a managed Run Command so no self-hosted agent with line of sight to
// the domain controllers is needed. The credential is sent as a protected parameter.

@description('Name of the existing, domain-joined VM.')
param vmName string

@description('Azure region.')
param location string

@description('Distinguished name of the OU where login groups are created.')
param groupsOuPath string

@description('AD group added to local Administrators.')
param adminGroupName string

@description('AD group added to local Remote Desktop Users.')
param userGroupName string

@description('Create the groups if they do not exist. When false, the groups must already exist.')
param createGroups bool

@description('Account with rights to create groups in the OU (normally the domain join account).')
param domainUserName string

@description('Password for domainUserName. Supplied from Key Vault via getSecret().')
@secure()
param domainPassword string

@description('Tags applied to the run command.')
param tags object

resource vm 'Microsoft.Compute/virtualMachines@2025-04-01' existing = {
  name: vmName
}

resource loginGroups 'Microsoft.Compute/virtualMachines/runCommands@2025-04-01' = {
  parent: vm
  name: 'Set-AdLoginGroups'
  location: location
  tags: tags
  properties: {
    source: {
      script: loadTextContent('../scripts/Set-AdLoginGroups.ps1')
    }
    parameters: [
      {
        name: 'GroupsOuPath'
        value: groupsOuPath
      }
      {
        name: 'AdminGroupName'
        value: adminGroupName
      }
      {
        name: 'UserGroupName'
        value: userGroupName
      }
      {
        name: 'DomainUserName'
        value: domainUserName
      }
      {
        name: 'CreateGroups'
        value: createGroups ? 'true' : 'false'
      }
    ]
    protectedParameters: [
      {
        name: 'DomainPassword'
        value: domainPassword
      }
    ]
    asyncExecution: false
    treatFailureAsDeploymentFailure: true
    timeoutInSeconds: 900
  }
}
