// Azure Virtual Desktop: spoke network, pooled host pool, desktop, workspace, FSLogix profile
// storage and Entra-joined session hosts built from the image-builder gallery image.
// Deploy into resource group rg-avd.

param userGroupId string
param adminGroupId string
@secure()
param adminPassword string
param adminUsername string = 'avdadmin'
param hostCount int = 1
param vmSize string = 'Standard_D4ds_v5'
@description('Where FSLogix keeps profiles: an Azure Files share or Cloud Cache on blob storage.')
@allowed(['AzureFiles', 'BlobCloudCache'])
param profileStorageType string = 'AzureFiles'
@description('Azure Files share size. Premium shares start at 100 GiB.')
@minValue(100)
param profileShareQuotaGiB int = 100
param profileSizeInMBs int = 30000
param tokenStart string = utcNow()
param location string = resourceGroup().location

var subnetPrefix = '10.1.0.0/24'

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
            sourceAddresses: [subnetPrefix]
            destinationAddresses: ['WindowsVirtualDesktop', 'AzureMonitor', 'AzureActiveDirectory']
            destinationPorts: ['443']
          }
          {
            ruleType: 'NetworkRule'
            name: 'windows-activation'
            ipProtocols: ['TCP']
            sourceAddresses: [subnetPrefix]
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
            sourceAddresses: [subnetPrefix]
            fqdnTags: ['WindowsVirtualDesktop', 'WindowsUpdate', 'WindowsDiagnostics', 'MicrosoftActiveProtectionService']
          }
          {
            ruleType: 'ApplicationRule'
            name: 'certificate-revocation'
            protocols: [{ protocolType: 'Https', port: 443 }, { protocolType: 'Http', port: 80 }]
            sourceAddresses: [subnetPrefix]
            targetFqdns: ['oneocsp.microsoft.com', 'www.microsoft.com', 'ctldl.windowsupdate.com']
          }
        ]
      }
    ]
  }
}

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' = {
  name: 'vdpool-avd'
  location: location
  properties: {
    hostPoolType: 'Pooled'
    loadBalancerType: 'BreadthFirst'
    maxSessionLimit: 10
    preferredAppGroupType: 'Desktop'
    customRdpProperty: 'targetisaadjoined:i:1;enablerdsaadauth:i:1'
    registrationInfo: {
      expirationTime: dateTimeAdd(tokenStart, 'PT4H')
      registrationTokenOperation: 'Update'
    }
  }
}

resource desktop 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-03' = {
  name: 'vdag-desktop'
  location: location
  properties: {
    applicationGroupType: 'Desktop'
    hostPoolArmPath: hostPool.id
  }
}

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2024-04-03' = {
  name: 'vdws-avd'
  location: location
  properties: {
    applicationGroupReferences: [desktop.id]
  }
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
var useFiles = profileStorageType == 'AzureFiles'
var storageService = useFiles ? 'file' : 'blob'

resource profileStorage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: 'stfslogix${uniqueString(resourceGroup().id)}'
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

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2025-01-01' = if (useFiles) {
  parent: profileStorage
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: { enabled: true, days: 7 }
    protocolSettings: {
      smb: { versions: 'SMB3.1.1', channelEncryption: 'AES-256-GCM' }
    }
  }
}

resource profileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2025-01-01' = if (useFiles) {
  parent: fileService
  name: 'profiles'
  properties: {
    shareQuota: profileShareQuotaGiB
    enabledProtocols: 'SMB'
  }
}

module storageZone '../modules/dns-zone.bicep' = {
  name: 'dns-${storageService}'
  scope: resourceGroup('rg-hub')
  params: {
    name: 'privatelink.${storageService}.${environment().suffixes.storage}'
  }
}

resource profileEndpoint 'Microsoft.Network/privateEndpoints@2025-07-01' = {
  name: 'pe-fslogix'
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

resource profileDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-07-01' = {
  parent: profileEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: storageService, properties: { privateDnsZoneId: storageZone.outputs.id } }
    ]
  }
}

resource image 'Microsoft.Compute/galleries/images@2024-03-03' existing = {
  name: 'gal_images/win11-avd'
  scope: resourceGroup('rg-image-builder')
}

resource nics 'Microsoft.Network/networkInterfaces@2025-07-01' = [
  for i in range(0, hostCount): {
    name: 'nic-avd-${i}'
    location: location
    properties: {
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
  for i in range(0, hostCount): {
    name: 'vm-avd-${i}'
    location: location
    identity: { type: 'SystemAssigned' }
    properties: {
      hardwareProfile: { vmSize: vmSize }
      licenseType: 'Windows_Client'
      securityProfile: {
        securityType: 'TrustedLaunch'
        uefiSettings: { secureBootEnabled: true, vTpmEnabled: true }
      }
      osProfile: {
        computerName: 'avd-${i}'
        adminUsername: adminUsername
        adminPassword: adminPassword
      }
      storageProfile: {
        imageReference: { id: image.id }
        osDisk: {
          createOption: 'FromImage'
          deleteOption: 'Delete'
          diskSizeGB: 256 // room for the FSLogix local cache
          managedDisk: { storageAccountType: 'Premium_LRS' }
        }
      }
      networkProfile: {
        networkInterfaces: [{ id: nics[i].id, properties: { deleteOption: 'Delete' } }]
      }
    }
  }
]

resource entraJoin 'Microsoft.Compute/virtualMachines/extensions@2025-04-01' = [
  for i in range(0, hostCount): {
    parent: hosts[i]
    name: 'AADLoginForWindows'
    location: location
    properties: {
      publisher: 'Microsoft.Azure.ActiveDirectory'
      type: 'AADLoginForWindows'
      typeHandlerVersion: '2.0'
      autoUpgradeMinorVersion: true
    }
  }
]

// Installs the AVD agent and registers the host with the host pool.
resource registration 'Microsoft.Compute/virtualMachines/extensions@2025-04-01' = [
  for i in range(0, hostCount): {
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
          hostPoolName: hostPool.name
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
          RegistrationInfoToken: hostPool.listRegistrationTokens().value[0].token
        }
      }
    }
    dependsOn: [entraJoin[i]]
  }
]

resource fslogix 'Microsoft.Compute/virtualMachines/runCommands@2025-04-01' = [
  for i in range(0, hostCount): {
    parent: hosts[i]
    name: 'configure-fslogix'
    location: location
    properties: {
      asyncExecution: false
      treatFailureAsDeploymentFailure: true
      timeoutInSeconds: 900
      source: { script: loadTextContent('fslogix.ps1') }
      parameters: [
        { name: 'StorageType', value: profileStorageType }
        { name: 'AccountName', value: profileStorage.name }
        { name: 'EndpointSuffix', value: environment().suffixes.storage }
        { name: 'SizeInMBs', value: string(profileSizeInMBs) }
      ]
      protectedParameters: [
        { name: 'AccountKey', value: profileStorage.listKeys().keys[0].value }
      ]
    }
    dependsOn: [registration[i], profileDns, profileShare]
  }
]
