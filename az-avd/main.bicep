metadata name = 'Azure Virtual Desktop'
metadata description = 'AVD workload: spoke network, host pool, application groups, workspace, scaling plan, FSLogix profile storage, session hosts and monitoring, attached to the platform landing zone.'

targetScope = 'subscription'

import { environmentType, hubReferenceType, lockFor, monitoringReferenceType, tagsType } from '../modules/shared/types.bicep'
import { compactName, regionShortNames } from '../modules/shared/naming.bicep'
import {
  applicationGroupType
  avdNetworkType
  complianceType
  fslogixType
  hostPoolType
  identityType
  localAdminType
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

@description('Optional. Create Azure Firewall IP Groups for the session host and private endpoint subnets, and use them as the source of the AVD rules instead of literal prefixes. Defaults to false.')
param useFirewallIpGroups bool = false

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

@description('Optional. Local administrator settings: a Windows LAPS-managed break-glass account.')
param localAdmin localAdminType = {}

@description('Optional. Compliance evidence and AppLocker and Defender event collection.')
param compliance complianceType = {}

@description('Optional. Email-free alerting: alerts use the landing zone action group from monitoring.actionGroupResourceId.')
param enableAlerts bool = true

@description('Optional. Enable AVM usage telemetry.')
param enableTelemetry bool = true

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

var isProd = environment == 'prod'
var lock = lockFor(environment)

// Parameter combinations that can't work. fail() stops the deployment (and bicep snapshot)
// before any resource is created; baseName references the checks so they're always evaluated.
// The cloud check is separate because environment() is only known at deployment time, and
// keeping it apart lets bicep snapshot evaluate the parameter-only checks offline.
var configurationErrors = filter(
  [
    isCloudOnly && !isEntraJoined
      ? 'identity.userIdentitySource CloudOnly requires identity.mode EntraJoined (cloud-only users cannot sign in to domain-joined hosts).'
      : ''
    isCloudOnly && useAzureFiles && contains(['AADDS', 'AD'], fslogix.?directoryService ?? 'AADKERB')
      ? 'Cloud-only identities need fslogix.directoryService AADKERB; AADDS and AD only know domain identities.'
      : ''
    applyDeferredStigs && empty(sessionHosts.?galleryImageResourceId ?? '')
      ? 'sessionHosts.applyDeferredStigs needs an az-image-builder image (sessionHosts.galleryImageResourceId); marketplace images have no deferred STIG package.'
      : ''
    complianceEvidence && empty(monitoring.?dataCollectionEndpointResourceId ?? '')
      ? 'compliance.evidence needs monitoring.dataCollectionEndpointResourceId: Azure Monitor Agent only collects log files through a data collection endpoint.'
      : ''
  ],
  e => !empty(e)
)
var configurationCheck = empty(configurationErrors) ? '' : fail(join(configurationErrors, ' '))
var cloudCheck = cloudOnlyFilesUnsupported
  ? fail('Cloud-only identities on Azure Files are not supported in ${az.environment().name}. Set fslogix.storageType to BlobCloudCache, or use hybrid identities.')
  : ''

var baseName = '${workload}-${environment}-${regionShortNames[location]}${configurationCheck}${cloudCheck}'

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
var isCloudOnly = (identity.?userIdentitySource ?? 'Hybrid') == 'CloudOnly'
var fslogixEnabled = fslogix.?enabled ?? true
var storageType = fslogix.?storageType ?? 'AzureFiles'
var useAzureFiles = fslogixEnabled && storageType == 'AzureFiles'
var useBlobCloudCache = fslogixEnabled && storageType == 'BlobCloudCache'
var shareQuotaGiB = fslogix.?shareQuotaGiB ?? (isProd ? 1024 : 100)
var directoryService = isCloudOnly ? 'AADKERB' : (fslogix.?directoryService ?? (isEntraJoined ? 'AADKERB' : 'AADDS'))
// Cloud-only identities on Azure Files are supported in the Azure public cloud only.
var cloudOnlyFilesUnsupported = isCloudOnly && useAzureFiles && contains(
  ['AzureUSGovernment', 'AzureChinaCloud'],
  az.environment().name
)
var scalingEnabled = isPooled && (scaling.?enabled ?? true)
var pauseScaling = scalingEnabled && (scaling.?pauseDuringDeployment ?? true)
var applyDeferredStigs = sessionHosts.?applyDeferredStigs ?? !empty(sessionHosts.?galleryImageResourceId ?? '')
var guestAttestation = sessionHosts.?guestAttestation ?? true
var complianceEvidence = compliance.?evidence ?? false
var securityEvents = compliance.?securityEvents ?? false
var breakGlass = localAdmin.?breakGlass ?? { enabled: false }
var autoGrow = useAzureFiles && (fslogix.?autoGrow.?enabled ?? false)
var autoGrowScheduleName = 'fslogix-share-autogrow'
var exclusionTag = scaling.?exclusionTag ?? 'scaling-exclude'
var adminGroups = identity.?adminGroupObjectIds ?? []

var dnsZoneRg = hub.privateDnsZoneResourceGroupResourceId
var dnsZone = {
  wvd: '${dnsZoneRg}/providers/Microsoft.Network/privateDnsZones/privatelink.wvd.microsoft.com'
  file: '${dnsZoneRg}/providers/Microsoft.Network/privateDnsZones/privatelink.file.${az.environment().suffixes.storage}'
  blob: '${dnsZoneRg}/providers/Microsoft.Network/privateDnsZones/privatelink.blob.${az.environment().suffixes.storage}'
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
  storageAccountContributor: '17d1049b-9a84-46fb-8f53-869881c3d3ab'
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

// IP Groups for this spoke's subnets. Other workloads' rules (for example the tools spoke)
// can reference them through the ipGroupResourceIds output.
var ipGroupNames = {
  sessionHosts: '${baseName}-ipg-session-hosts'
  privateEndpoints: '${baseName}-ipg-private-endpoints'
}
var ipGroupAddresses = {
  sessionHosts: [network.sessionHostSubnetPrefix]
  privateEndpoints: [network.privateEndpointSubnetPrefix]
}

module ipGroups 'br/public:avm/res/network/ip-group:0.4.0' = [
  for g in items(ipGroupNames): if (useFirewallIpGroups) {
    name: '${uniqueString(deployment().name, location)}-ipg-${g.key}'
    scope: resourceGroup(rgNames.network)
    params: {
      name: g.value
      location: location
      ipAddresses: ipGroupAddresses[g.key]
      lock: lock
      tags: tags
      enableTelemetry: enableTelemetry
    }
    dependsOn: [resourceGroups]
  }
]

var ipGroupResourceIds = {
  sessionHosts: resourceId(
    subscription().subscriptionId,
    rgNames.network,
    'Microsoft.Network/ipGroups',
    ipGroupNames.sessionHosts
  )
  privateEndpoints: resourceId(
    subscription().subscriptionId,
    rgNames.network,
    'Microsoft.Network/ipGroups',
    ipGroupNames.privateEndpoints
  )
}
var sessionHostSource = useFirewallIpGroups
  ? { sourceIpGroups: [ipGroupResourceIds.sessionHosts] }
  : { sourceAddresses: [network.sessionHostSubnetPrefix] }

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
            ...sessionHostSource
            destinationAddresses: concat(
              ['WindowsVirtualDesktop', 'AzureMonitor', 'AzureActiveDirectory'],
              guestAttestation ? ['AzureAttestation'] : []
            )
            destinationPorts: ['443']
          }
          {
            // Windows activation. Uses the storage suffix because the KMS host shares it in every cloud.
            ruleType: 'NetworkRule'
            name: 'windows-activation'
            ipProtocols: ['TCP']
            ...sessionHostSource
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
              ...sessionHostSource
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
              ...sessionHostSource
              targetFqdns: ['oneocsp.microsoft.com', 'www.microsoft.com', 'ctldl.windowsupdate.com']
            }
          ],
          (identity.?intuneEnrollment ?? false)
            ? [
                {
                  ruleType: 'ApplicationRule'
                  name: 'intune'
                  protocols: [{ protocolType: 'Https', port: 443 }]
                  ...sessionHostSource
                  targetFqdns: ['*.manage.microsoft.com', '*.dm.microsoft.com', 'enterpriseregistration.windows.net']
                }
              ]
            : []
        )
      }
    ]
  }
  // Rules reference the IP Groups by ID; they must exist first.
  dependsOn: [ipGroups]
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

var scalingSchedules = [
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

// The plan is created (or updated) with the host pool reference turned off while session hosts
// deploy, so it can't stop or drain a host that is still being configured, and turned back on
// by scalingPlanResume once every host is done.
module scalingPlan 'br/public:avm/res/desktop-virtualization/scaling-plan:0.5.0' = if (scalingEnabled) {
  name: '${uniqueString(deployment().name, location)}-scaling'
  scope: resourceGroup(rgNames.service)
  params: {
    name: '${baseName}-vdscaling'
    location: location
    hostPoolType: 'Pooled'
    timeZone: scaling.?timeZone ?? 'UTC'
    exclusionTag: exclusionTag
    schedules: scalingSchedules
    diagnosticSettings: diagnosticSettings
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
    hostPoolReferences: [{ hostPoolResourceId: hostPoolResourceId, scalingPlanEnabled: !pauseScaling }]
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

module profileStorage 'br/public:avm/res/storage/storage-account:0.33.1' = if (useAzureFiles) {
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
    // Cloud-only users need no domain properties; they only apply to hybrid or AD DS identities.
    azureFilesIdentityBasedAuthentication: union(
      { directoryServiceOptions: directoryService, defaultSharePermission: 'None' },
      !isCloudOnly && fslogix.?activeDirectoryProperties != null
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
    // The auto-grow runbook changes the share quota (control plane only, no data access).
    roleAssignments: autoGrow
      ? [
          {
            principalId: fslogixAutomation!.outputs.?systemAssignedMIPrincipalId ?? ''
            principalType: 'ServicePrincipal'
            roleDefinitionIdOrName: subscriptionResourceId(
              'Microsoft.Authorization/roleDefinitions',
              roleIds.storageAccountContributor
            )
          }
        ]
      : []
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
  dependsOn: [resourceGroups]
}

// Share auto-grow (fslogix.autoGrow). ARM can't upload runbook content from a file, so the
// runbook is published and linked to this schedule by scripts/Publish-FslogixAutoGrowRunbook.ps1.
module fslogixAutomation 'br/public:avm/res/automation/automation-account:0.19.3' = if (autoGrow) {
  name: '${uniqueString(deployment().name, location)}-fslogix-automation'
  scope: resourceGroup(rgNames.storage)
  params: {
    name: '${baseName}-aa-fslogix'
    location: location
    skuName: 'Basic'
    managedIdentities: { systemAssigned: true }
    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'
    schedules: [
      {
        name: autoGrowScheduleName
        description: 'FSLogix profile share quota check.'
        frequency: 'Hour'
        interval: fslogix.?autoGrow.?intervalHours ?? 6
        timeZone: 'Etc/UTC'
      }
    ]
    diagnosticSettings: diagnosticSettings
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
  dependsOn: [resourceGroups]
}

// Kerberos-free profile store: FSLogix Cloud Cache on page blobs. Cloud Cache only
// authenticates with an account key, so this is the one account that keeps shared key
// access, and it carries the exception tag that the governance policy checks.
var blobStorageAccountName = compactName(
  workload,
  environment,
  location,
  'fslb',
  uniqueString(subscription().id, workload),
  24
)
var blobStorageAccountResourceId = resourceId(
  subscription().subscriptionId,
  rgNames.storage,
  'Microsoft.Storage/storageAccounts',
  blobStorageAccountName
)

module profileBlobStorage 'br/public:avm/res/storage/storage-account:0.33.1' = if (useBlobCloudCache) {
  name: '${uniqueString(deployment().name, location)}-fslogix-blob'
  scope: resourceGroup(rgNames.storage)
  params: {
    name: blobStorageAccountName
    location: location
    kind: 'StorageV2'
    skuName: isProd ? 'Standard_ZRS' : 'Standard_LRS'
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    allowCrossTenantReplication: false
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Disabled'
    networkAcls: { bypass: 'AzureServices', defaultAction: 'Deny' }
    blobServices: {
      deleteRetentionPolicyEnabled: true
      deleteRetentionPolicyDays: 7
      containerDeleteRetentionPolicyEnabled: true
      containerDeleteRetentionPolicyDays: 7
      diagnosticSettings: diagnosticSettings
    }
    privateEndpoints: [
      {
        name: '${blobStorageAccountName}-pe-blob'
        service: 'blob'
        subnetResourceId: spoke.outputs.subnetResourceIds['snet-private-endpoints']
        privateDnsZoneGroup: { privateDnsZoneGroupConfigs: [{ privateDnsZoneResourceId: dnsZone.blob }] }
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
    tags: union(tags, { 'shared-key-exception': 'fslogix-cloud-cache' })
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
    // Share capacity and latency alerts apply to the Azure Files store only.
    profileStorageAccountResourceId: useAzureFiles ? storageAccountResourceId : ''
    profileShareQuotaGiB: shareQuotaGiB
    actionGroupResourceId: enableAlerts ? (monitoring.?actionGroupResourceId ?? '') : ''
    baseSeverity: isProd ? 1 : 3
    complianceEvidence: complianceEvidence
    securityEvents: securityEvents
    fslogixWorkbook: useAzureFiles && (fslogix.?operationsWorkbook ?? false)
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
      empty(baselineDataCollectionRuleResourceId) ? [] : [baselineDataCollectionRuleResourceId],
      complianceEvidence || securityEvents ? [avdMonitoring.outputs.securityDataCollectionRuleResourceId] : []
    )
    fslogix: {
      enabled: fslogixEnabled
      configurationMethod: fslogix.?configurationMethod ?? 'RunCommand'
      storageType: storageType
      profileLocations: useAzureFiles
        ? ['\\\\${storageAccountName}.file.${az.environment().suffixes.storage}\\profiles']
        : []
      blobStorageAccountResourceId: useBlobCloudCache ? blobStorageAccountResourceId : ''
      blobKeyName: fslogix.?blobKeyName ?? 'key1'
      cloudCache: fslogix.?cloudCache ?? false
      sizeInMBs: fslogix.?profileSizeInMBs ?? 30000
    }
    entraKerberos: useAzureFiles && directoryService == 'AADKERB'
    cloudOnlyIdentities: isCloudOnly
    guestAttestation: guestAttestation
    applyDeferredStigs: applyDeferredStigs
    disableLocalAdministrators: sessionHosts.?disableLocalAdministrators ?? true
    breakGlass: {
      enabled: breakGlass.enabled
      configurationMethod: breakGlass.?configurationMethod ?? ((identity.?intuneEnrollment ?? false)
        ? 'Intune'
        : 'RunCommand')
      accountName: breakGlass.?accountName
      backupDirectory: breakGlass.?backupDirectory ?? (isEntraJoined ? 'EntraID' : 'ActiveDirectory')
      passwordAgeDays: breakGlass.?passwordAgeDays
      passwordLength: breakGlass.?passwordLength
      postAuthenticationResetDelayHours: breakGlass.?postAuthenticationResetDelayHours
    }
    complianceEvidence: {
      enabled: complianceEvidence
      dailyAt: compliance.?dailyAt
      scapCommand: compliance.?scapCommand
      scapArguments: compliance.?scapArguments
      scapResultsPath: compliance.?scapResultsPath
    }
    diskEncryptionSetResourceId: sessionHosts.?diskEncryptionSetResourceId
    lock: lock
    tags: union(tags, { 'avd-host-pool': hostPoolName })
    enableTelemetry: enableTelemetry
  }
  dependsOn: [avdHostPool, profileStorage, profileBlobStorage, firewallRules, scalingPlan]
}

module scalingPlanResume 'br/public:avm/res/desktop-virtualization/scaling-plan:0.5.0' = if (pauseScaling) {
  name: '${uniqueString(deployment().name, location)}-scaling-resume'
  scope: resourceGroup(rgNames.service)
  params: {
    name: '${baseName}-vdscaling'
    location: location
    hostPoolType: 'Pooled'
    timeZone: scaling.?timeZone ?? 'UTC'
    exclusionTag: exclusionTag
    schedules: scalingSchedules
    diagnosticSettings: diagnosticSettings
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
    hostPoolReferences: [{ hostPoolResourceId: hostPoolResourceId, scalingPlanEnabled: true }]
  }
  dependsOn: [scalingPlan, avdSessionHosts]
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

@description('Resource ID of the FSLogix storage account (file share or Cloud Cache blob account), empty when disabled.')
output profileStorageAccountResourceId string = useAzureFiles
  ? profileStorage!.outputs.resourceId
  : (useBlobCloudCache ? profileBlobStorage!.outputs.resourceId : '')

@description('Resource ID of the spoke virtual network.')
output virtualNetworkResourceId string = spoke.outputs.resourceId

@description('Resource IDs of the firewall IP Groups (sessionHosts, privateEndpoints), empty when useFirewallIpGroups is false.')
output ipGroupResourceIds object = useFirewallIpGroups ? ipGroupResourceIds : {}

@description('Resource ID of the session host compliance workbook, empty when compliance.evidence is false.')
output complianceWorkbookResourceId string = avdMonitoring.outputs.complianceWorkbookResourceId

@description('Values for scripts/Publish-FslogixAutoGrowRunbook.ps1, empty when fslogix.autoGrow is off.')
output fslogixAutoGrow object = autoGrow
  ? {
      resourceGroupName: rgNames.storage
      automationAccountName: fslogixAutomation!.outputs.name
      scheduleName: autoGrowScheduleName
      storageAccountResourceId: storageAccountResourceId
    }
  : {}
