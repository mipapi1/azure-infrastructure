// Azure Compute Gallery: creates one, or uses an existing one. Either way the image template identity
// gets the gallery distribution role on it. Deployed in the gallery's resource group.

@description('Gallery name')
param name string

@description('true = create the gallery; false = it already exists in this resource group')
param create bool = true

@description('Azure region (new gallery only)')
param location string

@description('Tags applied to a new gallery')
param tags object = {}

@description('Gallery description (new gallery only)')
param galleryDescription string = 'Images built by Azure Image Builder'

@description('Principal ID of the image template identity')
param templateIdentityPrincipalId string

@description('Resource ID of the gallery distribution role definition')
param roleDefinitionId string

@description('When true, applies a lock to a new gallery')
param enableLock bool = false

@description('Lock kind when enableLock is true')
@allowed(['CanNotDelete', 'ReadOnly'])
param lockKind string = 'CanNotDelete'

module gallery 'br/public:avm/res/compute/gallery:0.9.5' = if (create) {
  name: 'gal-${name}'
  params: {
    name: name
    location: location
    tags: tags
    description: galleryDescription
    lock: enableLock ? { kind: lockKind, name: 'lock-${name}' } : null
    roleAssignments: [
      {
        principalId: templateIdentityPrincipalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: roleDefinitionId
      }
    ]
  }
}

resource existingGallery 'Microsoft.Compute/galleries@2025-03-03' existing = if (!create) {
  name: name
}

resource existingGalleryAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!create) {
  name: guid(resourceId('Microsoft.Compute/galleries', name), templateIdentityPrincipalId, roleDefinitionId)
  scope: existingGallery
  properties: {
    principalId: templateIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleDefinitionId
  }
}

output name string = name
output resourceId string = resourceId('Microsoft.Compute/galleries', name)
