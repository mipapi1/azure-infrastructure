metadata name = 'Azure Virtual Desktop'
metadata description = 'AVD workload: spoke network, host pool, application groups, workspace, scaling plan, FSLogix profile storage, session hosts and monitoring, attached to the platform landing zone.'

targetScope = 'subscription'

import { environmentType, hubReferenceType, lockFor, monitoringReferenceType, tagsType } from '../modules/shared/types.bicep'
import { compactName, regionShortNames } from '../modules/shared/naming.bicep'
import {
  applicationGroupType
  avdNetworkType
  fslogixType
  hostPoolType
  identityType
  scalingScheduleType
  scalingType
  sessionHostsType
} from 'types.bicep'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Required. Environment.')
param environment environmentType

@description('Required. Region for every regional resource. Also the metadata location of the host pool, application groups and workspace.')
param location string

@description('Optional. Workload name used in resource names. Use a different value per host pool.')
param workload string = 'avd'

@description('Required. Tags applied to every resource.')
param tags tagsType

@description('Required. Hub connection details (az-landing-zone output "hub").')
param hub hubReferenceType

@description('Required. Central monitoring (az-landing-zone output "monitoring").')
param monitoring monitoringReferenceType

@description('Optional. Baseline Windows VM data collection rule (az-landing-zone output vmDataCollectionRuleResourceIds.windows).')
param baselineDataCollectionRuleResourceId string = ''

@description('Optional. Hub firewall policy (az-landing-zone output firewallPolicyResourceId). When set, the AVD egress rules are added to it.')
param firewallPolicyResourceId string = ''

@description('Optional. Priority of the AVD rule collection group in the hub firewall policy.')
param firewallRulePriority int = 1000

@description('Required. Spoke network.')
param network avdNetworkType

@description('Optional. Host pool settings.')
param hostPool hostPoolType = {}

@description('Required. Session hosts.')
param sessionHosts sessionHostsType

@description('Required. Local administrator password for the session hosts. Pass it from Key Vault (az.getSecret) or an environment variable; never commit it.')
@secure()
param sessionHostAdminPassword string

@description('Required. Identity and access.')
param identity identityType

@description('Conditional. Password of the domain join account (DomainJoined only).')
@secure()
param domainJoinPassword string = ''

@description('Optional. FSLogix profile storage and configuration.')
param fslogix fslogixType = {}

@description('Optional. Application groups. Defaults to one desktop application group.')
param applicationGroups applicationGroupType[] = [
  { name: 'desktop', type: 'Desktop', friendlyName: 'Desktop' }
]

@description('Optional. Workspace friendly name.')
param workspaceFriendlyName string = 'Virtual Desktop'

@description('Optional. Scaling plan settings.')
param scaling scalingType = {}

@description('Optional. Email-free alerting: alerts use the landing zone action group from monitoring.actionGroupResourceId.')
param enableAlerts bool = true

@description('Optional. Enable AVM usage telemetry.')
param enableTelemetry bool = true

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

var isProd = environment == 'prod'
var lock = lockFor(environment)
var baseName = '${workload}-${environment}-${regionShortNames[location]}'

var rgNames = {
  network: '${baseName}-network-rg'
  service: '${baseName}-service-rg'
  compute: '${baseName}-compute-rg'
  storage: '${baseName}-storage-rg'
}

var identityMode = identity.?mode ?? 'EntraJoined'
var isEntraJoined = identityMode == 'EntraJoined'
var poolType = hostPool.?type ?? 'Pooled'
var isPooled = poolType == 'Pooled'
var maxSessionLimit = isPooled ? (hostPool.?maxSessionLimit ?? 12) : 1
var fslogixEnabled = fslogix.?enabled ?? true
var shareQuotaGiB = fslogix.?shareQuotaGiB ?? (isProd ? 1024 : 100)
var directoryService = fslogix.?directoryService ?? (isEntraJoined ? 'AADKERB' : 'AADDS')
var scalingEnabled = isPooled && (scaling.?enabled ?? true)
var exclusionTag = scaling.?exclusionTag ?? 'scaling-exclude'
var adminGroups = identity.?adminGroupObjectIds ?? []

var dnsZoneRg = hub.privateDnsZoneResourceGroupResourceId
var dnsZone = {
  wvd: '${dnsZoneRg}/providers/Microsoft.Network/privateDnsZones/privatelink.wvd.microsoft.com'
  file: '${dnsZoneRg}/providers/Microsoft.Network/privateDnsZones/privatelink.file.${az.environment().suffixes.storage}'
}

var diagnosticSettings = [
  {
    name: 'to-central-law'
    workspaceResourceId: monitoring.logAnalyticsWorkspaceResourceId
  }
]

// Entra SSO; device redirection off by default so data stays in the session.
var defaultRdpProperties = join(
  [
    'enablerdsaadauth:i:${isEntraJoined ? 1 : 0}'
    'targetisaadjoined:i:${isEntraJoined ? 1 : 0}'
    'drivestoredirect:s:'
    'redirectprinters:i:0'
    'usbdevicestoredirect:s:'
    'redirectcomports:i:0'
    'redirectsmartcards:i:1'
    'redirectclipboard:i:${isProd ? 0 : 1}'
    'audiomode:i:0'
    'audiocapturemode:i:1'
    'camerastoredirect:s:*'
    'use multimon:i:1'
    'enablecredsspsupport:i:1'
  ],
  ';'
)

var defaultSchedules scalingScheduleType[] = [
  {
    daysOfWeek: ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday']
    rampUpStart: '07:00'
    peakStart: '09:00'
    rampDownStart: '17:00'
    offPeakStart: '20:00'
    rampUpMinimumHostsPct: isProd ? 20 : 10
    capacityThresholdPct: 60
    rampDownMinimumHostsPct: isProd ? 10 : 0
  }
  {
    daysOfWeek: ['Saturday', 'Sunday']
    rampUpStart: '09:00'
    peakStart: '10:00'
    rampDownStart: '16:00'
    offPeakStart: '18:00'
    rampUpMinimumHostsPct: isProd ? 10 : 0
    capacityThresholdPct: 80
    rampDownMinimumHostsPct: 0
  }
]

@description('Converts HH:mm to the scaling plan time object.')
func time(t string) object => { hour: int(split(t, ':')[0]), minute: int(split(t, ':')[1]) }

// ---------------------------------------------------------------------------
// Resource groups and role assignments at resource group scope
// ---------------------------------------------------------------------------

var roleIds = {
  vmUserLogin: 'fb879df8-f326-4884-b1cf-06f3ad86be52'
  vmAdminLogin: '1c0163c0-47e6-4577-8991-ea5c82e286e4'
  powerOnOffContributor: '40c5ff49-9181-41f8-ae61-143b0e78555e'
  desktopVirtualizationUser: '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63'
  smbShareContributor: '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb'
  smbShareElevatedContributor: 'a7264617-510b-434b-a828-9731dc254ea7'
}

var computeRoleAssignments = concat(
  isEntraJoined
    ? map(identity.userGroupObjectIds, g => {
        principalId: g
        principalType: 'Group'
        roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.vmUserLogin)
      })
    : [],
  isEntraJoined
    ? map(adminGroups, g => {
        principalId: g
        principalType: 'Group'
        roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.vmAdminLogin)
      })
    : [],
  // Scaling plans and start VM on connect power hosts on and off through the AVD service principal.
  !empty(identity.?avdServicePrincipalObjectId ?? '')
    ? [
        {
          principalId: identity.?avdServicePrincipalObjectId!
          principalType: 'ServicePrincipal'
          roleDefinitionIdOrName: subscriptionResourceId(
            'Microsoft.Authorization/roleDefinitions',
            roleIds.powerOnOffContributor
          )
        }
      ]
    : []
)

module resourceGroups 'br/public:avm/res/resources/resource-group:0.4.4' = [
  for rg in items(rgNames): {
    name: '${uniqueString(deployment().name, location)}-rg-${rg.key}'
    params: {
      name: rg.value
      location: location
      roleAssignments: rg.key == 'compute' ? computeRoleAssignments : []
      lock: lock
      tags: tags
      enableTelemetry: enableTelemetry
    }
  }
]

// ---------------------------------------------------------------------------
// Network: spoke and hub firewall rules
// ---------------------------------------------------------------------------

module spoke '../modules/network/spoke-network/main.bicep' = {
  name: '${uniqueString(deployment().name, location)}-spoke'
  scope: resourceGroup(rgNames.network)
  params: {
    name: '${baseName}-vnet'
    location: location
    addressPrefixes: network.addressPrefixes
    hub: hub
    subnets: [
      {
        name: 'snet-session-hosts'
        addressPrefix: network.sessionHostSubnetPrefix
      }
      {
        name: 'snet-private-endpoints'
        addressPrefix: network.privateEndpointSubnetPrefix
        routeToFirewall: false
        securityRules: [
          {
            name: 'allow-session-hosts-https-smb'
            properties: {
              access: 'Allow'
              direction: 'Inbound'
              priority: 100
              protocol: 'Tcp'
              sourceAddressPrefix: network.sessionHostSubnetPrefix
              sourcePortRange: '*'
              destinationAddressPrefix: network.privateEndpointSubnetPrefix
              destinationPortRanges: ['443', '445']
            }
          }
          {
            name: 'deny-vnet-inbound'
            properties: {
              access: 'Deny'
              direction: 'Inbound'
              priority: 4000
              protocol: '*'
              sourceAddressPrefix: 'VirtualNetwork'
              sourcePortRange: '*'
              destinationAddressPrefix: '*'
              destinationPortRange: '*'
            }
          }
        ]
      }
    ]
    diagnosticSettings: diagnosticSettings
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
  dependsOn: [resourceGroups]
}

var firewallPolicySegments = split(firewallPolicyResourceId, '/')

// Required AVD endpoints: https://learn.microsoft.com/azure/virtual-desktop/required-fqdn-endpoint
module firewallRules '../modules/network/firewall-rule-collection-group/main.bicep' = if (!empty(firewallPolicyResourceId)) {
  name: '${uniqueString(deployment().name, location)}-afw-rules'
  scope: resourceGroup(firewallPolicySegments[2], firewallPolicySegments[4])
  params: {
    firewallPolicyName: last(firewallPolicySegments)
    name: '${baseName}-rcg'
    priority: firewallRulePriority
    ruleCollections: [
      {
        name: 'avd-network'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 100
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'avd-service-tags'
            ipProtocols: ['TCP']
            sourceAddresses: [network.sessionHostSubnetPrefix]
            destinationAddresses: ['WindowsVirtualDesktop', 'AzureMonitor', 'AzureActiveDirectory']
            destinationPorts: ['443']
          }
          {
            // Windows activation. Uses the storage suffix because the KMS host shares it in every cloud.
            ruleType: 'NetworkRule'
            name: 'windows-activation'
            ipProtocols: ['TCP']
            sourceAddresses: [network.sessionHostSubnetPrefix]
            destinationFqdns: ['azkms.${az.environment().suffixes.storage}', 'kms.${az.environment().suffixes.storage}']
            destinationPorts: ['1688']
          }
        ]
      }
      {
        name: 'avd-application'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 200
        action: { type: 'Allow' }
        rules: concat(
          [
            {
              ruleType: 'ApplicationRule'
              name: 'avd-fqdn-tags'
              protocols: [{ protocolType: 'Https', port: 443 }, { protocolType: 'Http', port: 80 }]
              sourceAddresses: [network.sessionHostSubnetPrefix]
              fqdnTags: [
                'WindowsVirtualDesktop'
                'WindowsUpdate'
                'WindowsDiagnostics'
                'MicrosoftActiveProtectionService'
              ]
            }
            {
              ruleType: 'ApplicationRule'
              name: 'certificate-revocation'
              protocols: [{ protocolType: 'Http', port: 80 }, { protocolType: 'Https', port: 443 }]
              sourceAddresses: [network.sessionHostSubnetPrefix]
              targetFqdns: ['oneocsp.microsoft.com', 'www.microsoft.com', 'ctldl.windowsupdate.com']
            }
          ],
          (identity.?intuneEnrollment ?? false)
            ? [
                {
                  ruleType: 'ApplicationRule'
                  name: 'intune'
                  protocols: [{ protocolType: 'Https', port: 443 }]
                  sourceAddresses: [network.sessionHostSubnetPrefix]
                  targetFqdns: ['*.manage.microsoft.com', '*.dm.microsoft.com', 'enterpriseregistration.windows.net']
                }
              ]
            : []
        )
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// AVD service objects
// ---------------------------------------------------------------------------

var hostPoolName = '${baseName}-vdpool'
var publicNetworkAccess = hostPool.?publicNetworkAccess ?? 'EnabledForClientsOnly'
// Compile-time IDs keep what-if predictions precise; modules that use them depend on the deployments.
var hostPoolResourceId = resourceId(
  subscription().subscriptionId,
  rgNames.service,
  'Microsoft.DesktopVirtualization/hostPools',
  hostPoolName
)

module avdHostPool 'br/public:avm/res/desktop-virtualization/host-pool:0.8.2' = {
  name: '${uniqueString(deployment().name, location)}-hostpool'
  scope: resourceGroup(rgNames.service)
  params: {
    name: hostPoolName
    location: location
    friendlyName: hostPool.?friendlyName ?? workspaceFriendlyName
    hostPoolType: poolType
    loadBalancerType: isPooled ? (hostPool.?loadBalancerType ?? 'BreadthFirst') : 'Persistent'
    personalDesktopAssignmentType: isPooled ? null : (hostPool.?personalDesktopAssignmentType ?? 'Automatic')
    maxSessionLimit: maxSessionLimit
    validationEnvironment: hostPool.?validationEnvironment ?? !isProd
    startVMOnConnect: hostPool.?startVMOnConnect ?? true
    customRdpProperty: hostPool.?customRdpProperty ?? defaultRdpProperties
    preferredAppGroupType: 'Desktop'
    publicNetworkAccess: publicNetworkAccess
    // A new token on every deployment, valid only long enough to register hosts.
    tokenValidityLength: 'PT4H'
    privateEndpoints: publicNetworkAccess == 'Enabled'
      ? []
      : [
          {
            name: '${hostPoolName}-pe-connection'
            service: 'connection'
            subnetResourceId: spoke.outputs.subnetResourceIds['snet-private-endpoints']
            privateDnsZoneGroup: { privateDnsZoneGroupConfigs: [{ privateDnsZoneResourceId: dnsZone.wvd }] }
            tags: tags
          }
        ]
    diagnosticSettings: diagnosticSettings
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

module avdApplicationGroups 'br/public:avm/res/desktop-virtualization/application-group:0.4.2' = [
  for ag in applicationGroups: {
    name: '${uniqueString(deployment().name, location)}-ag-${ag.name}'
    scope: resourceGroup(rgNames.service)
    params: {
      name: '${baseName}-vdag-${ag.name}'
      location: location
      hostpoolName: avdHostPool.outputs.name
      applicationGroupType: ag.type
      friendlyName: ag.?friendlyName ?? ag.name
      applications: ag.type == 'RemoteApp' ? (ag.?applications ?? []) : []
      roleAssignments: map(ag.?assignedGroupObjectIds ?? identity.userGroupObjectIds, g => {
        principalId: g
        principalType: 'Group'
        roleDefinitionIdOrName: subscriptionResourceId(
          'Microsoft.Authorization/roleDefinitions',
          roleIds.desktopVirtualizationUser
        )
      })
      diagnosticSettings: diagnosticSettings
      lock: lock
      tags: tags
      enableTelemetry: enableTelemetry
    }
  }
]

module avdWorkspace 'br/public:avm/res/desktop-virtualization/workspace:0.9.2' = {
  name: '${uniqueString(deployment().name, location)}-workspace'
  scope: resourceGroup(rgNames.service)
  params: {
    name: '${baseName}-vdws'
    location: location
    friendlyName: workspaceFriendlyName
    applicationGroupReferences: [for (ag, i) in applicationGroups: avdApplicationGroups[i].outputs.resourceId]
    publicNetworkAccess: publicNetworkAccess == 'Disabled' ? 'Disabled' : 'Enabled'
    privateEndpoints: publicNetworkAccess == 'Enabled'
      ? []
      : [
          {
            name: '${baseName}-vdws-pe-feed'
            service: 'feed'
            subnetResourceId: spoke.outputs.subnetResourceIds['snet-private-endpoints']
            privateDnsZoneGroup: { privateDnsZoneGroupConfigs: [{ privateDnsZoneResourceId: dnsZone.wvd }] }
            tags: tags
          }
        ]
    diagnosticSettings: diagnosticSettings
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

module scalingPlan 'br/public:avm/res/desktop-virtualization/scaling-plan:0.5.0' = if (scalingEnabled) {
  name: '${uniqueString(deployment().name, location)}-scaling'
  scope: resourceGroup(rgNames.service)
  params: {
    name: '${baseName}-vdscaling'
    location: location
    hostPoolType: 'Pooled'
    timeZone: scaling.?timeZone ?? 'UTC'
    exclusionTag: exclusionTag
    hostPoolReferences: [{ hostPoolResourceId: hostPoolResourceId, scalingPlanEnabled: true }]
    schedules: [
      for (s, i) in (scaling.?schedules ?? defaultSchedules): {
        name: 'schedule-${i}'
        daysOfWeek: s.daysOfWeek
        rampUpStartTime: time(s.rampUpStart)
        rampUpLoadBalancingAlgorithm: 'BreadthFirst'
        rampUpMinimumHostsPct: s.?rampUpMinimumHostsPct ?? 20
        rampUpCapacityThresholdPct: s.?capacityThresholdPct ?? 60
        peakStartTime: time(s.peakStart)
        peakLoadBalancingAlgorithm: hostPool.?loadBalancerType ?? 'BreadthFirst'
        rampDownStartTime: time(s.rampDownStart)
        rampDownLoadBalancingAlgorithm: 'DepthFirst'
        rampDownMinimumHostsPct: s.?rampDownMinimumHostsPct ?? 10
        rampDownCapacityThresholdPct: 90
        rampDownForceLogoffUsers: false
        rampDownStopHostsWhen: 'ZeroActiveSessions'
        rampDownWaitTimeMinutes: 30
        rampDownNotificationMessage: 'This session host is being shut down. Save your work; you will be moved to another host when you sign in again.'
        offPeakStartTime: time(s.offPeakStart)
        offPeakLoadBalancingAlgorithm: 'DepthFirst'
      }
    ]
    diagnosticSettings: diagnosticSettings
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
  dependsOn: [avdHostPool]
}

// ---------------------------------------------------------------------------
// FSLogix profile storage
// ---------------------------------------------------------------------------

var storageAccountName = compactName(
  workload,
  environment,
  location,
  'fsl',
  uniqueString(subscription().id, workload),
  24
)
var storageAccountResourceId = resourceId(
  subscription().subscriptionId,
  rgNames.storage,
  'Microsoft.Storage/storageAccounts',
  storageAccountName
)

module profileStorage 'br/public:avm/res/storage/storage-account:0.33.1' = if (fslogixEnabled) {
  name: '${uniqueString(deployment().name, location)}-fslogix-storage'
  scope: resourceGroup(rgNames.storage)
  params: {
    name: storageAccountName
    location: location
    kind: 'FileStorage'
    skuName: isProd ? 'Premium_ZRS' : 'Premium_LRS'
    largeFileSharesState: 'Enabled'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Disabled'
    networkAcls: { bypass: 'AzureServices', defaultAction: 'Deny' }
    azureFilesIdentityBasedAuthentication: union(
      { directoryServiceOptions: directoryService, defaultSharePermission: 'None' },
      fslogix.?activeDirectoryProperties != null
        ? { activeDirectoryProperties: fslogix.?activeDirectoryProperties }
        : {}
    )
    fileServices: {
      shareDeleteRetentionPolicy: { enabled: true, days: 7 }
      protocolSettings: {
        smb: {
          versions: 'SMB3.1.1'
          authenticationMethods: 'Kerberos'
          kerberosTicketEncryption: 'AES-256'
          channelEncryption: 'AES-256-GCM'
        }
      }
      shares: [
        {
          name: 'profiles'
          shareQuota: shareQuotaGiB
          enabledProtocols: 'SMB'
          roleAssignments: concat(
            map(identity.userGroupObjectIds, g => {
              principalId: g
              principalType: 'Group'
              roleDefinitionIdOrName: subscriptionResourceId(
                'Microsoft.Authorization/roleDefinitions',
                roleIds.smbShareContributor
              )
            }),
            map(adminGroups, g => {
              principalId: g
              principalType: 'Group'
              roleDefinitionIdOrName: subscriptionResourceId(
                'Microsoft.Authorization/roleDefinitions',
                roleIds.smbShareElevatedContributor
              )
            })
          )
        }
      ]
      diagnosticSettings: diagnosticSettings
    }
    privateEndpoints: [
      {
        name: '${storageAccountName}-pe-file'
        service: 'file'
        subnetResourceId: spoke.outputs.subnetResourceIds['snet-private-endpoints']
        privateDnsZoneGroup: { privateDnsZoneGroupConfigs: [{ privateDnsZoneResourceId: dnsZone.file }] }
        tags: tags
      }
    ]
    diagnosticSettings: [
      {
        name: 'to-central-law'
        workspaceResourceId: monitoring.logAnalyticsWorkspaceResourceId
        metricCategories: [{ category: 'Transaction' }]
      }
    ]
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
  dependsOn: [resourceGroups]
}

// ---------------------------------------------------------------------------
// Monitoring and session hosts
// ---------------------------------------------------------------------------

module avdMonitoring '../modules/avd/monitoring/main.bicep' = {
  name: '${uniqueString(deployment().name, location)}-monitoring'
  scope: resourceGroup(rgNames.service)
  params: {
    namePrefix: baseName
    location: location
    logAnalyticsWorkspaceResourceId: monitoring.logAnalyticsWorkspaceResourceId
    dataCollectionEndpointResourceId: monitoring.?dataCollectionEndpointResourceId
    hostPoolResourceId: hostPoolResourceId
    sessionHostPrefix: sessionHosts.namePrefix
    maxSessionLimit: maxSessionLimit
    profileStorageAccountResourceId: fslogixEnabled ? storageAccountResourceId : ''
    profileShareQuotaGiB: shareQuotaGiB
    actionGroupResourceId: enableAlerts ? (monitoring.?actionGroupResourceId ?? '') : ''
    baseSeverity: isProd ? 1 : 3
    tags: tags
    enableTelemetry: enableTelemetry
  }
  dependsOn: [avdHostPool, profileStorage]
}

module avdSessionHosts '../modules/avd/session-hosts/main.bicep' = {
  name: '${uniqueString(deployment().name, location)}-session-hosts'
  scope: resourceGroup(rgNames.compute)
  params: {
    namePrefix: sessionHosts.namePrefix
    count: sessionHosts.count
    startIndex: sessionHosts.?startIndex ?? 1
    location: location
    availabilityZones: sessionHosts.?availabilityZones ?? (isProd ? [1, 2, 3] : [])
    vmSize: sessionHosts.vmSize
    osDisk: {
      storageAccountType: sessionHosts.?osDiskType ?? 'Premium_LRS'
      sizeGB: sessionHosts.?osDiskSizeGB ?? 128
    }
    image: {
      galleryImageResourceId: sessionHosts.?galleryImageResourceId
      marketplace: sessionHosts.?marketplaceImage ?? {
        publisher: 'MicrosoftWindowsDesktop'
        offer: 'windows-11'
        sku: 'win11-25h2-avd'
        version: 'latest'
      }
    }
    subnetResourceId: spoke.outputs.subnetResourceIds['snet-session-hosts']
    adminUsername: sessionHosts.adminUsername
    adminPassword: sessionHostAdminPassword
    identityMode: identityMode
    intuneEnrollment: identity.?intuneEnrollment ?? false
    domainJoin: identity.?domainJoin
    domainJoinPassword: domainJoinPassword
    hostPoolResourceId: hostPoolResourceId
    dataCollectionRuleResourceIds: concat(
      [avdMonitoring.outputs.avdInsightsDataCollectionRuleResourceId],
      empty(baselineDataCollectionRuleResourceId) ? [] : [baselineDataCollectionRuleResourceId]
    )
    fslogix: {
      enabled: fslogixEnabled
      configurationMethod: fslogix.?configurationMethod ?? 'RunCommand'
      profileLocations: ['\\\\${storageAccountName}.file.${az.environment().suffixes.storage}\\profiles']
      cloudCache: fslogix.?cloudCache ?? false
      sizeInMBs: fslogix.?profileSizeInMBs ?? 30000
    }
    entraKerberos: directoryService == 'AADKERB'
    diskEncryptionSetResourceId: sessionHosts.?diskEncryptionSetResourceId
    lock: lock
    tags: union(tags, { 'avd-host-pool': hostPoolName })
    enableTelemetry: enableTelemetry
  }
  dependsOn: [avdHostPool, profileStorage, firewallRules]
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Resource ID of the host pool.')
output hostPoolResourceId string = avdHostPool.outputs.resourceId

@description('Resource ID of the workspace.')
output workspaceResourceId string = avdWorkspace.outputs.resourceId

@description('Session host names.')
output sessionHostNames string[] = avdSessionHosts.outputs.names

@description('Resource ID of the FSLogix storage account, empty when disabled.')
output profileStorageAccountResourceId string = fslogixEnabled ? profileStorage!.outputs.resourceId : ''

@description('Resource ID of the spoke virtual network.')
output virtualNetworkResourceId string = spoke.outputs.resourceId
