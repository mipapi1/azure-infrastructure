using '../../main.bicep'

// Test: every add-on on: AKS Backup, the image verification identity and the external-dns
// identity on the GitLab zone.
// expect-type: microsoft.dataprotection/backupvaults
// expect-type: microsoft.containerservice/managedclusters/trustedaccessrolebindings
// expect-property: microsoft.kubernetesconfiguration/extensions extensionType=microsoft.dataprotection.kubernetes
// expect-type: microsoft.managedidentity/userassignedidentities/federatedidentitycredentials

var hubSub = '00000000-0000-0000-0000-000000000000'
var hubPrefix = '/subscriptions/${hubSub}/resourceGroups/hub-staging-eus'

param environment = 'staging'
param location = 'eastus'

param tags = {
  environment: 'staging'
  workload: 'aks'
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

param firewallPolicyResourceId = '${hubPrefix}-networking-rg/providers/Microsoft.Network/firewallPolicies/hub-staging-eus-afwp'

// Flux and the platform charts pull from these until images are mirrored into the registry.
param allowedEgressFqdns = [
  'github.com'
  'ghcr.io'
  'pkg-containers.githubusercontent.com'
  'quay.io'
  '*.quay.io'
  'charts.jetstack.io'
  'charts.external-secrets.io'
]

param network = {
  addressPrefixes: ['10.120.0.0/23']
  nodeSubnetPrefix: '10.120.0.0/24'
  privateEndpointSubnetPrefix: '10.120.1.0/27'
  // Shared-cluster GitLab (az-gitlab staging): CI nodes get their own subnet and allowlist.
  additionalNodeSubnets: [
    {
      name: 'snet-aks-runners'
      addressPrefix: '10.120.1.64/26'
      allowedEgressFqdns: []
    }
  ]
  privateEndpointSecurityRules: [
    {
      name: 'deny-runners-data-services'
      properties: {
        access: 'Deny'
        direction: 'Inbound'
        priority: 200
        protocol: 'Tcp'
        sourceAddressPrefix: '10.120.1.64/26'
        sourcePortRange: '*'
        destinationAddressPrefix: '10.120.1.0/27'
        destinationPortRanges: ['5432', '6379', '10000']
      }
    }
  ]
}

param cluster = {
  kubernetesVersion: '1.34'
  systemPool: {
    name: 'system'
    vmSize: 'Standard_D4ds_v5'
    minCount: 2
    maxCount: 3
  }
  userPools: [
    {
      name: 'general'
      vmSize: 'Standard_D4ds_v5'
      minCount: 1
      maxCount: 3
    }
    // Shared-cluster GitLab (az-gitlab staging). Both pools scale from zero, so they cost
    // nothing until GitLab is deployed.
    {
      name: 'gitlab'
      vmSize: 'Standard_D4ds_v5'
      minCount: 0
      maxCount: 3
      nodeLabels: { 'platform.workload': 'gitlab' }
      nodeTaints: ['workload=gitlab:NoSchedule']
    }
    {
      name: 'runners'
      vmSize: 'Standard_D4ds_v5'
      minCount: 0
      maxCount: 3
      subnetName: 'snet-aks-runners'
      nodeLabels: { 'platform.workload': 'ci' }
      nodeTaints: ['workload=ci:NoSchedule']
      spot: true
    }
  ]
}

param access = {
  adminGroupObjectIds: ['<aks-admins-group-object-id>']
  readerGroupObjectIds: ['<aks-readers-group-object-id>']
}

param gitOps = {
  repositoryUrl: 'https://github.com/<org>/azure-infrastructure'
  branch: 'main'
}

param addons = {
  backup: { enabled: true, retentionDays: 7 }
  imageVerification: true
  externalDnsZoneNames: ['git-staging.example.internal']
}
