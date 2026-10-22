using '../main.bicep'

// Values in <angle brackets> and the all-zero subscription ID are placeholders.
// Take hub, monitoring and firewall values from the az-landing-zone outputs.

var hubSub = '00000000-0000-0000-0000-000000000000'
var hubPrefix = '/subscriptions/${hubSub}/resourceGroups/hub-prod-eus'

param environment = 'prod'
param location = 'eastus'

param tags = {
  environment: 'prod'
  workload: 'aks'
  managedBy: 'bicep'
}

param hub = {
  virtualNetworkResourceId: '${hubPrefix}-networking-rg/providers/Microsoft.Network/virtualNetworks/hub-prod-eus-vnet'
  firewallPrivateIp: '10.0.0.4'
  privateDnsZoneResourceGroupResourceId: '${hubPrefix}-dns-rg'
}

param monitoring = {
  logAnalyticsWorkspaceResourceId: '${hubPrefix}-monitoring-rg/providers/Microsoft.OperationalInsights/workspaces/hub-prod-eus-law'
  dataCollectionEndpointResourceId: '${hubPrefix}-monitoring-rg/providers/Microsoft.Insights/dataCollectionEndpoints/hub-prod-eus-dce'
  actionGroupResourceId: '${hubPrefix}-monitoring-rg/providers/Microsoft.Insights/actionGroups/hub-prod-eus-ag-platform'
}

param firewallPolicyResourceId = '${hubPrefix}-networking-rg/providers/Microsoft.Network/firewallPolicies/hub-prod-eus-afwp'

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
  addressPrefixes: ['10.20.0.0/22']
  nodeSubnetPrefix: '10.20.0.0/23'
  privateEndpointSubnetPrefix: '10.20.2.0/27'
}

param cluster = {
  kubernetesVersion: '1.34'
  systemPool: {
    name: 'system'
    vmSize: 'Standard_D4ds_v5'
    minCount: 3
    maxCount: 5
  }
  userPools: [
    {
      name: 'general'
      vmSize: 'Standard_D8ds_v5'
      minCount: 3
      maxCount: 10
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
