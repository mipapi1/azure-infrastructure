// Baseline policy for a management group: allowed locations and the Microsoft cloud security benchmark.
targetScope = 'managementGroup'

param location string
@description('Regions resources may be created in.')
param locations array = [location]

resource allowedLocations 'Microsoft.Authorization/policyAssignments@2025-03-01' = {
  name: 'allowed-locations'
  properties: {
    displayName: 'Allowed locations'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', 'e56962a6-4747-49cd-b67b-bf8b01975c4c')
    parameters: {
      listOfAllowedLocations: { value: locations }
    }
  }
}

// The initiative includes deployIfNotExists policies, so the assignment needs an identity.
// It only audits here: no remediation roles are granted.
resource securityBenchmark 'Microsoft.Authorization/policyAssignments@2025-03-01' = {
  name: 'security-benchmark'
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'Microsoft cloud security benchmark'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policySetDefinitions', '1f3afdf9-d0c9-4c3d-847f-89da613e70a8')
  }
}
