// Hub network: firewall (all spoke egress and DNS), Bastion, Log Analytics with Sentinel,
// Key Vault on a private endpoint and a budget.
// Deploy into resource group <env>-rg-<workload>-hub. Spokes find these resources by name (modules/naming.bicep).

import { envCode, name, uniqueName } from '../modules/naming.bicep'

@description('Environment: p (prod) or s (staging).')
param env envCode
@description('Workload name used in every resource name: <env>-<type>-<workload>-<component>.')
param workload string
param alertEmail string
@description('Basic: portal connections only. Standard: also native-client SSH/RDP (az network bastion ssh).')
@allowed(['Basic', 'Standard'])
param bastionSku string = 'Basic'
@description('Log Analytics daily ingestion cap in GB; -1 for none.')
param logDailyCapGb int = -1
param budgetAmount int = 500
param budgetStartDate string = utcNow('yyyy-MM-01')
param location string = resourceGroup().location

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: name(env, 'log', workload, 'hub')
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: logDailyCapGb }
  }
}

resource sentinel 'Microsoft.SecurityInsights/onboardingStates@2024-03-01' = {
  name: 'default'
  scope: workspace
  properties: {}
}

resource vnet 'Microsoft.Network/virtualNetworks@2025-07-01' = {
  name: name(env, 'vnet', workload, 'hub')
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.0.0.0/22'] }
    subnets: [
      { name: 'AzureFirewallSubnet', properties: { addressPrefix: '10.0.0.0/26' } }
      { name: 'AzureBastionSubnet', properties: { addressPrefix: '10.0.1.0/26' } }
      { name: 'GatewaySubnet', properties: { addressPrefix: '10.0.2.0/27' } } // reserved for a VPN or ExpressRoute gateway
      { name: 'snet-pe', properties: { addressPrefix: '10.0.3.0/27' } }
    ]
  }
}

resource firewallIp 'Microsoft.Network/publicIPAddresses@2025-07-01' = {
  name: name(env, 'pip', workload, 'afw')
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource bastionIp 'Microsoft.Network/publicIPAddresses@2025-07-01' = {
  name: name(env, 'pip', workload, 'bas')
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

// Spokes use the firewall as their DNS server, so private DNS zones linked to the hub resolve everywhere.
resource firewallPolicy 'Microsoft.Network/firewallPolicies@2025-07-01' = {
  name: name(env, 'afwp', workload, 'hub')
  location: location
  properties: {
    sku: { tier: 'Standard' }
    threatIntelMode: 'Deny'
    dnsSettings: { enableProxy: true }
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2025-07-01' = {
  name: name(env, 'afw', workload, 'hub')
  location: location
  properties: {
    sku: { name: 'AZFW_VNet', tier: 'Standard' }
    firewallPolicy: { id: firewallPolicy.id }
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: { id: '${vnet.id}/subnets/AzureFirewallSubnet' }
          publicIPAddress: { id: firewallIp.id }
        }
      }
    ]
  }
}

resource firewallLogs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-afw'
  scope: firewall
  properties: {
    workspaceId: workspace.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2025-07-01' = {
  name: name(env, 'bas', workload, 'hub')
  location: location
  sku: { name: bastionSku }
  properties: {
    enableTunneling: bastionSku == 'Standard'
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: { id: '${vnet.id}/subnets/AzureBastionSubnet' }
          publicIPAddress: { id: bastionIp.id }
        }
      }
    ]
  }
}

// Platform secrets. RBAC only, no public access. Purge protection is off so a torn-down sandbox
// can be purged and redeployed; turn it on for production and for customer-managed keys.
resource vault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: uniqueName(env, 'kv', workload, 'hub', subscription().id)
  location: location
  properties: {
    tenantId: tenant().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Disabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'AzureServices' }
  }
}

resource vaultLogs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-kv'
  scope: vault
  properties: {
    workspaceId: workspace.id
    logs: [{ categoryGroup: 'audit', enabled: true }]
  }
}

module vaultZone '../modules/dns-zone.bicep' = {
  name: 'dns-vault'
  params: {
    env: env
    workload: workload
    name: 'privatelink.vaultcore.azure.net'
  }
  dependsOn: [vnet]
}

resource vaultEndpoint 'Microsoft.Network/privateEndpoints@2025-07-01' = {
  name: name(env, 'pep', workload, 'hub-vault')
  location: location
  properties: {
    subnet: { id: '${vnet.id}/subnets/snet-pe' }
    privateLinkServiceConnections: [
      {
        name: 'vault'
        properties: {
          privateLinkServiceId: vault.id
          groupIds: ['vault']
        }
      }
    ]
  }
}

resource vaultDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-07-01' = {
  parent: vaultEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'vault', properties: { privateDnsZoneId: vaultZone.outputs.id } }
    ]
  }
}

module budget '../modules/budget.bicep' = {
  name: 'hub-budget'
  scope: subscription()
  params: {
    env: env
    workload: workload
    amount: budgetAmount
    startDate: budgetStartDate
    email: alertEmail
  }
}
