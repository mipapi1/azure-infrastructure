using '../main.bicep'

// Values in <angle brackets> and the all-zero subscription ID are placeholders.
// Take hub, monitoring and firewall values from the az-landing-zone outputs.

var hubSub = '00000000-0000-0000-0000-000000000000'
var hubPrefix = '/subscriptions/${hubSub}/resourceGroups/hub-prod-eus'

param environment = 'prod'
param location = 'eastus'

param tags = {
  environment: 'prod'
  workload: 'avd'
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

param baselineDataCollectionRuleResourceId = '${hubPrefix}-monitoring-rg/providers/Microsoft.Insights/dataCollectionRules/hub-prod-eus-dcr-vm-windows'
param firewallPolicyResourceId = '${hubPrefix}-networking-rg/providers/Microsoft.Network/firewallPolicies/hub-prod-eus-afwp'

param network = {
  addressPrefixes: ['10.10.0.0/22']
  sessionHostSubnetPrefix: '10.10.0.0/23'
  privateEndpointSubnetPrefix: '10.10.2.0/27'
}

param hostPool = {
  type: 'Pooled'
  loadBalancerType: 'BreadthFirst'
  maxSessionLimit: 12
  validationEnvironment: false
  startVMOnConnect: true
  friendlyName: 'Desktop'
}

param sessionHosts = {
  count: 6
  namePrefix: 'avdp'
  vmSize: 'Standard_D8ads_v5'
  availabilityZones: [1, 2, 3]
  osDiskType: 'Premium_LRS'
  adminUsername: 'avdlocaladmin'
  // To use an image from az-image-builder:
  // galleryImageResourceId: '/subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.Compute/galleries/<gallery>/images/win11-avd'
}

// Never commit the password. Read it from the environment, or replace with
// az.getSecret('<subscription-id>', '<rg>', '<key-vault>', 'avd-local-admin').
param sessionHostAdminPassword = readEnvironmentVariable('AVD_LOCAL_ADMIN_PASSWORD', '')

param identity = {
  mode: 'EntraJoined'
  intuneEnrollment: true
  userGroupObjectIds: ['<avd-users-group-object-id>']
  adminGroupObjectIds: ['<avd-admins-group-object-id>']
  avdServicePrincipalObjectId: '<azure-virtual-desktop-sp-object-id>'
}

param fslogix = {
  enabled: true
  configurationMethod: 'RunCommand'
  shareQuotaGiB: 1024
  cloudCache: false
}

param applicationGroups = [
  { name: 'desktop', type: 'Desktop', friendlyName: 'Desktop' }
]

param scaling = {
  enabled: true
  timeZone: 'Eastern Standard Time'
}
