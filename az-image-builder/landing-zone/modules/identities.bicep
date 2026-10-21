// Image template identity (used by the Image Builder service) and build VM identity (attached to the build VM).
// The template identity gets Managed Identity Operator on the build VM identity so it can attach it.

@description('Image template identity name')
param templateIdentityName string

@description('Build VM identity name')
param buildVmIdentityName string

@description('Azure region')
param location string

@description('Tags applied to the identities')
param tags object = {}

@description('When true, applies a lock to both identities')
param enableLock bool = false

@description('Lock kind when enableLock is true')
@allowed([ 'CanNotDelete', 'ReadOnly' ])
param lockKind string = 'CanNotDelete'

module templateIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'uami-${templateIdentityName}'
  params: {
    name: templateIdentityName
    location: location
    tags: tags
    lock: enableLock ? { kind: lockKind, name: 'lock-${templateIdentityName}' } : null
  }
}

module buildVmIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'uami-${buildVmIdentityName}'
  params: {
    name: buildVmIdentityName
    location: location
    tags: tags
    lock: enableLock ? { kind: lockKind, name: 'lock-${buildVmIdentityName}' } : null
    roleAssignments: [
      {
        principalId: templateIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Managed Identity Operator'
      }
    ]
  }
}

output templateIdentityName string = templateIdentity.outputs.name
output templateIdentityPrincipalId string = templateIdentity.outputs.principalId
output buildVmIdentityName string = buildVmIdentity.outputs.name
output buildVmIdentityPrincipalId string = buildVmIdentity.outputs.principalId
output buildVmIdentityClientId string = buildVmIdentity.outputs.clientId
