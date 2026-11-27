// Private DNS zone linked to the hub VNet. Spokes resolve it through the firewall DNS proxy.
// Deployed into the hub resource group.
import { envCode, name as resourceName } from 'naming.bicep'

param env envCode
param workload string
param name string
param aRecords array = []

resource hubVnet 'Microsoft.Network/virtualNetworks@2025-07-01' existing = {
  name: resourceName(env, 'vnet', workload, 'hub')
}

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: name
  location: 'global'
}

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: hubVnet.name
  location: 'global'
  properties: {
    virtualNetwork: { id: hubVnet.id }
    registrationEnabled: false
  }
}

resource records 'Microsoft.Network/privateDnsZones/A@2024-06-01' = [
  for r in aRecords: {
    parent: zone
    name: r.name
    properties: {
      ttl: 300
      aRecords: [{ ipv4Address: r.ip }]
    }
  }
]

output id string = zone.id
