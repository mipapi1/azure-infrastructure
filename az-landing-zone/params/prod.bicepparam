using '../main.bicep'

param environment = 'prod'
param location = 'eastus'

param tags = {
  environment: 'prod'
  workload: 'platform-hub'
  managedBy: 'bicep'
}

param network = {
  addressPrefix: '10.0.0.0/22'
  firewallSubnetPrefix: '10.0.0.0/26'
  bastionSubnetPrefix: '10.0.1.0/26'
  gatewaySubnetPrefix: '10.0.2.0/27'
  privateEndpointSubnetPrefix: '10.0.3.0/26'
}

param firewall = {
  tier: 'Premium'
  threatIntelMode: 'Deny'
  intrusionDetectionMode: 'Deny'
}

param monitoring = {
  retentionInDays: 365
  enableSentinel: false
  replicationLocation: 'westus2'
  publicNetworkAccessForIngestion: 'Disabled'
  publicNetworkAccessForQuery: 'Disabled'
  alertEmails: ['platform-alerts@contoso.example']
}

param budget = {
  amount: 5000
  contactEmails: ['finops@contoso.example']
}

param defender = {
  securityContactEmail: 'security@contoso.example'
}

// Hybrid connectivity and DDoS protection are off by default.
param gateway = { type: 'None' }
param enableDdosProtection = false
