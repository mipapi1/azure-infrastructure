using '../../landing-zone/main.bicep'

// Behind a separately managed firewall: route only, no rule collection group.
param location = 'eastus'
param resourceGroupConfig = { name: 'aib-test-fw2-rg' }
param network = {
  name: 'aib-test-fw2-vnet'
  addressPrefix: '10.32.0.0/24'
  buildSubnet: { name: 'snet-build', addressPrefix: '10.32.0.0/27' }
  containerInstanceSubnet: { name: 'snet-aci', addressPrefix: '10.32.0.32/27' }
  privateEndpointSubnet: { name: 'snet-pe', addressPrefix: '10.32.0.64/28' }
  egress: { mode: 'firewall', firewallPrivateIpAddress: '10.0.0.4' }
}
param storage = { name: 'aibtestfw2st' }
param identities = { templateIdentityName: 'aib-test-fw2-template', buildVmIdentityName: 'aib-test-fw2-buildvm' }
param gallery = { name: 'aib_test_fw2_gal' }
