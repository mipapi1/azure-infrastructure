// Spoke network peered to the hub VNet. All traffic and DNS go through the hub firewall, which gets
// this spoke's allow rules as its own rule collection group (rcg-<spoke>). Each subnet gets an IP
// group in the hub resource group (<env>-ipg-<workload>-<spoke>-<subnet>) for rules to use as sources.
import { envCode, name } from 'naming.bicep'

param env envCode
param workload string
@description('Spoke component name, e.g. avd: <env>-vnet-<workload>-avd.')
param spoke string
param addressPrefix string
@description('''[{ name, addressPrefix, delegation?, privateLinkServices?, serviceEndpoints? }]. name is short (hosts,
pe): the subnet is snet-<name>. delegation is a service name; privateLinkServices allows Private Link services in
the subnet; serviceEndpoints lists services such as Microsoft.Storage.''')
param subnets array
param ruleCollections array
param rulePriority int
param location string = resourceGroup().location

var hubGroup = resourceGroup(name(env, 'rg', workload, 'hub'))

resource hubVnet 'Microsoft.Network/virtualNetworks@2025-07-01' existing = {
  name: name(env, 'vnet', workload, 'hub')
  scope: hubGroup
}

resource firewall 'Microsoft.Network/azureFirewalls@2025-07-01' existing = {
  name: name(env, 'afw', workload, 'hub')
  scope: hubGroup
}

var firewallIp = firewall.properties.ipConfigurations[0].properties.privateIPAddress

resource routeTable 'Microsoft.Network/routeTables@2025-07-01' = {
  name: name(env, 'rt', workload, spoke)
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
  name: name(env, 'vnet', workload, spoke)
  location: location
  properties: {
    addressSpace: { addressPrefixes: [addressPrefix] }
    dhcpOptions: { dnsServers: [firewallIp] }
    subnets: [
      for s in subnets: {
        name: 'snet-${s.name}'
        properties: {
          addressPrefix: s.addressPrefix
          routeTable: { id: routeTable.id }
          delegations: empty(s.?delegation ?? '') ? [] : [{ name: 'delegation', properties: { serviceName: s.delegation } }]
          privateLinkServiceNetworkPolicies: (s.?privateLinkServices ?? false) ? 'Disabled' : 'Enabled'
          serviceEndpoints: map(s.?serviceEndpoints ?? [], e => { service: e })
        }
      }
    ]
  }
}

resource toHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2025-07-01' = {
  parent: vnet
  name: 'peer-${spoke}-to-hub'
  properties: {
    remoteVirtualNetwork: { id: hubVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
}

module fromHub 'hub-peering.bicep' = {
  name: 'hub-peering-${spoke}'
  scope: hubGroup
  params: {
    env: env
    workload: workload
    spoke: spoke
    spokeVnetId: vnet.id
  }
}

module ipGroups 'ip-groups.bicep' = {
  name: 'ip-groups-${spoke}'
  scope: hubGroup
  params: {
    env: env
    workload: workload
    spoke: spoke
    subnets: subnets
    location: location
  }
}

module rules 'firewall-rules.bicep' = {
  name: 'firewall-rules-${spoke}'
  scope: hubGroup
  params: {
    env: env
    workload: workload
    name: 'rcg-${spoke}'
    priority: rulePriority
    ruleCollections: ruleCollections
  }
  dependsOn: [ipGroups]
}

output vnetId string = vnet.id
