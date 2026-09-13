// roles.bicep — two custom roles, both assignable ONLY to rg-valheim-server.
// Replaces Contributor for the SWA service principal and the VM identity.
// Neither role contains Microsoft.Authorization/*, so no principal here can grant itself more.
targetScope = 'subscription'

param serverRgId string

// Shared read/async-operation plumbing the ARM SDK and az CLI need.
var common = [
  'Microsoft.Resources/subscriptions/resourceGroups/read'
  'Microsoft.Resources/deployments/read'
  'Microsoft.Resources/deployments/write'
  'Microsoft.Resources/deployments/delete'
  'Microsoft.Resources/deployments/validate/action'
  'Microsoft.Resources/deployments/cancel/action'
  'Microsoft.Resources/deployments/operations/read'
  'Microsoft.Resources/deployments/operationstatuses/read'
  'Microsoft.Compute/locations/operations/read'
  'Microsoft.Network/locations/operations/read'
  'Microsoft.Network/locations/operationResults/read'
]

// Read actions on exactly the six types server.bicep deploys.
var reads = [
  'Microsoft.Compute/virtualMachines/read'
  'Microsoft.Compute/virtualMachines/instanceView/read'
  'Microsoft.Compute/disks/read'
  'Microsoft.Network/networkInterfaces/read'
  'Microsoft.Network/publicIPAddresses/read'
  'Microsoft.Network/virtualNetworks/read'
  'Microsoft.Network/virtualNetworks/subnets/read'
  'Microsoft.Network/networkSecurityGroups/read'
]

var deletes = [
  'Microsoft.Compute/virtualMachines/delete'
  'Microsoft.Compute/disks/delete'
  'Microsoft.Network/networkInterfaces/delete'
  'Microsoft.Network/publicIPAddresses/delete'
  'Microsoft.Network/virtualNetworks/delete'
  'Microsoft.Network/networkSecurityGroups/delete'
]

// ---------------------------------------------------------------------------
// Deployer — used by the SWA API. Can stand the server up, tear it down, and
// send a Run Command. Cannot create anything that isn't in this list, which
// means no AKS, no GPU VMs, no SQL, no App Service, no storage accounts.
// ---------------------------------------------------------------------------
resource deployer 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(serverRgId, 'valheim-deployer')
  properties: {
    roleName: 'Valheim Server Deployer'
    description: 'Create, read, delete and run commands on the single Valheim VM and its network. No other resource types, no role assignments.'
    type: 'CustomRole'
    assignableScopes: [ serverRgId ]
    permissions: [
      {
        actions: union(common, reads, deletes, [
          'Microsoft.Compute/virtualMachines/write'
          'Microsoft.Compute/virtualMachines/runCommand/action'
          'Microsoft.Compute/virtualMachines/retrieveBootDiagnosticsData/action'
          'Microsoft.Compute/disks/write'
          'Microsoft.Network/networkInterfaces/write'
          'Microsoft.Network/networkInterfaces/join/action'
          'Microsoft.Network/publicIPAddresses/write'
          'Microsoft.Network/publicIPAddresses/join/action'
          'Microsoft.Network/virtualNetworks/write'
          'Microsoft.Network/virtualNetworks/subnets/join/action'
          'Microsoft.Network/networkSecurityGroups/write'
          'Microsoft.Network/networkSecurityGroups/join/action'
        ])
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Destroyer — used by the VM's own identity for self-teardown. Delete only:
// it can run the complete-mode empty deployment, and nothing else. If this
// identity is ever compromised the worst it can do is end your game session.
// ---------------------------------------------------------------------------
resource destroyer 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(serverRgId, 'valheim-destroyer')
  properties: {
    roleName: 'Valheim Server Destroyer'
    description: 'Delete the Valheim VM and its network via deployment. Cannot create or modify any resource.'
    type: 'CustomRole'
    assignableScopes: [ serverRgId ]
    permissions: [
      {
        actions: union(common, reads, deletes)
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

output deployerRoleId string = deployer.id
output destroyerRoleId string = destroyer.id
