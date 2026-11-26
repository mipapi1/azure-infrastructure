// Compute Gallery and Image Builder templates for two images:
//   win11-avd         AVD session hosts: Windows 11 multi-session with Microsoft 365 Apps, fully
//                     patched, optionally STIG-hardened (windowsStig, stig.ps1).
//   ubuntu-2404-stig  Linux VMs: Ubuntu 24.04 LTS, patched and STIG-hardened (stig-linux.sh).
// Builds run in a spoke peered to the hub: the build VM and Image Builder's container (Packer) sit in
// their own subnets and reach the internet only through the hub firewall, which allows the
// endpoints below. Deploy into resource group rg-image-builder after the hub, then run the templates.

// Windows STIG (stig.ps1). Every choice is passed to the script; set them in main.bicepparam.
@description('Apply DISA STIG hardening to the Windows image.')
param windowsStig bool = false
@description('GPO folders from the DISA package, matched as "DoD <name> ...".')
param windowsStigGpos string[] = ['Windows 11', 'Windows Defender Firewall', 'Microsoft Defender Antivirus', 'Microsoft Edge']
@description('Also apply STIG and baseline settings the GPO package does not set (TLS, .NET crypto, DEP, PowerShell 2.0, auditing).')
param windowsStigSupplemental bool = true
@description('DISA STIG GPO package and its SHA256.')
param windowsStigPackage { url: string, sha256: string } = {
  url: 'https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/U_STIG_GPO_Package_October_2026.zip'
  sha256: 'C8A093C0656CCF6D71D98A9556AA37E0F4E31574AC2AAC86F76D7D14355167BA'
}
@description('DISA SCAP Compliance Checker bundle and its SHA256. Empty url: not installed.')
param windowsScc { url: string, sha256: string } = {
  url: 'https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/scc-5.15_Windows_bundle.zip'
  sha256: 'A537A0F9A39CCC2231818709F8BB5F8F9B9CBFC2EC0D44DBBFABBE35D4F558BA'
}

// Ubuntu STIG (stig-linux.sh), always applied to the Linux image.
@description('SCAP Security Guide profile id, e.g. stig or cis_level1_server.')
param linuxStigProfile string = 'stig'
@description('SSG rule ids not applied. Each one is a finding to justify.')
param linuxStigExcludes string[] = ['sudo_remove_nopasswd', 'sudo_require_authentication']
@description('SCAP Security Guide release and the SHA256 of its zip.')
param linuxSsg { version: string, sha256: string } = {
  version: '0.1.82'
  sha256: '765e84bdce7f9055f9b9c2dd0ee2b713d4255f8eec94eac6d35ea4973c28919c'
}
@description('Optional DISA SCC bundle for Linux (a zip with a .deb) and its SHA256. Empty url: not installed.')
param linuxScc { url: string, sha256: string } = { url: '', sha256: '' }

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
            // Image Builder's container mounts a file share from its staging storage account.
            ruleType: 'NetworkRule'
            name: 'container-file-share'
            ipProtocols: ['TCP']
            sourceIpGroups: [containerIpGroup]
            destinationAddresses: ['Storage']
            destinationPorts: ['445']
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

// Arguments for stig.ps1 and environment for stig-linux.sh, built from the parameters above.
var windowsStigArgs = join(
  [
    '-GpoNames @(${join(map(windowsStigGpos, g => '\'${g}\''), ',')})'
    '-PackageUrl \'${windowsStigPackage.url}\''
    '-PackageSha256 \'${windowsStigPackage.sha256}\''
    '-Supplemental $${windowsStigSupplemental}'
    '-SccUrl \'${windowsScc.url}\''
    '-SccSha256 \'${windowsScc.sha256}\''
  ],
  ' '
)
var linuxStigEnv = join(
  [
    'SSG_VERSION=${linuxSsg.version}'
    'SSG_SHA256=${linuxSsg.sha256}'
    'STIG_PROFILE=${linuxStigProfile}'
    'STIG_EXCLUDES="${join(linuxStigExcludes, ' ')}"'
    'SCC_URL="${linuxScc.url}"'
    'SCC_SHA256="${linuxScc.sha256}"'
  ],
  ' '
)

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
      windowsStig
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
                '& C:\\Windows\\Temp\\stig.ps1 ${windowsStigArgs}; exit $LASTEXITCODE'
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
        inline: ['echo ${base64(loadTextContent('stig-linux.sh'))} | base64 -d > /tmp/stig-linux.sh', 'sudo ${linuxStigEnv} bash /tmp/stig-linux.sh']
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
