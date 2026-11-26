using '../main.bicep'

// Cloud-only example: Entra-joined hosts, users created only in Microsoft Entra ID, no AD DS
// and no Entra Connect. Profiles on Azure Files with Entra Kerberos (Azure public cloud only).
// For a Kerberos-free variant, or Azure Government, set fslogix.storageType to 'BlobCloudCache'.
// After deploying, follow "Cloud-only identities: post-deploy steps" in the README.
//
// Values in <angle brackets> and the all-zero subscription ID are placeholders.
// Take hub, monitoring and firewall values from the az-landing-zone outputs.
// expect-property: microsoft.compute/virtualmachines/extensions type=AADLoginForWindows

var hubSub = '00000000-0000-0000-0000-000000000000'
var hubPrefix = '/subscriptions/${hubSub}/resourceGroups/hub-staging-eus'

param environment = 'staging'
param location = 'eastus'
param workload = 'avdco'

param tags = {
  environment: 'staging'
  workload: 'avdco'
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
param firewallRulePriority = 1010

param network = {
  addressPrefixes: ['10.112.0.0/23']
  sessionHostSubnetPrefix: '10.112.0.0/24'
  privateEndpointSubnetPrefix: '10.112.1.0/27'
}

param hostPool = {
  type: 'Pooled'
  maxSessionLimit: 8
  friendlyName: 'Desktop (cloud-only)'
}

// The image must meet the cloud-only Entra Kerberos client minimum (Windows 11 25H2 build
// 26200.8116 or later). The Marketplace 25H2 image at 'latest' does; check gallery images.
param sessionHosts = {
  count: 2
  namePrefix: 'avdc'
  vmSize: 'Standard_D4ads_v5'
  availabilityZones: []
  osDiskType: 'StandardSSD_LRS'
  adminUsername: 'avdlocaladmin'
}

param sessionHostAdminPassword = readEnvironmentVariable('AVD_LOCAL_ADMIN_PASSWORD', '')

param identity = {
  mode: 'EntraJoined'
  userIdentitySource: 'CloudOnly'
  intuneEnrollment: true
  userGroupObjectIds: ['<avd-users-group-object-id>']
  adminGroupObjectIds: ['<avd-admins-group-object-id>']
  // Lets AVD start and stop session hosts (scaling plan, start VM on connect).
  // az ad sp show --id 9cdead84-a844-4324-93f2-b2e6bb768d07 --query id -o tsv
  avdServicePrincipalObjectId: '<azure-virtual-desktop-sp-object-id>'
}

param fslogix = {
  enabled: true
  storageType: 'AzureFiles'
  shareQuotaGiB: 100
}

param scaling = {
  enabled: true
  timeZone: 'Eastern Standard Time'
}
