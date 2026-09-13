// core-resources.bicep — resource-group scoped module used by core.bicep
param location string
param storageAccountName string
param swaPrincipalObjectId string

// Built-in role IDs
var storageBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var managedIdentityOperator = 'f1a07417-d97a-45cb-824c-7a7467783830'

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' } // cheapest; world files are a few MB. Use Standard_GRS if you want geo-redundancy (~2x cost, still pennies).
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false // identity-only access
    supportsHttpsTrafficOnly: true
  }
}

resource blob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: sa
  name: 'default'
  properties: {
    // Soft delete = cheap insurance against a bad sync overwriting a good world.
    deleteRetentionPolicy: { enabled: true, days: 30 }
    isVersioningEnabled: true
  }
}

resource worldContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blob
  name: 'valheim'
}

// Lifecycle: keep versions for 30 days, and expire zipped backups after 60 days.
resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: sa
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'expire-old-versions'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: { blobTypes: [ 'blockBlob' ] }
            actions: { version: { delete: { daysAfterCreationGreaterThan: 30 } } }
          }
        }
        {
          name: 'expire-backups'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: { blobTypes: [ 'blockBlob' ], prefixMatch: [ 'valheim/backups/' ] }
            actions: { baseBlob: { delete: { daysAfterModificationGreaterThan: 60 } } }
          }
        }
      ]
    }
  }
}

// Identity the VM runs as. Pre-created so per-session deployments need no role assignments.
resource vmIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-valheim-vm'
  location: location
}

// Scoped to the single container, not the whole account: the VM identity cannot
// read or write any other container you later add to this storage account.
resource vmBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(worldContainer.id, vmIdentity.id, storageBlobDataContributor)
  scope: worldContainer
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributor)
    principalId: vmIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// The SWA API needs to attach this identity to VMs it creates.
resource swaMiOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vmIdentity.id, swaPrincipalObjectId, managedIdentityOperator)
  scope: vmIdentity
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', managedIdentityOperator)
    principalId: swaPrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

output vmIdentityPrincipalId string = vmIdentity.properties.principalId
output vmIdentityClientId string = vmIdentity.properties.clientId
output vmIdentityResourceId string = vmIdentity.id
