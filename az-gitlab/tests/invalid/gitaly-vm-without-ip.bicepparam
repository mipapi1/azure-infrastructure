// expect-error: gitaly.mode VirtualMachine needs gitaly.privateIp
using '../../main.bicep'

var sub = '00000000-0000-0000-0000-000000000000'
var rg = '/subscriptions/${sub}/resourceGroups/tools-staging-eus-rg'

param environment = 'staging'
param location = 'eastus'
param tags = { environment: 'staging', workload: 'gitlab', managedBy: 'bicep' }
param hub = {
  virtualNetworkResourceId: '/subscriptions/${sub}/resourceGroups/hub/providers/Microsoft.Network/virtualNetworks/hub'
  firewallPrivateIp: '10.100.0.4'
  privateDnsZoneResourceGroupResourceId: '/subscriptions/${sub}/resourceGroups/hub-dns'
}
param monitoring = {
  logAnalyticsWorkspaceResourceId: '/subscriptions/${sub}/resourceGroups/hub/providers/Microsoft.OperationalInsights/workspaces/law'
}
param cluster = {
  clusterResourceId: '${rg}/providers/Microsoft.ContainerService/managedClusters/aks'
  oidcIssuerUrl: 'https://issuer.example/'
  keyVaultResourceId: '${rg}/providers/Microsoft.KeyVault/vaults/kv'
  registryResourceId: '${rg}/providers/Microsoft.ContainerRegistry/registries/cr'
  subnetResourceIds: {
    'snet-gitaly': '${rg}/providers/Microsoft.Network/virtualNetworks/v/subnets/snet-gitaly'
    'snet-private-endpoints': '${rg}/providers/Microsoft.Network/virtualNetworks/v/subnets/snet-private-endpoints'
  }
}
param dns = { zoneName: 'git.example.internal', ingressIp: '10.120.0.250', sshIp: '10.120.0.251' }
param postgresAdministratorPassword = ''
param gitaly = { mode: 'VirtualMachine', adminSshPublicKey: 'ssh-ed25519 AAAA placeholder' }
