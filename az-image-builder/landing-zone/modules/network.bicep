// Image builder VNet: build VM, container instance (delegated) and private endpoint subnets, an NSG per subnet,
// and egress through an existing firewall (route table) or a NAT gateway. Default outbound access is off.

@description('Name of the virtual network')
param name string

@description('Azure region')
param location string

@description('Tags applied to every network resource')
param tags object = {}

@description('Address space of the VNet')
param addressPrefix string

@description('Build VM subnet. { name, addressPrefix }')
param buildSubnet object

@description('Container instance subnet, delegated to Microsoft.ContainerInstance/containerGroups. { name, addressPrefix }')
param containerInstanceSubnet object

@description('Private endpoint subnet. { name, addressPrefix }')
param privateEndpointSubnet object

@description('Extra prefixes allowed to reach the private endpoints on 443 (e.g. a VPN range for publishing)')
param privateEndpointAllowedSourcePrefixes string[] = []

@description('Custom DNS servers. Empty = Azure-provided DNS')
param dnsServers string[] = []

@description('Egress: firewall (route 0.0.0.0/0 to firewallPrivateIpAddress) or natGateway')
@allowed([ 'firewall', 'natGateway' ])
param egressMode string

@description('Firewall private IP (egressMode firewall)')
param firewallPrivateIpAddress string = ''

@description('Disable BGP route propagation on the route table (egressMode firewall)')
param disableBgpRoutePropagation bool = true

@description('NAT gateway availability zone (egressMode natGateway). -1 = no zone')
param natGatewayAvailabilityZone int = -1

@description('Peering to a hub VNet. { remoteVirtualNetworkResourceId, useRemoteGateways?, createRemotePeering? }. Empty = none')
param hubPeering object = {}

@description('Role assignments on the VNet')
param roleAssignments array = []

@description('When true, applies a lock to the VNet')
param enableLock bool = false

@description('Lock kind when enableLock is true')
@allowed([ 'CanNotDelete', 'ReadOnly' ])
param lockKind string = 'CanNotDelete'

var useFirewall = egressMode == 'firewall'

var denyVnetInbound = {
  name: 'DenyVnetInbound'
  properties: {
    access: 'Deny'
    direction: 'Inbound'
    priority: 4000
    protocol: '*'
    sourceAddressPrefix: 'VirtualNetwork'
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRange: '*'
  }
}

module buildNsg 'br/public:avm/res/network/network-security-group:0.5.4' = {
  name: 'nsg-${name}-build'
  params: {
    name: '${name}-${buildSubnet.name}-nsg'
    location: location
    tags: tags
    securityRules: [
      {
        // The Image Builder container (Packer) drives the build VM over WinRM (Windows) or SSH (Linux).
        name: 'AllowContainerInstanceToBuildVm'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 100
          protocol: 'Tcp'
          sourceAddressPrefix: containerInstanceSubnet.addressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: buildSubnet.addressPrefix
          destinationPortRanges: [ '5986', '22' ]
        }
      }
      denyVnetInbound
    ]
  }
}

module containerInstanceNsg 'br/public:avm/res/network/network-security-group:0.5.4' = {
  name: 'nsg-${name}-aci'
  params: {
    name: '${name}-${containerInstanceSubnet.name}-nsg'
    location: location
    tags: tags
    securityRules: [ denyVnetInbound ]
  }
}

module privateEndpointNsg 'br/public:avm/res/network/network-security-group:0.5.4' = {
  name: 'nsg-${name}-pe'
  params: {
    name: '${name}-${privateEndpointSubnet.name}-nsg'
    location: location
    tags: tags
    securityRules: [
      {
        name: 'AllowHttpsToPrivateEndpoints'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 100
          protocol: 'Tcp'
          sourceAddressPrefixes: concat([ buildSubnet.addressPrefix ], privateEndpointAllowedSourcePrefixes)
          sourcePortRange: '*'
          destinationAddressPrefix: privateEndpointSubnet.addressPrefix
          destinationPortRange: '443'
        }
      }
      denyVnetInbound
    ]
  }
}

module routeTable 'br/public:avm/res/network/route-table:0.5.0' = if (useFirewall) {
  name: 'rt-${name}'
  params: {
    name: '${name}-rt'
    location: location
    tags: tags
    disableBgpRoutePropagation: disableBgpRoutePropagation
    routes: [
      {
        name: 'default-to-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIpAddress
        }
      }
    ]
  }
}

module natGateway 'br/public:avm/res/network/nat-gateway:2.1.1' = if (!useFirewall) {
  name: 'ng-${name}'
  params: {
    name: '${name}-ng'
    location: location
    tags: tags
    availabilityZone: natGatewayAvailabilityZone
    publicIPAddresses: [
      {
        name: '${name}-ng-pip'
      }
    ]
  }
}

var egress = useFirewall
  ? { routeTableResourceId: routeTable!.outputs.resourceId }
  : { natGatewayResourceId: natGateway!.outputs.resourceId }

module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'vnet-${name}'
  params: {
    name: name
    location: location
    tags: tags
    addressPrefixes: [ addressPrefix ]
    dnsServers: dnsServers
    lock: enableLock ? { kind: lockKind, name: 'lock-${name}' } : null
    roleAssignments: roleAssignments
    subnets: [
      union(egress, {
        name: buildSubnet.name
        addressPrefix: buildSubnet.addressPrefix
        networkSecurityGroupResourceId: buildNsg.outputs.resourceId
        defaultOutboundAccess: false
      })
      union(egress, {
        name: containerInstanceSubnet.name
        addressPrefix: containerInstanceSubnet.addressPrefix
        networkSecurityGroupResourceId: containerInstanceNsg.outputs.resourceId
        delegation: 'Microsoft.ContainerInstance/containerGroups'
        defaultOutboundAccess: false
      })
      {
        name: privateEndpointSubnet.name
        addressPrefix: privateEndpointSubnet.addressPrefix
        networkSecurityGroupResourceId: privateEndpointNsg.outputs.resourceId
        privateEndpointNetworkPolicies: 'NetworkSecurityGroupEnabled'
        defaultOutboundAccess: false
      }
    ]
    peerings: empty(hubPeering) ? [] : [
      {
        name: 'to-${last(split(hubPeering.remoteVirtualNetworkResourceId, '/'))}'
        remoteVirtualNetworkResourceId: hubPeering.remoteVirtualNetworkResourceId
        allowVirtualNetworkAccess: true
        allowForwardedTraffic: true
        useRemoteGateways: hubPeering.?useRemoteGateways ?? false
        remotePeeringEnabled: hubPeering.?createRemotePeering ?? false
        remotePeeringName: 'to-${name}'
        remotePeeringAllowVirtualNetworkAccess: true
        remotePeeringAllowForwardedTraffic: true
        remotePeeringAllowGatewayTransit: hubPeering.?useRemoteGateways ?? false
      }
    ]
  }
}

output name string = vnet.outputs.name
output resourceId string = vnet.outputs.resourceId
output buildSubnetResourceId string = vnet.outputs.subnetResourceIds[0]
output containerInstanceSubnetResourceId string = vnet.outputs.subnetResourceIds[1]
output privateEndpointSubnetResourceId string = vnet.outputs.subnetResourceIds[2]
