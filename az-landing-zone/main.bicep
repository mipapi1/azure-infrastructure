targetScope = 'subscription'

////////////////
// parameters //
////////////////

@description('Azure region')
param location string

@description('Common tags applied to all resources')
param tags object

@description('Resource groups to create. Each: { name, enableLock?, lockKind?, roleAssignments? }')
param resourceGroups array

@description('User-assigned managed identities. Each: { name, resourceGroupName, enableLock?, lockKind?, roleAssignments?, federatedIdentityCredentials? }')
param userAssignedIdentities array

@description('Log Analytics workspace. { name, resourceGroupName, retentionInDays?, skuName?, publicNetworkAccessForIngestion?, publicNetworkAccessForQuery?, enableLock?, lockKind?, roleAssignments? }')
param logging object

@description('Hub virtual network. { name, resourceGroupName, addressPrefix, firewallSubnetPrefix, bastionSubnetPrefix, gatewaySubnetPrefix, privateEndpointSubnetPrefix, enableLock?, lockKind? }')
param vnet object

@description('Private DNS zones. { resourceGroupName, zones, enableLock?, lockKind? }')
param privateDns object

@description('Firewall policy. { name, resourceGroupName, tier?, threatIntelMode? }')
param firewallPolicy object

@description('Azure Firewall. { name, resourceGroupName, skuTier? }')
param firewall object

@description('Azure Bastion. { name, resourceGroupName, skuName? }')
param bastion object

@description('Azure Monitor Private Link Scope. { name, resourceGroupName }')
param ampls object

////////////////////////
// module deployments //
////////////////////////

module hubResourceGroups 'modules/resource-groups.bicep' = [for r in resourceGroups: {
  name: 'deploy-${r.name}'
  params: {
    name: r.name
    location: location
    tags: tags
    enableLock: r.?enableLock ?? false
    lockKind: r.?lockKind ?? 'CanNotDelete'
    roleAssignments: r.?roleAssignments ?? []
  }
}]

module hubIdentities 'modules/user-assigned-identity.bicep' = [for u in userAssignedIdentities: {
  name: 'deploy-${u.name}'
  scope: resourceGroup(u.resourceGroupName)
  params: {
    name: u.name
    location: location
    tags: tags
    enableLock: u.?enableLock ?? false
    lockKind: u.?lockKind ?? 'CanNotDelete'
    roleAssignments: u.?roleAssignments ?? []
    federatedIdentityCredentials: u.?federatedIdentityCredentials ?? []
  }
  dependsOn: [hubResourceGroups]
}]

module hubVnet 'modules/vnet-hub.bicep' = {
  name: 'deploy-${vnet.name}'
  scope: resourceGroup(vnet.resourceGroupName)
  params: {
    name: vnet.name
    location: location
    tags: tags
    addressPrefix: vnet.addressPrefix
    firewallSubnetPrefix: vnet.firewallSubnetPrefix
    bastionSubnetPrefix: vnet.bastionSubnetPrefix
    gatewaySubnetPrefix: vnet.gatewaySubnetPrefix
    privateEndpointSubnetPrefix: vnet.privateEndpointSubnetPrefix
    enableLock: vnet.?enableLock ?? false
    lockKind: vnet.?lockKind ?? 'CanNotDelete'
  }
  dependsOn: [hubResourceGroups]
}

module hubFirewallPolicy 'modules/firewall-policy.bicep' = {
  name: 'deploy-${firewallPolicy.name}'
  scope: resourceGroup(firewallPolicy.resourceGroupName)
  params: {
    name: firewallPolicy.name
    location: location
    tags: tags
    tier: firewallPolicy.?tier ?? 'Standard'
    threatIntelMode: firewallPolicy.?threatIntelMode ?? 'Alert'
    ruleCollectionGroups: concat(
      loadJsonContent('config/firewall-rules/network-rules.json'),
      loadJsonContent('config/firewall-rules/application-rules.json')
    )
  }
  dependsOn: [hubResourceGroups]
}

module hubFirewall 'modules/azure-firewall.bicep' = {
  name: 'deploy-${firewall.name}'
  scope: resourceGroup(firewall.resourceGroupName)
  params: {
    name: firewall.name
    location: location
    tags: tags
    virtualNetworkResourceId: hubVnet.outputs.vnetResourceId
    firewallPolicyId: hubFirewallPolicy.outputs.resourceId
    azureSkuTier: firewall.?skuTier ?? 'Standard'
  }
  dependsOn: [hubResourceGroups]
}

module hubBastion 'modules/bastion.bicep' = {
  name: 'deploy-${bastion.name}'
  scope: resourceGroup(bastion.resourceGroupName)
  params: {
    name: bastion.name
    location: location
    tags: tags
    virtualNetworkResourceId: hubVnet.outputs.vnetResourceId
    skuName: bastion.?skuName ?? 'Standard'
  }
  dependsOn: [hubResourceGroups]
}

module hubPrivateDns 'modules/private-dns-zones.bicep' = {
  name: 'deploy-private-dns'
  scope: resourceGroup(privateDns.resourceGroupName)
  params: {
    zones: privateDns.zones
    vnetResourceId: hubVnet.outputs.vnetResourceId
    tags: tags
    enableLock: privateDns.?enableLock ?? false
    lockKind: privateDns.?lockKind ?? 'CanNotDelete'
  }
  dependsOn: [hubResourceGroups]
}

module hubLogging 'modules/log-analytics.bicep' = {
  name: 'deploy-${logging.name}'
  scope: resourceGroup(logging.resourceGroupName)
  params: {
    name: logging.name
    location: location
    tags: tags
    skuName: logging.?skuName ?? 'PerGB2018'
    retentionInDays: logging.?retentionInDays ?? 90
    publicNetworkAccessForIngestion: logging.?publicNetworkAccessForIngestion ?? 'Enabled'
    publicNetworkAccessForQuery: logging.?publicNetworkAccessForQuery ?? 'Enabled'
    enableLock: logging.?enableLock ?? false
    lockKind: logging.?lockKind ?? 'CanNotDelete'
    roleAssignments: logging.?roleAssignments ?? []
  }
  dependsOn: [hubResourceGroups, hubIdentities]
}

module hubAmpls 'modules/ampls.bicep' = {
  name: 'deploy-${ampls.name}'
  scope: resourceGroup(ampls.resourceGroupName)
  params: {
    name: ampls.name
    tags: tags
    lawResourceId: hubLogging.outputs.resourceId
    privateEndpointSubnetResourceId: hubVnet.outputs.privateEndpointSubnetResourceId
    privateDnsZoneResourceIds: [
      resourceId(subscription().subscriptionId, privateDns.resourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.monitor.azure.com')
      resourceId(subscription().subscriptionId, privateDns.resourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.oms.opinsights.azure.com')
      resourceId(subscription().subscriptionId, privateDns.resourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.ods.opinsights.azure.com')
      resourceId(subscription().subscriptionId, privateDns.resourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.agentsvc.azure-automation.net')
      resourceId(subscription().subscriptionId, privateDns.resourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.blob.${environment().suffixes.storage}')
    ]
    enableLock: ampls.?enableLock ?? false
    lockKind: ampls.?lockKind ?? 'CanNotDelete'
  }
  dependsOn: [hubPrivateDns]
}
