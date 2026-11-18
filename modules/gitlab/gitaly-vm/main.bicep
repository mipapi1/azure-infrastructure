metadata name = 'Gitaly VM'
metadata description = 'Standalone Gitaly server for GitLab on AKS: Ubuntu VM with a premium repository disk, Entra ID SSH sign-in, Azure Monitor Agent, and the GitLab Linux package configured as Gitaly only by a managed run command.'

@description('Required. VM name.')
param name string

@description('Optional. Location.')
param location string = resourceGroup().location

@description('Required. Subnet for the VM NIC.')
param subnetResourceId string

@description('Required. Static private IP in the subnet. The chart points at it (Helm values in Git), so it must not change.')
param privateIp string

@description('Optional. VM size.')
param vmSize string = 'Standard_D4ds_v5'

@description('Optional. Availability zone, -1 for none.')
param zone (-1 | 1 | 2 | 3) = -1

@description('Optional. Repository disk size in GB.')
param diskSizeGB int = 256

@description('Required. SSH public key of the break-glass admin account.')
param adminSshPublicKey string

@description('Optional. Break-glass admin user name.')
param adminUsername string = 'gitalyadmin'

@description('Required. gitlab-ee package version, for example 19.4.3-ee.0. Must match the chart\'s GitLab version.')
param packageVersion string

@description('Required. GitLab URL that Gitaly calls back on (https://<gitlab host>).')
param internalApiUrl string

@description('Optional. PEM CA certificate that signs the GitLab certificate, when it is not publicly trusted.')
param trustedCaPem string = ''

@description('Required. Gitaly authentication token (shared with the chart through Key Vault).')
@secure()
param gitalyAuthToken string

@description('Required. GitLab Shell secret (shared with the chart through Key Vault).')
@secure()
param gitlabShellSecret string

@description('Optional. Data collection rules to associate (Linux VM insights or syslog).')
param dataCollectionRuleResourceIds string[] = []

@description('Optional. Lock.')
param lock object?

@description('Optional. Tags.')
param tags object = {}

@description('Optional. Enable AVM usage telemetry.')
param enableTelemetry bool = true

var dataDiskLun = 0

module virtualMachine 'br/public:avm/res/compute/virtual-machine:0.22.3' = {
  name: '${uniqueString(deployment().name, location)}-${name}'
  params: {
    name: name
    location: location
    osType: 'Linux'
    vmSize: vmSize
    availabilityZone: zone
    imageReference: {
      publisher: 'Canonical'
      offer: 'ubuntu-24_04-lts'
      sku: 'server'
      version: 'latest'
    }
    securityType: 'TrustedLaunch'
    secureBootEnabled: true
    vTpmEnabled: true
    encryptionAtHost: true
    osDisk: {
      caching: 'ReadWrite'
      deleteOption: 'Delete'
      diskSizeGB: 64
      managedDisk: { storageAccountType: 'Premium_LRS' }
    }
    // The repository disk outlives the VM: rebuilding the VM reattaches nothing automatically,
    // but deleting the VM never deletes repositories.
    dataDisks: [
      {
        name: '${name}-repositories'
        lun: dataDiskLun
        diskSizeGB: diskSizeGB
        caching: 'None'
        createOption: 'Empty'
        deleteOption: 'Detach'
        managedDisk: { storageAccountType: zone == -1 ? 'Premium_LRS' : 'Premium_ZRS' }
      }
    ]
    adminUsername: adminUsername
    disablePasswordAuthentication: true
    publicKeys: [
      {
        keyData: adminSshPublicKey
        path: '/home/${adminUsername}/.ssh/authorized_keys'
      }
    ]
    managedIdentities: { systemAssigned: true }
    bootDiagnostics: true
    patchMode: 'AutomaticByPlatform'
    nicConfigurations: [
      {
        nicSuffix: '-nic'
        deleteOption: 'Delete'
        enableAcceleratedNetworking: true
        ipConfigurations: [
          {
            name: 'ipconfig1'
            subnetResourceId: subnetResourceId
            privateIPAllocationMethod: 'Static'
            privateIPAddress: privateIp
          }
        ]
      }
    ]
    // Entra ID SSH sign-in (Virtual Machine Administrator/User Login roles), so the key above
    // is only for break-glass.
    extensionAadJoinConfig: { enabled: true }
    extensionMonitoringAgentConfig: {
      enabled: true
      dataCollectionRuleAssociations: [
        for (dcr, d) in dataCollectionRuleResourceIds: {
          name: 'dcra-${d}-${last(split(dcr, '/'))}'
          dataCollectionRuleResourceId: dcr
        }
      ]
    }
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2025-04-01' existing = {
  name: name
}

resource configureGitaly 'Microsoft.Compute/virtualMachines/runCommands@2025-04-01' = {
  parent: vm
  name: 'configure-gitaly'
  location: location
  tags: tags
  properties: {
    asyncExecution: false
    treatFailureAsDeploymentFailure: true
    timeoutInSeconds: 1800
    source: {
      script: loadTextContent('scripts/configure-gitaly.sh')
    }
    parameters: [
      { name: 'PACKAGE_VERSION', value: packageVersion }
      { name: 'INTERNAL_API_URL', value: internalApiUrl }
      { name: 'DISK_LUN', value: string(dataDiskLun) }
      { name: 'TRUSTED_CA_PEM', value: trustedCaPem }
    ]
    protectedParameters: [
      { name: 'GITALY_TOKEN', value: gitalyAuthToken }
      { name: 'SHELL_SECRET', value: gitlabShellSecret }
    ]
  }
  dependsOn: [virtualMachine]
}

@description('Resource ID of the VM.')
output resourceId string = virtualMachine.outputs.resourceId

@description('Name of the VM.')
output name string = virtualMachine.outputs.name

@description('Private IP address of the VM (the Gitaly address for the chart).')
output privateIp string = privateIp
