// Hub network: firewall (all spoke egress and DNS), Bastion, Log Analytics and a budget.
// Deploy into resource group rg-hub. Spokes find these resources by name.

param alertEmail string
param budgetAmount int = 500
param budgetStartDate string = utcNow('yyyy-MM-01')
param location string = resourceGroup().location

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: 'law-hub'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2025-07-01' = {
  name: 'vnet-hub'
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.0.0.0/22'] }
    subnets: [
      { name: 'AzureFirewallSubnet', properties: { addressPrefix: '10.0.0.0/26' } }
      { name: 'AzureBastionSubnet', properties: { addressPrefix: '10.0.1.0/26' } }
    ]
  }
}

resource firewallIp 'Microsoft.Network/publicIPAddresses@2025-07-01' = {
  name: 'pip-afw-hub'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource bastionIp 'Microsoft.Network/publicIPAddresses@2025-07-01' = {
  name: 'pip-bas-hub'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

// Spokes use the firewall as their DNS server, so private DNS zones linked to the hub resolve everywhere.
resource firewallPolicy 'Microsoft.Network/firewallPolicies@2025-07-01' = {
  name: 'afwp-hub'
  location: location
  properties: {
    sku: { tier: 'Standard' }
    threatIntelMode: 'Deny'
    dnsSettings: { enableProxy: true }
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2025-07-01' = {
  name: 'afw-hub'
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
  name: 'law-hub'
  scope: firewall
  properties: {
    workspaceId: workspace.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2025-07-01' = {
  name: 'bas-hub'
  location: location
  sku: { name: 'Basic' }
  properties: {
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

module budget '../modules/budget.bicep' = {
  name: 'hub-budget'
  scope: subscription()
  params: {
    amount: budgetAmount
    startDate: budgetStartDate
    email: alertEmail
  }
}
