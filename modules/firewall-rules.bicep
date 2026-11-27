// A workload's rule collection group on the hub firewall policy. Deployed into the hub resource group.
import { envCode, name as resourceName } from 'naming.bicep'

param env envCode
param workload string
param name string
param priority int
param ruleCollections array

resource policy 'Microsoft.Network/firewallPolicies@2025-07-01' existing = {
  name: resourceName(env, 'afwp', workload, 'hub')
}

resource group 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-07-01' = {
  parent: policy
  name: name
  properties: {
    priority: priority
    ruleCollections: ruleCollections
  }
}
