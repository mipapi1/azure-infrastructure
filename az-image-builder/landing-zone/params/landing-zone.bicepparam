using '../main.bicep'

// Naming inputs — change here to update every name consistently
var workload = 'aib'
var environment = 'prod'
var shortLocation = 'eus'

var baseName = '${workload}-${environment}-${shortLocation}'

param location = 'eastus'

param tags = {
  environment: environment
  workload: 'platform-image-builder'
  managedBy: 'bicep'
}

param resourceGroupConfig = {
  name: '${baseName}-rg'
  enableLock: true
}

param network = {
  name: '${baseName}-vnet'
  addressPrefix: '10.20.0.0/24'
  buildSubnet: { name: 'snet-build', addressPrefix: '10.20.0.0/27' }
  containerInstanceSubnet: { name: 'snet-aci', addressPrefix: '10.20.0.32/27' }
  privateEndpointSubnet: { name: 'snet-pe', addressPrefix: '10.20.0.64/28' }

  // Behind the hub firewall. The rule collection group is added to the hub policy.
  egress: {
    mode: 'firewall'
    firewallPrivateIpAddress: '10.0.0.4'
    firewallPolicyResourceId: '/subscriptions/<hub-subscription-id>/resourceGroups/hub-prod-eus-networking-rg/providers/Microsoft.Network/firewallPolicies/hub-prod-eus-afwp'
  }
  hubPeering: {
    remoteVirtualNetworkResourceId: '/subscriptions/<hub-subscription-id>/resourceGroups/hub-prod-eus-networking-rg/providers/Microsoft.Network/virtualNetworks/hub-prod-eus-vnet'
    createRemotePeering: true
  }

  // No firewall: replace egress and remove hubPeering.
  // egress: { mode: 'natGateway' }
}

param storage = {
  name: replace('${baseName}st', '-', '')
  // Hub zone, when the VNet uses hub DNS: '/subscriptions/<hub-subscription-id>/resourceGroups/hub-prod-eus-dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net'
}

param identities = {
  templateIdentityName: '${baseName}-uami-template'
  buildVmIdentityName: '${baseName}-uami-buildvm'
}

param gallery = {
  name: replace('${baseName}_gal', '-', '_')
  // Existing gallery instead:
  // create: false
  // resourceGroupName: '<gallery-rg>'
}

param publishers = [
  // { principalId: '<image-admins-group-object-id>', principalType: 'Group' }
]
