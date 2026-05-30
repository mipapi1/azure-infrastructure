using '../main.bicep'

// Naming inputs — change here to update every RG name consistently
var workload = 'hub'
var environment = 'prod'
var shortLocation = 'eus'

param location = 'eastus'

var baseName = '${workload}-${environment}-${shortLocation}'

param tags = {
  environment: environment
  workload: 'platform-${workload}'
  managedBy: 'bicep'
}

param resourceGroups = [
  {
    name: '${baseName}-networking-rg'
    enableLock: true
    lockKind: 'CanNotDelete'
    // roleAssignments: [
    //   {
    //     principalId: '<network-ops-group-object-id>'
    //     roleDefinitionIdOrName: 'Network Contributor'
    //     principalType: 'Group'
    //   }
    // ]
  }
  {
    name: '${baseName}-security-rg'
    enableLock: true
    lockKind: 'CanNotDelete'
    // roleAssignments: [
    //   {
    //     principalId: '<sec-ops-group-object-id>'
    //     roleDefinitionIdOrName: 'Key Vault Administrator'
    //     principalType: 'Group'
    //   }
    // ]
  }
  {
    name: '${baseName}-monitoring-rg'
  }
  {
    name: '${baseName}-dns-rg'
    enableLock: true
    lockKind: 'CanNotDelete'
  }
]
