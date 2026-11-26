// A workload's rule collection group on the hub firewall policy. Deployed into rg-hub.

param name string
param priority int
param ruleCollections array

resource policy 'Microsoft.Network/firewallPolicies@2025-07-01' existing = {
  name: 'afwp-hub'
}

resource group 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-07-01' = {
  parent: policy
  name: name
  properties: {
    priority: priority
    ruleCollections: ruleCollections
  }
}
