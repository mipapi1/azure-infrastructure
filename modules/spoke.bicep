// Spoke network peered to vnet-hub. All traffic and DNS go through the hub firewall,
// which gets this spoke's allow rules as its own rule collection group. Each subnet gets an
// IP group in rg-hub (ipg-<name>-<subnet>) for rules to use as their source.

param name string
param addressPrefix string
@description('[{ name, addressPrefix, delegation?, privateLinkServices? }]: delegation is a service name; privateLinkServices allows Private Link services in the subnet.')
param subnets array
param ruleCollections array
param rulePriority int
@description('Extra routes, e.g. [{ name, addressPrefix, nextHopType }] for a service tag that must skip the firewall.')
param routes array = []
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
    routes: concat(
      [
        {
          name: 'default-via-firewall'
          properties: {
            addressPrefix: '0.0.0.0/0'
            nextHopType: 'VirtualAppliance'
            nextHopIpAddress: firewallIp
          }
        }
      ],
      map(routes, r => { name: r.name, properties: { addressPrefix: r.addressPrefix, nextHopType: r.nextHopType } })
    )
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
          delegations: empty(s.?delegation ?? '') ? [] : [{ name: 'delegation', properties: { serviceName: s.delegation } }]
          privateLinkServiceNetworkPolicies: (s.?privateLinkServices ?? false) ? 'Disabled' : 'Enabled'
        }
      }
    ]
  }
}

resource toHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2025-07-01' = {
  parent: vnet
  name: 'peer-${name}-to-hub'
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

module ipGroups 'ip-groups.bicep' = {
  name: 'ip-groups-${name}'
  scope: resourceGroup('rg-hub')
  params: {
    name: name
    subnets: subnets
    location: location
  }
}

module rules 'firewall-rules.bicep' = {
  name: 'firewall-rules-${name}'
  scope: resourceGroup('rg-hub')
  params: {
    name: 'rcg-${name}'
    priority: rulePriority
    ruleCollections: ruleCollections
  }
  dependsOn: [ipGroups]
}

output vnetId string = vnet.id
