using '../main.bicep'

// GitLab cluster: <env>-aks-<workload>-gitlab in <env>-rg-<workload>-gitlab. Kept apart from the
// applications because CI runners run any code that is pushed. GitLab's PostgreSQL, Redis and
// storage (gitlab/main.bicep) deploy into the same resource group and spoke.
param env = 's' // p: prod, s: staging
param workload = 'mipapi'
param cluster = 'gitlab'

param network = {
  addressPrefix: '10.5.0.0/22'
  nodesPrefix: '10.5.0.0/24'
  endpointsPrefix: '10.5.1.0/27'
}
param rulePriority = 250

param adminGroupId = '<aks-admins-group-object-id>'
param nodeVmSize = 'Standard_E4as_v4' // GitLab is memory-bound: 4 vCPU, 32 GB
param nodeCount = 2
param registry = false
