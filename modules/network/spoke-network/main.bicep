metadata name = 'Spoke network'
metadata description = 'Spoke virtual network peered to the hub, with an NSG per subnet, a default route to the hub firewall, and DNS through the firewall DNS proxy.'

import { diagnosticSettingFullType, lockType, roleAssignmentType } from 'br/public:avm/utl/types/avm-common-types:0.7.0'
import { hubReferenceType, spokeSubnetType, tagsType } from '../../shared/types.bicep'

@description('Required. Name of the spoke virtual network.')
param name string

@description('Optional. Location for all resources.')
param location string = resourceGroup().location

@description('Required. Address space of the spoke virtual network.')
param addressPrefixes string[]

@description('Required. Subnets to create.')
param subnets spokeSubnetType[]

@description('Optional. Hub connection details. Leave empty for an isolated spoke (no peering, no forced tunnelling).')
param hub hubReferenceType?

@description('Optional. Use the hub firewall as DNS server (firewall DNS proxy). Defaults to true when a hub is set.')
param useHubDnsProxy bool = true

@description('Optional. Custom DNS servers. Overrides the hub DNS proxy when set.')
param dnsServers string[] = []

@description('Optional. Additional routes on the spoke route table.')
param additionalRoutes array = []

@description('Optional. Resource ID of a DDoS protection plan to associate.')
param ddosProtectionPlanResourceId string?

@description('Optional. Diagnostic settings for the virtual network and NSGs.')
param diagnosticSettings diagnosticSettingFullType[]?

@description('Optional. Lock applied to every resource in this module.')
param lock lockType?

@description('Optional. Role assignments on the virtual network.')
param roleAssignments roleAssignmentType[]?

@description('Required. Tags applied to every resource.')
param tags tagsType

@description('Optional. Enable AVM usage telemetry.')
param enableTelemetry bool = true

var hasHub = hub != null
var routeTableName = '${name}-rt'

// Deny inbound from the internet and outbound SSH/RDP to the VNet on every subnet.
// Workload rules are added on top with lower priority numbers.
var baselineRules = [
  {
    name: 'deny-internet-inbound'
    properties: {
      access: 'Deny'
      direction: 'Inbound'
      priority: 4096
      protocol: '*'
      sourceAddressPrefix: 'Internet'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
      description: 'Block direct inbound traffic from the internet.'
    }
  }
  {
    name: 'deny-lateral-outbound'
    properties: {
      access: 'Deny'
      direction: 'Outbound'
      priority: 4096
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRanges: ['22', '3389']
      description: 'Limit lateral movement over SSH and RDP. Management goes through Bastion.'
    }
  }
]

var nsgSubnets = filter(subnets, s => s.?createNetworkSecurityGroup ?? true)

module networkSecurityGroups 'br/public:avm/res/network/network-security-group:0.5.4' = [
  for subnet in nsgSubnets: {
    name: '${uniqueString(deployment().name, location)}-nsg-${subnet.name}'
    params: {
      name: '${name}-${subnet.name}-nsg'
      location: location
      securityRules: concat(subnet.?securityRules ?? [], baselineRules)
      diagnosticSettings: map(diagnosticSettings ?? [], d => {
        name: d.?name
        workspaceResourceId: d.?workspaceResourceId!
        logCategoriesAndGroups: [{ categoryGroup: 'allLogs' }]
      })
      lock: lock
      tags: tags
      enableTelemetry: enableTelemetry
    }
  }
]

module routeTable 'br/public:avm/res/network/route-table:0.5.0' = if (hasHub) {
  name: '${uniqueString(deployment().name, location)}-rt'
  params: {
    name: routeTableName
    location: location
    disableBgpRoutePropagation: true
    routes: concat(
      [
        {
          name: 'default-to-hub-firewall'
          properties: {
            addressPrefix: '0.0.0.0/0'
            nextHopType: 'VirtualAppliance'
            nextHopIpAddress: hub!.firewallPrivateIp
          }
        }
      ],
      additionalRoutes
    )
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

var nsgSubnetNames = map(nsgSubnets, s => s.name)

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: '${uniqueString(deployment().name, location)}-vnet'
  params: {
    name: name
    location: location
    addressPrefixes: addressPrefixes
    dnsServers: !empty(dnsServers) ? dnsServers : (hasHub && useHubDnsProxy ? [hub!.firewallPrivateIp] : [])
    ddosProtectionPlanResourceId: ddosProtectionPlanResourceId
    subnets: [
      for subnet in subnets: {
        name: subnet.name
        addressPrefix: subnet.addressPrefix
        networkSecurityGroupResourceId: contains(nsgSubnetNames, subnet.name)
          ? resourceId('Microsoft.Network/networkSecurityGroups', '${name}-${subnet.name}-nsg')
          : null
        routeTableResourceId: hasHub && (subnet.?routeToFirewall ?? true) ? routeTable!.outputs.resourceId : null
        delegation: subnet.?delegation
        serviceEndpoints: subnet.?serviceEndpoints
        privateEndpointNetworkPolicies: subnet.?privateEndpointNetworkPolicies ?? 'Enabled'
        defaultOutboundAccess: false
      }
    ]
    peerings: hasHub
      ? [
          {
            name: 'to-hub'
            remoteVirtualNetworkResourceId: hub!.virtualNetworkResourceId
            allowForwardedTraffic: true
            allowVirtualNetworkAccess: true
            useRemoteGateways: hub.?useRemoteGateways ?? false
            remotePeeringEnabled: true
            remotePeeringName: 'to-${name}'
            remotePeeringAllowForwardedTraffic: true
            remotePeeringAllowVirtualNetworkAccess: true
            remotePeeringAllowGatewayTransit: hub.?useRemoteGateways ?? false
          }
        ]
      : []
    diagnosticSettings: diagnosticSettings
    lock: lock
    roleAssignments: roleAssignments
    tags: tags
    enableTelemetry: enableTelemetry
  }
  dependsOn: [networkSecurityGroups]
}

@description('Resource ID of the spoke virtual network.')
output resourceId string = virtualNetwork.outputs.resourceId

@description('Name of the spoke virtual network.')
output name string = virtualNetwork.outputs.name

@description('Subnet resource IDs keyed by subnet name.')
output subnetResourceIds object = toObject(
  subnets,
  s => s.name,
  s => '${virtualNetwork.outputs.resourceId}/subnets/${s.name}'
)

@description('Resource ID of the spoke route table, empty when there is no hub.')
output routeTableResourceId string = hasHub ? routeTable!.outputs.resourceId : ''
