metadata name = 'AKS Backup cluster side'
metadata description = 'Backup extension, trusted access for the Backup vault and the vault\'s Reader role on the cluster. Deployed into the cluster resource group by modules/aks/backup.'

@description('Required. AKS cluster name.')
param clusterName string

@description('Required. Backup vault name.')
param backupVaultName string

@description('Required. Resource group of the Backup vault.')
param backupVaultResourceGroupName string

@description('Required. Principal ID of the Backup vault system-assigned identity.')
param backupVaultPrincipalId string

@description('Required. Storage account for the backup extension.')
param storageAccountName string

@description('Required. Resource group of the storage account.')
param storageAccountResourceGroupName string

@description('Required. Blob container for the backup extension.')
param blobContainerName string

@description('Optional. Enable AVM usage telemetry.')
param enableTelemetry bool = true

var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var backupVaultResourceId = resourceId(
  backupVaultResourceGroupName,
  'Microsoft.DataProtection/backupVaults',
  backupVaultName
)

resource cluster 'Microsoft.ContainerService/managedClusters@2025-07-01' existing = {
  name: clusterName
}

module extension 'br/public:avm/res/kubernetes-configuration/extension:0.3.8' = {
  name: '${uniqueString(deployment().name)}-aks-backup-ext'
  params: {
    name: 'azure-aks-backup'
    clusterName: clusterName
    clusterType: 'managedCluster'
    extensionType: 'microsoft.dataprotection.kubernetes'
    releaseTrain: 'stable'
    configurationSettings: {
      blobContainer: blobContainerName
      storageAccount: storageAccountName
      storageAccountResourceGroup: storageAccountResourceGroupName
      storageAccountSubscriptionId: subscription().subscriptionId
    }
    enableTelemetry: enableTelemetry
  }
}

// The extension creates its own identity in the node resource group; the AVM module doesn't
// output it, so it's read here.
resource extensionResource 'Microsoft.KubernetesConfiguration/extensions@2025-03-01' existing = {
  scope: cluster
  name: 'azure-aks-backup'
  dependsOn: [extension]
}

resource trustedAccess 'Microsoft.ContainerService/managedClusters/trustedAccessRoleBindings@2025-07-01' = {
  parent: cluster
  name: 'backup-vault'
  properties: {
    sourceResourceId: backupVaultResourceId
    roles: ['Microsoft.DataProtection/backupVaults/backup-operator']
  }
}

resource vaultReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: cluster
  name: guid(cluster.id, backupVaultResourceId, readerRoleId)
  properties: {
    principalId: backupVaultPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
  }
}

@description('Principal ID of the backup extension identity.')
output extensionPrincipalId string = extensionResource.properties.aksAssignedIdentity.principalId
