@description('Array of private DNS zone names to deploy')
param zones array

@description('Resource ID of the hub VNet to link each zone to')
param vnetResourceId string

@description('Tags applied to all zones')
param tags object = {}

@description('When true, applies a lock to each zone')
param enableLock bool = false

@description('Lock kind when enableLock is true')
@allowed([ 'CanNotDelete', 'ReadOnly' ])
param lockKind string = 'CanNotDelete'

module privateDnsZone 'br/public:avm/res/network/private-dns-zone:0.8.0' = [for zone in zones: {
  name: 'dns-${replace(zone, '.', '-')}'
  params: {
    name: zone
    location: 'global'
    tags: tags
    lock: enableLock ? { kind: lockKind, name: 'lock-${zone}' } : null
    virtualNetworkLinks: [
      {
        name: 'link-hub-vnet'
        virtualNetworkResourceId: vnetResourceId
        registrationEnabled: false
      }
    ]
  }
}]
