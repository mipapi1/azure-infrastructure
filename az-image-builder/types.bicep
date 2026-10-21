////////////////////////////////////////////////////////////////////
// Shared types: the landing zone outputs a landingZoneReference; //
// the workload takes it as input.                                //
////////////////////////////////////////////////////////////////////

@export()
@description('Where the landing zone resources are. Output by landing-zone/main.bicep (output landingZone).')
type landingZoneReference = {
  @description('Subscription of the landing zone. Default: the deployment subscription.')
  subscriptionId: string?

  @description('Resource group holding the network, storage account and identities.')
  resourceGroupName: string

  @description('Region of the landing zone. Image templates must be in the same region as the VNet.')
  location: string

  virtualNetworkName: string
  buildSubnetName: string
  containerInstanceSubnetName: string

  @description('Storage account with the scripts and installers containers.')
  storageAccountName: string

  @description('Identity the image templates run as (gallery write, subnet join).')
  templateIdentityName: string

  @description('Identity attached to the build VM (blob read on scripts and installers).')
  buildVmIdentityName: string

  gallery: galleryReference
}

@export()
type galleryReference = {
  @description('Default: the landing zone subscription.')
  subscriptionId: string?
  resourceGroupName: string
  name: string
}

@export()
@description('A principal granted access to a resource.')
type principal = {
  principalId: string
  principalType: ('User' | 'Group' | 'ServicePrincipal')?
}

///////////////////////////////////////////////////////////////
// Image configuration: one image template per imageConfig.  //
///////////////////////////////////////////////////////////////

@export()
@description('One image: source, gallery definition, software, hardening and distribution.')
type imageConfig = {
  @description('Image template name prefix. Deployed as <name>-<yyyyMMddHHmmss> (templates are immutable).')
  @maxLength(40)
  name: string

  @description('Operating system. Selects the bootstrap, scripts and STIG content. Linux version comes from source.')
  os: 'win11' | 'ws2022' | 'ws2025' | 'ubuntu' | 'rhel'

  source: imageSource

  definition: imageDefinition

  build: buildSettings?

  @description('OS updates before the software installs. Default: enabled.')
  updates: {
    enabled: bool?
    @description('Windows: updates per Windows Update pass. Default: 20.')
    updateLimit: int?
  }?

  @description('artifacts.json groups to download before the software steps. Hardening and Chrome groups are added automatically.')
  artifactGroups: string[]?

  @description('Install steps, in order. Each runs a script from workload/scripts as root/SYSTEM.')
  software: softwareStep[]?

  @description('Raw Image Builder customizers (PowerShell, Shell, File, WindowsRestart, ...), run after software and before hardening.')
  customizers: object[]?

  hardening: hardeningSettings?

  distribution: distributionSettings?

  @description('Tags on the image template, merged with the deployment tags.')
  tags: object?
}

@export()
@discriminator('type')
type imageSource = platformImageSource | galleryImageSource

@description('Marketplace image. List SKUs: az vm image list-skus -l <region> -p <publisher> -f <offer> -o table')
type platformImageSource = {
  type: 'PlatformImage'
  publisher: string
  offer: string
  sku: string
  @description('Default: latest.')
  version: string?
}

@description('Compute gallery image version (or image definition, for its latest version).')
type galleryImageSource = {
  type: 'SharedImageVersion'
  imageVersionId: string
}

@export()
type imageDefinition = {
  @description('Gallery image definition name.')
  name: string
  publisher: string
  offer: string
  sku: string
  description: string?
  @description('Default: TrustedLaunch. Must match the source image (Gen2; TrustedLaunchSupported sources need TrustedLaunchSupported).')
  securityType: ('TrustedLaunch' | 'TrustedLaunchSupported' | 'Standard')?
  @description('Create or update the definition with this deployment. Default: true. Features can be added later but never removed.')
  create: bool?
}

@export()
type buildSettings = {
  @description('Default: Standard_D4ds_v5.')
  vmSize: string?
  @description('Default: 127 (Windows), source disk size (Linux).')
  osDiskSizeGB: int?
  @description('Default: 240.')
  timeoutInMinutes: int?
  @description('abort keeps the build VM after a failure for troubleshooting; cleanup deletes it. Default: cleanup.')
  onError: ('abort' | 'cleanup')?
}

@export()
type softwareStep = {
  @description('Customizer name shown in the build log.')
  name: string
  @description('Script path relative to workload/scripts, e.g. windows/software/installGit.ps1 or linux/software/install-packages.sh.')
  script: string
  @description('Arguments passed to the script as written, e.g. "-Version 2.1" or "jq unzip".')
  arguments: string?
  @description('Windows only: restart the build VM after this step. Default: false.')
  restartAfter: bool?
}

@export()
type hardeningSettings = {
  @description('STIG hardening. Default: true.')
  enabled: bool?

  // Linux

  @description('Linux: SCAP Security Guide profile. Default: stig. Others, e.g. stig_gui (RHEL), cis_level1_server (Ubuntu).')
  stigProfile: string?

  @description('Linux: extra rule IDs to skip, on top of scripts/linux/stig/exceptions. Document each one.')
  excludeRules: string[]?

  @description('Linux: OpenSCAP compliance scan after hardening (/var/log/image-compliance). Default: true.')
  scan: bool?

  // Windows

  @description('Windows: Standard = developer friendly (AppLocker scripts/MSI audit-only, dev tools allowed); Restricted = locked down. Default: Restricted.')
  profile: ('Standard' | 'Restricted')?

  @description('Windows: browsers to install (chrome) and harden with their STIG. Default: [edge] (none on ws2022).')
  browsers: ('edge' | 'chrome')[]?

  @description('Windows: extra DISA GPO folders, by name without "DoD " and version, e.g. "Office 2019-M365 Apps".')
  additionalStigPackages: string[]?

  @description('Windows: AppLocker policy. Default: true.')
  appLocker: bool?

  @description('Windows: extra folders everyone may run code from (no trailing \\*).')
  appLockerAllowedFolders: string[]?

  @description('Windows: let Administrators run browsers, Outlook, Teams and OneDrive. Default: false (STIG).')
  allowAdminsToBrowse: bool?

  @description('Windows: disconnected session sign-out, \'\' = none or e.g. \'90m\', \'8h\'. Default: \'\'.')
  disconnectedSessionLimit: string?

  @description('Windows: logon banner. Default: the DISA banner from the STIG package.')
  legalNotice: {
    caption: string
    text: string
  }?

  @description('Windows: NTP server. Default: Azure host time sync.')
  ntpServer: string?

  @description('Windows: sites allowed to open pop-ups in Edge and Chrome, e.g. [*.]contoso.com.')
  allowedPopups: string[]?
}

@export()
type distributionSettings = {
  @description('Gallery replication regions. Default: the landing zone region, 1 replica, Standard_LRS.')
  regions: {
    name: string
    replicaCount: int?
    storageAccountType: ('Standard_LRS' | 'Standard_ZRS' | 'Premium_LRS')?
  }[]?
  @description('Keep the new version out of "latest" (e.g. a test build). Default: false.')
  excludeFromLatest: bool?
}
