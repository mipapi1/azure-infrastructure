// Hub side of a spoke peering. Deployed into rg-hub.

param name string
param spokeVnetId string

resource hubVnet 'Microsoft.Network/virtualNetworks@2025-07-01' existing = {
  name: 'vnet-hub'
}

resource toSpoke 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2025-07-01' = {
  parent: hubVnet
  name: 'peer-hub-to-${name}'
  properties: {
    remoteVirtualNetwork: { id: spokeVnetId }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
}
