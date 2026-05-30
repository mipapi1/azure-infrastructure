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
    name: '${baseName}-management-rg'
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

param vnet = {
  name: '${baseName}-vnet'
  resourceGroupName: '${baseName}-networking-rg'
  addressPrefix: '10.0.0.0/22'
  firewallSubnetPrefix: '10.0.0.0/26'
  bastionSubnetPrefix: '10.0.1.0/26'
  gatewaySubnetPrefix: '10.0.2.0/27'
  privateEndpointSubnetPrefix: '10.0.3.0/26'
}

var firewallTier = environment == 'prod' ? 'Premium' : 'Standard'

param firewallPolicy = {
  name: '${baseName}-afwp'
  resourceGroupName: '${baseName}-networking-rg'
  tier: firewallTier
  threatIntelMode: 'Deny'
}

param firewall = {
  name: '${baseName}-afw'
  resourceGroupName: '${baseName}-networking-rg'
  skuTier: firewallTier
}

param bastion = {
  name: '${baseName}-bastion'
  resourceGroupName: '${baseName}-networking-rg'
}

param privateDns = {
  resourceGroupName: '${baseName}-dns-rg'
  zones: loadJsonContent('../config/private-dns-zones.json')
}

param logging = {
  name: '${baseName}-law'
  resourceGroupName: '${baseName}-monitoring-rg'
  retentionInDays: 90
  publicNetworkAccessForIngestion: 'Disabled'
  publicNetworkAccessForQuery: 'Disabled'
}

param ampls = {
  name: '${baseName}-ampls'
  resourceGroupName: '${baseName}-monitoring-rg'
}

param userAssignedIdentities = [
  {
    name: '${baseName}-uami-logging'
    resourceGroupName: '${baseName}-management-rg'
  }
  {
    name: '${baseName}-uami-encryption'
    resourceGroupName: '${baseName}-management-rg'
  }
]
