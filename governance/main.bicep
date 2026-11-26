// Management groups, subscription placement and baseline policy.
// Deploy at management group alz, created first with az account management-group create
// (docs/DEPLOYMENT.md): Azure checks permissions for the policy deployment before it exists.
targetScope = 'managementGroup'

param subscriptionId string
param location string = deployment().location

var groups = [
  { name: 'alz-platform', displayName: 'Platform' }
  { name: 'alz-landingzones', displayName: 'Landing zones' }
]

resource root 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: 'alz'
  scope: tenant()
  properties: {
    displayName: 'Azure Landing Zones'
  }
}

resource children 'Microsoft.Management/managementGroups@2023-04-01' = [
  for g in groups: {
    name: g.name
    scope: tenant()
    properties: {
      displayName: g.displayName
      details: { parent: { id: root.id } }
    }
  }
]

resource placement 'Microsoft.Management/managementGroups/subscriptions@2023-04-01' = {
  name: 'alz-landingzones/${subscriptionId}'
  scope: tenant()
  dependsOn: [children]
}

module policy '../modules/policy.bicep' = {
  name: 'governance-policy'
  scope: managementGroup(root.name)
  params: {
    location: location
  }
}
