using '../main.bicep'

// Values in <angle brackets> and the all-zero subscription ID are placeholders.
// Take hub, monitoring and firewall values from the az-landing-zone outputs.

var hubSub = '00000000-0000-0000-0000-000000000000'
var hubPrefix = '/subscriptions/${hubSub}/resourceGroups/hub-staging-eus'

param environment = 'staging'
param location = 'eastus'

param tags = {
  environment: 'staging'
  workload: 'aks'
  managedBy: 'bicep'
}

param hub = {
  virtualNetworkResourceId: '${hubPrefix}-networking-rg/providers/Microsoft.Network/virtualNetworks/hub-staging-eus-vnet'
  firewallPrivateIp: '10.100.0.4'
  privateDnsZoneResourceGroupResourceId: '${hubPrefix}-dns-rg'
}

param monitoring = {
  logAnalyticsWorkspaceResourceId: '${hubPrefix}-monitoring-rg/providers/Microsoft.OperationalInsights/workspaces/hub-staging-eus-law'
  dataCollectionEndpointResourceId: '${hubPrefix}-monitoring-rg/providers/Microsoft.Insights/dataCollectionEndpoints/hub-staging-eus-dce'
  actionGroupResourceId: '${hubPrefix}-monitoring-rg/providers/Microsoft.Insights/actionGroups/hub-staging-eus-ag-platform'
}

param firewallPolicyResourceId = '${hubPrefix}-networking-rg/providers/Microsoft.Network/firewallPolicies/hub-staging-eus-afwp'

// Flux and the platform charts pull from these until images are mirrored into the registry.
param allowedEgressFqdns = [
  'github.com'
  'ghcr.io'
  'pkg-containers.githubusercontent.com'
  'quay.io'
  '*.quay.io'
  'charts.jetstack.io'
  'charts.external-secrets.io'
]

param network = {
  addressPrefixes: ['10.120.0.0/23']
  nodeSubnetPrefix: '10.120.0.0/24'
  privateEndpointSubnetPrefix: '10.120.1.0/27'
}

param cluster = {
  kubernetesVersion: '1.34'
  systemPool: {
    name: 'system'
    vmSize: 'Standard_D4ds_v5'
    minCount: 2
    maxCount: 3
  }
  userPools: [
    {
      name: 'general'
      vmSize: 'Standard_D4ds_v5'
      minCount: 1
      maxCount: 3
    }
  ]
}

param access = {
  adminGroupObjectIds: ['<aks-admins-group-object-id>']
  readerGroupObjectIds: ['<aks-readers-group-object-id>']
}

param gitOps = {
  repositoryUrl: 'https://github.com/<org>/azure-infrastructure'
  branch: 'main'
}
