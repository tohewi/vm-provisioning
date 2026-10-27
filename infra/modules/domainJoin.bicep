// Joins an existing VM to Active Directory Domain Services and places the computer
// object in a delegated OU. The password is passed only via protectedSettings,
// which are encrypted and never returned by the Azure API or written to logs.

@description('Name of the existing VM.')
param vmName string

@description('Azure region.')
param location string

@description('FQDN of the AD domain, e.g. corp.contoso.com.')
param domainFqdn string

@description('Distinguished name of the delegated OU, e.g. OU=Servers,OU=Azure,DC=corp,DC=contoso,DC=com.')
param ouPath string

@description('Domain join account (UPN or DOMAIN\\user) with delegated rights on the OU.')
param domainJoinUserName string

@description('Domain join account password. Supplied from Key Vault via getSecret().')
@secure()
param domainJoinPassword string

@description('Tags applied to the extension.')
param tags object

resource vm 'Microsoft.Compute/virtualMachines@2025-04-01' existing = {
  name: vmName
}

resource domainJoin 'Microsoft.Compute/virtualMachines/extensions@2025-04-01' = {
  parent: vm
  name: 'JoinDomain'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'JsonADDomainExtension'
    typeHandlerVersion: '1.3'
    autoUpgradeMinorVersion: true
    settings: {
      Name: domainFqdn
      OUPath: ouPath
      User: domainJoinUserName
      Restart: 'true'
      // 3 = NETSETUP_JOIN_DOMAIN | NETSETUP_ACCT_CREATE
      Options: '3'
    }
    protectedSettings: {
      Password: domainJoinPassword
    }
  }
}
