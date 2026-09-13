// policy-assignments.bicep — assigned at rg-valheim-server scope by policy.bicep
param pinVmNameDefinitionId string
param capDisksDefinitionId string
param vmName string
param allowedVmSkus array
param allowedLocations array
param maxDiskSizeGB int

// Built-in definition GUIDs. Verify with:
//   az policy definition list --query "[?displayName=='Allowed resource types'].name" -o tsv
var builtIn = {
  allowedResourceTypes: 'a08ec900-254a-4555-9bf5-e42af04b5c5c'
  allowedVmSkus: 'cccc23c7-8427-4f53-ad12-b6a63eb452b3'
  allowedLocations: 'e56962a6-4747-49cd-b67b-bf8b01975c4c'
}

// Exactly what server.bicep deploys, plus deployments themselves. Anything else is denied.
var permittedTypes = [
  'Microsoft.Compute/virtualMachines'
  'Microsoft.Compute/virtualMachines/extensions'
  'Microsoft.Compute/virtualMachines/runCommands'
  'Microsoft.Compute/disks'
  'Microsoft.Network/networkInterfaces'
  'Microsoft.Network/publicIPAddresses'
  'Microsoft.Network/virtualNetworks'
  'Microsoft.Network/networkSecurityGroups'
  'Microsoft.Resources/deployments'
]

resource singleVm 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'valheim-single-vm'
  properties: {
    displayName: 'Valheim: single VM only'
    policyDefinitionId: pinVmNameDefinitionId
    parameters: { vmName: { value: vmName } }
    enforcementMode: 'Default'
  }
}

resource cheapDisks 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'valheim-cheap-disks'
  properties: {
    displayName: 'Valheim: small standard disks only'
    policyDefinitionId: capDisksDefinitionId
    parameters: { maxDiskSizeGB: { value: maxDiskSizeGB } }
  }
}

resource types 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'valheim-resource-types'
  properties: {
    displayName: 'Valheim: permitted resource types'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', builtIn.allowedResourceTypes)
    parameters: { listOfResourceTypesAllowed: { value: permittedTypes } }
  }
}

resource skus 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'valheim-vm-skus'
  properties: {
    displayName: 'Valheim: permitted VM sizes'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', builtIn.allowedVmSkus)
    parameters: { listOfAllowedSKUs: { value: allowedVmSkus } }
  }
}

resource locations 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'valheim-locations'
  properties: {
    displayName: 'Valheim: permitted regions'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', builtIn.allowedLocations)
    parameters: { listOfAllowedLocations: { value: allowedLocations } }
  }
}
