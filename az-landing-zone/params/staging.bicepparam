using '../main.bicep'

param environment = 'staging'
param location = 'eastus'

param tags = {
  environment: 'staging'
  workload: 'platform-hub'
  managedBy: 'bicep'
}

param network = {
  addressPrefix: '10.100.0.0/22'
  firewallSubnetPrefix: '10.100.0.0/26'
  bastionSubnetPrefix: '10.100.1.0/26'
  gatewaySubnetPrefix: '10.100.2.0/27'
  privateEndpointSubnetPrefix: '10.100.3.0/26'
}

// Standard tier, no zones: enough to test rules and routing at lower cost.
param firewall = {
  tier: 'Standard'
}

param bastionSku = 'Basic'

param monitoring = {
  retentionInDays: 30
  dailyQuotaGb: '5'
  publicNetworkAccessForIngestion: 'Disabled'
  publicNetworkAccessForQuery: 'Enabled'
  alertEmails: ['platform-alerts@contoso.example']
}

param keyVault = {
  sku: 'standard'
}

param budget = {
  amount: 1000
  contactEmails: ['finops@contoso.example']
}

param defender = {
  plans: ['CloudPosture']
}
