// Example: Windows Server joined to Microsoft Entra ID.
// Entra login groups (<prefix>-<VMNAME>-Admins / -Users) are created by the pipeline
// if missing and granted the VM login roles on the VM scope.
using '../../main.bicep'

param vmName = 'vmdevweb01'
param joinType = 'EntraID'
param vmSize = 'Standard_D2s_v5'
param adminUsername = 'azlocaladmin'
param subnetResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-network-dev/providers/Microsoft.Network/virtualNetworks/vnet-dev/subnets/snet-servers'

param keyVaultName = 'kv-vmprov-dev'

// Additional, pre-existing Entra groups (object IDs) can be granted login as well.
param entraAdminGroupObjectIds = []
param entraUserGroupObjectIds = []

param tags = {
  environment: 'dev'
  workload: 'web'
  managedBy: 'vm-provisioning'
}
