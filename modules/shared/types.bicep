metadata name = 'Shared types'
metadata description = 'User-defined types shared by every workload in this repository.'

import { lockType } from 'br/public:avm/utl/types/avm-common-types:0.7.0'

@export()
@description('Deployment environment. Drives SKU, redundancy, retention and lock defaults.')
type environmentType = 'staging' | 'prod'

@export()
@description('Tags applied to every resource. environment and workload are required; add owner, costCenter and any other string tags as needed.')
type tagsType = {
  @description('Required. Environment name.')
  environment: environmentType

  @description('Required. Workload or platform component the resource belongs to.')
  workload: string

  *: string
}

@export()
@description('Connection details for the hub network. Spokes use these to peer, route egress through the firewall, and resolve private DNS.')
type hubReferenceType = {
  @description('Required. Resource ID of the hub virtual network.')
  virtualNetworkResourceId: string

  @description('Required. Private IP address of the hub firewall. Used as the default route next hop and, when DNS proxy is enabled, as the DNS server.')
  firewallPrivateIp: string

  @description('Required. Resource ID of the resource group that holds the private DNS zones.')
  privateDnsZoneResourceGroupResourceId: string

  @description('Optional. Whether the hub has a gateway that spokes should use. Defaults to false.')
  useRemoteGateways: bool?
}

@export()
@description('Central monitoring targets created by the landing zone.')
type monitoringReferenceType = {
  @description('Required. Resource ID of the central Log Analytics workspace.')
  logAnalyticsWorkspaceResourceId: string

  @description('Optional. Resource ID of the data collection endpoint used by Azure Monitor Agent over private link.')
  dataCollectionEndpointResourceId: string?

  @description('Optional. Resource ID of the action group that alert rules notify.')
  actionGroupResourceId: string?
}

@export()
@description('Network security rule, as accepted by the network security group AVM.')
type securityRuleType = {
  @description('Required. Rule name.')
  name: string

  @description('Required. Rule properties.')
  properties: {
    access: 'Allow' | 'Deny'
    direction: 'Inbound' | 'Outbound'
    priority: int
    protocol: '*' | 'Ah' | 'Esp' | 'Icmp' | 'Tcp' | 'Udp'
    description: string?
    sourceAddressPrefix: string?
    sourceAddressPrefixes: string[]?
    sourcePortRange: string?
    sourcePortRanges: string[]?
    destinationAddressPrefix: string?
    destinationAddressPrefixes: string[]?
    destinationPortRange: string?
    destinationPortRanges: string[]?
  }
}

@export()
@description('Subnet definition for a spoke virtual network.')
type spokeSubnetType = {
  @description('Required. Subnet name.')
  name: string

  @description('Required. Subnet address prefix.')
  addressPrefix: string

  @description('Optional. Extra NSG rules. A deny-all-inbound rule from the internet is always added.')
  securityRules: securityRuleType[]?

  @description('Optional. Send 0.0.0.0/0 to the hub firewall. Defaults to true.')
  routeToFirewall: bool?

  @description('Optional. Create an NSG for this subnet. Defaults to true.')
  createNetworkSecurityGroup: bool?

  @description('Optional. Service delegation, for example Microsoft.ContainerService/managedClusters.')
  delegation: string?

  @description('Optional. Service endpoints to enable.')
  serviceEndpoints: string[]?

  @description('Optional. Private endpoint network policies. Defaults to Enabled so NSGs and UDRs apply to private endpoints.')
  privateEndpointNetworkPolicies: ('Disabled' | 'Enabled' | 'NetworkSecurityGroupEnabled' | 'RouteTableEnabled')?
}

@export()
@description('Returns the lock to apply for an environment: CanNotDelete in prod, none in staging.')
func lockFor(environment environmentType) lockType =>
  environment == 'prod' ? { kind: 'CanNotDelete' } : { kind: 'None' }
