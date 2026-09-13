// policy.bicep — guardrails for rg-valheim-server. Deploy once, after core.bicep.
//   az deployment sub create -l eastus -f policy.bicep
//
// Layer 1: name-pin the VM  -> at most ONE VM can exist in the RG (names are unique per type per RG)
// Layer 2: allowed resource types -> nothing but the six things server.bicep deploys
// Layer 3: allowed VM SKUs + allowed locations + disk size cap -> unit cost ceiling
//
// All effects are "deny", so no managed identity is needed on the assignments.
targetScope = 'subscription'

param serverRgName string = 'rg-valheim-server'
param vmName string = 'valheim-vm'
param allowedVmSkus array = [
  'Standard_D2as_v7 '
  'Standard_D4as_v7'
]
param allowedLocations array = [ 'eastus', 'southcentralus', 'swedencentral' ]
param maxDiskSizeGB int = 64

// ---------- custom definitions (definitions must live at sub or MG scope) ----------

resource pinVmName 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: 'valheim-single-vm'
  properties: {
    displayName: 'Valheim: only one VM, and it must be named correctly'
    description: 'Denies any virtual machine whose name is not the expected one. Because resource names are unique per type within a resource group, this caps the group at a single VM.'
    policyType: 'Custom'
    mode: 'All'
    parameters: {
      vmName: { type: 'String', metadata: { displayName: 'Permitted VM name' } }
    }
    policyRule: {
      if: {
        allOf: [
          { field: 'type', equals: 'Microsoft.Compute/virtualMachines' }
          { field: 'name', notEquals: '[parameters(\'vmName\')]' }
        ]
      }
      then: { effect: 'deny' }
    }
  }
}

resource capDisks 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: 'valheim-cheap-disks-only'
  properties: {
    displayName: 'Valheim: small standard disks only'
    description: 'Denies managed disks above a size cap or on Premium/Ultra tiers. Stops a 32 TiB Ultra disk being attached to the one permitted VM.'
    policyType: 'Custom'
    mode: 'Indexed'
    parameters: {
      maxDiskSizeGB: { type: 'Integer', metadata: { displayName: 'Max disk size (GB)' } }
    }
    policyRule: {
      if: {
        allOf: [
          { field: 'type', equals: 'Microsoft.Compute/disks' }
          {
            anyOf: [
              { field: 'Microsoft.Compute/disks/diskSizeGB', greater: '[parameters(\'maxDiskSizeGB\')]' }
              { field: 'Microsoft.Compute/disks/sku.name', notIn: [ 'Standard_LRS', 'StandardSSD_LRS' ] }
            ]
          }
        ]
      }
      then: { effect: 'deny' }
    }
  }
}

module assignments 'policy-assignments.bicep' = {
  name: 'valheim-policy-assignments'
  scope: resourceGroup(serverRgName)
  params: {
    pinVmNameDefinitionId: pinVmName.id
    capDisksDefinitionId: capDisks.id
    vmName: vmName
    allowedVmSkus: allowedVmSkus
    allowedLocations: allowedLocations
    maxDiskSizeGB: maxDiskSizeGB
  }
}
