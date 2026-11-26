// Spoke network peered to vnet-hub. All traffic and DNS go through the hub firewall,
// which gets this spoke's allow rules as its own rule collection group.

param name string
param addressPrefix string
param subnets array
param ruleCollections array
param rulePriority int
param location string = resourceGroup().location

resource hubVnet 'Microsoft.Network/virtualNetworks@2025-07-01' existing = {
  name: 'vnet-hub'
  scope: resourceGroup('rg-hub')
}

resource firewall 'Microsoft.Network/azureFirewalls@2025-07-01' existing = {
  name: 'afw-hub'
  scope: resourceGroup('rg-hub')
}

var firewallIp = firewall.properties.ipConfigurations[0].properties.privateIPAddress

resource routeTable 'Microsoft.Network/routeTables@2025-07-01' = {
  name: 'rt-${name}'
  location: location
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'default-via-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallIp
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2025-07-01' = {
  name: 'vnet-${name}'
  location: location
  properties: {
    addressSpace: { addressPrefixes: [addressPrefix] }
    dhcpOptions: { dnsServers: [firewallIp] }
    subnets: [
      for s in subnets: {
        name: s.name
        properties: {
          addressPrefix: s.addressPrefix
          routeTable: { id: routeTable.id }
        }
      }
    ]
  }
}

resource toHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2025-07-01' = {
  parent: vnet
  name: 'to-hub'
  properties: {
    remoteVirtualNetwork: { id: hubVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
}

module fromHub 'hub-peering.bicep' = {
  name: 'hub-peering-${name}'
  scope: resourceGroup('rg-hub')
  params: {
    name: name
    spokeVnetId: vnet.id
  }
}

module rules 'firewall-rules.bicep' = {
  name: 'firewall-rules-${name}'
  scope: resourceGroup('rg-hub')
  params: {
    name: name
    priority: rulePriority
    ruleCollections: ruleCollections
  }
}

output vnetId string = vnet.id
