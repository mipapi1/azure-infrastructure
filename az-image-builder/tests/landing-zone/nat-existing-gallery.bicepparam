using '../../landing-zone/main.bicep'

// No firewall (NAT gateway), created private DNS zone, existing gallery in another resource group.
param location = 'eastus'
param resourceGroupConfig = { name: 'aib-test-nat-rg', enableLock: true }
param network = {
  name: 'aib-test-nat-vnet'
  addressPrefix: '10.31.0.0/24'
  buildSubnet: { name: 'snet-build', addressPrefix: '10.31.0.0/27' }
  containerInstanceSubnet: { name: 'snet-aci', addressPrefix: '10.31.0.32/27' }
  privateEndpointSubnet: { name: 'snet-pe', addressPrefix: '10.31.0.64/28' }
  egress: { mode: 'natGateway' }
}
param storage = { name: 'aibtestnatst', publicNetworkAccess: 'Disabled' }
param identities = { templateIdentityName: 'aib-test-nat-template', buildVmIdentityName: 'aib-test-nat-buildvm' }
param gallery = { name: 'shared_gal', create: false, resourceGroupName: 'shared-images-rg' }
