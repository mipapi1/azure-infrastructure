// Azure Virtual Desktop: spoke network, pooled host pool, desktop, workspace and
// Entra-joined session hosts built from the image-builder gallery image.
// Deploy into resource group rg-avd.

param userGroupId string
param adminGroupId string
@secure()
param adminPassword string
param adminUsername string = 'avdadmin'
param hostCount int = 1
param vmSize string = 'Standard_D4ds_v5'
param tokenStart string = utcNow()
param location string = resourceGroup().location

var subnetPrefix = '10.1.0.0/24'

module spoke '../modules/spoke.bicep' = {
  name: 'spoke-avd'
  params: {
    name: 'avd'
    location: location
    addressPrefix: subnetPrefix
    subnets: [{ name: 'snet-hosts', addressPrefix: subnetPrefix }]
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
