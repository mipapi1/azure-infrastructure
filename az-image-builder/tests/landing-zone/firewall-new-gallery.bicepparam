using '../../landing-zone/main.bicep'

// Behind an existing firewall, rules added to its policy, hub peering, new gallery.
param location = 'eastus'
param resourceGroupConfig = { name: 'aib-test-fw-rg' }
param network = {
  name: 'aib-test-fw-vnet'
  addressPrefix: '10.30.0.0/24'
  buildSubnet: { name: 'snet-build', addressPrefix: '10.30.0.0/27' }
  containerInstanceSubnet: { name: 'snet-aci', addressPrefix: '10.30.0.32/27' }
  privateEndpointSubnet: { name: 'snet-pe', addressPrefix: '10.30.0.64/28' }
  dnsServers: [ '10.0.0.4' ]
  egress: {
    mode: 'firewall'
    firewallPrivateIpAddress: '10.0.0.4'
    firewallPolicyResourceId: '/subscriptions/00000000-0000-0000-0000-0000000000aa/resourceGroups/hub-rg/providers/Microsoft.Network/firewallPolicies/hub-afwp'
  }
  hubPeering: {
    remoteVirtualNetworkResourceId: '/subscriptions/00000000-0000-0000-0000-0000000000aa/resourceGroups/hub-rg/providers/Microsoft.Network/virtualNetworks/hub-vnet'
  }
}
param storage = {
  name: 'aibtestfwst'
  privateDnsZoneResourceId: '/subscriptions/00000000-0000-0000-0000-0000000000aa/resourceGroups/hub-dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net'
}
param identities = { templateIdentityName: 'aib-test-fw-template', buildVmIdentityName: 'aib-test-fw-buildvm' }
param gallery = { name: 'aib_test_fw_gal' }
param publishers = [ { principalId: '11111111-1111-1111-1111-111111111111', principalType: 'Group' } ]
