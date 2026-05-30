@description('Name of the Azure Firewall')
param name string

@description('Azure region')
param location string

@description('Tags applied to the firewall')
param tags object = {}

@description('Resource ID of the hub VNet')
param virtualNetworkResourceId string

@description('Resource ID of the firewall policy')
param firewallPolicyId string

@description('Firewall SKU tier — must match the firewall policy tier')
@allowed([ 'Standard', 'Premium' ])
param azureSkuTier string = 'Standard'

module firewall 'br/public:avm/res/network/azure-firewall:0.10.0' = {
  name: 'afw-${name}'
  params: {
    name: name
    location: location
    tags: tags
    virtualNetworkResourceId: virtualNetworkResourceId
    firewallPolicyId: firewallPolicyId
    azureSkuTier: azureSkuTier
    publicIPAddressObject: {
      name: '${name}-pip'
    }
  }
}

output resourceId string = firewall.outputs.resourceId
output name string = firewall.outputs.name
output privateIpAddress string = firewall.outputs.privateIp
