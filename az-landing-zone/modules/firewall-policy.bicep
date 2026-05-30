@description('Name of the firewall policy')
param name string

@description('Azure region')
param location string

@description('Tags applied to the policy')
param tags object = {}

@description('Policy tier — must match the Azure Firewall SKU tier')
@allowed([ 'Standard', 'Premium' ])
param tier string = 'Standard'

@description('Threat intelligence mode')
@allowed([ 'Alert', 'Deny', 'Off' ])
param threatIntelMode string = 'Alert'

@description('Rule collection groups — loaded from config/firewall-rules.json')
param ruleCollectionGroups array = []

module firewallPolicy 'br/public:avm/res/network/firewall-policy:0.3.0' = {
  name: 'afwp-${name}'
  params: {
    name: name
    location: location
    tags: tags
    tier: tier
    threatIntelMode: threatIntelMode
    ruleCollectionGroups: ruleCollectionGroups
  }
}

output resourceId string = firewallPolicy.outputs.resourceId
output name string = firewallPolicy.outputs.name
