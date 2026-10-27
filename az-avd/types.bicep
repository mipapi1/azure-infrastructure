metadata name = 'AVD types'
metadata description = 'Parameter types for the Azure Virtual Desktop workload.'

@export()
@description('Spoke network for AVD.')
type avdNetworkType = {
  @description('Required. Spoke address space.')
  addressPrefixes: string[]

  @description('Required. Session host subnet prefix.')
  sessionHostSubnetPrefix: string

  @description('Required. Private endpoint subnet prefix (host pool, workspace, profile storage).')
  privateEndpointSubnetPrefix: string
}

@export()
@description('Host pool settings.')
type hostPoolType = {
  @description('Optional. Pooled (multi-session, default) or Personal (one user per VM).')
  type: ('Pooled' | 'Personal')?

  @description('Optional. BreadthFirst spreads users across hosts; DepthFirst fills one host first. Personal pools always use Persistent. Defaults to BreadthFirst.')
  loadBalancerType: ('BreadthFirst' | 'DepthFirst')?

  @description('Optional. Maximum sessions per host (pooled). Defaults to 12.')
  maxSessionLimit: int?

  @description('Optional. Personal pools: Automatic assigns on first sign-in, Direct needs an admin. Defaults to Automatic.')
  personalDesktopAssignmentType: ('Automatic' | 'Direct')?

  @description('Optional. Receive AVD service updates before other pools. Defaults to true in staging, false in prod.')
  validationEnvironment: bool?

  @description('Optional. Start a deallocated host when a user connects. Defaults to true.')
  startVMOnConnect: bool?

  @description('Optional. RDP properties. Defaults to Entra SSO with drive, printer and USB redirection off.')
  customRdpProperty: string?

  @description('Optional. Friendly name shown in clients.')
  friendlyName: string?

  @description('Optional. Enabled, EnabledForClientsOnly (session hosts use private link, default) or Disabled (clients need private connectivity too).')
  publicNetworkAccess: ('Enabled' | 'EnabledForClientsOnly' | 'EnabledForSessionHostsOnly' | 'Disabled')?
}

@export()
@description('Session host settings.')
type sessionHostsType = {
  @description('Required. Number of hosts.')
  count: int

  @description('Required. Host name prefix, 11 characters or fewer.')
  namePrefix: string

  @description('Optional. First host number. Defaults to 1.')
  startIndex: int?

  @description('Required. VM size.')
  vmSize: string

  @description('Optional. Availability zones. Defaults to 1, 2, 3 in prod and none in staging.')
  availabilityZones: int[]?

  @description('Optional. OS disk SKU. Defaults to Premium_LRS.')
  osDiskType: ('Premium_LRS' | 'Premium_ZRS' | 'StandardSSD_LRS' | 'StandardSSD_ZRS')?

  @description('Optional. OS disk size in GB. Defaults to 128.')
  osDiskSizeGB: int?

  @description('Optional. Marketplace image. Defaults to Windows 11 Enterprise multi-session 25H2.')
  marketplaceImage: {
    publisher: string
    offer: string
    sku: string
    version: string?
  }?

  @description('Optional. Compute Gallery image or version resource ID (az-image-builder output). Overrides marketplaceImage.')
  galleryImageResourceId: string?

  @description('Required. Local administrator name.')
  adminUsername: string

  @description('Optional. Resource ID of a disk encryption set for customer-managed keys.')
  diskEncryptionSetResourceId: string?

  @description('Optional. Run the deferred STIG step baked into az-image-builder images (Apply-DeferredStigs.ps1 -Phase Deploy) after registration and FSLogix. Defaults to true when galleryImageResourceId is set; set false for gallery images built without the STIG package.')
  applyDeferredStigs: bool?

  @description('Optional. With applyDeferredStigs, disable every local administrator (V-253432). localAdmin.breakGlass keeps one LAPS-managed account enabled. Defaults to true.')
  disableLocalAdministrators: bool?

  @description('Optional. Install the Guest Attestation extension (boot integrity monitoring). Adds a firewall rule to the AzureAttestation service tag. Defaults to true.')
  guestAttestation: bool?
}

@export()
@description('Identity and access settings.')
type identityType = {
  @description('Optional. EntraJoined (default) or DomainJoined (AD DS or Entra Domain Services).')
  mode: ('EntraJoined' | 'DomainJoined')?

  @description('Optional. Where user accounts are mastered. Hybrid (default): synced from AD DS. CloudOnly: created in Microsoft Entra ID only; requires mode EntraJoined, and Azure Files profile storage needs the Azure public cloud.')
  userIdentitySource: ('Hybrid' | 'CloudOnly')?

  @description('Optional. Enroll Entra-joined hosts in Intune. Defaults to false.')
  intuneEnrollment: bool?

  @description('Conditional. Domain join settings. Required for DomainJoined.')
  domainJoin: {
    domainName: string
    ouPath: string?
    user: string
  }?

  @description('Required. Entra group object IDs of users: application group access, VM user login and profile share access.')
  userGroupObjectIds: string[]

  @description('Optional. Entra group object IDs of administrators: VM administrator login and elevated profile share access.')
  adminGroupObjectIds: string[]?

  @description('Optional. Object ID of the Azure Virtual Desktop service principal in this tenant (application ID 9cdead84-a844-4324-93f2-b2e6bb768d07). Required for scaling plans and start VM on connect.')
  avdServicePrincipalObjectId: string?
}

@export()
@description('FSLogix profile storage and configuration.')
type fslogixType = {
  @description('Optional. Deploy profile storage and configure FSLogix. Defaults to true.')
  enabled: bool?

  @description('Optional. RunCommand (default) configures hosts during deployment; None leaves configuration to Intune or Group Policy.')
  configurationMethod: ('RunCommand' | 'None')?

  @description('Optional. AzureFiles (default): premium file share with identity-based (Kerberos) access. BlobCloudCache: Cloud Cache on a blob storage account with an account key stored on each host; no Kerberos, works in every cloud, but needs shared key access.')
  storageType: ('AzureFiles' | 'BlobCloudCache')?

  @description('Optional. BlobCloudCache only: storage account key the hosts use. Switch to the other key, redeploy, then regenerate the old one to rotate. Defaults to key1.')
  blobKeyName: ('key1' | 'key2')?

  @description('Optional. AzureFiles only: use FSLogix Cloud Cache over SMB. BlobCloudCache always uses Cloud Cache. Defaults to false.')
  cloudCache: bool?

  @description('Optional. Profile share quota in GiB (premium shares are billed on provisioned size). Defaults to 1024 in prod and 100 in staging.')
  shareQuotaGiB: int?

  @description('Optional. Maximum profile container size in MB. Defaults to 30000.')
  profileSizeInMBs: int?

  @description('Optional. AzureFiles only: identity source. Defaults to AADKERB for EntraJoined and AADDS for DomainJoined. AD needs activeDirectoryProperties from an AD DS storage account join. CloudOnly users require AADKERB.')
  directoryService: ('AADKERB' | 'AADDS' | 'AD')?

  @description('Optional. AzureFiles only: domain properties for AD DS (or hybrid Entra Kerberos) authentication. Ignored for CloudOnly users.')
  activeDirectoryProperties: object?
}

@export()
@description('Local administrator settings.')
type localAdminType = {
  @description('Optional. One Windows LAPS-managed break-glass administrator per host. Off by default.')
  breakGlass: {
    @description('Required. Configure the break-glass account.')
    enabled: bool

    @description('Optional. RunCommand writes the Windows LAPS Local Configuration registry root during deployment (for hosts without Intune or Group Policy LAPS). Intune: deploy an Intune LAPS policy instead (see README); nothing is written to the hosts. Defaults to Intune when identity.intuneEnrollment is true, otherwise RunCommand.')
    configurationMethod: ('RunCommand' | 'Intune')?

    @description('Optional. Managed account name, 20 characters or fewer. Defaults to WLapsAdmin.')
    @maxLength(20)
    accountName: string?

    @description('Optional. EntraID (Entra-joined or hybrid-joined hosts) or ActiveDirectory (AD DS-joined hosts). Defaults to EntraID for EntraJoined and ActiveDirectory for DomainJoined.')
    backupDirectory: ('EntraID' | 'ActiveDirectory')?

    @description('Optional. Maximum password age in days, 7-365. Defaults to 30.')
    @minValue(7)
    @maxValue(365)
    passwordAgeDays: int?

    @description('Optional. Password length, 14-64. Defaults to 20.')
    @minValue(14)
    @maxValue(64)
    passwordLength: int?

    @description('Optional. Hours after the account signs in before LAPS resets the password and signs it out, 1-24. Defaults to 8.')
    @minValue(1)
    @maxValue(24)
    postAuthenticationResetDelayHours: int?
  }?
}

@export()
@description('Compliance evidence and security event collection.')
type complianceType = {
  @description('Optional. Daily evidence task on each host (deferred STIG step, registry and security template settings, AppLocker, Defender, optional SCAP) sent to the AvdComplianceEvidence_CL table, with a workbook. Needs monitoring.dataCollectionEndpointResourceId. Defaults to false.')
  evidence: bool?

  @description('Optional. Forward AppLocker and Microsoft Defender Antivirus events to the Event table. Defaults to false.')
  securityEvents: bool?

  @description('Optional. Local time of the daily evidence run, HH:mm. Defaults to 03:00.')
  dailyAt: string?

  @description('Optional. SCAP scanner executable on the image, run before the evidence is written. Bring your own scanner; none is installed by this repo.')
  scapCommand: string?

  @description('Optional. Arguments for the SCAP scanner.')
  scapArguments: string?

  @description('Optional. Folder the SCAP scanner writes XCCDF results to; the newest XML file is parsed.')
  scapResultsPath: string?
}

@export()
@description('Application group.')
type applicationGroupType = {
  @description('Required. Short name, used as the name suffix.')
  name: string

  @description('Required. Desktop or RemoteApp.')
  type: 'Desktop' | 'RemoteApp'

  @description('Optional. Friendly name in clients.')
  friendlyName: string?

  @description('Optional. Entra groups assigned to this group. Defaults to identity.userGroupObjectIds.')
  assignedGroupObjectIds: string[]?

  @description('Optional. RemoteApp applications, in the application group AVM schema.')
  applications: object[]?
}

@export()
@description('Scaling schedule (one ramp-up/peak/ramp-down/off-peak cycle).')
type scalingScheduleType = {
  @description('Required. Days this schedule applies to.')
  daysOfWeek: ('Monday' | 'Tuesday' | 'Wednesday' | 'Thursday' | 'Friday' | 'Saturday' | 'Sunday')[]

  @description('Required. Ramp-up start, HH:mm.')
  rampUpStart: string

  @description('Required. Peak start, HH:mm.')
  peakStart: string

  @description('Required. Ramp-down start, HH:mm.')
  rampDownStart: string

  @description('Required. Off-peak start, HH:mm.')
  offPeakStart: string

  @description('Optional. Minimum percentage of hosts on during ramp-up. Defaults to 20.')
  rampUpMinimumHostsPct: int?

  @description('Optional. Capacity threshold that triggers more hosts during ramp-up and peak. Defaults to 60.')
  capacityThresholdPct: int?

  @description('Optional. Minimum percentage of hosts on during ramp-down. Defaults to 10.')
  rampDownMinimumHostsPct: int?
}

@export()
@description('Scaling plan settings (pooled host pools).')
type scalingType = {
  @description('Optional. Deploy a scaling plan. Defaults to true for pooled host pools.')
  enabled: bool?

  @description('Optional. Windows time zone name. Defaults to UTC.')
  timeZone: string?

  @description('Optional. Hosts with this tag are left alone by the scaling plan. Defaults to scaling-exclude.')
  exclusionTag: string?

  @description('Optional. Schedules. Defaults to a weekday business-hours schedule and a weekend schedule.')
  schedules: scalingScheduleType[]?

  @description('Optional. Turn the scaling plan off for the host pool while session hosts deploy and back on afterwards, so it does not stop or drain hosts mid-deployment. Defaults to true.')
  pauseDuringDeployment: bool?
}
