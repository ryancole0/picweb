// server.bicep — deployed into rg-valheim-server by the SWA API on "Start".
// Everything here is disposable. Destroy = complete-mode deployment of empty.json,
// which deletes every resource in the RG. World data lives in the core storage account.
//
// Compile for the API:  az bicep build -f server.bicep --outfile ../api/templates/server.json

@allowed([ 'eastus', 'southcentralus', 'swedencentral' ])
param location string

@description('Cheapest sensible size. D2as_v7 = 2 vCPU / 8 GiB burstable. Step up to Standard_D2as_v5 when credits run dry.')
param vmSize string = 'Standard_D2as_v7'

@description('Set true for Spot (roughly 60-80% cheaper, but Azure can evict you mid-raid).')
param useSpot bool = false

param storageAccountName string
param vmIdentityResourceId string
param vmIdentityClientId string

param serverName string = 'Family Valheim'
param worldName string = 'Midgard'
@secure()
param serverPassword string // >= 5 chars, Valheim requirement

@description('Minutes with zero players before the VM tears itself down.')
param idleMinutes int = 30
@description('Grace period after boot before idle checks start (people need time to join).')
param bootGraceMinutes int = 20
@description('Absolute ceiling on VM lifetime. Backstop in case the player count is unreadable.')
param maxUptimeMinutes int = 360
@description('Listing the server publicly is what makes the Steam query -- and therefore the player count -- work. Password still required to join.')
param serverPublic bool = true

param timestamp string = utcNow('yyyy-MM-ddTHH:mm:ssZ')

@description('''Valheim world modifiers, passed through to the server command line.
Order matters: -preset is read first and overwrites anything before it, so put it first or omit it.
  resources    muchless | less | more | muchmore | most     (rounds UP; excludes fish, trophies, boss drops)
  portals      casual | hard | veryhard                      (casual = metals through portals)
  deathpenalty casual | veryeasy | easy | hard | hardcore
  combat       veryeasy | easy | hard | veryhard
  raids        none | muchless | less | more | muchmore
  setkeys      nobuildcost | playerevents | passivemobs | nomap
Add -crossplay for console players.''')
param serverArgs string = ''

param adminUsername string = 'valheim'
@description('SSH public key. NSG does not expose 22; this is only a VM creation requirement. Use Run Command for admin.')
param adminSshPublicKey string

var prefix = 'valheim'

// ---- cloud-init: token-substituted, base64 for customData ----
var cloudInitRaw = loadTextContent('cloud-init.yaml')
var cloudInit = replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(
  cloudInitRaw,
  '__STORAGE_ACCOUNT__', storageAccountName),
  '__UAMI_CLIENT_ID__', vmIdentityClientId),
  '__RESOURCE_GROUP__', resourceGroup().name),
  '__SERVER_NAME__', serverName),
  '__WORLD_NAME__', worldName),
  '__SERVER_PASS__', serverPassword),
  '__IDLE_MINUTES__', string(idleMinutes)),
  '__MAX_UPTIME_MINUTES__', string(maxUptimeMinutes)),
  '__SERVER_PUBLIC__', toLower(string(serverPublic))),
  '__SERVER_ARGS__', serverArgs),
  '__BOOT_GRACE_MINUTES__', string(bootGraceMinutes)),
  '__LOCATION__', location)

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: '${prefix}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'valheim-udp'
        properties: {
          priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Udp'
          sourceAddressPrefix: '*', sourcePortRange: '*'
          destinationAddressPrefix: '*', destinationPortRange: '2456-2457'
        }
      }
      {
        // Read-only JSON status page from the container (player count). Used by the SWA API and the idle watchdog.
        name: 'status-http'
        properties: {
          priority: 110, direction: 'Inbound', access: 'Allow', protocol: 'Tcp'
          sourceAddressPrefix: 'Internet', sourcePortRange: '*'
          destinationAddressPrefix: '*', destinationPortRange: '80'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: '${prefix}-vnet'
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ '10.66.0.0/24' ] }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.66.0.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: '${prefix}-pip'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: { domainNameLabel: '${prefix}-${uniqueString(resourceGroup().id, location)}' }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: '${prefix}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: vnet.properties.subnets[0].id }
          publicIPAddress: { id: pip.id }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: '${prefix}-vm'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${vmIdentityResourceId}': {} }
  }
  tags: { deployedAt: timestamp, region: location }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    priority: useSpot ? 'Spot' : 'Regular'
    evictionPolicy: useSpot ? 'Delete' : null
    billingProfile: useSpot ? { maxPrice: -1 } : null
    storageProfile: {
      imageReference: { publisher: 'Canonical', offer: 'ubuntu-24_04-lts', sku: 'server', version: 'latest' }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 32
        deleteOption: 'Delete'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' } // ~$2.40/mo pro-rated hourly; Valheim server + Docker image ~ 3 GB
      }
    }
    osProfile: {
      computerName: 'valheim'
      adminUsername: adminUsername
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [ { path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: adminSshPublicKey } ] }
        patchSettings: { patchMode: 'ImageDefault' }
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: nic.id, properties: { deleteOption: 'Delete' } } ]
    }
    diagnosticsProfile: { bootDiagnostics: { enabled: true } } // managed storage, free
  }
}

output publicIp string = pip.properties.ipAddress
output fqdn string = pip.properties.dnsSettings.fqdn
output vmName string = vm.name
