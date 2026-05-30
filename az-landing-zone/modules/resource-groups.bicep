targetScope = 'subscription'

@description('Resource group name')
param name string

@description('Azure region')
param location string

@description('Tags applied to the resource group')
param tags object = {}

@description('When true, applies a lock to the resource group')
param enableLock bool = false

@description('Lock kind when enableLock is true')
@allowed([ 'CanNotDelete', 'ReadOnly' ])
param lockKind string = 'CanNotDelete'

@description('Role assignments to apply at the resource group scope')
param roleAssignments array = []

module rg 'br/public:avm/res/resources/resource-group:0.4.3' = {
  params: {
    name: name
    location: location
    tags: tags
    lock: enableLock ? {
      kind: lockKind
      name: 'lock-${name}'
    } : null
    roleAssignments: roleAssignments
  }
}

output name string = rg.outputs.name
output resourceId string = rg.outputs.resourceId
