// Baseline policy for a management group: allowed location and the Microsoft cloud security benchmark.
targetScope = 'managementGroup'

param location string

resource allowedLocations 'Microsoft.Authorization/policyAssignments@2025-03-01' = {
  name: 'allowed-locations'
  properties: {
    displayName: 'Allowed locations'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', 'e56962a6-4747-49cd-b67b-bf8b01975c4c')
    parameters: {
      listOfAllowedLocations: { value: [location] }
    }
  }
}

resource securityBenchmark 'Microsoft.Authorization/policyAssignments@2025-03-01' = {
  name: 'security-benchmark'
  properties: {
    displayName: 'Microsoft cloud security benchmark'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policySetDefinitions', '1f3afdf9-d0c9-4c3d-847f-89da613e70a8')
  }
}
