@description('Name of the Log Analytics workspace')
param name string

@description('Azure region')
param location string

@description('Tags applied to the workspace')
param tags object = {}

@description('SKU name')
@allowed([ 'PerGB2018', 'CapacityReservation', 'LACluster', 'PerNode', 'Premium', 'Standalone', 'Standard' ])
param skuName string = 'PerGB2018'

@description('Data retention in days (30-730)')
@minValue(30)
@maxValue(730)
param retentionInDays int = 90

@description('When true, applies a lock to the workspace')
param enableLock bool = false

@description('Lock kind when enableLock is true')
@allowed([ 'CanNotDelete', 'ReadOnly' ])
param lockKind string = 'CanNotDelete'

@description('Role assignments on the workspace')
param roleAssignments array = []

module law 'br/public:avm/res/operational-insights/workspace:0.15.0' = {
  name: 'law-${name}'
  params: {
    name: name
    location: location
    tags: tags
    skuName: skuName
    dataRetention: retentionInDays
    lock: enableLock ? { kind: lockKind, name: 'lock-${name}' } : null
    roleAssignments: roleAssignments
  }
}

output name string = law.outputs.name
output resourceId string = law.outputs.resourceId
