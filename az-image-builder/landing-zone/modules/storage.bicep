// Scripts and installers storage: Entra ID only (no shared key, no SAS), deny-by-default firewall,
// blob private endpoint in the image builder VNet. The build VM identity reads; publishers write.

@description('Storage account name (3-24 lowercase letters and digits, globally unique)')
@minLength(3)
@maxLength(24)
param name string

@description('Azure region')
param location string

@description('Tags applied to the storage account')
param tags object = {}

@allowed([ 'Standard_LRS', 'Standard_ZRS', 'Standard_GRS', 'Standard_GZRS' ])
param skuName string = 'Standard_LRS'

@description('Enabled = reachable from allowedIpRanges only (firewall default Deny). Disabled = private endpoint only')
@allowed([ 'Enabled', 'Disabled' ])
param publicNetworkAccess string = 'Enabled'

@description('Public IPs/CIDRs allowed through the storage firewall. Leave empty: the publish tools add your IP only while they run')
param allowedIpRanges string[] = []

@description('Subnet for the blob private endpoint')
param privateEndpointSubnetResourceId string

@description('Existing privatelink.blob private DNS zone. Empty = create one linked to virtualNetworkResourceId')
param privateDnsZoneResourceId string = ''

@description('VNet linked to the created private DNS zone (when privateDnsZoneResourceId is empty)')
param virtualNetworkResourceId string

@description('Build VM identity principal ID: Storage Blob Data Reader on both containers')
param buildVmPrincipalId string

@description('Who publishes scripts and installers: Storage Blob Data Contributor on both containers. [{ principalId, principalType? }]')
param publishers array = []

@description('When true, applies a lock to the storage account')
param enableLock bool = false

@description('Lock kind when enableLock is true')
@allowed([ 'CanNotDelete', 'ReadOnly' ])
param lockKind string = 'CanNotDelete'

var blobZoneName = 'privatelink.blob.${environment().suffixes.storage}'

var containerRoles = concat(
  [
    {
      principalId: buildVmPrincipalId
      principalType: 'ServicePrincipal'
      roleDefinitionIdOrName: 'Storage Blob Data Reader'
    }
  ],
  map(publishers, p => {
    principalId: p.principalId
    principalType: p.?principalType ?? 'User'
    roleDefinitionIdOrName: 'Storage Blob Data Contributor'
  })
)

module blobZone 'br/public:avm/res/network/private-dns-zone:0.8.1' = if (empty(privateDnsZoneResourceId)) {
  name: 'pdz-${name}-blob'
  params: {
    name: blobZoneName
    location: 'global'
    tags: tags
    virtualNetworkLinks: [
      {
        name: last(split(virtualNetworkResourceId, '/'))
        virtualNetworkResourceId: virtualNetworkResourceId
        registrationEnabled: false
      }
    ]
  }
}

module storage 'br/public:avm/res/storage/storage-account:0.33.1' = {
  name: 'st-${name}'
  params: {
    name: name
    location: location
    tags: tags
    kind: 'StorageV2'
    skuName: skuName
    accessTier: 'Hot'
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    requireInfrastructureEncryption: true
    publicNetworkAccess: publicNetworkAccess
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'None'
      ipRules: map(allowedIpRanges, ip => { value: ip, action: 'Allow' })
    }
    lock: enableLock ? { kind: lockKind, name: 'lock-${name}' } : null
    blobServices: {
      deleteRetentionPolicyEnabled: true
      deleteRetentionPolicyDays: 7
      containerDeleteRetentionPolicyEnabled: true
      containerDeleteRetentionPolicyDays: 7
      containers: [
        {
          name: 'scripts'
          publicAccess: 'None'
          roleAssignments: containerRoles
        }
        {
          name: 'installers'
          publicAccess: 'None'
          roleAssignments: containerRoles
        }
      ]
    }
    privateEndpoints: [
      {
        service: 'blob'
        subnetResourceId: privateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: empty(privateDnsZoneResourceId) ? blobZone!.outputs.resourceId : privateDnsZoneResourceId
            }
          ]
        }
      }
    ]
  }
}

output name string = storage.outputs.name
output resourceId string = storage.outputs.resourceId
output blobEndpoint string = storage.outputs.primaryBlobEndpoint
