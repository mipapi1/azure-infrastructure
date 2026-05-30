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
