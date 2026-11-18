using '../main.bicep'

// GitLab on the dedicated tools cluster (az-aks/params/tools-prod.bicepparam).
// Values in <angle brackets> and the all-zero subscription ID are placeholders.
// cluster comes from the tools cluster's az-aks outputs; hub, monitoring and the firewall
// policy from the az-landing-zone outputs.

var sub = '00000000-0000-0000-0000-000000000000'
var hubPrefix = '/subscriptions/${sub}/resourceGroups/hub-prod-eus'
var toolsRg = '/subscriptions/${sub}/resourceGroups/tools-prod-eus-rg'
var toolsNetwork = '/subscriptions/${sub}/resourceGroups/tools-prod-eus-network-rg/providers/Microsoft.Network/virtualNetworks/tools-prod-eus-vnet/subnets'

param environment = 'prod'
param location = 'eastus'
param placement = 'Dedicated'

param tags = {
  environment: 'prod'
  workload: 'gitlab'
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

param cluster = {
  clusterResourceId: '${toolsRg}/providers/Microsoft.ContainerService/managedClusters/tools-prod-eus-aks'
  oidcIssuerUrl: 'https://eastus.oic.prod-aks.azure.com/<tenant-id>/<issuer-id>/'
  keyVaultResourceId: '${toolsRg}/providers/Microsoft.KeyVault/vaults/<tools-key-vault-name>'
  registryResourceId: '${toolsRg}/providers/Microsoft.ContainerRegistry/registries/<tools-registry-name>'
  subnetResourceIds: {
    'snet-aks-nodes': '${toolsNetwork}/snet-aks-nodes'
    'snet-aks-runners': '${toolsNetwork}/snet-aks-runners'
    'snet-private-endpoints': '${toolsNetwork}/snet-private-endpoints'
  }
}

// The zone is created and linked to the hub by az-landing-zone (additionalPrivateDnsZones).
// The two addresses are free IPs in the tools node subnet (10.30.0.0/24).
param dns = {
  zoneName: 'git.example.internal'
  ingressIp: '10.30.0.250'
  sshIp: '10.30.0.251'
}

// Never commit secrets. scripts/seed-secrets.sh generates them into the tools key vault; read
// them from the environment, or replace with
// az.getSecret('<subscription-id>', 'tools-prod-eus-rg', '<tools-key-vault-name>', '<secret>').
param postgresAdministratorPassword = readEnvironmentVariable('GITLAB_POSTGRES_PASSWORD', '')

// Gitaly runs in the cluster on the dedicated gitaly pool (az-aks/params/tools-prod.bicepparam).
param gitaly = {
  diskSizeGB: 512
}

// AVD users and the application cluster (Flux) reach GitLab; VPN or ExpressRoute ranges too.
param access = {
  clientIpGroupResourceIds: [
    '/subscriptions/${sub}/resourceGroups/avd-prod-eus-network-rg/providers/Microsoft.Network/ipGroups/avd-prod-eus-ipg-session-hosts'
    '/subscriptions/${sub}/resourceGroups/aks-prod-eus-network-rg/providers/Microsoft.Network/ipGroups/aks-prod-eus-ipg-nodes'
  ]
  clientAddressPrefixes: []
}

// CI jobs push application images to the application cluster registry.
param runners = {
  pushRegistryResourceIds: [
    '/subscriptions/${sub}/resourceGroups/aks-prod-eus-rg/providers/Microsoft.ContainerRegistry/registries/<app-registry-name>'
  ]
  pushRegistryPrivateEndpointPrefixes: ['10.20.2.0/27']
  runnerIpGroupResourceId: '/subscriptions/${sub}/resourceGroups/tools-prod-eus-network-rg/providers/Microsoft.Network/ipGroups/tools-prod-eus-ipg-aks-runners'
}
