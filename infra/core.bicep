// core.bicep — deploy ONCE, at subscription scope.
// Creates the long-lived pieces that survive server destroy/recreate:
//   rg-valheim-core   : storage account (world saves + backups) + user-assigned identity
//   rg-valheim-server : empty RG that the ephemeral VM lives in; wiped on destroy
//
//   az deployment sub create -l eastus -f core.bicep \
//       -p swaPrincipalObjectId=<objectId of the SWA API service principal>
//
targetScope = 'subscription'

@description('Region for the persistent RG + storage account. Pick the "middle" region (East US).')
param coreLocation string = 'eastus'

@description('Object ID (not app ID) of the service principal used by the SWA API.')
param swaPrincipalObjectId string

@description('Globally unique storage account name (3-24 lowercase alphanumerics).')
param storageAccountName string = 'stvalheim${uniqueString(subscription().id)}'

var coreRgName = 'rg-valheim-core'
var serverRgName = 'rg-valheim-server'

resource coreRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: coreRgName
  location: coreLocation
}

resource serverRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: serverRgName
  location: coreLocation // metadata only; the VM itself can be in any region
}

module core 'core-resources.bicep' = {
  name: 'core-resources'
  scope: coreRg
  params: {
    location: coreLocation
    storageAccountName: storageAccountName
    swaPrincipalObjectId: swaPrincipalObjectId
  }
}

// Custom roles, assignable only to the disposable RG. No Contributor is used anywhere.
module roles 'roles.bicep' = {
  name: 'valheim-roles'
  params: {
    serverRgId: serverRg.id
  }
}

// Server RG permissions: the VM's identity (delete only) and the SWA API (deploy + delete).
module serverRgRoles 'rg-roles.bicep' = {
  name: 'server-rg-roles'
  scope: serverRg
  params: {
    vmIdentityPrincipalId: core.outputs.vmIdentityPrincipalId
    swaPrincipalObjectId: swaPrincipalObjectId
    deployerRoleId: roles.outputs.deployerRoleId
    destroyerRoleId: roles.outputs.destroyerRoleId
  }
}

output storageAccountName string = storageAccountName
output vmIdentityResourceId string = core.outputs.vmIdentityResourceId
output vmIdentityClientId string = core.outputs.vmIdentityClientId
output serverResourceGroup string = serverRgName
