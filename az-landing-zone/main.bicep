metadata name = 'Platform landing zone'
metadata description = 'Connectivity (hub network, firewall, Bastion, private DNS, optional gateway and DDoS plan) and management (Log Analytics, AMPLS, data collection, Key Vault, Defender, budget) for one environment.'

targetScope = 'subscription'

import { environmentType, hubReferenceType, lockFor, monitoringReferenceType, tagsType } from '../modules/shared/types.bicep'
import { compactName, regionShortNames } from '../modules/shared/naming.bicep'
import {
  budgetType
  defenderType
  firewallType
  gatewayType
  hubNetworkType
  keyVaultType
  monitoringType
} from 'types.bicep'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Required. Environment. Drives SKU, redundancy, retention and lock defaults.')
param environment environmentType

@description('Required. Region for every regional resource.')
param location string

@description('Optional. Workload name used in resource names.')
param workload string = 'hub'

@description('Required. Tags applied to every resource.')
param tags tagsType

@description('Required. Hub network layout.')
param network hubNetworkType

@description('Optional. Azure Firewall settings.')
param firewall firewallType = {}

@description('Optional. Bastion SKU. Defaults to Standard.')
param bastionSku ('Basic' | 'Standard' | 'Premium') = 'Standard'

@description('Optional. Hybrid connectivity gateway. Defaults to none.')
param gateway gatewayType = { type: 'None' }

@description('Optional. Deploy a DDoS Network Protection plan and associate it with the hub. Defaults to false (the plan has a significant fixed monthly cost).')
param enableDdosProtection bool = false

@description('Optional. Central monitoring settings.')
param monitoring monitoringType = {}

@description('Optional. Platform Key Vault settings.')
param keyVault keyVaultType = {}

@description('Optional. Monthly budget. Omit to skip.')
param budget budgetType?

@description('Optional. Microsoft Defender for Cloud settings. Omit to leave Defender unchanged.')
param defender defenderType?

@description('Optional. Private DNS zones in addition to the defaults (Azure Monitor, Key Vault, Storage, AVD, ACR, AKS, Grafana).')
param additionalPrivateDnsZones string[] = []

@description('Optional. Enable AVM usage telemetry.')
param enableTelemetry bool = true

@description('Generated. Do not set. Used for the budget start date.')
param deploymentTime string = utcNow('yyyy-MM-01')

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

var isProd = environment == 'prod'
var lock = lockFor(environment)
// <workload>-<environment>-<region>, the prefix of every name (see modules/shared/naming.bicep).
var baseName = '${workload}-${environment}-${regionShortNames[location]}'

var rgNames = {
  networking: '${baseName}-networking-rg'
  management: '${baseName}-management-rg'
  monitoring: '${baseName}-monitoring-rg'
  dns: '${baseName}-dns-rg'
}

var internalRanges = network.?internalAddressRanges ?? ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']
var firewallTier = firewall.?tier ?? (isProd ? 'Premium' : 'Standard')
var zones = firewall.?availabilityZones ?? (isProd ? [1, 2, 3] : [])

var storageSuffix = az.environment().suffixes.storage
var defaultPrivateDnsZones = [
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
  'privatelink.blob.${storageSuffix}'
  'privatelink.file.${storageSuffix}'
  'privatelink.queue.${storageSuffix}'
  'privatelink.table.${storageSuffix}'
  'privatelink${az.environment().suffixes.keyvaultDns}'
  'privatelink.wvd.microsoft.com'
  'privatelink-global.wvd.microsoft.com'
  'privatelink${az.environment().suffixes.acrLoginServer}'
  'privatelink.${location}.azmk8s.io'
  'privatelink.${location}.prometheus.monitor.azure.com'
  'privatelink.grafana.azure.com'
]
var privateDnsZones = union(defaultPrivateDnsZones, additionalPrivateDnsZones)
var dnsZoneResourceGroupId = subscriptionResourceId('Microsoft.Resources/resourceGroups', rgNames.dns)

var lawName = '${baseName}-law'
var lawResourceId = resourceId(
  subscription().subscriptionId,
  rgNames.monitoring,
  'Microsoft.OperationalInsights/workspaces',
  lawName
)
var dceResourceId = resourceId(
  subscription().subscriptionId,
  rgNames.monitoring,
  'Microsoft.Insights/dataCollectionEndpoints',
  '${baseName}-dce'
)
// Every resource that supports it sends all logs and metrics to the central workspace.
var diagnosticSettings = [
  {
    name: 'to-central-law'
    workspaceResourceId: lawResourceId
  }
]

var firewallRuleCollectionGroups = concat(
  loadJsonContent('config/firewall-rules/network-rules.json'),
  loadJsonContent('config/firewall-rules/application-rules.json')
)

// ---------------------------------------------------------------------------
// Resource groups
// ---------------------------------------------------------------------------

module resourceGroups 'br/public:avm/res/resources/resource-group:0.4.4' = [
  for rg in items(rgNames): {
    name: '${uniqueString(deployment().name, location)}-rg-${rg.key}'
    params: {
      name: rg.value
      location: location
      lock: lock
      tags: tags
      enableTelemetry: enableTelemetry
    }
  }
]

// ---------------------------------------------------------------------------
// Management: identities, Log Analytics, AMPLS, data collection, alerts
// ---------------------------------------------------------------------------

module identities 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = [
  for purpose in ['logging', 'encryption']: {
    name: '${uniqueString(deployment().name, location)}-uami-${purpose}'
    scope: resourceGroup(rgNames.management)
    params: {
      name: '${baseName}-uami-${purpose}'
      location: location
      lock: lock
      tags: tags
      enableTelemetry: enableTelemetry
    }
    dependsOn: [resourceGroups]
  }
]

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: '${uniqueString(deployment().name, location)}-law'
  scope: resourceGroup(rgNames.monitoring)
  params: {
    name: lawName
    location: location
    skuName: 'PerGB2018'
    dataRetention: monitoring.?retentionInDays ?? (isProd ? 365 : 30)
    dailyQuotaGb: monitoring.?dailyQuotaGb ?? (isProd ? '-1' : '5')
    publicNetworkAccessForIngestion: monitoring.?publicNetworkAccessForIngestion ?? 'Disabled'
    publicNetworkAccessForQuery: monitoring.?publicNetworkAccessForQuery ?? 'Enabled'
    replication: !empty(monitoring.?replicationLocation ?? '')
      ? { enabled: true, location: monitoring.?replicationLocation }
      : null
    gallerySolutions: (monitoring.?enableSentinel ?? false)
      ? [
          {
            name: 'SecurityInsights(${lawName})'
            plan: { product: 'OMSGallery/SecurityInsights', publisher: 'Microsoft' }
          }
        ]
      : []
    onboardWorkspaceToSentinel: monitoring.?enableSentinel ?? false
    features: {
      disableLocalAuth: true
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    diagnosticSettings: [{ name: 'self', useThisWorkspace: true }]
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
  dependsOn: [resourceGroups]
}

module dataCollectionEndpoint 'br/public:avm/res/insights/data-collection-endpoint:0.5.1' = {
  name: '${uniqueString(deployment().name, location)}-dce'
  scope: resourceGroup(rgNames.monitoring)
  params: {
    name: '${baseName}-dce'
    location: location
    kind: 'Windows'
    publicNetworkAccess: 'Disabled'
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
  dependsOn: [resourceGroups]
}

// Baseline guest data for every VM: the workloads add their own DCRs (AVD Insights, Container Insights).
module vmDataCollectionRules 'br/public:avm/res/insights/data-collection-rule:0.11.0' = [
  for os in ['Windows', 'Linux']: {
    name: '${uniqueString(deployment().name, location)}-dcr-${toLower(os)}'
    scope: resourceGroup(rgNames.monitoring)
    params: {
      name: '${baseName}-dcr-vm-${toLower(os)}'
      location: location
      dataCollectionRuleProperties: os == 'Windows'
        ? {
            kind: 'Windows'
            description: 'Baseline Windows event logs and performance counters.'
            dataCollectionEndpointResourceId: dceResourceId
            dataSources: {
              windowsEventLogs: [
                {
                  name: 'eventLogs'
                  streams: ['Microsoft-Event']
                  xPathQueries: [
                    'Application!*[System[(Level=1 or Level=2 or Level=3)]]'
                    'System!*[System[(Level=1 or Level=2 or Level=3)]]'
                    'Security!*[System[(band(Keywords,13510798882111488))]]'
                  ]
                }
              ]
              performanceCounters: [
                {
                  name: 'perfCounters'
                  streams: ['Microsoft-Perf']
                  samplingFrequencyInSeconds: 60
                  counterSpecifiers: [
                    '\\Processor Information(_Total)\\% Processor Time'
                    '\\Memory\\Available Bytes'
                    '\\Memory\\% Committed Bytes In Use'
                    '\\LogicalDisk(_Total)\\% Free Space'
                    '\\LogicalDisk(_Total)\\Avg. Disk sec/Transfer'
                    '\\Network Interface(*)\\Bytes Total/sec'
                  ]
                }
              ]
            }
            destinations: {
              logAnalytics: [{ name: 'law', workspaceResourceId: lawResourceId }]
            }
            dataFlows: [{ streams: ['Microsoft-Event', 'Microsoft-Perf'], destinations: ['law'] }]
          }
        : {
            kind: 'Linux'
            description: 'Baseline Linux syslog and performance counters.'
            dataCollectionEndpointResourceId: dceResourceId
            dataSources: {
              syslog: [
                {
                  name: 'syslog'
                  streams: ['Microsoft-Syslog']
                  facilityNames: ['auth', 'authpriv', 'cron', 'daemon', 'kern', 'syslog', 'user']
                  logLevels: ['Warning', 'Error', 'Critical', 'Alert', 'Emergency']
                }
              ]
              performanceCounters: [
                {
                  name: 'perfCounters'
                  streams: ['Microsoft-Perf']
                  samplingFrequencyInSeconds: 60
                  counterSpecifiers: [
                    'Processor(*)\\% Processor Time'
                    'Memory(*)\\% Used Memory'
                    'Logical Disk(*)\\% Used Space'
                    'Network(*)\\Total Bytes'
                  ]
                }
              ]
            }
            destinations: {
              logAnalytics: [{ name: 'law', workspaceResourceId: lawResourceId }]
            }
            dataFlows: [{ streams: ['Microsoft-Syslog', 'Microsoft-Perf'], destinations: ['law'] }]
          }
      lock: lock
      tags: tags
      enableTelemetry: enableTelemetry
    }
    dependsOn: [logAnalytics, dataCollectionEndpoint]
  }
]

module actionGroup 'br/public:avm/res/insights/action-group:0.8.0' = {
  name: '${uniqueString(deployment().name, location)}-ag'
  scope: resourceGroup(rgNames.monitoring)
  params: {
    name: '${baseName}-ag-platform'
    groupShortName: take('plat${environment}', 12)
    location: 'global'
    emailReceivers: map(monitoring.?alertEmails ?? [], e => {
      name: e
      emailAddress: e
      useCommonAlertSchema: true
    })
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
  dependsOn: [resourceGroups]
}

// ---------------------------------------------------------------------------
// Connectivity: hub network, firewall, Bastion, gateway, private DNS
// ---------------------------------------------------------------------------

module ddosPlan 'br/public:avm/res/network/ddos-protection-plan:0.3.2' = if (enableDdosProtection) {
  name: '${uniqueString(deployment().name, location)}-ddos'
  scope: resourceGroup(rgNames.networking)
  params: {
    name: '${baseName}-ddos'
    location: location
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
  dependsOn: [resourceGroups]
}

module privateEndpointNsg 'br/public:avm/res/network/network-security-group:0.5.4' = {
  name: '${uniqueString(deployment().name, location)}-nsg-pe'
  scope: resourceGroup(rgNames.networking)
  params: {
    name: '${baseName}-vnet-PrivateEndpointSubnet-nsg'
    location: location
    securityRules: [
      {
        name: 'allow-internal-https'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 100
          protocol: 'Tcp'
          sourceAddressPrefixes: internalRanges
          sourcePortRange: '*'
          destinationAddressPrefix: network.privateEndpointSubnetPrefix
          destinationPortRange: '443'
        }
      }
      {
        name: 'deny-lateral-outbound'
        properties: {
          access: 'Deny'
          direction: 'Outbound'
          priority: 4000
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: ['22', '3389']
        }
      }
      {
        name: 'deny-all-inbound'
        properties: {
          access: 'Deny'
          direction: 'Inbound'
          priority: 4096
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
    diagnosticSettings: [
      {
        name: 'to-central-law'
        workspaceResourceId: lawResourceId
        logCategoriesAndGroups: [{ categoryGroup: 'allLogs' }]
      }
    ]
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
  dependsOn: [resourceGroups, logAnalytics]
}

module bastionNsg 'br/public:avm/res/network/network-security-group:0.5.4' = {
  name: '${uniqueString(deployment().name, location)}-nsg-bastion'
  scope: resourceGroup(rgNames.networking)
  params: {
    name: '${baseName}-vnet-AzureBastionSubnet-nsg'
    location: location
    // Required rules for the Bastion subnet: https://learn.microsoft.com/azure/bastion/bastion-nsg
    securityRules: [
      {
        name: 'allow-https-inbound'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 120
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'allow-gateway-manager-inbound'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 130
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'allow-load-balancer-inbound'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 140
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'allow-bastion-host-communication-inbound'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 150
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: ['8080', '5701']
        }
      }
      {
        name: 'deny-all-inbound'
        properties: {
          access: 'Deny'
          direction: 'Inbound'
          priority: 4096
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'allow-ssh-rdp-outbound'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 100
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: ['22', '3389']
        }
      }
      {
        name: 'allow-azure-cloud-outbound'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 110
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureCloud'
          destinationPortRange: '443'
        }
      }
      {
        name: 'allow-bastion-communication-outbound'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 120
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: ['8080', '5701']
        }
      }
      {
        name: 'allow-session-information-outbound'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 130
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '80'
        }
      }
    ]
    diagnosticSettings: [
      {
        name: 'to-central-law'
        workspaceResourceId: lawResourceId
        logCategoriesAndGroups: [{ categoryGroup: 'allLogs' }]
      }
    ]
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
  dependsOn: [resourceGroups, logAnalytics]
}

module hubVnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: '${uniqueString(deployment().name, location)}-vnet'
  scope: resourceGroup(rgNames.networking)
  params: {
    name: '${baseName}-vnet'
    location: location
    addressPrefixes: [network.addressPrefix]
    ddosProtectionPlanResourceId: enableDdosProtection ? ddosPlan!.outputs.resourceId : null
    subnets: concat(
      [
        { name: 'AzureFirewallSubnet', addressPrefix: network.firewallSubnetPrefix }
        {
          name: 'AzureBastionSubnet'
          addressPrefix: network.bastionSubnetPrefix
          networkSecurityGroupResourceId: bastionNsg.outputs.resourceId
        }
        { name: 'GatewaySubnet', addressPrefix: network.gatewaySubnetPrefix }
        {
          name: 'PrivateEndpointSubnet'
          addressPrefix: network.privateEndpointSubnetPrefix
          networkSecurityGroupResourceId: privateEndpointNsg.outputs.resourceId
          privateEndpointNetworkPolicies: 'Enabled'
          defaultOutboundAccess: false
        }
      ],
      !empty(network.?firewallManagementSubnetPrefix ?? '')
        ? [{ name: 'AzureFirewallManagementSubnet', addressPrefix: network.?firewallManagementSubnetPrefix }]
        : []
    )
    diagnosticSettings: diagnosticSettings
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
  dependsOn: [logAnalytics]
}

module firewallPolicy 'br/public:avm/res/network/firewall-policy:0.3.6' = {
  name: '${uniqueString(deployment().name, location)}-afwp'
  scope: resourceGroup(rgNames.networking)
  params: {
    name: '${baseName}-afwp'
    location: location
    tier: firewallTier
    threatIntelMode: firewall.?threatIntelMode ?? 'Deny'
    intrusionDetection: firewallTier == 'Premium'
      ? { mode: firewall.?intrusionDetectionMode ?? (isProd ? 'Deny' : 'Alert') }
      : null
    enableProxy: firewall.?dnsProxyEnabled ?? true
    insightsIsEnabled: true
    defaultWorkspaceResourceId: lawResourceId
    retentionDays: isProd ? 90 : 30
    ruleCollectionGroups: firewallRuleCollectionGroups
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
  dependsOn: [resourceGroups, logAnalytics]
}

module azureFirewall 'br/public:avm/res/network/azure-firewall:0.11.1' = {
  name: '${uniqueString(deployment().name, location)}-afw'
  scope: resourceGroup(rgNames.networking)
  params: {
    name: '${baseName}-afw'
    location: location
    azureSkuTier: firewallTier
    virtualNetworkResourceId: hubVnet.outputs.resourceId
    firewallPolicyId: firewallPolicy.outputs.resourceId
    availabilityZones: zones
    publicIPAddressObject: {
      name: '${baseName}-afw-pip'
      availabilityZones: zones
      diagnosticSettings: diagnosticSettings
    }
    diagnosticSettings: [
      {
        name: 'to-central-law'
        workspaceResourceId: lawResourceId
        logAnalyticsDestinationType: 'Dedicated'
      }
    ]
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

module bastion 'br/public:avm/res/network/bastion-host:0.8.2' = {
  name: '${uniqueString(deployment().name, location)}-bastion'
  scope: resourceGroup(rgNames.networking)
  params: {
    // Kept as "-bastion" (not the CAF "bas") to match names already deployed.
    name: '${baseName}-bastion'
    location: location
    virtualNetworkResourceId: hubVnet.outputs.resourceId
    skuName: bastionSku
    disableCopyPaste: isProd
    enableFileCopy: !isProd && bastionSku != 'Basic'
    enableShareableLink: false
    diagnosticSettings: diagnosticSettings
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

module virtualNetworkGateway 'br/public:avm/res/network/virtual-network-gateway:0.12.0' = if (gateway.type != 'None') {
  name: '${uniqueString(deployment().name, location)}-vgw'
  scope: resourceGroup(rgNames.networking)
  params: {
    name: '${baseName}-vgw'
    location: location
    gatewayType: gateway.type == 'Vpn' ? 'Vpn' : 'ExpressRoute'
    skuName: gateway.?skuName ?? (gateway.type == 'Vpn' ? 'VpnGw1AZ' : 'ErGw1AZ')
    virtualNetworkResourceId: hubVnet.outputs.resourceId
    clusterSettings: gateway.type == 'Vpn' && (gateway.?activeActive ?? isProd)
      ? { clusterMode: 'activeActiveNoBgp' }
      : { clusterMode: 'activePassiveNoBgp' }
    diagnosticSettings: diagnosticSettings
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

module privateDns 'br/public:avm/res/network/private-dns-zone:0.8.1' = [
  for zone in privateDnsZones: {
    name: '${uniqueString(deployment().name, location)}-pdns-${uniqueString(zone)}'
    scope: resourceGroup(rgNames.dns)
    params: {
      name: zone
      location: 'global'
      virtualNetworkLinks: [
        {
          name: 'link-hub-vnet'
          virtualNetworkResourceId: hubVnet.outputs.resourceId
          registrationEnabled: false
        }
      ]
      lock: lock
      tags: tags
      enableTelemetry: enableTelemetry
    }
  }
]

// ---------------------------------------------------------------------------
// Private access to monitoring and secrets
// ---------------------------------------------------------------------------

module ampls 'br/public:avm/res/insights/private-link-scope:0.7.3' = {
  name: '${uniqueString(deployment().name, location)}-ampls'
  scope: resourceGroup(rgNames.monitoring)
  params: {
    name: '${baseName}-ampls'
    location: 'global'
    accessModeSettings: {
      ingestionAccessMode: monitoring.?amplsIngestionAccessMode ?? 'PrivateOnly'
      queryAccessMode: monitoring.?amplsQueryAccessMode ?? 'Open'
    }
    scopedResources: [
      { name: 'scoped-law', linkedResourceId: logAnalytics.outputs.resourceId }
      { name: 'scoped-dce', linkedResourceId: dataCollectionEndpoint.outputs.resourceId }
    ]
    privateEndpoints: [
      {
        name: '${baseName}-ampls-pe'
        subnetResourceId: '${hubVnet.outputs.resourceId}/subnets/PrivateEndpointSubnet'
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: '${dnsZoneResourceGroupId}/providers/Microsoft.Network/privateDnsZones/privatelink.monitor.azure.com'
            }
            {
              privateDnsZoneResourceId: '${dnsZoneResourceGroupId}/providers/Microsoft.Network/privateDnsZones/privatelink.oms.opinsights.azure.com'
            }
            {
              privateDnsZoneResourceId: '${dnsZoneResourceGroupId}/providers/Microsoft.Network/privateDnsZones/privatelink.ods.opinsights.azure.com'
            }
            {
              privateDnsZoneResourceId: '${dnsZoneResourceGroupId}/providers/Microsoft.Network/privateDnsZones/privatelink.agentsvc.azure-automation.net'
            }
            {
              privateDnsZoneResourceId: '${dnsZoneResourceGroupId}/providers/Microsoft.Network/privateDnsZones/privatelink.blob.${storageSuffix}'
            }
          ]
        }
        tags: tags
      }
    ]
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
  dependsOn: [privateDns]
}

module platformKeyVault 'br/public:avm/res/key-vault/vault:0.14.2' = if (keyVault.?enabled ?? true) {
  // Stable deployment name so the PSRule suppression (D-007) can target it.
  name: '${baseName}-kv-deploy'
  scope: resourceGroup(rgNames.management)
  params: {
    name: compactName(workload, environment, location, 'kv', uniqueString(subscription().id), 24)
    location: location
    sku: keyVault.?sku ?? (isProd ? 'premium' : 'standard')
    enableRbacAuthorization: true
    enablePurgeProtection: true
    softDeleteRetentionInDays: 90
    enableVaultForDiskEncryption: true
    publicNetworkAccess: 'Disabled'
    networkAcls: { bypass: 'AzureServices', defaultAction: 'Deny' }
    privateEndpoints: [
      {
        name: '${baseName}-kv-pe'
        subnetResourceId: '${hubVnet.outputs.resourceId}/subnets/PrivateEndpointSubnet'
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: '${dnsZoneResourceGroupId}/providers/Microsoft.Network/privateDnsZones/privatelink${az.environment().suffixes.keyvaultDns}'
            }
          ]
        }
        tags: tags
      }
    ]
    roleAssignments: [
      {
        // The encryption identity unwraps CMK keys for workloads (disk encryption sets, storage).
        principalId: identities[1].outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Key Vault Crypto Service Encryption User'
      }
    ]
    diagnosticSettings: diagnosticSettings
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
  dependsOn: [privateDns]
}

// ---------------------------------------------------------------------------
// Governance at subscription scope: budget, Defender for Cloud
// ---------------------------------------------------------------------------

var budgetThresholds = budget.?thresholds ?? [50, 80, 100]

module subscriptionBudget 'br/public:avm/res/consumption/budget:0.3.8' = if (budget != null) {
  name: '${uniqueString(deployment().name, location)}-budget'
  params: {
    name: '${baseName}-budget'
    amount: budget!.amount
    resetPeriod: 'Monthly'
    startDate: budget.?startDate ?? deploymentTime
    thresholds: budgetThresholds
    contactEmails: budget!.contactEmails
    actionGroups: [actionGroup.outputs.resourceId]
    location: location
    enableTelemetry: enableTelemetry
  }
}

module subscriptionForecastBudget 'br/public:avm/res/consumption/budget:0.3.8' = if (budget != null) {
  name: '${uniqueString(deployment().name, location)}-budget-forecast'
  params: {
    name: '${baseName}-budget-forecast'
    amount: budget!.amount
    resetPeriod: 'Monthly'
    startDate: budget.?startDate ?? deploymentTime
    thresholdType: 'Forecasted'
    thresholds: [100, 120]
    contactEmails: budget!.contactEmails
    actionGroups: [actionGroup.outputs.resourceId]
    location: location
    enableTelemetry: enableTelemetry
  }
}

var defaultDefenderPlans = isProd
  ? ['CloudPosture', 'VirtualMachines', 'StorageAccounts', 'KeyVaults', 'Arm', 'Containers', 'Dns']
  : ['CloudPosture']

module defenderForCloud 'br/public:avm/ptn/security/security-center:0.3.0' = if (defender != null) {
  name: '${uniqueString(deployment().name, location)}-defender'
  params: {
    location: location
    defenderPlans: map(defender.?plans ?? defaultDefenderPlans, p => {
      name: p
      pricingTier: 'Standard'
      subPlan: p == 'VirtualMachines' ? 'P2' : (p == 'StorageAccounts' ? 'DefenderForStorageV2' : null)
      extensions: p == 'StorageAccounts'
        ? [
            {
              name: 'OnUploadMalwareScanning'
              isEnabled: 'True'
              additionalExtensionProperties: { CapGBPerMonthPerStorageAccount: '5000' }
            }
            { name: 'SensitiveDataDiscovery', isEnabled: 'True' }
          ]
        : null
    })
    securityContactProperties: !empty(defender.?securityContactEmail ?? '')
      ? {
          emails: defender.?securityContactEmail
          isEnabled: true
          notificationsByRole: { roles: ['Owner'], state: 'On' }
          notificationsSources: [{ sourceType: 'Alert', minimalSeverity: 'High' }]
        }
      : null
    enableTelemetry: enableTelemetry
  }
}

// ---------------------------------------------------------------------------
// Outputs: consumed by az-avd, az-aks and az-image-builder through parameters
// ---------------------------------------------------------------------------

@description('Hub reference for spoke deployments (hubReferenceType).')
output hub hubReferenceType = {
  virtualNetworkResourceId: hubVnet.outputs.resourceId
  firewallPrivateIp: azureFirewall.outputs.privateIp
  privateDnsZoneResourceGroupResourceId: resourceGroups[3].outputs.resourceId
  useRemoteGateways: gateway.type != 'None'
}

@description('Monitoring reference for workload deployments (monitoringReferenceType).')
output monitoring monitoringReferenceType = {
  logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
  dataCollectionEndpointResourceId: dataCollectionEndpoint.outputs.resourceId
  actionGroupResourceId: actionGroup.outputs.resourceId
}

@description('Resource ID of the hub firewall policy. Workloads add their own rule collection groups to it.')
output firewallPolicyResourceId string = firewallPolicy.outputs.resourceId

@description('Resource IDs of the baseline VM data collection rules, keyed by OS.')
output vmDataCollectionRuleResourceIds object = {
  windows: vmDataCollectionRules[0].outputs.resourceId
  linux: vmDataCollectionRules[1].outputs.resourceId
}

@description('Resource ID of the platform Key Vault, empty when disabled.')
output keyVaultResourceId string = (keyVault.?enabled ?? true) ? platformKeyVault!.outputs.resourceId : ''

@description('Resource ID of the user-assigned identity used for customer-managed key access.')
output encryptionIdentityResourceId string = identities[1].outputs.resourceId
