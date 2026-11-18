#!/usr/bin/env bash
# Protects the cluster with the Backup vault that az-aks deploys with addons.backup.enabled:
# initializes the backup configuration (all namespaces except the AKS system ones, cluster-scoped
# resources, disk snapshots), validates the vault's permissions and creates the backup instance.
# Needs the dataprotection CLI extension (az extension add --name dataprotection).
#
#   new-backup-instance.sh <az-aks deployment name>
#
# Restore test: README, "AKS Backup".
set -euo pipefail

deployment="${1:?az-aks subscription deployment name}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# out NAME [FIELD]: a deployment output, or one field of an object output.
out() { az deployment sub show --name "$deployment" --query "properties.outputs.$1.value${2:+.$2}" -o tsv; }
cluster_id=$(out clusterResourceId)
vault_id=$(out backup vaultResourceId)
policy_id=$(out backup policyResourceId)
snapshot_rg=$(out backup snapshotResourceGroupName)
[ -n "$vault_id" ] || { echo "addons.backup is off in $deployment" >&2; exit 2; }
vault_rg=$(cut -d/ -f5 <<<"$vault_id")
vault_name="${vault_id##*/}"
location=$(az resource show --ids "$cluster_id" --query location -o tsv)

az dataprotection backup-instance initialize-backupconfig --datasource-type AzureKubernetesService > "$work/config.json"
az dataprotection backup-instance initialize \
  --datasource-id "$cluster_id" --datasource-location "$location" --datasource-type AzureKubernetesService \
  --policy-id "$policy_id" --backup-configuration "$work/config.json" \
  --friendly-name "${cluster_id##*/}" --snapshot-resource-group-name "$snapshot_rg" > "$work/instance.json"

# az-aks assigns the documented roles; this reports anything still missing instead of granting it.
az dataprotection backup-instance validate-for-backup --backup-instance "$work/instance.json" --ids "$vault_id"
az dataprotection backup-instance create --backup-instance "$work/instance.json" --resource-group "$vault_rg" --vault-name "$vault_name"
echo "protected ${cluster_id##*/} with $vault_name"
