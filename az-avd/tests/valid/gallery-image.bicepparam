using '../../main.bicep'

// Test: session hosts from a Compute Gallery image definition (latest version).
// expect-property: microsoft.compute/virtualmachines storageProfile.imageReference.id=/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/aib-prod-eus-rg/providers/Microsoft.Compute/galleries/aib_prod_eus_gal/images/win11-avd

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
  type: 'Pooled'
  loadBalancerType: 'DepthFirst'
  maxSessionLimit: 8
  validationEnvironment: true
  startVMOnConnect: true
  friendlyName: 'Desktop (validation)'
}

param sessionHosts = {
  count: 2
  namePrefix: 'avds'
  vmSize: 'Standard_D4ads_v5'
  availabilityZones: []
  // PSRule Azure.VM.Standalone: gallery-image hosts without zones need premium disks
  osDiskType: 'Premium_LRS'
  adminUsername: 'avdlocaladmin'
  galleryImageResourceId: '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/aib-prod-eus-rg/providers/Microsoft.Compute/galleries/aib_prod_eus_gal/images/win11-avd'
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
