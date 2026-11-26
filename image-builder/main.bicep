// Compute Gallery and Image Builder templates for two images:
//   win11-avd         AVD session hosts: Windows 11 multi-session with Microsoft 365 Apps, fully
//                     patched, optionally STIG-hardened (stig).
//   ubuntu-2404-stig  Linux VMs: Ubuntu 24.04 LTS, patched and STIG-hardened (stig-linux.sh).
// Builds run in a spoke peered to the hub: the build VM and Image Builder's container (Packer) sit in
// their own subnets and reach the internet only through the hub firewall, which allows the
// endpoints below. Deploy into resource group rg-image-builder after the hub, then run the templates.

@description('Apply the DISA STIG GPO package to the image (stig.ps1).')
param stig bool = false
@description('Build VM size. Two builds at 2 vCPUs each fit a 4 vCPU regional quota.')
param buildVmSize string = 'Standard_D2s_v5'
param location string = resourceGroup().location

var buildPrefix = '10.4.0.0/25'
var containerPrefix = '10.4.0.128/27'
var buildIpGroup = resourceId('rg-hub', 'Microsoft.Network/ipGroups', 'ipg-image-builder-snet-build')
var containerIpGroup = resourceId('rg-hub', 'Microsoft.Network/ipGroups', 'ipg-image-builder-snet-container')

module spoke '../modules/spoke.bicep' = {
  name: 'spoke-image-builder'
  params: {
    name: 'image-builder'
    location: location
    addressPrefix: '10.4.0.0/24'
    subnets: [
      { name: 'snet-build', addressPrefix: buildPrefix }
      { name: 'snet-container', addressPrefix: containerPrefix, delegation: 'Microsoft.ContainerInstance/containerGroups' }
    ]
    rulePriority: 500
    ruleCollections: [
      {
        name: 'image-builder-network'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 100
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'windows-activation'
            ipProtocols: ['TCP']
            sourceIpGroups: [buildIpGroup]
            destinationFqdns: ['azkms.${environment().suffixes.storage}', 'kms.${environment().suffixes.storage}']
            destinationPorts: ['1688']
          }
          {
            ruleType: 'NetworkRule'
            name: 'ntp'
            ipProtocols: ['UDP']
            sourceIpGroups: [buildIpGroup]
            destinationFqdns: ['time.windows.com', 'ntp.ubuntu.com']
            destinationPorts: ['123']
          }
        ]
      }
      {
        name: 'image-builder-application'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 200
        action: { type: 'Allow' }
        rules: [
          {
            // Packer calls Azure Resource Manager and Entra ID and writes logs to the staging account.
            ruleType: 'ApplicationRule'
            name: 'image-builder-container'
            protocols: [{ protocolType: 'Https', port: 443 }]
            sourceIpGroups: [containerIpGroup]
            targetFqdns: [
              split(environment().resourceManager, '/')[2]
              split(environment().authentication.loginEndpoint, '/')[2]
              'mcr.microsoft.com'
              '*.data.mcr.microsoft.com'
              'packages.microsoft.com'
              '*.blob.${environment().suffixes.storage}'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            name: 'os-updates'
            protocols: [{ protocolType: 'Https', port: 443 }, { protocolType: 'Http', port: 80 }]
            sourceIpGroups: [buildIpGroup]
            fqdnTags: ['WindowsUpdate', 'WindowsDiagnostics', 'MicrosoftActiveProtectionService']
          }
          {
            // Defender, certificate revocation, Ubuntu repositories, STIG content (stig.ps1, stig-linux.sh).
            ruleType: 'ApplicationRule'
            name: 'build-downloads'
            protocols: [{ protocolType: 'Https', port: 443 }, { protocolType: 'Http', port: 80 }]
            sourceIpGroups: [buildIpGroup]
            targetFqdns: [
              'go.microsoft.com'
              'definitionupdates.microsoft.com'
              'crl.microsoft.com'
              'oneocsp.microsoft.com'
              'www.microsoft.com'
              'ctldl.windowsupdate.com'
              'azure.archive.ubuntu.com'
              'archive.ubuntu.com'
              'security.ubuntu.com'
              'esm.ubuntu.com'
              'download.microsoft.com'
              'dl.dod.cyber.mil'
              'github.com'
              'objects.githubusercontent.com'
              'release-assets.githubusercontent.com'
            ]
          }
        ]
      }
    ]
  }
}

var vnetConfig = {
  subnetId: '${spoke.outputs.vnetId}/subnets/snet-build'
  containerInstanceSubnetId: '${spoke.outputs.vnetId}/subnets/snet-container'
}

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
    vmProfile: { vmSize: buildVmSize, vnetConfig: vnetConfig }
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
              // Run as a file: Packer indents inline lines, which breaks PowerShell here-strings.
              inline: [
                '$s = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\'${base64(loadTextContent('stig.ps1'))}\'))'
                'Set-Content -LiteralPath C:\\Windows\\Temp\\stig.ps1 -Value $s -Encoding UTF8'
                '& C:\\Windows\\Temp\\stig.ps1; exit $LASTEXITCODE'
              ]
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
    vmProfile: { vmSize: buildVmSize, vnetConfig: vnetConfig }
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
