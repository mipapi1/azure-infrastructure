// Hub side of a spoke peering. Deployed into the hub resource group.
import { envCode, name } from 'naming.bicep'

param env envCode
param workload string
param spoke string
param spokeVnetId string

resource hubVnet 'Microsoft.Network/virtualNetworks@2025-07-01' existing = {
  name: name(env, 'vnet', workload, 'hub')
}

resource toSpoke 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2025-07-01' = {
  parent: hubVnet
  name: 'peer-hub-to-${spoke}'
  properties: {
    remoteVirtualNetwork: { id: spokeVnetId }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
}
