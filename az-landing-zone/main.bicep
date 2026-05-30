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

////////////////////////
// module deployments //
////////////////////////

module hubResourceGroups 'modules/foundation/resource-groups.bicep' = [for r in resourceGroups: {
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

module hubIdentities 'modules/identity/userAssignedIdentity.bicep' = [for u in userAssignedIdentities: {
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
