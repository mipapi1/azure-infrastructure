@description('Name of the user-assigned managed identity')
param name string

@description('Azure region')
param location string

@description('Tags applied to the identity')
param tags object = {}

@description('When true, applies a lock to the identity')
param enableLock bool = false

@description('Lock kind when enableLock is true')
@allowed([ 'CanNotDelete', 'ReadOnly' ])
param lockKind string = 'CanNotDelete'

@description('Role assignments granted AT this identity (rare — usually you grant this identity access to OTHER resources via their roleAssignments)')
param roleAssignments array = []

@description('Federated identity credentials — for workload identity / OIDC scenarios (GitHub Actions, AKS workload identity, etc.)')
param federatedIdentityCredentials array = []

module uami 'br/public:avm/res/managed-identity/user-assigned-identity:0.5.0' = {
  name: 'uami-${name}'
  params: {
    name: name
    location: location
    tags: tags
    lock: enableLock ? {
      kind: lockKind
      name: 'lock-${name}'
    } : null
    roleAssignments: roleAssignments
    federatedIdentityCredentials: federatedIdentityCredentials
  }
}

output name string = uami.outputs.name
output resourceId string = uami.outputs.resourceId
output principalId string = uami.outputs.principalId
output clientId string = uami.outputs.clientId
