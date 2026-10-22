using '../main.bicep'

param environment = 'prod'
param location = 'eastus'
param allowedLocations = ['eastus', 'westus2']

// Second pass, after az-landing-zone is deployed: fill these from its outputs
// (monitoring.logAnalyticsWorkspaceResourceId, vmDataCollectionRuleResourceIds.windows,
// and the logging identity) to turn on the DeployIfNotExists policies.
param logAnalyticsWorkspaceResourceId = ''
param vmDataCollectionRuleResourceId = ''
param vmMonitoringIdentityResourceId = ''

// Subscription IDs by management group, for example:
// param subscriptionPlacement = {
//   connectivity: '<connectivity subscription id>'
//   corp: '<workload subscription id>'
// }
