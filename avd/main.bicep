// Azure Virtual Desktop: spoke network, pooled host pool, desktop, workspace, FSLogix profile
// storage and Entra-joined session hosts from the Marketplace or the image-builder gallery image.
// Deploy into resource group rg-avd.

param userGroupId string
param adminGroupId string
@secure()
param adminPassword string
param adminUsername string = 'avdadmin'

@description('''Object ID of the Azure Virtual Desktop service principal, for start VM on connect and the scaling plan:
az ad sp show --id 9cdead84-a844-4324-93f2-b2e6bb768d07 --query id -o tsv. Empty: neither gets its role.''')
param avdServicePrincipalId string = ''

@description('Session host image: a gallery image definition or version ID, e.g. the image-builder win11-avd image. Empty: the Marketplace Windows 11 multi-session + Microsoft 365 image (FSLogix is preinstalled on both).')
param imageId string = ''

@description('Host pool settings.')
param hostPool {
  @description('Maximum concurrent user sessions per host.')
  maxSessionLimit: int
  @description('BreadthFirst spreads users across hosts; DepthFirst fills one host before the next.')
  loadBalancerType: ('BreadthFirst' | 'DepthFirst')
  @description('Start deallocated hosts when a user connects (needs avdServicePrincipalId).')
  startVMOnConnect: bool
  @description('RDP properties, one per entry: https://learn.microsoft.com/azure/virtual-desktop/rdp-properties')
  rdpProperties: string[]
  publicNetworkAccess: ('Enabled' | 'Disabled' | 'EnabledForClientsOnly' | 'EnabledForSessionHostsOnly')
} = {
  maxSessionLimit: 10
  loadBalancerType: 'BreadthFirst'
  startVMOnConnect: true
  rdpProperties: ['targetisaadjoined:i:1', 'enablerdsaadauth:i:1']
  publicNetworkAccess: 'Enabled'
}

@description('Workspace settings.')
param workspace {
  @description('Name shown in the Windows App.')
  friendlyName: string
  publicNetworkAccess: ('Enabled' | 'Disabled')
} = {
  friendlyName: 'Azure Virtual Desktop'
  publicNetworkAccess: 'Enabled'
}

@description('Session host settings.')
param sessionHosts {
  @description('Number of session hosts. Lowering it does not delete hosts.')
  count: int
  @description('Number of the first host (-001).')
  startNumber: int
  @description('''Host names are <namePrefix><3-character hash>-<nnn>, e.g. avdk7q-001 (VM vm-avdk7q-001).
The hash changes with the image, the VM size and forceNewHost, so a new set never reuses a name.''')
  @maxLength(7)
  namePrefix: string
  @description('''Any new text gives a new set of host names. Use it after deleting hosts: Entra keeps the
deleted hosts' devices, and a new host with the same name fails to join.''')
  forceNewHost: string
  vmSize: string
  osDiskSizeGB: int
  osDiskType: ('Premium_LRS' | 'StandardSSD_LRS' | 'Premium_ZRS' | 'StandardSSD_ZRS')
  acceleratedNetworking: bool
  @description('Enroll hosts in Intune during the Entra join.')
  intuneEnrollment: bool
  @description('Trusted Launch boot integrity monitoring (guest attestation extension, reported in Defender for Cloud).')
  guestAttestation: bool
} = {
  count: 1
  startNumber: 1
  namePrefix: 'avd'
  forceNewHost: ''
  vmSize: 'Standard_D4ds_v5'
  osDiskSizeGB: 256
  osDiskType: 'Premium_LRS'
  acceleratedNetworking: true
  intuneEnrollment: false
  guestAttestation: true
}

@description('''FSLogix profile containers. storageType AzureFiles: Premium SMB share (the usual choice).
BlobCloudCache: page blobs with a local cache on each host (cheaper, rides out short outages).''')
param fslogix {
  enabled: bool
  storageType: ('AzureFiles' | 'BlobCloudCache')
  @description('Maximum profile disk size in MB.')
  sizeInMBs: int
  @description('Azure Files share size in GiB (Premium starts at 100).')
  shareQuotaGiB: int
} = {
  enabled: true
  storageType: 'AzureFiles'
  sizeInMBs: 30000
  shareQuotaGiB: 100
}

@description('Time of day, 24-hour clock, in the scaling plan time zone.')
type time = { hour: int, minute: int }

@description('One scaling schedule: the days and what each of the four phases does.')
type schedule = {
  name: string
  daysOfWeek: ('Monday' | 'Tuesday' | 'Wednesday' | 'Thursday' | 'Friday' | 'Saturday' | 'Sunday')[]
  rampUpStartTime: time
  rampUpLoadBalancingAlgorithm: ('BreadthFirst' | 'DepthFirst')
  rampUpMinimumHostsPct: int
  rampUpCapacityThresholdPct: int
  peakStartTime: time
  peakLoadBalancingAlgorithm: ('BreadthFirst' | 'DepthFirst')
  rampDownStartTime: time
  rampDownLoadBalancingAlgorithm: ('BreadthFirst' | 'DepthFirst')
  rampDownMinimumHostsPct: int
  rampDownCapacityThresholdPct: int
  rampDownForceLogoffUsers: bool
  rampDownWaitTimeMinutes: int
  rampDownNotificationMessage: string
  rampDownStopHostsWhen: ('ZeroSessions' | 'ZeroActiveSessions')
  offPeakStartTime: time
  offPeakLoadBalancingAlgorithm: ('BreadthFirst' | 'DepthFirst')
}

@description('Scaling plan for the host pool (needs avdServicePrincipalId). Hosts tagged with exclusionTag are left alone.')
param scalingPlan {
  enabled: bool
  timeZone: string
  exclusionTag: string
  schedules: schedule[]
} = {
  enabled: false
  timeZone: 'Eastern Standard Time'
  exclusionTag: ''
  schedules: [
    {
      name: 'weekdays'
      daysOfWeek: ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday']
      rampUpStartTime: { hour: 8, minute: 0 }
      rampUpLoadBalancingAlgorithm: 'BreadthFirst'
      rampUpMinimumHostsPct: 20
      rampUpCapacityThresholdPct: 60
      peakStartTime: { hour: 9, minute: 0 }
      peakLoadBalancingAlgorithm: 'DepthFirst'
      rampDownStartTime: { hour: 18, minute: 0 }
      rampDownLoadBalancingAlgorithm: 'DepthFirst'
      rampDownMinimumHostsPct: 0
      rampDownCapacityThresholdPct: 90
      rampDownForceLogoffUsers: false
      rampDownWaitTimeMinutes: 30
      rampDownNotificationMessage: 'You will be signed out in 30 minutes. Save your work.'
      rampDownStopHostsWhen: 'ZeroActiveSessions'
      offPeakStartTime: { hour: 20, minute: 0 }
      offPeakLoadBalancingAlgorithm: 'DepthFirst'
    }
  ]
}

@description('Send host pool, application group and workspace logs to law-hub.')
param diagnostics bool = true

param tokenStart string = utcNow()
param location string = resourceGroup().location

var subnetPrefix = '10.1.0.0/24'
var hostsIpGroup = resourceId('rg-hub', 'Microsoft.Network/ipGroups', 'ipg-avd-snet-hosts')

module spoke '../modules/spoke.bicep' = {
  name: 'spoke-avd'
  params: {
    name: 'avd'
    location: location
    addressPrefix: '10.1.0.0/23'
    subnets: [
      { name: 'snet-hosts', addressPrefix: subnetPrefix }
      { name: 'snet-pe', addressPrefix: '10.1.1.0/27' }
    ]
    rulePriority: 100
    ruleCollections: [
      {
        name: 'avd-network'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 100
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'avd-services'
            ipProtocols: ['TCP']
            sourceIpGroups: [hostsIpGroup]
            destinationAddresses: ['WindowsVirtualDesktop', 'AzureMonitor', 'AzureActiveDirectory']
            destinationPorts: ['443']
          }
          {
            ruleType: 'NetworkRule'
            name: 'windows-activation'
            ipProtocols: ['TCP']
            sourceIpGroups: [hostsIpGroup]
            destinationFqdns: ['azkms.${environment().suffixes.storage}', 'kms.${environment().suffixes.storage}']
            destinationPorts: ['1688']
          }
        ]
      }
      {
        name: 'avd-application'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 200
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'avd-fqdn-tags'
            protocols: [{ protocolType: 'Https', port: 443 }, { protocolType: 'Http', port: 80 }]
            sourceIpGroups: [hostsIpGroup]
            fqdnTags: ['WindowsVirtualDesktop', 'WindowsUpdate', 'WindowsDiagnostics', 'MicrosoftActiveProtectionService']
          }
          {
            ruleType: 'ApplicationRule'
            name: 'certificate-revocation'
            protocols: [{ protocolType: 'Https', port: 443 }, { protocolType: 'Http', port: 80 }]
            sourceIpGroups: [hostsIpGroup]
            targetFqdns: ['oneocsp.microsoft.com', 'www.microsoft.com', 'ctldl.windowsupdate.com']
          }
        ]
      }
    ]
  }
}

resource pool 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' = {
  name: 'vdpool-avd'
  location: location
  properties: {
    hostPoolType: 'Pooled'
    loadBalancerType: hostPool.loadBalancerType
    maxSessionLimit: hostPool.maxSessionLimit
    startVMOnConnect: hostPool.startVMOnConnect
    publicNetworkAccess: hostPool.publicNetworkAccess
    preferredAppGroupType: 'Desktop'
    customRdpProperty: join(hostPool.rdpProperties, ';')
    registrationInfo: {
      expirationTime: dateTimeAdd(tokenStart, 'PT4H')
      registrationTokenOperation: 'Update'
    }
  }
}

resource desktop 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-03' = {
  name: 'vdag-avd'
  location: location
  properties: {
    applicationGroupType: 'Desktop'
    hostPoolArmPath: pool.id
  }
}

resource desktopWorkspace 'Microsoft.DesktopVirtualization/workspaces@2024-04-03' = {
  name: 'vdws-avd'
  location: location
  properties: {
    friendlyName: workspace.friendlyName
    publicNetworkAccess: workspace.publicNetworkAccess
    applicationGroupReferences: [desktop.id]
  }
}

var logs = resourceId('rg-hub', 'Microsoft.OperationalInsights/workspaces', 'law-hub')

resource poolLogs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (diagnostics) {
  name: 'diag-vdpool-avd'
  scope: pool
  properties: { workspaceId: logs, logs: [{ categoryGroup: 'allLogs', enabled: true }] }
}

resource desktopLogs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (diagnostics) {
  name: 'diag-vdag-avd'
  scope: desktop
  properties: { workspaceId: logs, logs: [{ categoryGroup: 'allLogs', enabled: true }] }
}

resource workspaceLogs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (diagnostics) {
  name: 'diag-vdws-avd'
  scope: desktopWorkspace
  properties: { workspaceId: logs, logs: [{ categoryGroup: 'allLogs', enabled: true }] }
}

// Start VM on connect and the scaling plan act through the Azure Virtual Desktop service principal.
var powerOnOff = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '40c5ff49-9181-41f8-ae61-143b0e78555e')
var powerOn = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '489581de-a3bd-480d-9518-53dea7416b33')
var avdRole = scalingPlan.enabled ? powerOnOff : powerOn

resource avdPower 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(avdServicePrincipalId) && (scalingPlan.enabled || hostPool.startVMOnConnect)) {
  name: guid(resourceGroup().id, avdServicePrincipalId, avdRole)
  properties: {
    principalId: avdServicePrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: avdRole
  }
}

resource scaling 'Microsoft.DesktopVirtualization/scalingPlans@2024-04-03' = if (scalingPlan.enabled) {
  name: 'vdscaling-avd'
  location: location
  properties: {
    hostPoolType: 'Pooled'
    timeZone: scalingPlan.timeZone
    exclusionTag: scalingPlan.exclusionTag
    schedules: scalingPlan.schedules
    hostPoolReferences: [{ hostPoolArmPath: pool.id, scalingPlanEnabled: true }]
  }
  dependsOn: [avdPower]
}

resource desktopAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(desktop.id, userGroupId, '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63')
  scope: desktop
  properties: {
    principalId: userGroupId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63')
  }
}

resource userLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, userGroupId, 'fb879df8-f326-4884-b1cf-06f3ad86be52')
  properties: {
    principalId: userGroupId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'fb879df8-f326-4884-b1cf-06f3ad86be52')
  }
}

resource adminLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, adminGroupId, '1c0163c0-47e6-4577-8991-ea5c82e286e4')
  properties: {
    principalId: adminGroupId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1c0163c0-47e6-4577-8991-ea5c82e286e4')
  }
}

// FSLogix profile storage, reached over a private endpoint with public access off. Both options
// work on Entra-joined hosts without Kerberos: hosts authenticate with the account key, which
// only reaches them as a protected Run Command parameter.
//   AzureFiles      Premium SMB share. Lower latency for VHDX; the usual choice.
//   BlobCloudCache  Standard page blobs with a local cache on each host. Cheaper, and keeps
//                   working through short storage outages.
var useFiles = fslogix.storageType == 'AzureFiles'
var storageService = useFiles ? 'file' : 'blob'

resource profileStorage 'Microsoft.Storage/storageAccounts@2025-01-01' = if (fslogix.enabled) {
  name: 'stavd${take(uniqueString(subscription().id), 6)}'
  location: location
  kind: useFiles ? 'FileStorage' : 'StorageV2'
  sku: { name: useFiles ? 'Premium_LRS' : 'Standard_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    publicNetworkAccess: 'Disabled'
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2025-01-01' = if (fslogix.enabled && useFiles) {
  parent: profileStorage
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: { enabled: true, days: 7 }
    protocolSettings: {
      // Key authentication (NTLMv2) needs AES-128-GCM allowed; AES-256-GCM alone returned access denied.
      smb: { versions: 'SMB3.1.1', authenticationMethods: 'NTLMv2;Kerberos', channelEncryption: 'AES-128-GCM;AES-256-GCM' }
    }
  }
}

resource profileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2025-01-01' = if (fslogix.enabled && useFiles) {
  parent: fileService
  name: 'profiles'
  properties: {
    shareQuota: fslogix.shareQuotaGiB
    enabledProtocols: 'SMB'
  }
}

module storageZone '../modules/dns-zone.bicep' = if (fslogix.enabled) {
  name: 'dns-${storageService}'
  scope: resourceGroup('rg-hub')
  params: {
    name: 'privatelink.${storageService}.${environment().suffixes.storage}'
  }
}

resource profileEndpoint 'Microsoft.Network/privateEndpoints@2025-07-01' = if (fslogix.enabled) {
  name: 'pe-avd-${storageService}'
  location: location
  properties: {
    subnet: { id: '${spoke.outputs.vnetId}/subnets/snet-pe' }
    privateLinkServiceConnections: [
      {
        name: storageService
        properties: {
          privateLinkServiceId: profileStorage.id
          groupIds: [storageService]
        }
      }
    ]
  }
}

resource profileDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-07-01' = if (fslogix.enabled) {
  parent: profileEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: storageService, properties: { privateDnsZoneId: storageZone!.outputs.id } }
    ]
  }
}


// Same pool, image, size and forceNewHost: same names. Changing any of them deploys a new set.
var hostId = take(uniqueString(resourceGroup().id, imageId, sessionHosts.vmSize, sessionHosts.forceNewHost), 3)
var hostNames = [for i in range(0, sessionHosts.count): '${sessionHosts.namePrefix}${hostId}-${padLeft(i + sessionHosts.startNumber, 3, '0')}']

resource nics 'Microsoft.Network/networkInterfaces@2025-07-01' = [
  for i in range(0, sessionHosts.count): {
    name: 'nic-${hostNames[i]}'
    location: location
    properties: {
      enableAcceleratedNetworking: sessionHosts.acceleratedNetworking
      ipConfigurations: [
        {
          name: 'ipconfig'
          properties: {
            subnet: { id: '${spoke.outputs.vnetId}/subnets/snet-hosts' }
          }
        }
      ]
    }
  }
]

resource hosts 'Microsoft.Compute/virtualMachines@2025-04-01' = [
  for i in range(0, sessionHosts.count): {
    name: 'vm-${hostNames[i]}'
    location: location
    identity: { type: 'SystemAssigned' }
    properties: {
      hardwareProfile: { vmSize: sessionHosts.vmSize }
      licenseType: 'Windows_Client'
      securityProfile: {
        securityType: 'TrustedLaunch'
        uefiSettings: { secureBootEnabled: true, vTpmEnabled: true }
      }
      osProfile: {
        computerName: hostNames[i]
        adminUsername: adminUsername
        adminPassword: adminPassword
      }
      storageProfile: {
        imageReference: empty(imageId)
          ? { publisher: 'MicrosoftWindowsDesktop', offer: 'office-365', sku: 'win11-25h2-avd-m365', version: 'latest' }
          : { id: imageId }
        osDisk: {
          createOption: 'FromImage'
          deleteOption: 'Delete'
          diskSizeGB: sessionHosts.osDiskSizeGB // room for the FSLogix local cache
          managedDisk: { storageAccountType: sessionHosts.osDiskType }
        }
      }
      networkProfile: {
        networkInterfaces: [{ id: nics[i].id, properties: { deleteOption: 'Delete' } }]
      }
      diagnosticsProfile: { bootDiagnostics: { enabled: true } }
    }
  }
]

resource attestation 'Microsoft.Compute/virtualMachines/extensions@2025-04-01' = [
  for i in range(0, sessionHosts.count): if (sessionHosts.guestAttestation) {
    parent: hosts[i]
    name: 'GuestAttestation'
    location: location
    properties: {
      publisher: 'Microsoft.Azure.Security.WindowsAttestation'
      type: 'GuestAttestation'
      typeHandlerVersion: '1.0'
      autoUpgradeMinorVersion: true
      enableAutomaticUpgrade: true
      settings: {
        AttestationConfig: {
          MaaSettings: { maaEndpoint: '', maaTenantName: 'GuestAttestation' }
          AscSettings: { ascReportingEndpoint: '', ascReportingFrequency: '' }
          useCustomToken: 'false'
          disableAlerts: 'false'
        }
      }
    }
  }
]

resource entraJoin 'Microsoft.Compute/virtualMachines/extensions@2025-04-01' = [
  for i in range(0, sessionHosts.count): {
    parent: hosts[i]
    name: 'AADLoginForWindows'
    location: location
    properties: {
      publisher: 'Microsoft.Azure.ActiveDirectory'
      type: 'AADLoginForWindows'
      typeHandlerVersion: '2.0'
      autoUpgradeMinorVersion: true
      settings: sessionHosts.intuneEnrollment ? { mdmId: '0000000a-0000-0000-c000-000000000000' } : null
    }
    dependsOn: [attestation[i]]
  }
]

// Stops the deployment if the Entra join didn't happen (entra-join-check.ps1).
resource entraJoinCheck 'Microsoft.Compute/virtualMachines/runCommands@2025-04-01' = [
  for i in range(0, sessionHosts.count): {
    parent: hosts[i]
    name: 'check-entra-join'
    location: location
    properties: {
      asyncExecution: false
      treatFailureAsDeploymentFailure: true
      timeoutInSeconds: 600
      source: { script: loadTextContent('entra-join-check.ps1') }
    }
    dependsOn: [entraJoin[i]]
  }
]

// Installs the AVD agent and registers the host with the host pool.
resource registration 'Microsoft.Compute/virtualMachines/extensions@2025-04-01' = [
  for i in range(0, sessionHosts.count): {
    parent: hosts[i]
    name: 'AddSessionHost'
    location: location
    properties: {
      publisher: 'Microsoft.Powershell'
      type: 'DSC'
      typeHandlerVersion: '2.77'
      autoUpgradeMinorVersion: true
      settings: {
        modulesUrl: 'https://wvdportalstorageblob.blob.${environment().suffixes.storage}/galleryartifacts/Configuration_1.0.03211.1002.zip'
        configurationFunction: 'Configuration.ps1\\AddSessionHost'
        properties: {
          hostPoolName: pool.name
          registrationInfoTokenCredential: {
            UserName: 'PLACEHOLDER_DO_NOT_USE'
            Password: 'PrivateSettingsRef:RegistrationInfoToken'
          }
          aadJoin: true
          UseAgentDownloadEndpoint: true
        }
      }
      protectedSettings: {
        Items: {
          RegistrationInfoToken: pool.listRegistrationTokens().value[0].token
        }
      }
    }
    dependsOn: [entraJoinCheck[i]]
  }
]

resource configureFslogix 'Microsoft.Compute/virtualMachines/runCommands@2025-04-01' = [
  for i in range(0, sessionHosts.count): if (fslogix.enabled) {
    parent: hosts[i]
    name: 'configure-fslogix'
    location: location
    properties: {
      asyncExecution: false
      treatFailureAsDeploymentFailure: true
      timeoutInSeconds: 900
      source: { script: loadTextContent('fslogix.ps1') }
      parameters: [
        { name: 'StorageType', value: fslogix.storageType }
        { name: 'AccountName', value: profileStorage!.name }
        { name: 'EndpointSuffix', value: environment().suffixes.storage }
        { name: 'SizeInMBs', value: string(fslogix.sizeInMBs) }
      ]
      protectedParameters: [
        { name: 'AccountKey', value: profileStorage!.listKeys().keys[0].value }
      ]
    }
    dependsOn: [registration[i], profileDns, profileShare]
  }
]

output sessionHostNames string[] = hostNames
