// AKS: spoke network, private cluster with Entra ID RBAC, and a container registry
// reached through a private endpoint. Deploy into resource group rg-aks.

param adminGroupId string
param nodeVmSize string = 'Standard_D4ds_v5'
@description('Starting and minimum node count; the autoscaler adds up to 5.')
@minValue(1)
param nodeCount int = 2
param location string = resourceGroup().location

var nodePrefix = '10.2.0.0/24'
var nodesIpGroup = resourceId('rg-hub', 'Microsoft.Network/ipGroups', 'ipg-aks-snet-nodes')

module spoke '../modules/spoke.bicep' = {
  name: 'spoke-aks'
  params: {
    name: 'aks'
    location: location
    addressPrefix: '10.2.0.0/22'
    subnets: [
      { name: 'snet-nodes', addressPrefix: nodePrefix }
      { name: 'snet-pe', addressPrefix: '10.2.1.0/27' }
    ]
    rulePriority: 200
    ruleCollections: [
      {
        name: 'aks-network'
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
        name: 'aks-application'
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
  name: 'id-aks'
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
resource cluster 'Microsoft.ContainerService/managedClusters@2025-07-01' = {
  name: 'aks'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${controlPlane.id}': {} }
  }
  properties: {
    dnsPrefix: 'aks'
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
        maxCount: 5
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
  name: guid(cluster.id, adminGroupId, 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b')
  scope: cluster
  properties: {
    principalId: adminGroupId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b')
  }
}

// Public access stays on so `az acr build` can push; the cluster pulls through the private endpoint.
resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: 'craks${uniqueString(resourceGroup().id)}'
  location: location
  sku: { name: 'Premium' }
  properties: {
    adminUserEnabled: false
  }
}

resource pull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, 'kubelet', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  scope: registry
  properties: {
    principalId: cluster.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  }
}

module registryZone '../modules/dns-zone.bicep' = {
  name: 'dns-acr'
  scope: resourceGroup('rg-hub')
  params: {
    name: 'privatelink.azurecr.io'
  }
}

resource registryEndpoint 'Microsoft.Network/privateEndpoints@2025-07-01' = {
  name: 'pe-acr'
  location: location
  properties: {
    subnet: { id: '${spoke.outputs.vnetId}/subnets/snet-pe' }
    privateLinkServiceConnections: [
      {
        name: 'registry'
        properties: {
          privateLinkServiceId: registry.id
          groupIds: ['registry']
        }
      }
    ]
  }
}

resource registryDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-07-01' = {
  parent: registryEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'registry', properties: { privateDnsZoneId: registryZone.outputs.id } }
    ]
  }
}
