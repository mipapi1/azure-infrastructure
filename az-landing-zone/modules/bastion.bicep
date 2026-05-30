@description('Name of the Bastion host')
param name string

@description('Azure region')
param location string

@description('Tags applied to the Bastion host')
param tags object = {}

@description('Resource ID of the hub VNet — AVM targets AzureBastionSubnet automatically')
param virtualNetworkResourceId string

@description('Bastion SKU — Standard enables tunneling, file copy, and shareable links')
@allowed([ 'Basic', 'Standard', 'Premium' ])
param skuName string = 'Standard'

module bastion 'br/public:avm/res/network/bastion-host:0.8.0' = {
  name: 'bastion-${name}'
  params: {
    name: name
    location: location
    tags: tags
    virtualNetworkResourceId: virtualNetworkResourceId
    skuName: skuName
  }
}

output resourceId string = bastion.outputs.resourceId
output name string = bastion.outputs.name
