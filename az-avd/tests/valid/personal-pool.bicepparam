using '../../main.bicep'

// Test: personal host pool with automatic assignment.
// expect-property: microsoft.desktopvirtualization/hostpools hostPoolType=Personal
// expect-property: microsoft.desktopvirtualization/hostpools personalDesktopAssignmentType=Automatic

var hubSub = '00000000-0000-0000-0000-000000000000'
var hubPrefix = '/subscriptions/${hubSub}/resourceGroups/hub-staging-eus'

param environment = 'staging'
param location = 'eastus'

param tags = {
  environment: 'staging'
  workload: 'avd'
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

param baselineDataCollectionRuleResourceId = '${hubPrefix}-monitoring-rg/providers/Microsoft.Insights/dataCollectionRules/hub-staging-eus-dcr-vm-windows'
param firewallPolicyResourceId = '${hubPrefix}-networking-rg/providers/Microsoft.Network/firewallPolicies/hub-staging-eus-afwp'

param network = {
  addressPrefixes: ['10.110.0.0/23']
  sessionHostSubnetPrefix: '10.110.0.0/24'
  privateEndpointSubnetPrefix: '10.110.1.0/27'
}

// Validation pool: gets AVD service updates first.
param hostPool = {
  type: 'Personal'
  personalDesktopAssignmentType: 'Automatic'
  friendlyName: 'Personal desktop'
}

param sessionHosts = {
  count: 2
  namePrefix: 'avds'
  vmSize: 'Standard_D4ads_v5'
  availabilityZones: []
  osDiskType: 'StandardSSD_LRS'
  adminUsername: 'avdlocaladmin'
}

param sessionHostAdminPassword = readEnvironmentVariable('AVD_LOCAL_ADMIN_PASSWORD', '')

param identity = {
  mode: 'EntraJoined'
  intuneEnrollment: false
  userGroupObjectIds: ['<avd-users-group-object-id>']
  adminGroupObjectIds: ['<avd-admins-group-object-id>']
  avdServicePrincipalObjectId: '<azure-virtual-desktop-sp-object-id>'
}

param fslogix = {
  enabled: true
  shareQuotaGiB: 100
}

param scaling = {
  enabled: true
  timeZone: 'Eastern Standard Time'
}
