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
}

@export()
@description('Identity and access settings.')
type identityType = {
  @description('Optional. EntraJoined (default) or DomainJoined (AD DS or Entra Domain Services).')
  mode: ('EntraJoined' | 'DomainJoined')?

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

  @description('Optional. Use FSLogix Cloud Cache. Defaults to false.')
  cloudCache: bool?

  @description('Optional. Profile share quota in GiB (premium shares are billed on provisioned size). Defaults to 1024 in prod and 100 in staging.')
  shareQuotaGiB: int?

  @description('Optional. Maximum profile container size in MB. Defaults to 30000.')
  profileSizeInMBs: int?

  @description('Optional. Azure Files identity source. Defaults to AADKERB for EntraJoined and AADDS for DomainJoined. AD needs activeDirectoryProperties from an AD DS storage account join.')
  directoryService: ('AADKERB' | 'AADDS' | 'AD')?

  @description('Optional. Domain properties for AD DS (or hybrid Entra Kerberos) authentication.')
  activeDirectoryProperties: object?
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
}
