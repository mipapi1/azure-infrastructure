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

// PIM-eligible instead of standing access (scripts/Get-StandingPrivilegedAccess.ps1 lists what to
// convert). Grant to groups governed by PIM for Groups (scripts/Set-PimGroupPolicy.ps1). After the
// first deployment, change requestType to AdminUpdate (PIM rejects a second AdminAssign).
// param eligibleRoleAssignments = [
//   {
//     principalId: '<platform-owners-group-object-id>'
//     roleDefinitionId: '8e3af657-a8ff-443c-a75c-2fe8c4bcb635' // Owner
//     managementGroup: 'platform'
//     justification: 'Platform owners, just in time'
//   }
// ]
