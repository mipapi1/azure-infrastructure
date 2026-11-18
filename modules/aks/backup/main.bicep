metadata name = 'AKS Backup'
metadata description = 'Azure Backup for AKS: Backup vault with a daily operational-tier policy, storage for the backup extension on a private endpoint, the backup extension and trusted access. Deployed into its own resource group, which also holds the disk snapshots. The backup instance is created afterwards with az-aks/scripts/new-backup-instance.sh.'

@description('Required. Base name for the resources.')
param baseName string

@description('Optional. Location.')
param location string = resourceGroup().location

@description('Required. AKS cluster name.')
param clusterName string

@description('Required. Resource group of the AKS cluster.')
param clusterResourceGroupName string

@description('Required. Principal ID of the cluster (control plane) identity. It needs Contributor on this resource group to write disk snapshots.')
param clusterPrincipalId string

@description('Required. Private endpoint subnet for the storage account.')
param privateEndpointSubnetResourceId string

@description('Required. privatelink.blob private DNS zone.')
param blobPrivateDnsZoneResourceId string

@description('Optional. Days to keep operational-tier (snapshot) recovery points.')
@minValue(1)
@maxValue(360)
param retentionDays int = 7

@description('Optional. Daily backup time (UTC, HH:mm).')
param backupTime string = '02:00'

@description('Optional. Vault redundancy.')
param vaultRedundancy ('LocallyRedundant' | 'ZoneRedundant' | 'GeoRedundant') = 'ZoneRedundant'

@description('Optional. Diagnostic settings for the storage account.')
param diagnosticSettings array = []

@description('Optional. Lock.')
param lock object?

@description('Optional. Tags.')
param tags object = {}

@description('Optional. Enable AVM usage telemetry.')
param enableTelemetry bool = true

var roleIds = {
  contributor: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
  reader: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
}
var containerName = 'aks-backup'
var vaultName = '${baseName}-bvault'
var storageAccountName = take('st${replace(baseName, '-', '')}bk${uniqueString(resourceGroup().id)}', 24)
var operationalStore = { dataStoreType: 'OperationalStore', objectType: 'DataStoreInfoBase' }

module storage 'br/public:avm/res/storage/storage-account:0.33.1' = {
  name: '${uniqueString(deployment().name, location)}-st-backup'
  params: {
    name: storageAccountName
    location: location
    kind: 'StorageV2'
    skuName: vaultRedundancy == 'LocallyRedundant' ? 'Standard_LRS' : 'Standard_ZRS'
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    allowCrossTenantReplication: false
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Disabled'
    networkAcls: { bypass: 'AzureServices', defaultAction: 'Deny' }
    blobServices: {
      containers: [{ name: containerName, publicAccess: 'None' }]
      diagnosticSettings: diagnosticSettings
    }
    privateEndpoints: [
      {
        name: '${storageAccountName}-blob-pe'
        service: 'blob'
        subnetResourceId: privateEndpointSubnetResourceId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [{ privateDnsZoneResourceId: blobPrivateDnsZoneResourceId }]
        }
        tags: tags
      }
    ]
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

module vault 'br/public:avm/res/data-protection/backup-vault:0.13.3' = {
  name: '${uniqueString(deployment().name, location)}-bvault'
  params: {
    name: vaultName
    location: location
    managedIdentities: { systemAssigned: true }
    dataStoreType: 'VaultStore'
    type: vaultRedundancy
    softDeleteSettings: { state: 'On', retentionDurationInDays: 14 }
    immutabilitySettingState: 'Unlocked'
    backupPolicies: [
      {
        name: 'aks-daily'
        properties: {
          objectType: 'BackupPolicy'
          datasourceTypes: ['Microsoft.ContainerService/managedClusters']
          policyRules: [
            {
              name: 'BackupDaily'
              objectType: 'AzureBackupRule'
              backupParameters: { objectType: 'AzureBackupParams', backupType: 'Incremental' }
              dataStore: operationalStore
              trigger: {
                objectType: 'ScheduleBasedTriggerContext'
                schedule: {
                  repeatingTimeIntervals: ['R/2025-01-01T${backupTime}:00+00:00/P1D']
                  timeZone: 'UTC'
                }
                taggingCriteria: [
                  {
                    isDefault: true
                    taggingPriority: 99
                    tagInfo: { id: 'Default_', tagName: 'Default' }
                  }
                ]
              }
            }
            {
              name: 'Default'
              objectType: 'AzureRetentionRule'
              isDefault: true
              lifecycles: [
                {
                  deleteAfter: { objectType: 'AbsoluteDeleteOption', duration: 'P${retentionDays}D' }
                  sourceDataStore: operationalStore
                  targetDataStoreCopySettings: []
                }
              ]
            }
          ]
        }
      }
    ]
    lock: lock
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

module clusterSide 'cluster.bicep' = {
  name: '${uniqueString(deployment().name, location)}-aks-backup-cluster'
  scope: resourceGroup(clusterResourceGroupName)
  params: {
    clusterName: clusterName
    backupVaultName: vaultName
    backupVaultResourceGroupName: resourceGroup().name
    backupVaultPrincipalId: vault.outputs.?systemAssignedMIPrincipalId ?? ''
    storageAccountName: storageAccountName
    storageAccountResourceGroupName: resourceGroup().name
    blobContainerName: containerName
    enableTelemetry: enableTelemetry
  }
  dependsOn: [storage]
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: storageAccountName
  dependsOn: [storage]
}

resource extensionBlobAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(storageAccount.id, 'azure-aks-backup', roleIds.storageBlobDataContributor)
  properties: {
    principalId: clusterSide.outputs.extensionPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      roleIds.storageBlobDataContributor
    )
  }
}

// Snapshots live in this resource group: the vault reads it, the cluster identity writes it.
resource vaultReaderOnSnapshots 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, 'backup-vault', roleIds.reader)
  properties: {
    principalId: vault.outputs.?systemAssignedMIPrincipalId ?? ''
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.reader)
  }
}

resource clusterContributorOnSnapshots 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, 'cluster-identity', roleIds.contributor)
  properties: {
    principalId: clusterPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.contributor)
  }
}

@description('Resource ID of the Backup vault.')
output backupVaultResourceId string = vault.outputs.resourceId

@description('Resource ID of the AKS backup policy.')
output backupPolicyResourceId string = '${vault.outputs.resourceId}/backupPolicies/aks-daily'

@description('Resource group that holds the snapshots (this one).')
output snapshotResourceGroupName string = resourceGroup().name
