metadata name = 'Firewall rule collection group'
metadata description = 'Adds one rule collection group to an existing firewall policy, so a workload can own its egress rules without redeploying the hub policy. No AVM covers a standalone rule collection group (the firewall policy AVM manages all groups at once).'

@description('Required. Name of the existing firewall policy (in this resource group).')
param firewallPolicyName string

@description('Required. Rule collection group name.')
param name string

@description('Required. Priority, unique within the policy (100-65000).')
@minValue(100)
@maxValue(65000)
param priority int

@description('Required. Rule collections, in the firewall policy schema.')
param ruleCollections resourceInput<'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-05-01'>.properties.ruleCollections

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2025-05-01' existing = {
  name: firewallPolicyName
}

resource ruleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-05-01' = {
  parent: firewallPolicy
  name: name
  properties: {
    priority: priority
    ruleCollections: ruleCollections
  }
}

@description('Resource ID of the rule collection group.')
output resourceId string = ruleCollectionGroup.id
