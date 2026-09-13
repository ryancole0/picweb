// rg-roles.bicep — assigns the two custom roles at rg-valheim-server scope.
// No Contributor anywhere.
param vmIdentityPrincipalId string
param swaPrincipalObjectId string
param deployerRoleId string
param destroyerRoleId string

resource swaDeployer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, swaPrincipalObjectId, deployerRoleId)
  properties: {
    roleDefinitionId: deployerRoleId
    principalId: swaPrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

resource vmDestroyer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, vmIdentityPrincipalId, destroyerRoleId)
  properties: {
    roleDefinitionId: destroyerRoleId
    principalId: vmIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}
