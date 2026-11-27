// AKS cluster in its own spoke: private cluster with Entra ID RBAC, workload identity and, optionally,
// a container registry reached through a private endpoint. One deployment per cluster, each with its
// own param file in clusters/:
//   clusters/apps.bicepparam    <env>-aks-<workload>-apps    applications, with the registry
//   clusters/gitlab.bicepparam  <env>-aks-<workload>-gitlab  GitLab (and its CI runners), isolated
// Deploy into resource group <env>-rg-<workload>-<cluster>.
import { envCode, name, compactName } from '../modules/naming.bicep'

@description('Environment: p (prod) or s (staging).')
param env envCode
@description('Workload name used in every resource name: <env>-<type>-<workload>-<component>.')
param workload string
@description('Cluster name and spoke component, e.g. apps or gitlab.')
param cluster string

@description('Spoke address space and its subnets (nodes, private endpoints). Each cluster needs its own.')
param network { addressPrefix: string, nodesPrefix: string, endpointsPrefix: string }
@description('Priority of this cluster\'s rule collection group on the hub firewall policy. Unique per spoke.')
param rulePriority int

param adminGroupId string
param nodeVmSize string = 'Standard_D4ds_v5'
@description('Starting and minimum node count; the autoscaler adds up to maxNodeCount.')
@minValue(1)
param nodeCount int = 2
param maxNodeCount int = 5
@description('Create a container registry for this cluster (apps). GitLab has its own registry on blob storage.')
param registry bool = false
param location string = resourceGroup().location

var hubGroup = name(env, 'rg', workload, 'hub')
var nodesIpGroup = resourceId(hubGroup, 'Microsoft.Network/ipGroups', name(env, 'ipg', workload, '${cluster}-nodes'))

module spoke '../modules/spoke.bicep' = {
  name: 'spoke-${cluster}'
  params: {
    env: env
    workload: workload
    spoke: cluster
    location: location
    addressPrefix: network.addressPrefix
    subnets: [
      { name: 'nodes', addressPrefix: network.nodesPrefix }
      { name: 'pe', addressPrefix: network.endpointsPrefix }
    ]
    rulePriority: rulePriority
    ruleCollections: [
      {
        name: '${cluster}-network'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 100
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'ntp'
            ipProtocols: ['UDP']
            sourceIpGroups: [nodesIpGroup]
            destinationFqdns: ['ntp.ubuntu.com']
            destinationPorts: ['123']
          }
        ]
      }
      {
        name: '${cluster}-application'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 200
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'aks-required'
            protocols: [{ protocolType: 'Https', port: 443 }, { protocolType: 'Http', port: 80 }]
            sourceIpGroups: [nodesIpGroup]
            fqdnTags: ['AzureKubernetesService']
          }
        ]
      }
    ]
  }
}

var nodeSubnetId = '${spoke.outputs.vnetId}/subnets/snet-nodes'

// The cluster needs Network Contributor to use the spoke subnet and route table.
resource controlPlane 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: name(env, 'id', workload, cluster)
  location: location
}

resource networkAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, controlPlane.id, '4d97b98b-1d4f-4787-a291-c67834d212e7')
  properties: {
    principalId: controlPlane.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')
  }
}

// Private API server without a private DNS zone: its name resolves through public DNS
// to the private IP, which works with the firewall as DNS server.
resource aks 'Microsoft.ContainerService/managedClusters@2025-07-01' = {
  name: name(env, 'aks', workload, cluster)
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${controlPlane.id}': {} }
  }
  properties: {
    dnsPrefix: name(env, 'aks', workload, cluster)
    enableRBAC: true
    disableLocalAccounts: true
    aadProfile: {
      managed: true
      enableAzureRBAC: true
      adminGroupObjectIDs: [adminGroupId]
    }
    apiServerAccessProfile: {
      enablePrivateCluster: true
      privateDNSZone: 'none'
    }
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        osType: 'Linux'
        osSKU: 'AzureLinux'
        vmSize: nodeVmSize
        enableAutoScaling: true
        count: nodeCount
        minCount: nodeCount
        maxCount: max(nodeCount, maxNodeCount)
        vnetSubnetID: nodeSubnetId
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkDataplane: 'cilium'
      networkPolicy: 'cilium'
      outboundType: 'userDefinedRouting'
      podCidr: '192.168.0.0/16'
      serviceCidr: '172.16.0.0/16'
      dnsServiceIP: '172.16.0.10'
    }
    oidcIssuerProfile: { enabled: true }
    securityProfile: { workloadIdentity: { enabled: true } }
    autoUpgradeProfile: {
      upgradeChannel: 'patch'
      nodeOSUpgradeChannel: 'NodeImage'
    }
  }
  dependsOn: [networkAccess]
}

resource clusterAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aks.id, adminGroupId, 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b')
  scope: aks
  properties: {
    principalId: adminGroupId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b')
  }
}

// Public access stays on so images can be pushed; the cluster pulls through the private endpoint.
resource containerRegistry 'Microsoft.ContainerRegistry/registries@2025-04-01' = if (registry) {
  name: compactName(env, 'cr', workload, cluster, subscription().id)
  location: location
  sku: { name: 'Premium' }
  properties: {
    adminUserEnabled: false
  }
}

resource pull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (registry) {
  name: guid(containerRegistry.id, 'kubelet', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  scope: containerRegistry
  properties: {
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  }
}

module registryZone '../modules/dns-zone.bicep' = if (registry) {
  name: 'dns-acr'
  scope: resourceGroup(hubGroup)
  params: {
    env: env
    workload: workload
    name: 'privatelink.azurecr.io'
  }
}

resource registryEndpoint 'Microsoft.Network/privateEndpoints@2025-07-01' = if (registry) {
  name: name(env, 'pep', workload, '${cluster}-registry')
  location: location
  properties: {
    subnet: { id: '${spoke.outputs.vnetId}/subnets/snet-pe' }
    privateLinkServiceConnections: [
      {
        name: 'registry'
        properties: {
          privateLinkServiceId: containerRegistry.id
          groupIds: ['registry']
        }
      }
    ]
  }
}

resource registryDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-07-01' = if (registry) {
  parent: registryEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'registry', properties: { privateDnsZoneId: registryZone!.outputs.id } }
    ]
  }
}

output clusterName string = aks.name
output registryName string = registry ? containerRegistry.name : ''
