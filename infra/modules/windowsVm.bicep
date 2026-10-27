// Windows Server VM with a private NIC only (no public IP), Trusted Launch and a
// system-assigned managed identity (required for Microsoft Entra ID join).

@description('VM / computer name. Max 15 characters (NetBIOS limit, required for AD and Entra join).')
@minLength(1)
@maxLength(15)
param vmName string

@description('Azure region.')
param location string

@description('VM size.')
param vmSize string

@description('Marketplace image reference.')
param imageReference object

@description('OS disk storage SKU.')
param osDiskType string

@description('Resource ID of the existing subnet the NIC is attached to.')
param subnetResourceId string

@description('Name of the local administrator account. Never use "admin" or "administrator".')
param adminUsername string

@description('Local administrator password. Supplied from Key Vault via getSecret(); never pass as plain text.')
@secure()
param adminPassword string

@description('Availability zone ("" for no zone).')
param zone string

@description('Azure Hybrid Benefit license type ("" or "Windows_Server").')
@allowed([
  ''
  'Windows_Server'
])
param licenseType string

@description('Enable encryption at host (requires the EncryptionAtHost feature to be registered on the subscription).')
param encryptionAtHost bool

@description('Tags applied to all resources.')
param tags object

resource nic 'Microsoft.Network/networkInterfaces@2025-05-01' = {
  name: 'nic-${vmName}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetResourceId
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2025-04-01' = {
  name: vmName
  location: location
  tags: tags
  zones: empty(zone) ? null : [
    zone
  ]
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    licenseType: empty(licenseType) ? null : licenseType
    hardwareProfile: {
      vmSize: vmSize
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      encryptionAtHost: encryptionAtHost
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          assessmentMode: 'AutomaticByPlatform'
        }
      }
    }
    storageProfile: {
      imageReference: imageReference
      osDisk: {
        name: 'osdisk-${vmName}'
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: osDiskType
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

output vmResourceId string = vm.id
output vmName string = vm.name
output principalId string = vm.identity.principalId
output privateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress
