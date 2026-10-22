// Gallery image definition: generalized, Gen2, x64, accelerated networking, SCSI + NVMe disk controllers.
// Deployed in the gallery's resource group.

@description('Name of the existing gallery')
param galleryName string

@description('Image definition name')
param name string

@description('Azure region')
param location string

@description('Tags applied to the definition')
param tags object = {}

@allowed(['Windows', 'Linux'])
param osType string

param definitionDescription string = ''
param publisher string
param offer string
param sku string

@allowed(['TrustedLaunch', 'TrustedLaunchSupported', 'Standard'])
param securityType string = 'TrustedLaunch'

resource gallery 'Microsoft.Compute/galleries@2025-03-03' existing = {
  name: galleryName
}

resource definition 'Microsoft.Compute/galleries/images@2025-03-03' = {
  parent: gallery
  name: name
  location: location
  tags: tags
  properties: {
    description: definitionDescription
    osType: osType
    osState: 'Generalized'
    hyperVGeneration: 'V2'
    architecture: 'x64'
    identifier: {
      publisher: publisher
      offer: offer
      sku: sku
    }
    // Features can be added to a definition but never removed.
    features: concat(
      [
        {
          name: 'IsAcceleratedNetworkSupported'
          value: 'True'
        }
        {
          // v6 VM sizes are NVMe-only.
          name: 'DiskControllerTypes'
          value: 'SCSI, NVMe'
        }
      ],
      securityType == 'Standard'
        ? []
        : [
            {
              name: 'SecurityType'
              value: securityType
            }
          ]
    )
  }
}

output resourceId string = definition.id
