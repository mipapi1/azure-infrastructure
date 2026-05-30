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
