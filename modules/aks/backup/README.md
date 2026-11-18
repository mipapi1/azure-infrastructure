# AKS Backup

Azure Backup for AKS, used by `az-aks` (`addons.backup`). Deployed into its own resource group, which also holds the disk snapshots, so the vault's Reader and the cluster identity's Contributor stay scoped to backup data.

| Resource | Notes |
|---|---|
| Storage account | Container `aks-backup` for the cluster resources the extension backs up. Shared key off, public access off, blob private endpoint in the cluster spoke. |
| Backup vault | System-assigned identity, soft delete 14 days, immutability unlocked, policy `aks-daily` (operational tier, daily, `retentionDays`). |
| Backup extension | `microsoft.dataprotection.kubernetes` (`azure-aks-backup`, release train stable) with Storage Blob Data Contributor for its identity on the account. |
| Trusted access | `Microsoft.DataProtection/backupVaults/backup-operator` for the vault on the cluster. |
| Roles | Vault: Reader on the cluster and on this resource group. Cluster identity: Contributor on this resource group (snapshots). |

The backup instance isn't created here: `az-aks/scripts/new-backup-instance.sh` initializes, validates and creates it after the deployment. Don't lock this resource group; Azure Backup deletes expired snapshots in it.

## Parameters

<!-- BEGIN_PARAMS -->
| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `baseName` | string | yes |  | Base name for the resources. |
| `location` | string | no | computed | Location. |
| `clusterName` | string | yes |  | AKS cluster name. |
| `clusterResourceGroupName` | string | yes |  | Resource group of the AKS cluster. |
| `clusterPrincipalId` | string | yes |  | Principal ID of the cluster (control plane) identity. It needs Contributor on this resource group to write disk snapshots. |
| `privateEndpointSubnetResourceId` | string | yes |  | Private endpoint subnet for the storage account. |
| `blobPrivateDnsZoneResourceId` | string | yes |  | privatelink.blob private DNS zone. |
| `retentionDays` | int | no | `7` | Days to keep operational-tier (snapshot) recovery points. |
| `backupTime` | string | no | `"02:00"` | Daily backup time (UTC, HH:mm). |
| `vaultRedundancy` | `GeoRedundant` \| `LocallyRedundant` \| `ZoneRedundant` | no | `"ZoneRedundant"` | Vault redundancy. |
| `diagnosticSettings` | array | no | `[]` | Diagnostic settings for the storage account. |
| `lock` | object | no |  | Lock. |
| `tags` | object | no | `{}` | Tags. |
| `enableTelemetry` | bool | no | `true` | Enable AVM usage telemetry. |

| Output | Type | Description |
|---|---|---|
| `backupVaultResourceId` | string | Resource ID of the Backup vault. |
| `backupPolicyResourceId` | string | Resource ID of the AKS backup policy. |
| `snapshotResourceGroupName` | string | Resource group that holds the snapshots (this one). |
<!-- END_PARAMS -->
