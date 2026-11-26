using 'main.bicep'

param userGroupId = '<avd-users-group-object-id>'
param adminGroupId = '<avd-admins-group-object-id>'
param adminPassword = readEnvironmentVariable('AVD_ADMIN_PASSWORD', '')

// Azure Virtual Desktop service principal, for start VM on connect and the scaling plan:
// az ad sp show --id 9cdead84-a844-4324-93f2-b2e6bb768d07 --query id -o tsv
param avdServicePrincipalId = '<avd-service-principal-object-id>'

// Session host image. Empty: Marketplace Windows 11 multi-session + Microsoft 365. For the image
// builder image: az sig image-definition show -g rg-image-builder -r gal_images -i win11-avd --query id -o tsv
param imageId = ''

param hostPool = {
  maxSessionLimit: 10
  loadBalancerType: 'BreadthFirst' // or DepthFirst: fill one host before the next
  startVMOnConnect: true
  // https://learn.microsoft.com/azure/virtual-desktop/rdp-properties
  rdpProperties: [
    'targetisaadjoined:i:1'
    'enablerdsaadauth:i:1'
  ]
  publicNetworkAccess: 'Enabled'
}

param workspace = {
  friendlyName: 'Azure Virtual Desktop' // shown in the Windows App
  publicNetworkAccess: 'Enabled'
}

param sessionHosts = {
  count: 1
  startNumber: 1
  namePrefix: 'avd' // hosts avd<hash>-001...; VMs vm-avd<hash>-001
  // After deleting hosts, set any new text here (e.g. a date) for new names: Entra keeps the old
  // hosts' devices, so a host with a reused name can't join.
  forceNewHost: ''
  vmSize: 'Standard_D4ds_v5'
  osDiskSizeGB: 256 // room for the FSLogix local cache
  osDiskType: 'Premium_LRS'
  acceleratedNetworking: true
  intuneEnrollment: false
  guestAttestation: true
}

// FSLogix profiles. storageType: 'AzureFiles' (SMB share) or 'BlobCloudCache' (page blobs; use it
// with a STIG image, which blocks the saved credential the file share needs).
param fslogix = {
  enabled: true
  storageType: 'AzureFiles'
  sizeInMBs: 30000
  shareQuotaGiB: 100
}

// Scaling plan: hosts start and stop on the schedules below (times in timeZone).
param scalingPlan = {
  enabled: false
  timeZone: 'Eastern Standard Time'
  exclusionTag: '' // hosts with this tag are left alone, e.g. while troubleshooting
  schedules: [
    {
      name: 'weekdays'
      daysOfWeek: ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday']
      rampUpStartTime: { hour: 8, minute: 0 }
      rampUpLoadBalancingAlgorithm: 'BreadthFirst'
      rampUpMinimumHostsPct: 20
      rampUpCapacityThresholdPct: 60
      peakStartTime: { hour: 9, minute: 0 }
      peakLoadBalancingAlgorithm: 'DepthFirst'
      rampDownStartTime: { hour: 18, minute: 0 }
      rampDownLoadBalancingAlgorithm: 'DepthFirst'
      rampDownMinimumHostsPct: 0
      rampDownCapacityThresholdPct: 90
      rampDownForceLogoffUsers: false
      rampDownWaitTimeMinutes: 30
      rampDownNotificationMessage: 'You will be signed out in 30 minutes. Save your work.'
      rampDownStopHostsWhen: 'ZeroActiveSessions'
      offPeakStartTime: { hour: 20, minute: 0 }
      offPeakLoadBalancingAlgorithm: 'DepthFirst'
    }
  ]
}

param diagnostics = true // host pool, application group and workspace logs to law-hub
