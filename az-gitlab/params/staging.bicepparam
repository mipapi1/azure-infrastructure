using '../main.bicep'

// Shared-cluster mode: GitLab on tainted pools of the staging application cluster
// (az-aks/params/staging.bicepparam, pools gitlab and runners), Gitaly on the gitlab pool.
// Cheaper, but GitLab shares the cluster, its upgrades and its failure domain with the
// applications, so the staging cluster's Flux must keep following the hosted Git provider.
// Values in <angle brackets> and the all-zero subscription ID are placeholders.

var sub = '00000000-0000-0000-0000-000000000000'
var hubPrefix = '/subscriptions/${sub}/resourceGroups/hub-staging-eus'
var aksRg = '/subscriptions/${sub}/resourceGroups/aks-staging-eus-rg'
var aksNetwork = '/subscriptions/${sub}/resourceGroups/aks-staging-eus-network-rg/providers/Microsoft.Network/virtualNetworks/aks-staging-eus-vnet/subnets'

param environment = 'staging'
param location = 'eastus'
param placement = 'Shared'

param tags = {
  environment: 'staging'
  workload: 'gitlab'
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

param cluster = {
  clusterResourceId: '${aksRg}/providers/Microsoft.ContainerService/managedClusters/aks-staging-eus-aks'
  oidcIssuerUrl: 'https://eastus.oic.prod-aks.azure.com/<tenant-id>/<issuer-id>/'
  keyVaultResourceId: '${aksRg}/providers/Microsoft.KeyVault/vaults/<staging-key-vault-name>'
  registryResourceId: '${aksRg}/providers/Microsoft.ContainerRegistry/registries/<staging-registry-name>'
  subnetResourceIds: {
    'snet-aks-nodes': '${aksNetwork}/snet-aks-nodes'
    'snet-aks-runners': '${aksNetwork}/snet-aks-runners'
    'snet-private-endpoints': '${aksNetwork}/snet-private-endpoints'
  }
}

param dns = {
  zoneName: 'git-staging.example.internal'
  ingressIp: '10.120.0.250'
  sshIp: '10.120.0.251'
}

param postgresAdministratorPassword = readEnvironmentVariable('GITLAB_POSTGRES_PASSWORD', '')

param gitaly = {
  diskSizeGB: 64
}

param access = {
  clientIpGroupResourceIds: []
  clientAddressPrefixes: ['10.110.0.0/24']
}
