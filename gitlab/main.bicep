// GitLab on the AKS cluster: PostgreSQL on a private endpoint in the AKS spoke,
// DNS name gitlab.gitlab.internal, and firewall rules for the chart's images.
// Deploy into resource group rg-gitlab, then install the chart (values.yaml).

param dbAdminGroupId string
param dbAdminGroupName string
@secure()
param postgresPassword string
param location string = resourceGroup().location
@description('PostgreSQL region. Defaults to location; set another region if the subscription is restricted from creating servers there. The private endpoint stays in the AKS spoke.')
param postgresLocation string = location

var nodePrefix = '10.2.0.0/24'
var ingressIp = '10.2.0.250'

// GitLab signs in with the password; people sign in with Entra ID through the admin group.
resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: 'psql-gitlab-${uniqueString(resourceGroup().id)}'
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
  name: 'pe-postgres'
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
    name: 'gitlab'
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
            sourceAddresses: ['10.1.0.0/24']
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
            sourceAddresses: [nodePrefix]
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
