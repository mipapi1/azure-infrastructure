using '../main.bicep'

// Tools cluster: a second az-aks deployment in its own spoke, for GitLab and its runners
// (az-gitlab). Kept apart from the application cluster so Flux there never depends on a Git
// host running inside the same cluster, and GitLab upgrades and CI load can't affect apps.
// Values in <angle brackets> and the all-zero subscription ID are placeholders.

var hubSub = '00000000-0000-0000-0000-000000000000'
var hubPrefix = '/subscriptions/${hubSub}/resourceGroups/hub-prod-eus'

param environment = 'prod'
param location = 'eastus'
param workload = 'tools'

param tags = {
  environment: 'prod'
  workload: 'tools'
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

param firewallPolicyResourceId = '${hubPrefix}-networking-rg/providers/Microsoft.Network/firewallPolicies/hub-prod-eus-afwp'
param firewallRulePriority = 1150
param useFirewallIpGroups = true

// The platform controllers (Flux, External Secrets, cert-manager) still pull from these.
// Runner and job images come through the registry cache instead (registryCacheRules).
param allowedEgressFqdns = [
  'github.com'
  'ghcr.io'
  'pkg-containers.githubusercontent.com'
  'quay.io'
  '*.quay.io'
  'charts.jetstack.io'
  'charts.external-secrets.io'
  'charts.gitlab.io'
  'gitlab-charts.s3.amazonaws.com'
]

// 10.30.0.0/22: next free /22 after the AVD (10.10) and application AKS (10.20) spokes.
param network = {
  addressPrefixes: ['10.30.0.0/22']
  nodeSubnetPrefix: '10.30.0.0/24'
  privateEndpointSubnetPrefix: '10.30.2.0/26'
  additionalNodeSubnets: [
    {
      // CI job nodes: own IP Group, no public egress beyond the AKS requirements.
      name: 'snet-aks-runners'
      addressPrefix: '10.30.1.0/24'
      allowedEgressFqdns: []
    }
  ]
  vmSubnets: [
    {
      name: 'snet-gitaly'
      addressPrefix: '10.30.2.64/28'
      securityRules: [
        {
          name: 'allow-gitlab-nodes-gitaly'
          properties: {
            access: 'Allow'
            direction: 'Inbound'
            priority: 100
            protocol: 'Tcp'
            sourceAddressPrefix: '10.30.0.0/24'
            sourcePortRange: '*'
            destinationAddressPrefix: '10.30.2.64/28'
            destinationPortRanges: ['8075', '9236']
          }
        }
        {
          name: 'deny-runners'
          properties: {
            access: 'Deny'
            direction: 'Inbound'
            priority: 200
            protocol: '*'
            sourceAddressPrefix: '10.30.1.0/24'
            sourcePortRange: '*'
            destinationAddressPrefix: '10.30.2.64/28'
            destinationPortRange: '*'
          }
        }
      ]
    }
  ]
  // CI jobs reach the registry and vault endpoints (443) but never the database or cache.
  privateEndpointSecurityRules: [
    {
      name: 'deny-runners-data-services'
      properties: {
        access: 'Deny'
        direction: 'Inbound'
        priority: 200
        protocol: 'Tcp'
        sourceAddressPrefix: '10.30.1.0/24'
        sourcePortRange: '*'
        destinationAddressPrefix: '10.30.2.0/26'
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
    minCount: 3
    maxCount: 5
  }
  userPools: [
    {
      name: 'gitlab'
      vmSize: 'Standard_D8ds_v5'
      minCount: 3
      maxCount: 6
      nodeLabels: { 'platform.workload': 'gitlab' }
      nodeTaints: ['workload=gitlab:NoSchedule']
    }
    {
      name: 'runners'
      vmSize: 'Standard_D4ds_v5'
      minCount: 0
      maxCount: 10
      subnetName: 'snet-aks-runners'
      nodeLabels: { 'platform.workload': 'ci' }
      nodeTaints: ['workload=ci:NoSchedule']
      spot: false
    }
  ]
}

param access = {
  adminGroupObjectIds: ['<tools-admins-group-object-id>']
  readerGroupObjectIds: ['<tools-readers-group-object-id>']
}

// The tools cluster follows the hosted Git provider, never the GitLab it runs.
param gitOps = {
  repositoryUrl: 'https://github.com/<org>/azure-infrastructure'
  branch: 'main'
}

// Upstreams the registry cache can pull without credentials (Docker Hub needs a credential set).
param registryCacheRules = [
  { name: 'azurelinux-core', sourceRepository: 'mcr.microsoft.com/azurelinux/base/core', targetRepository: 'cache/azurelinux/base/core' }
  { name: 'azure-cli', sourceRepository: 'mcr.microsoft.com/azure-cli', targetRepository: 'cache/azure-cli' }
  { name: 'trivy', sourceRepository: 'ghcr.io/aquasecurity/trivy', targetRepository: 'cache/aquasecurity/trivy' }
  { name: 'cosign', sourceRepository: 'ghcr.io/sigstore/cosign/cosign', targetRepository: 'cache/sigstore/cosign' }
]
