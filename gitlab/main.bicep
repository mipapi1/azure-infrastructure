// GitLab on the AKS cluster with managed backing services, each on a private endpoint in the AKS
// spoke: PostgreSQL, Azure Managed Redis, and blob storage for every GitLab object type, the
// container registry and backups. GitLab reaches blob storage with workload identity (no storage
// keys). Also the DNS name gitlab.gitlab.internal and firewall rules for the chart's images.
// Deploy into resource group rg-gitlab, then install the chart (values.yaml).

param dbAdminGroupId string
param dbAdminGroupName string
@secure()
param postgresPassword string
param location string = resourceGroup().location
@description('PostgreSQL region. Defaults to location; set another region if the subscription is restricted from creating servers there. The private endpoint stays in the AKS spoke.')
param postgresLocation string = location

@description('Azure Managed Redis SKU. Balanced_B0 is the smallest; use a larger Balanced SKU for real use.')
param redisSku string = 'Balanced_B0'

var suffix = take(uniqueString(subscription().id), 6)

// IP groups created with the AVD and AKS spokes.
var avdHostsIpGroup = resourceId('rg-hub', 'Microsoft.Network/ipGroups', 'ipg-avd-snet-hosts')
var aksNodesIpGroup = resourceId('rg-hub', 'Microsoft.Network/ipGroups', 'ipg-aks-snet-nodes')
var ingressIp = '10.2.0.250'

// GitLab signs in with the password; people sign in with Entra ID through the admin group.
resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: 'psql-gitlab-${take(uniqueString(subscription().id), 6)}'
  location: postgresLocation
  sku: { name: 'Standard_B2ms', tier: 'Burstable' }
  properties: {
    version: '17'
    administratorLogin: 'gitlab'
    administratorLoginPassword: postgresPassword
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Enabled'
      tenantId: tenant().tenantId
    }
    storage: { storageSizeGB: 128 }
    network: { publicNetworkAccess: 'Disabled' }
  }
}

resource dbAdmins 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2024-08-01' = {
  parent: postgres
  name: dbAdminGroupId
  properties: {
    principalType: 'Group'
    principalName: dbAdminGroupName
    tenantId: tenant().tenantId
  }
}

resource extensions 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: postgres
  name: 'azure.extensions'
  properties: {
    value: 'AMCHECK,BTREE_GIST,PG_TRGM,PG_STAT_STATEMENTS'
    source: 'user-override'
  }
  dependsOn: [dbAdmins]
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: postgres
  name: 'gitlabhq_production'
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
  dependsOn: [extensions]
}

module postgresZone '../modules/dns-zone.bicep' = {
  name: 'dns-postgres'
  scope: resourceGroup('rg-hub')
  params: {
    name: 'privatelink.postgres.database.azure.com'
  }
}

resource peSubnet 'Microsoft.Network/virtualNetworks/subnets@2025-07-01' existing = {
  name: 'vnet-aks/snet-pe'
  scope: resourceGroup('rg-aks')
}

resource postgresEndpoint 'Microsoft.Network/privateEndpoints@2025-07-01' = {
  name: 'pe-gitlab-postgres'
  location: location
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [
      {
        name: 'postgres'
        properties: {
          privateLinkServiceId: postgres.id
          groupIds: ['postgresqlServer']
        }
      }
    ]
  }
}

resource postgresDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-07-01' = {
  parent: postgresEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'postgres', properties: { privateDnsZoneId: postgresZone.outputs.id } }
    ]
  }
}

// The chart's ingress controller gets this fixed internal IP (values.yaml).
module gitlabZone '../modules/dns-zone.bicep' = {
  name: 'dns-gitlab'
  scope: resourceGroup('rg-hub')
  params: {
    name: 'gitlab.internal'
    aRecords: [{ name: 'gitlab', ip: ingressIp }]
  }
}

module rules '../modules/firewall-rules.bicep' = {
  name: 'firewall-rules-gitlab'
  scope: resourceGroup('rg-hub')
  params: {
    name: 'rcg-gitlab'
    priority: 300
    ruleCollections: [
      {
        name: 'gitlab-network'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 100
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'avd-to-gitlab'
            ipProtocols: ['TCP']
            sourceIpGroups: [avdHostsIpGroup]
            destinationAddresses: [ingressIp]
            destinationPorts: ['80', '22']
          }
        ]
      }
      {
        name: 'gitlab-application'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 200
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'chart-and-images'
            protocols: [{ protocolType: 'Https', port: 443 }]
            sourceIpGroups: [aksNodesIpGroup]
            targetFqdns: [
              'charts.gitlab.io'
              'registry.gitlab.com'
              'cdn.registry.gitlab-static.net'
              'registry.k8s.io'
              '*.pkg.dev'
              'registry-1.docker.io'
              'auth.docker.io'
              'production.cloudflare.docker.com'
            ]
          }
        ]
      }
    ]
  }
}

// Object storage --------------------------------------------------------------------------------
// GitLab's pods (service account gitlab in namespace gitlab) sign in as id-gitlab through the
// cluster's OIDC issuer. No storage keys exist.
resource cluster 'Microsoft.ContainerService/managedClusters@2025-07-01' existing = {
  name: 'aks-platform'
  scope: resourceGroup('rg-aks')
}

resource gitlabIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-gitlab'
  location: location
}

resource federation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: gitlabIdentity
  name: 'gitlab'
  properties: {
    issuer: cluster.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:gitlab:gitlab'
    audiences: ['api://AzureADTokenExchange']
  }
}

resource objectStorage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: 'stgitlab${suffix}'
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Disabled'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: objectStorage
  name: 'default'
}

// One container per GitLab object type (values.yaml), plus the registry, backups and a tmp area.
var buckets = [
  'git-lfs'
  'gitlab-artifacts'
  'gitlab-uploads'
  'gitlab-packages'
  'gitlab-mr-diffs'
  'gitlab-terraform-state'
  'gitlab-ci-secure-files'
  'gitlab-dependency-proxy'
  'registry'
  'gitlab-backups'
  'tmp'
]

resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = [
  for b in buckets: {
    parent: blobService
    name: b
  }
]

resource objectAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(objectStorage.id, gitlabIdentity.id, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: objectStorage
  properties: {
    principalId: gitlabIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}

module blobZone '../modules/dns-zone.bicep' = {
  name: 'dns-blob'
  scope: resourceGroup('rg-hub')
  params: {
    name: 'privatelink.blob.${environment().suffixes.storage}'
  }
}

resource blobEndpoint 'Microsoft.Network/privateEndpoints@2025-07-01' = {
  name: 'pe-gitlab-blob'
  location: location
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: {
          privateLinkServiceId: objectStorage.id
          groupIds: ['blob']
        }
      }
    ]
  }
}

resource blobDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-07-01' = {
  parent: blobEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'blob', properties: { privateDnsZoneId: blobZone.outputs.id } }
    ]
  }
}

// Redis -----------------------------------------------------------------------------------------
// Azure Managed Redis. GitLab doesn't support Redis Cluster: the EnterpriseCluster policy presents
// one non-clustered endpoint, TLS on port 10000. GitLab signs in with the access key.
resource redis 'Microsoft.Cache/redisEnterprise@2025-07-01' = {
  name: 'redis-gitlab-${suffix}'
  location: location
  sku: { name: redisSku }
  properties: {
    minimumTlsVersion: '1.2'
    highAvailability: 'Disabled'
    publicNetworkAccess: 'Disabled'
  }
}

resource redisDatabase 'Microsoft.Cache/redisEnterprise/databases@2025-07-01' = {
  parent: redis
  name: 'default'
  properties: {
    clientProtocol: 'Encrypted'
    port: 10000
    clusteringPolicy: 'EnterpriseCluster'
    evictionPolicy: 'NoEviction'
    accessKeysAuthentication: 'Enabled'
  }
}

module redisZone '../modules/dns-zone.bicep' = {
  name: 'dns-redis'
  scope: resourceGroup('rg-hub')
  params: {
    name: 'privatelink.redis.azure.net'
  }
}

resource redisEndpoint 'Microsoft.Network/privateEndpoints@2025-07-01' = {
  name: 'pe-gitlab-redis'
  location: location
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [
      {
        name: 'redis'
        properties: {
          privateLinkServiceId: redis.id
          groupIds: ['redisEnterprise']
        }
      }
    ]
  }
}

resource redisDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-07-01' = {
  parent: redisEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'redis', properties: { privateDnsZoneId: redisZone.outputs.id } }
    ]
  }
  dependsOn: [redisDatabase]
}

output objectStorageAccount string = objectStorage.name
output gitlabClientId string = gitlabIdentity.properties.clientId
output redisHost string = redis.properties.hostName
