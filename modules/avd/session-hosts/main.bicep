metadata name = 'AVD session hosts'
metadata description = 'Session hosts for an Azure Virtual Desktop host pool. Wraps the virtual machine AVM and adds what it lacks: agent registration with a secured, short-lived token, either identity mode, and FSLogix configuration.'

import { lockType } from 'br/public:avm/utl/types/avm-common-types:0.7.0'

@description('Required. Name prefix for VMs and computer names. Hosts are named <prefix>-<nnn>; keep the prefix to 11 characters or fewer.')
@maxLength(11)
param namePrefix string

@description('Required. Number of session hosts.')
@minValue(0)
param count int

@description('Optional. First host number. Increase it to add hosts without renaming existing ones.')
param startIndex int = 1

@description('Optional. Location for all resources.')
param location string = resourceGroup().location

@description('Optional. Availability zones to spread hosts across, round-robin. Empty for no zones.')
param availabilityZones int[] = [1, 2, 3]

@description('Required. VM size, for example Standard_D4ads_v5.')
param vmSize string

@description('Optional. OS disk settings.')
param osDisk {
  @description('Optional. Disk SKU. Defaults to Premium_LRS.')
  storageAccountType: ('Premium_LRS' | 'Premium_ZRS' | 'StandardSSD_LRS' | 'StandardSSD_ZRS')?
  @description('Optional. Size in GB. Defaults to 128.')
  sizeGB: int?
} = {}

@description('Required. Image: either a Marketplace reference or a Compute Gallery image (version) resource ID.')
param image {
  @description('Optional. Marketplace publisher, offer, SKU and version.')
  marketplace: {
    publisher: string
    offer: string
    sku: string
    version: string?
  }?
  @description('Optional. Resource ID of a Compute Gallery image or image version, for example from az-image-builder.')
  galleryImageResourceId: string?
}

@description('Required. Resource ID of the session host subnet.')
param subnetResourceId string

@description('Required. Local administrator user name.')
param adminUsername string

@description('Required. Local administrator password.')
@secure()
param adminPassword string

@description('Optional. How hosts join a directory.')
param identityMode ('EntraJoined' | 'DomainJoined') = 'EntraJoined'

@description('Optional. Enroll Entra-joined hosts in Intune.')
param intuneEnrollment bool = false

@description('Conditional. Domain join settings. Required when identityMode is DomainJoined.')
param domainJoin {
  @description('Required. DNS name of the AD DS or Entra Domain Services domain.')
  domainName: string
  @description('Optional. Distinguished name of the OU for the computer accounts.')
  ouPath: string?
  @description('Required. Join account in UPN or DOMAIN\\user form.')
  user: string
}?

@description('Conditional. Password of the domain join account. Required when identityMode is DomainJoined.')
@secure()
param domainJoinPassword string = ''

@description('Required. Resource ID of the host pool to register with. The host pool deployment must refresh the registration token before this module runs.')
param hostPoolResourceId string

@description('Optional. Data collection rules to associate (AVD Insights, baseline VM rules).')
param dataCollectionRuleResourceIds string[] = []

@description('Optional. FSLogix profile container settings.')
param fslogix {
  @description('Required. Configure FSLogix on the hosts.')
  enabled: bool
  @description('Optional. RunCommand writes the registry settings during deployment. None leaves it to Intune or Group Policy (the recommended method when either exists).')
  configurationMethod: ('RunCommand' | 'None')?
  @description('Optional. AzureFiles (SMB, default) or BlobCloudCache (Cloud Cache on page blobs with an account key, no Kerberos).')
  storageType: ('AzureFiles' | 'BlobCloudCache')?
  @description('Conditional. AzureFiles: UNC paths of the profile shares, in priority order.')
  profileLocations: string[]?
  @description('Conditional. BlobCloudCache: resource ID of the blob storage account. Its key is read during the deployment and only passed as a protected Run Command parameter.')
  blobStorageAccountResourceId: string?
  @description('Optional. BlobCloudCache: account key to use (key1 or key2). Defaults to key1.')
  blobKeyName: ('key1' | 'key2')?
  @description('Optional. AzureFiles: use Cloud Cache with every location as a provider. Defaults to false.')
  cloudCache: bool?
  @description('Optional. Maximum container size in MB. Defaults to 30000.')
  sizeInMBs: int?
} = { enabled: false }

@description('Optional. Use Entra Kerberos for Azure Files (sets CloudKerberosTicketRetrievalEnabled). Defaults to true for Entra-joined hosts.')
param entraKerberos bool = identityMode == 'EntraJoined'

@description('Optional. Users are cloud-only Entra identities. The FSLogix Run Command then also checks the documented Windows build for cloud-only Entra Kerberos.')
param cloudOnlyIdentities bool = false

@description('Optional. Enable encryption at host (temp disk and caches encrypted at rest).')
param encryptionAtHost bool = true

@description('Optional. Resource ID of a disk encryption set for customer-managed keys.')
param diskEncryptionSetResourceId string?

@description('Optional. URL of the AVD agent DSC configuration package. Microsoft publishes new versions; update after testing.')
param agentConfigurationZipUri string = 'https://wvdportalstorageblob.blob.${environment().suffixes.storage}/galleryartifacts/Configuration_1.0.03211.1002.zip'

@description('Optional. Lock applied to the VMs.')
param lock lockType?

@description('Optional. Tags applied to every resource.')
param tags resourceInput<'Microsoft.Compute/virtualMachines@2025-04-01'>.tags?

@description('Optional. Enable AVM usage telemetry.')
param enableTelemetry bool = true

var isEntraJoined = identityMode == 'EntraJoined'
var intuneMdmId = '0000000a-0000-0000-c000-000000000000'
var hostPoolSegments = split(hostPoolResourceId, '/')
var hostNames = [for i in range(startIndex, count): '${namePrefix}-${padLeft(i, 3, '0')}']
var useRunCommand = fslogix.enabled && (fslogix.?configurationMethod ?? 'RunCommand') == 'RunCommand'
var useBlobCloudCache = fslogix.enabled && (fslogix.?storageType ?? 'AzureFiles') == 'BlobCloudCache'
var blobKeyName = fslogix.?blobKeyName ?? 'key1'
// ARM evaluates the scope even when the reference is unused, so the fallback must be a valid ID.
var blobAccountSegments = split(
  useBlobCloudCache ? fslogix.?blobStorageAccountResourceId! : resourceId('Microsoft.Storage/storageAccounts', 'unused'),
  '/'
)

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2025-10-10' existing = {
  name: last(hostPoolSegments)
  scope: resourceGroup(hostPoolSegments[2], hostPoolSegments[4])
}

resource blobStorageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' existing = if (useBlobCloudCache) {
  name: last(blobAccountSegments)
  scope: resourceGroup(blobAccountSegments[2], blobAccountSegments[4])
}

module virtualMachines 'br/public:avm/res/compute/virtual-machine:0.22.3' = [
  for (hostName, i) in hostNames: {
    name: '${uniqueString(deployment().name, location)}-${hostName}'
    params: {
      name: hostName
      computerName: hostName
      location: location
      osType: 'Windows'
      licenseType: 'Windows_Client'
      vmSize: vmSize
      availabilityZone: empty(availabilityZones) ? -1 : availabilityZones[i % length(availabilityZones)]
      imageReference: !empty(image.?galleryImageResourceId ?? '')
        ? { id: image.?galleryImageResourceId }
        : {
            publisher: image.?marketplace.?publisher
            offer: image.?marketplace.?offer
            sku: image.?marketplace.?sku
            version: image.?marketplace.?version ?? 'latest'
          }
      securityType: 'TrustedLaunch'
      secureBootEnabled: true
      vTpmEnabled: true
      encryptionAtHost: encryptionAtHost
      osDisk: {
        caching: 'ReadWrite'
        deleteOption: 'Delete'
        diskSizeGB: osDisk.?sizeGB ?? 128
        managedDisk: {
          storageAccountType: osDisk.?storageAccountType ?? 'Premium_LRS'
          diskEncryptionSetResourceId: diskEncryptionSetResourceId
        }
      }
      adminUsername: adminUsername
      adminPassword: adminPassword
      managedIdentities: { systemAssigned: true }
      bootDiagnostics: true
      patchMode: 'AutomaticByOS'
      enableAutomaticUpdates: true
      nicConfigurations: [
        {
          nicSuffix: '-nic'
          deleteOption: 'Delete'
          enableAcceleratedNetworking: true
          ipConfigurations: [
            {
              name: 'ipconfig1'
              subnetResourceId: subnetResourceId
            }
          ]
        }
      ]
      extensionAadJoinConfig: {
        enabled: isEntraJoined
        settings: intuneEnrollment ? { mdmId: intuneMdmId } : {}
      }
      extensionDomainJoinConfig: {
        enabled: !isEntraJoined
        domainName: domainJoin.?domainName
        ouPath: domainJoin.?ouPath
        user: domainJoin.?user
        restart: true
        // NETSETUP_JOIN_DOMAIN | NETSETUP_ACCT_CREATE
        options: 3
      }
      extensionDomainJoinPassword: domainJoinPassword
      extensionMonitoringAgentConfig: {
        enabled: true
        dataCollectionRuleAssociations: [
          for (dcr, d) in dataCollectionRuleResourceIds: {
            name: 'dcra-${d}-${last(split(dcr, '/'))}'
            dataCollectionRuleResourceId: dcr
          }
        ]
      }
      extensionAntiMalwareConfig: {
        enabled: true
        settings: {
          AntimalwareEnabled: 'true'
          RealtimeProtectionEnabled: 'true'
          ScheduledScanSettings: { isEnabled: 'true', day: '7', time: '120', scanType: 'Quick' }
          // FSLogix recommended exclusions for profile containers.
          Exclusions: {
            Extensions: '.vhd;.vhdx'
            Paths: '%ProgramFiles%\\FSLogix\\Apps\\frxdrv.sys;%ProgramFiles%\\FSLogix\\Apps\\frxccd.sys;%TEMP%\\*.VHD;%TEMP%\\*.VHDX;%Windir%\\TEMP\\*.VHD;%Windir%\\TEMP\\*.VHDX'
            Processes: '%ProgramFiles%\\FSLogix\\Apps\\frxccd.exe;%ProgramFiles%\\FSLogix\\Apps\\frxccds.exe;%ProgramFiles%\\FSLogix\\Apps\\frxsvc.exe'
          }
        }
      }
      lock: lock
      tags: tags
      enableTelemetry: enableTelemetry
    }
  }
]

resource vmRefs 'Microsoft.Compute/virtualMachines@2025-04-01' existing = [
  for hostName in hostNames: {
    name: hostName
  }
]

// Registers each host with the host pool. The token is read here, at deployment
// time, and only passed in protected settings, so it never appears in outputs or
// deployment history. Tokens are short-lived and refreshed on every host pool deployment.
resource agentRegistration 'Microsoft.Compute/virtualMachines/extensions@2025-04-01' = [
  for (hostName, i) in hostNames: {
    parent: vmRefs[i]
    name: 'Microsoft.PowerShell.DSC'
    location: location
    tags: tags
    properties: {
      publisher: 'Microsoft.Powershell'
      type: 'DSC'
      typeHandlerVersion: '2.77'
      autoUpgradeMinorVersion: true
      settings: {
        modulesUrl: agentConfigurationZipUri
        configurationFunction: 'Configuration.ps1\\AddSessionHost'
        properties: {
          hostPoolName: hostPool.name
          // Not a credential: the DSC extension resolves this reference from protected settings.
          registrationInfoTokenCredential: {
            UserName: 'PLACEHOLDER_DO_NOT_USE'
            // checkov:skip=CKV_SECRET_6: reference name, not a secret value
            Password: 'PrivateSettingsRef:RegistrationInfoToken'
          }
          aadJoin: isEntraJoined
          UseAgentDownloadEndpoint: true
          mdmId: isEntraJoined && intuneEnrollment ? intuneMdmId : ''
        }
      }
      protectedSettings: {
        Items: {
          RegistrationInfoToken: hostPool.listRegistrationTokens().value[0].token
        }
      }
    }
    dependsOn: [virtualMachines]
  }
]

resource fslogixConfiguration 'Microsoft.Compute/virtualMachines/runCommands@2025-04-01' = [
  for (hostName, i) in hostNames: if (useRunCommand) {
    parent: vmRefs[i]
    name: 'configure-fslogix'
    location: location
    tags: tags
    properties: {
      asyncExecution: false
      treatFailureAsDeploymentFailure: true
      timeoutInSeconds: 600
      source: {
        script: loadTextContent('scripts/Set-FslogixConfiguration.ps1')
      }
      parameters: [
        { name: 'StorageType', value: fslogix.?storageType ?? 'AzureFiles' }
        { name: 'ProfileLocations', value: join(fslogix.?profileLocations ?? [], ';') }
        { name: 'CloudCache', value: string(fslogix.?cloudCache ?? false) }
        { name: 'SizeInMBs', value: string(fslogix.?sizeInMBs ?? 30000) }
        { name: 'EntraKerberos', value: string(entraKerberos) }
        { name: 'CloudOnly', value: string(cloudOnlyIdentities) }
        // Not secret: names the key in use, so switching keys re-runs the command.
        { name: 'BlobKeyName', value: useBlobCloudCache ? blobKeyName : '' }
      ]
      // The connection string is built here, at deployment time, and only travels in
      // protected parameters; the script stores it encrypted with frx add-secure-key.
      protectedParameters: useBlobCloudCache
        ? [
            {
              name: 'BlobConnectionString'
              value: 'DefaultEndpointsProtocol=https;AccountName=${blobStorageAccount.name};AccountKey=${filter(blobStorageAccount!.listKeys().keys, k => k.keyName == blobKeyName)[0].value};EndpointSuffix=${environment().suffixes.storage}'
            }
          ]
        : []
    }
    dependsOn: [agentRegistration]
  }
]

@description('Session host VM names.')
output names string[] = hostNames

@description('Session host VM resource IDs.')
output resourceIds string[] = [for (hostName, i) in hostNames: virtualMachines[i].outputs.resourceId]

@description('System-assigned identity principal IDs of the session hosts.')
output principalIds string[] = [
  for (hostName, i) in hostNames: virtualMachines[i].outputs.?systemAssignedMIPrincipalId ?? ''
]
