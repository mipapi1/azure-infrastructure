// Image Builder: one image per deployment, described by its own param file in images/.
// Each deployment creates or updates the shared parts (spoke, storage, identities, gallery) and
// its own gallery image definition and template, named after the image:
//   images/win11-avd.bicepparam         gallery definition win11-avd, template it-win11-avd
//   images/ubuntu-2404-stig.bicepparam  gallery definition ubuntu-2404-stig, template it-ubuntu-2404-stig
// Builds run in a spoke peered to the hub: the build VM and Image Builder's container (Packer) sit in
// their own subnets and reach the internet only through the hub firewall, which allows the
// endpoints below. Scripts and installers come from this stack's storage account over a private
// endpoint: publish.sh downloads every installer, checks its SHA256 and uploads it with the
// scripts; the first build step (bootstrap.ps1 / bootstrap.sh) downloads them with the build VM's
// identity and checks every hash again.
// Deploy into resource group rg-image-builder after the hub, run publish.sh, then run the template.

@description('A downloadable file and its SHA256. Empty url: none.')
type download = { url: string, sha256: string }

@description('An app: an install script in image-builder/apps/ and its installer.')
type app = { script: string, installer: download }

@description('''The image to build. name is used for the gallery definition and the template (it-<name>).
source is a Marketplace image: az vm image list-skus -l <region> -p <publisher> -f <offer> -o table.''')
param image {
  name: string
  os: ('Windows' | 'Linux')
  source: { publisher: string, offer: string, sku: string, version: string }
}

@description('Apps installed before the STIG step. Windows scripts get the installer path as $args[0]; Linux scripts run as root and get it as $1.')
param apps app[] = []

@description('Apply STIG hardening: the DISA GPO package on Windows (stig.ps1), the SCAP Security Guide on Linux (stig-linux.sh).')
param stig bool = false

// Windows STIG. The defaults are pinned here, so image param files only override what they need.
@description('GPO folders from the DISA package, matched as "DoD <name> ...".')
param windowsStigGpos string[] = ['Windows 11', 'Windows Defender Firewall', 'Microsoft Defender Antivirus', 'Microsoft Edge']
@description('Also apply STIG and baseline settings the GPO package does not set (TLS, .NET crypto, DEP, PowerShell 2.0, auditing).')
param windowsStigSupplemental bool = true
@description('DISA STIG GPO package. Download: https://public.cyber.mil/stigs/gpo/')
param windowsStigPackage download = {
  url: 'https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/U_STIG_GPO_Package_October_2026.zip'
  sha256: 'C8A093C0656CCF6D71D98A9556AA37E0F4E31574AC2AAC86F76D7D14355167BA'
}
@description('Microsoft LGPO, which imports the GPOs. Download: https://www.microsoft.com/download/details.aspx?id=55319')
param windowsLgpo download = {
  url: 'https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip'
  sha256: 'CB7159D134A0A1E7B1ED2ADA9A3CE8CE8F4DE391D14403D55438AF824247CC55'
}
@description('DISA SCAP Compliance Checker, installed for scans. Download: https://public.cyber.mil/stigs/scap/')
param windowsScc download = {
  url: 'https://dl.dod.cyber.mil/wp-content/uploads/stigs/zip/scc-5.15_Windows_bundle.zip'
  sha256: 'A537A0F9A39CCC2231818709F8BB5F8F9B9CBFC2EC0D44DBBFABBE35D4F558BA'
}

// Linux STIG (Ubuntu).
@description('SCAP Security Guide profile id, e.g. stig or cis_level1_server.')
param linuxStigProfile string = 'stig'
@description('SSG rule ids not applied. Each one is a finding; stig-linux.sh explains the defaults.')
param linuxStigExcludes string[] = ['sudo_remove_nopasswd', 'sudo_require_authentication']
@description('SCAP Security Guide release. Download: https://github.com/ComplianceAsCode/content/releases')
param linuxSsg download = {
  url: 'https://github.com/ComplianceAsCode/content/releases/download/v0.1.82/scap-security-guide-0.1.82.zip'
  sha256: '765e84bdce7f9055f9b9c2dd0ee2b713d4255f8eec94eac6d35ea4973c28919c'
}
@description('DISA SCC for Linux (a zip with a .deb). The download needs a DoD login, so host it yourself.')
param linuxScc download = { url: '', sha256: '' }

@description('Object IDs allowed to publish scripts and installers (Storage Blob Data Contributor).')
param publisherIds string[] = []
@description('Build VM size. Two builds at 2 vCPUs each fit a 4 vCPU regional quota.')
param buildVmSize string = 'Standard_D2s_v5'
param buildTimeoutInMinutes int = 240
param location string = resourceGroup().location

var buildPrefix = '10.4.0.0/25'
var containerPrefix = '10.4.0.128/27'
var endpointPrefix = '10.4.0.160/27'
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
      { name: 'snet-pe', addressPrefix: endpointPrefix }
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
            // Defender, certificate revocation, Ubuntu repositories. Scripts and installers come from
            // the storage account's private endpoint, not the internet.
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
            ]
          }
        ]
      }
    ]
  }
}

// Files the bootstrap step downloads from storage and checks. Installers are stored under their
// file name (publish.sh); script hashes come from scripts.json (publish.sh writes it).
var windows = image.os == 'Windows'
var scripts = loadJsonContent('scripts.json')
var blob = contentStorage.properties.primaryEndpoints.blob
var dir = windows ? 'C:\\BuildArtifacts' : '/var/tmp/build'
var sep = windows ? '\\' : '/'
var stigScript = windows ? 'stig.ps1' : 'stig-linux.sh'
var stigInstallers = windows ? [windowsStigPackage, windowsLgpo, windowsScc] : [linuxSsg, linuxScc]
func fileName(url string) string => last(split(url, '/'))
func localPath(url string, root string, sep string) string => empty(url) ? '' : '${root}${sep}installers${sep}${last(split(url, '/'))}'

var files = concat(
  stig ? [{ uri: '${blob}scripts/${stigScript}', sha256: scripts[stigScript], path: '${dir}${sep}scripts${sep}${stigScript}' }] : [],
  map(apps, a => {
    uri: '${blob}scripts/apps/${a.script}'
    sha256: scripts['apps/${a.script}']
    path: '${dir}${sep}scripts${sep}apps${sep}${a.script}'
  }),
  map(filter(concat(stig ? stigInstallers : [], map(apps, a => a.installer)), i => !empty(i.url)), i => {
    uri: '${blob}installers/${fileName(i.url)}'
    sha256: i.sha256
    path: localPath(i.url, dir, sep)
  })
)
var bootstrap = !empty(files)

// Arguments for stig.ps1 and environment for stig-linux.sh, built from the parameters above.
var windowsStigArgs = join(
  [
    '-GpoNames @(${join(map(windowsStigGpos, g => '\'${g}\''), ',')})'
    '-PackagePath \'${localPath(windowsStigPackage.url, dir, sep)}\''
    '-LgpoPath \'${localPath(windowsLgpo.url, dir, sep)}\''
    '-Supplemental $${windowsStigSupplemental}'
    '-SccPath \'${localPath(windowsScc.url, dir, sep)}\''
  ],
  ' '
)
var linuxStigEnv = join(
  [
    'SSG_ZIP=${localPath(linuxSsg.url, dir, sep)}'
    'STIG_PROFILE=${linuxStigProfile}'
    'STIG_EXCLUDES="${join(linuxStigExcludes, ' ')}"'
    'SCC_ZIP="${localPath(linuxScc.url, dir, sep)}"'
  ],
  ' '
)

// Build steps: OS updates, bootstrap, apps, STIG, cleanup.
var windowsSteps = concat(
  [
    { type: 'WindowsUpdate', name: 'windows-update' }
    { type: 'WindowsRestart', name: 'restart' }
  ],
  bootstrap
    ? [
        {
          type: 'PowerShell'
          name: 'bootstrap'
          runElevated: true
          runAsSystem: true
          // Written to a file and run: Packer indents inline lines, which breaks some PowerShell.
          inline: [
            '$s = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\'${base64(loadTextContent('bootstrap.ps1'))}\'))'
            'Set-Content -LiteralPath C:\\Windows\\Temp\\bootstrap.ps1 -Value $s -Encoding UTF8'
            '& C:\\Windows\\Temp\\bootstrap.ps1 -FilesBase64 \'${base64(string(files))}\' -ClientId \'${buildIdentity.properties.clientId}\'; exit $LASTEXITCODE'
          ]
        }
      ]
    : [],
  map(apps, a => {
    type: 'PowerShell'
    name: 'app-${a.script}'
    runElevated: true
    runAsSystem: true
    inline: ['& ${dir}\\scripts\\apps\\${a.script} \'${localPath(a.installer.url, dir, sep)}\'; exit $LASTEXITCODE']
  }),
  stig
    ? [
        {
          type: 'PowerShell'
          name: 'stig'
          runElevated: true
          runAsSystem: true
          inline: ['& ${dir}\\scripts\\stig.ps1 ${windowsStigArgs}; exit $LASTEXITCODE']
        }
      ]
    : [],
  bootstrap ? [{ type: 'PowerShell', name: 'cleanup', inline: ['Remove-Item -LiteralPath ${dir} -Recurse -Force -ErrorAction SilentlyContinue'] }] : []
)
var linuxSteps = concat(
  [
    {
      type: 'Shell'
      name: 'update'
      inline: ['sudo DEBIAN_FRONTEND=noninteractive apt-get update -q', 'sudo DEBIAN_FRONTEND=noninteractive apt-get -y -q dist-upgrade']
    }
  ],
  bootstrap
    ? [
        {
          type: 'Shell'
          name: 'bootstrap'
          inline: [
            'echo ${base64(loadTextContent('bootstrap.sh'))} | base64 -d > /tmp/bootstrap.sh'
            'sudo bash /tmp/bootstrap.sh ${buildIdentity.properties.clientId} ${base64(join(map(files, f => '${f.uri} ${f.sha256} ${f.path}'), '\n'))}'
          ]
        }
      ]
    : [],
  map(apps, a => {
    type: 'Shell'
    name: 'app-${a.script}'
    inline: ['sudo bash ${dir}/scripts/apps/${a.script} ${localPath(a.installer.url, dir, sep)}']
  }),
  stig ? [{ type: 'Shell', name: 'stig', inline: ['sudo ${linuxStigEnv} bash ${dir}/scripts/stig-linux.sh'] }] : [],
  bootstrap ? [{ type: 'Shell', name: 'cleanup', inline: ['sudo rm -rf ${dir}'] }] : []
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

// The build VM reads scripts and installers from storage with this identity.
resource buildIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'id-image-builder-vm'
  location: location
}

// Scripts and installers. No shared keys or anonymous access; the firewall denies by default and
// publish.sh allows the publisher's IP only while it runs. Builds read over the private endpoint.
resource contentStorage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: 'stimagebuilder${take(uniqueString(subscription().id), 6)}'
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    networkAcls: { defaultAction: 'Deny', bypass: 'AzureServices' }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: contentStorage
  name: 'default'
}

resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = [
  for c in ['scripts', 'installers']: {
    parent: blobService
    name: c
  }
]

var blobReader = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
var blobContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')

resource buildRead 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(contentStorage.id, buildIdentity.id, blobReader)
  scope: contentStorage
  properties: {
    principalId: buildIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: blobReader
  }
}

resource publishers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for id in publisherIds: {
    name: guid(contentStorage.id, id, blobContributor)
    scope: contentStorage
    properties: {
      principalId: id
      roleDefinitionId: blobContributor
    }
  }
]

module blobZone '../modules/dns-zone.bicep' = {
  name: 'dns-blob'
  scope: resourceGroup('rg-hub')
  params: {
    name: 'privatelink.blob.${environment().suffixes.storage}'
  }
}

resource storageEndpoint 'Microsoft.Network/privateEndpoints@2025-07-01' = {
  name: 'pe-image-builder-blob'
  location: location
  properties: {
    subnet: { id: '${spoke.outputs.vnetId}/subnets/snet-pe' }
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: {
          privateLinkServiceId: contentStorage.id
          groupIds: ['blob']
        }
      }
    ]
  }
}

resource storageDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2025-07-01' = {
  parent: storageEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'blob', properties: { privateDnsZoneId: blobZone.outputs.id } }
    ]
  }
}

resource gallery 'Microsoft.Compute/galleries@2024-03-03' = {
  name: 'gal_images'
  location: location
}

resource definition 'Microsoft.Compute/galleries/images@2024-03-03' = {
  parent: gallery
  name: image.name
  location: location
  properties: {
    osType: image.os
    osState: 'Generalized'
    hyperVGeneration: 'V2'
    features: [{ name: 'SecurityType', value: 'TrustedLaunch' }]
    identifier: {
      publisher: 'platform'
      offer: toLower(image.os)
      sku: image.name
    }
  }
}

resource template 'Microsoft.VirtualMachineImages/imageTemplates@2024-02-01' = {
  name: 'it-${image.name}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    buildTimeoutInMinutes: buildTimeoutInMinutes
    vmProfile: { vmSize: buildVmSize, vnetConfig: vnetConfig, userAssignedIdentities: [buildIdentity.id] }
    source: union({ type: 'PlatformImage' }, image.source)
    customize: windows ? windowsSteps : linuxSteps
    distribute: [
      {
        type: 'SharedImage'
        galleryImageId: definition.id
        runOutputName: image.name
        replicationRegions: [location]
      }
    ]
  }
  dependsOn: [identityAccess, buildRead, storageDns]
}
