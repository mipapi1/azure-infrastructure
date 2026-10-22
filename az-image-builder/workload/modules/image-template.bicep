// Azure Image Builder template: isolated build in existing subnets, SharedImage distribution.
// Not the AVM module: it always sends vnetConfig.proxyVmSize, which isolated builds reject.

@description('Template name prefix; the deployed name is <name>-<baseTime>')
param name string

param baseTime string

@description('Azure region (same as the VNet)')
param location string

param tags object = {}

param vmSize string
param osDiskSizeGB int

@description('Subnet for the build VM')
param subnetResourceId string

@description('Subnet delegated to Microsoft.ContainerInstance/containerGroups')
param containerInstanceSubnetResourceId string

@description('Empty = Image Builder creates and deletes its own staging resource group')
param stagingResourceGroupResourceId string = ''

param imageSource object

param customizationSteps array

@description('Image template (Azure Image Builder service) identity')
param templateIdentityResourceId string

@description('Identities attached to the build VM')
param vmUserAssignedIdentities string[] = []

param galleryImageDefinitionResourceId string

@description('[{ name, replicaCount?, storageAccountType? }]')
param targetRegions array

param excludeFromLatest bool = false

param artifactTags object = {}

@allowed(['cleanup', 'abort'])
param onError string = 'cleanup'

@description('0 = service default (240 minutes)')
param buildTimeoutInMinutes int = 0

resource imageTemplate 'Microsoft.VirtualMachineImages/imageTemplates@2025-10-01' = {
  #disable-next-line use-stable-resource-identifiers // templates are immutable; every deploy gets a new name
  name: '${name}-${baseTime}'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${templateIdentityResourceId}': {}
    }
  }
  properties: {
    buildTimeoutInMinutes: buildTimeoutInMinutes
    vmProfile: {
      vmSize: vmSize
      osDiskSizeGB: osDiskSizeGB
      userAssignedIdentities: vmUserAssignedIdentities
      vnetConfig: {
        subnetId: subnetResourceId
        containerInstanceSubnetId: containerInstanceSubnetResourceId
        // proxyVmSize intentionally omitted: not allowed with containerInstanceSubnetId.
      }
    }
    source: imageSource
    customize: customizationSteps
    stagingResourceGroup: empty(stagingResourceGroupResourceId) ? null : stagingResourceGroupResourceId
    distribute: [
      {
        type: 'SharedImage'
        runOutputName: '${last(split(galleryImageDefinitionResourceId, '/'))}-SharedImage'
        galleryImageId: galleryImageDefinitionResourceId
        artifactTags: artifactTags
        excludeFromLatest: excludeFromLatest
        targetRegions: map(targetRegions, r => {
          name: r.name
          replicaCount: r.?replicaCount ?? 1
          storageAccountType: r.?storageAccountType ?? 'Standard_LRS'
        })
      }
    ]
    autoRun: {
      state: 'Disabled'
    }
    errorHandling: {
      onCustomizerError: onError
      onValidationError: onError
    }
  }
}

output name string = imageTemplate.name
output resourceId string = imageTemplate.id
