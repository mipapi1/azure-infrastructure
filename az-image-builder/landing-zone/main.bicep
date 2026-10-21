targetScope = 'subscription'

// Azure Image Builder landing zone: resource group, isolated build network, scripts/installers storage,
// identities, compute gallery (new or existing) and least-privilege roles. Deploy once per environment;
// image templates (../workload) reference it through the landingZone output.

import { landingZoneReference, principal } from '../types.bicep'

////////////////
// parameters //
////////////////

@description('Azure region. Image templates, the VNet and the build run here.')
param location string

@description('Common tags applied to all resources')
param tags object = {}

@description('Resource group for the network, storage, identities and image templates.')
param resourceGroupConfig {
  name: string
  @description('CanNotDelete locks on the network, storage, identities and gallery. Default: false.')
  enableLock: bool?
}

@description('Build network. See README for sizing and egress modes.')
param network {
  name: string
  addressPrefix: string
  buildSubnet: subnet
  containerInstanceSubnet: subnet
  privateEndpointSubnet: subnet
  @description('Custom DNS servers (e.g. the hub DNS resolver). Default: Azure-provided DNS.')
  dnsServers: string[]?
  @description('Extra prefixes allowed to the private endpoints on 443, e.g. a VPN range for publishing.')
  privateEndpointAllowedSourcePrefixes: string[]?
  egress: egress
  hubPeering: {
    remoteVirtualNetworkResourceId: string
    useRemoteGateways: bool?
    @description('Also create the hub-to-spoke peering (needs rights on the hub VNet).')
    createRemotePeering: bool?
  }?
}

@description('Scripts and installers storage account.')
param storage {
  @minLength(3)
  @maxLength(24)
  name: string
  skuName: ('Standard_LRS' | 'Standard_ZRS' | 'Standard_GRS' | 'Standard_GZRS')?
  @description('Enabled (default) = firewall Deny, publish tools add your IP while they run. Disabled = private endpoint only.')
  publicNetworkAccess: ('Enabled' | 'Disabled')?
  allowedIpRanges: string[]?
  @description('Existing privatelink.blob zone (e.g. in the hub). Default: create one linked to this VNet.')
  privateDnsZoneResourceId: string?
}

@description('Managed identity names.')
param identities {
  templateIdentityName: string
  buildVmIdentityName: string
}

@description('Compute gallery. create: false uses an existing gallery in resourceGroupName (and subscriptionId).')
param gallery {
  name: string
  create: bool?
  @description('Default: resourceGroupConfig.name.')
  resourceGroupName: string?
  @description('Default: this subscription.')
  subscriptionId: string?
  description: string?
}

@description('Who publishes scripts and installers (Storage Blob Data Contributor on both containers).')
param publishers principal[] = []

@description('Prefix for the custom role names (role names are unique per tenant).')
param roleNamePrefix string = resourceGroupConfig.name

///////////////
// variables //
///////////////

type subnet = {
  name: string
  addressPrefix: string
}

@discriminator('mode')
type egress = firewallEgress | natGatewayEgress

@description('All outbound traffic is routed to an existing Azure Firewall (or other NVA).')
type firewallEgress = {
  mode: 'firewall'
  firewallPrivateIpAddress: string
  @description('Add the image builder rule collection group to this existing policy. Omit if the firewall is managed separately.')
  firewallPolicyResourceId: string?
  ruleCollectionGroupName: string?
  ruleCollectionGroupPriority: int?
  disableBgpRoutePropagation: bool?
}

@description('No firewall: outbound through a NAT gateway with its own public IP.')
type natGatewayEgress = {
  mode: 'natGateway'
  @description('-1 = no zone (default), or 1, 2, 3.')
  availabilityZone: int?
}

var rgName = resourceGroupConfig.name
var enableLock = resourceGroupConfig.?enableLock ?? false
// ReadOnly would block subnet join and the publish tools' storage firewall updates.
var lockKind = 'CanNotDelete'

var galleryCreate = gallery.?create ?? true
var gallerySubscriptionId = gallery.?subscriptionId ?? subscription().subscriptionId
var galleryResourceGroupName = gallery.?resourceGroupName ?? rgName

var firewallPolicyId = network.egress.mode == 'firewall' ? (network.egress.?firewallPolicyResourceId ?? '') : ''

//////////////////////
// role definitions //
//////////////////////

// Image Builder permissions from Microsoft's least-privilege examples, as custom roles.
resource galleryDistributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, rgName, 'image-builder-gallery-distributor')
  properties: {
    roleName: '${roleNamePrefix} Image Builder Gallery Distributor'
    description: 'Azure Image Builder: read gallery images and write image versions.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.Compute/galleries/read'
          'Microsoft.Compute/galleries/images/read'
          'Microsoft.Compute/galleries/images/versions/read'
          'Microsoft.Compute/galleries/images/versions/write'
        ]
        notActions: []
      }
    ]
    assignableScopes: union([ subscription().id ], [ '/subscriptions/${gallerySubscriptionId}' ])
  }
}

resource networkJoinRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(subscription().id, rgName, 'image-builder-network-join')
  properties: {
    roleName: '${roleNamePrefix} Image Builder Network Join'
    description: 'Azure Image Builder: place the build VM and container instance in existing subnets.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.Network/virtualNetworks/read'
          'Microsoft.Network/virtualNetworks/subnets/join/action'
        ]
        notActions: []
      }
    ]
    assignableScopes: [ subscription().id ]
  }
}

////////////////////////
// module deployments //
////////////////////////

module rg 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'deploy-${rgName}'
  params: {
    name: rgName
    location: location
    tags: tags
    // No lock on the resource group itself: old image templates in it must stay deletable.
  }
}

module ids 'modules/identities.bicep' = {
  name: 'deploy-${rgName}-identities'
  scope: resourceGroup(rgName)
  params: {
    templateIdentityName: identities.templateIdentityName
    buildVmIdentityName: identities.buildVmIdentityName
    location: location
    tags: tags
    enableLock: enableLock
    lockKind: lockKind
  }
  dependsOn: [ rg ]
}

module vnet 'modules/network.bicep' = {
  name: 'deploy-${network.name}'
  scope: resourceGroup(rgName)
  params: {
    name: network.name
    location: location
    tags: tags
    addressPrefix: network.addressPrefix
    buildSubnet: network.buildSubnet
    containerInstanceSubnet: network.containerInstanceSubnet
    privateEndpointSubnet: network.privateEndpointSubnet
    privateEndpointAllowedSourcePrefixes: network.?privateEndpointAllowedSourcePrefixes ?? []
    dnsServers: network.?dnsServers ?? []
    egressMode: network.egress.mode
    firewallPrivateIpAddress: network.egress.mode == 'firewall' ? network.egress.firewallPrivateIpAddress : ''
    disableBgpRoutePropagation: network.egress.mode == 'firewall' ? (network.egress.?disableBgpRoutePropagation ?? true) : true
    natGatewayAvailabilityZone: network.egress.mode == 'natGateway' ? (network.egress.?availabilityZone ?? -1) : -1
    hubPeering: network.?hubPeering ?? {}
    enableLock: enableLock
    lockKind: lockKind
    roleAssignments: [
      {
        principalId: ids.outputs.templateIdentityPrincipalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: networkJoinRole.id
      }
    ]
  }
  dependsOn: [ rg ]
}

module firewallRules 'modules/firewall-rules.bicep' = if (!empty(firewallPolicyId)) {
  name: 'deploy-${rgName}-firewall-rules'
  scope: resourceGroup(split(firewallPolicyId, '/')[2], split(firewallPolicyId, '/')[4])
  params: {
    firewallPolicyName: last(split(firewallPolicyId, '/'))
    name: network.egress.mode == 'firewall' ? (network.egress.?ruleCollectionGroupName ?? '${network.name}-image-builder') : ''
    priority: network.egress.mode == 'firewall' ? (network.egress.?ruleCollectionGroupPriority ?? 500) : 500
    buildSubnetPrefix: network.buildSubnet.addressPrefix
    containerInstanceSubnetPrefix: network.containerInstanceSubnet.addressPrefix
    rules: loadJsonContent('config/firewall-rules.json')
  }
}

module st 'modules/storage.bicep' = {
  name: 'deploy-${storage.name}'
  scope: resourceGroup(rgName)
  params: {
    name: storage.name
    location: location
    tags: tags
    skuName: storage.?skuName ?? 'Standard_LRS'
    publicNetworkAccess: storage.?publicNetworkAccess ?? 'Enabled'
    allowedIpRanges: storage.?allowedIpRanges ?? []
    privateEndpointSubnetResourceId: vnet.outputs.privateEndpointSubnetResourceId
    privateDnsZoneResourceId: storage.?privateDnsZoneResourceId ?? ''
    virtualNetworkResourceId: vnet.outputs.resourceId
    buildVmPrincipalId: ids.outputs.buildVmIdentityPrincipalId
    publishers: publishers
    enableLock: enableLock
    lockKind: lockKind
  }
}

module gal 'modules/gallery.bicep' = {
  name: 'deploy-${gallery.name}'
  scope: resourceGroup(gallerySubscriptionId, galleryResourceGroupName)
  params: {
    name: gallery.name
    create: galleryCreate
    location: location
    tags: tags
    galleryDescription: gallery.?description ?? 'Images built by Azure Image Builder'
    templateIdentityPrincipalId: ids.outputs.templateIdentityPrincipalId
    roleDefinitionId: galleryDistributorRole.id
    enableLock: enableLock
    lockKind: lockKind
  }
  dependsOn: [ rg ]
}

/////////////
// outputs //
/////////////

@description('Pass to the workload as param landingZone.')
output landingZone landingZoneReference = {
  subscriptionId: subscription().subscriptionId
  resourceGroupName: rgName
  location: location
  virtualNetworkName: vnet.outputs.name
  buildSubnetName: network.buildSubnet.name
  containerInstanceSubnetName: network.containerInstanceSubnet.name
  storageAccountName: st.outputs.name
  templateIdentityName: ids.outputs.templateIdentityName
  buildVmIdentityName: ids.outputs.buildVmIdentityName
  gallery: {
    subscriptionId: gallerySubscriptionId
    resourceGroupName: galleryResourceGroupName
    name: gal.outputs.name
  }
}

output storageBlobEndpoint string = st.outputs.blobEndpoint
