// Compute Gallery and Image Builder templates for two images:
//   win11-avd         AVD session hosts: Windows 11 multi-session with Microsoft 365 Apps, fully
//                     patched, optionally STIG-hardened (stig).
//   ubuntu-2404-stig  Linux VMs: Ubuntu 24.04 LTS, patched and STIG-hardened (stig-linux.sh).
// Deploy into resource group rg-image-builder, then run the template.

@description('Apply the DISA STIG GPO package to the image (stig.ps1).')
param stig bool = false
@description('Build VM size. Two builds at 2 vCPUs each fit a 4 vCPU regional quota.')
param buildVmSize string = 'Standard_D2s_v5'
param location string = resourceGroup().location

var contributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-image-builder'
  location: location
}

// Image Builder writes image versions to the gallery with this identity.
resource identityAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, identity.id, contributor)
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: contributor
  }
}

resource gallery 'Microsoft.Compute/galleries@2024-03-03' = {
  name: 'gal_images'
  location: location
}

resource imageDefinition 'Microsoft.Compute/galleries/images@2024-03-03' = {
  parent: gallery
  name: 'win11-avd'
  location: location
  properties: {
    osType: 'Windows'
    osState: 'Generalized'
    hyperVGeneration: 'V2'
    features: [{ name: 'SecurityType', value: 'TrustedLaunch' }]
    identifier: {
      publisher: 'platform'
      offer: 'windows-11'
      sku: 'win11-avd'
    }
  }
}

resource template 'Microsoft.VirtualMachineImages/imageTemplates@2024-02-01' = {
  name: 'it-win11-avd'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    buildTimeoutInMinutes: 240
    vmProfile: { vmSize: buildVmSize }
    source: {
      type: 'PlatformImage'
      publisher: 'MicrosoftWindowsDesktop'
      offer: 'office-365'
      sku: 'win11-25h2-avd-m365'
      version: 'latest'
    }
    customize: concat(
      [
        { type: 'WindowsUpdate', name: 'windows-update' }
        { type: 'WindowsRestart', name: 'restart' }
      ],
      stig
        ? [
            {
              type: 'PowerShell'
              name: 'stig'
              runElevated: true
              runAsSystem: true
              inline: split(loadTextContent('stig.ps1'), '\n')
            }
          ]
        : []
    )
    distribute: [
      {
        type: 'SharedImage'
        galleryImageId: imageDefinition.id
        runOutputName: 'win11-avd'
        replicationRegions: [location]
      }
    ]
  }
  dependsOn: [identityAccess]
}

resource linuxDefinition 'Microsoft.Compute/galleries/images@2024-03-03' = {
  parent: gallery
  name: 'ubuntu-2404-stig'
  location: location
  properties: {
    osType: 'Linux'
    osState: 'Generalized'
    hyperVGeneration: 'V2'
    features: [{ name: 'SecurityType', value: 'TrustedLaunch' }]
    identifier: {
      publisher: 'platform'
      offer: 'ubuntu-24_04'
      sku: 'ubuntu-2404-stig'
    }
  }
}

resource linuxTemplate 'Microsoft.VirtualMachineImages/imageTemplates@2024-02-01' = {
  name: 'it-ubuntu-2404-stig'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    buildTimeoutInMinutes: 120
    vmProfile: { vmSize: buildVmSize }
    source: {
      type: 'PlatformImage'
      publisher: 'Canonical'
      offer: 'ubuntu-24_04-lts'
      sku: 'server'
      version: 'latest'
    }
    customize: [
      {
        type: 'Shell'
        name: 'update'
        inline: ['sudo DEBIAN_FRONTEND=noninteractive apt-get update -q', 'sudo DEBIAN_FRONTEND=noninteractive apt-get -y -q dist-upgrade']
      }
      {
        type: 'Shell'
        name: 'stig'
        inline: ['echo ${base64(loadTextContent('stig-linux.sh'))} | base64 -d > /tmp/stig-linux.sh', 'sudo bash /tmp/stig-linux.sh']
      }
    ]
    distribute: [
      {
        type: 'SharedImage'
        galleryImageId: linuxDefinition.id
        runOutputName: 'ubuntu-2404-stig'
        replicationRegions: [location]
      }
    ]
  }
  dependsOn: [identityAccess]
}
