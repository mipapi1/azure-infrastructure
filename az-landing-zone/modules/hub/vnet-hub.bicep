@description('Name of the hub virtual network')
param name string

@description('Azure region')
param location string

@description('Tags applied to the VNet')
param tags object = {}

@description('Address space for the hub VNet (e.g. 10.0.0.0/22)')
param addressPrefix string

@description('Address prefix for AzureFirewallSubnet (/26 minimum)')
param firewallSubnetPrefix string

@description('Address prefix for AzureBastionSubnet (/26 minimum)')
param bastionSubnetPrefix string

@description('Address prefix for GatewaySubnet (/27 minimum — reserved for future VPN gateway)')
param gatewaySubnetPrefix string

@description('Address prefix for PrivateEndpointSubnet')
param privateEndpointSubnetPrefix string

@description('When true, applies a lock to the VNet')
param enableLock bool = false

@description('Lock kind when enableLock is true')
@allowed([ 'CanNotDelete', 'ReadOnly' ])
param lockKind string = 'CanNotDelete'

module vnet 'br/public:avm/res/network/virtual-network:0.9.0' = {
  name: 'vnet-${name}'
  params: {
    name: name
    location: location
    tags: tags
    addressPrefixes: [ addressPrefix ]
    lock: enableLock ? { kind: lockKind, name: 'lock-${name}' } : null
    subnets: [
      {
        name: 'AzureFirewallSubnet'
        addressPrefix: firewallSubnetPrefix
      }
      {
        name: 'AzureBastionSubnet'
        addressPrefix: bastionSubnetPrefix
      }
      {
        name: 'GatewaySubnet'
        addressPrefix: gatewaySubnetPrefix
      }
      {
        name: 'PrivateEndpointSubnet'
        addressPrefix: privateEndpointSubnetPrefix
        privateEndpointNetworkPolicies: 'Disabled'
      }
    ]
  }
}

output vnetResourceId string = vnet.outputs.resourceId
output vnetName string = vnet.outputs.name
output firewallSubnetResourceId string = '${vnet.outputs.resourceId}/subnets/AzureFirewallSubnet'
output bastionSubnetResourceId string = '${vnet.outputs.resourceId}/subnets/AzureBastionSubnet'
output gatewaySubnetResourceId string = '${vnet.outputs.resourceId}/subnets/GatewaySubnet'
output privateEndpointSubnetResourceId string = '${vnet.outputs.resourceId}/subnets/PrivateEndpointSubnet'
