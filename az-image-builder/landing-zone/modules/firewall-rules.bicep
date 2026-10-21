// Rule collection group for image builds, added to an existing firewall policy (deployed in the policy's
// resource group). Rules come from config/firewall-rules.json. A raw resource rather than AVM: the AVM
// firewall-policy module would redeploy the whole policy.

@description('Name of the existing firewall policy')
param firewallPolicyName string

@description('Rule collection group name')
param name string

@description('Rule collection group priority (unique in the policy)')
@minValue(100)
@maxValue(65000)
param priority int = 500

@description('Build VM subnet prefix')
param buildSubnetPrefix string

@description('Container instance subnet prefix')
param containerInstanceSubnetPrefix string

@description('Contents of config/firewall-rules.json')
param rules object

resource policy 'Microsoft.Network/firewallPolicies@2024-05-01' existing = {
  name: firewallPolicyName
}

resource ruleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-05-01' = {
  parent: policy
  name: name
  properties: {
    priority: priority
    ruleCollections: [
      {
        name: 'image-builder-container-instance'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: { type: 'Allow' }
        priority: 100
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'container-instance-https'
            protocols: [ { protocolType: 'Https', port: 443 } ]
            sourceAddresses: [ containerInstanceSubnetPrefix ]
            targetFqdns: rules.containerInstance.targetFqdns
          }
        ]
      }
      {
        name: 'image-builder-build-vm'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: { type: 'Allow' }
        priority: 110
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'build-vm-fqdn-tags'
            protocols: [ { protocolType: 'Https', port: 443 }, { protocolType: 'Http', port: 80 } ]
            sourceAddresses: [ buildSubnetPrefix ]
            fqdnTags: rules.buildVm.fqdnTags
          }
          {
            ruleType: 'ApplicationRule'
            name: 'build-vm-fqdns'
            protocols: [ { protocolType: 'Https', port: 443 }, { protocolType: 'Http', port: 80 } ]
            sourceAddresses: [ buildSubnetPrefix ]
            targetFqdns: rules.buildVm.targetFqdns
          }
        ]
      }
      {
        name: 'image-builder-build-vm-network'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: { type: 'Allow' }
        priority: 120
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'windows-activation'
            ipProtocols: [ 'TCP' ]
            sourceAddresses: [ buildSubnetPrefix ]
            destinationAddresses: rules.buildVm.kmsAddresses
            destinationPorts: [ '1688' ]
          }
        ]
      }
    ]
  }
}

output resourceId string = ruleCollectionGroup.id
