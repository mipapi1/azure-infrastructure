// Compute Gallery and an Image Builder template for the AVD session host image
// (Windows 11 multi-session with Microsoft 365 Apps, fully patched).
// Deploy into resource group rg-image-builder, then run the template.

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
    vmProfile: { vmSize: 'Standard_D4ds_v5' }
    source: {
      type: 'PlatformImage'
      publisher: 'MicrosoftWindowsDesktop'
      offer: 'office-365'
      sku: 'win11-25h2-avd-m365'
      version: 'latest'
    }
    customize: [
      { type: 'WindowsUpdate', name: 'windows-update' }
      { type: 'WindowsRestart', name: 'restart' }
    ]
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
