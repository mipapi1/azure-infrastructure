@description('Name of the Azure Monitor Private Link Scope')
param name string

@description('Tags applied to the resource')
param tags object = {}

@description('Resource ID of the Log Analytics Workspace to scope')
param lawResourceId string

@description('Resource ID of the private endpoint subnet')
param privateEndpointSubnetResourceId string

@description('Resource IDs of the private DNS zones for Azure Monitor')
param privateDnsZoneResourceIds array

param enableLock bool = false
@allowed([ 'CanNotDelete', 'ReadOnly' ])
param lockKind string = 'CanNotDelete'

module ampls 'br/public:avm/res/insights/private-link-scope:0.7.0' = {
  name: 'ampls-${name}'
  params: {
    name: name
    location: 'global'
    tags: tags
    lock: enableLock ? { kind: lockKind, name: 'lock-${name}' } : null
    scopedResources: [
      {
        name: 'scoped-law'
        linkedResourceId: lawResourceId
      }
    ]
    privateEndpoints: [
      {
        name: '${name}-pe'
        subnetResourceId: privateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [for zoneId in privateDnsZoneResourceIds: {
            privateDnsZoneResourceId: zoneId
          }]
        }
      }
    ]
  }
}

output resourceId string = ampls.outputs.resourceId
output name string = ampls.outputs.name
