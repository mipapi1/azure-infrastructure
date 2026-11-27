using '../main.bicep'

// Application cluster: <env>-aks-<workload>-apps in <env>-rg-<workload>-apps, with the container registry.
param env = 's' // p: prod, s: staging
param workload = 'mipapi'
param cluster = 'apps'

param network = {
  addressPrefix: '10.2.0.0/22'
  nodesPrefix: '10.2.0.0/24'
  endpointsPrefix: '10.2.1.0/27'
}
param rulePriority = 200

param adminGroupId = '<aks-admins-group-object-id>'
param nodeVmSize = 'Standard_D4ds_v5'
param nodeCount = 2
param registry = true
