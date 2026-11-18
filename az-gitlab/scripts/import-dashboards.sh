#!/usr/bin/env bash
# Imports the GitLab dashboards (az-gitlab/gitops/dashboards) into Managed Grafana (az-aks output
# grafanaResourceId) into a GitLab folder. Needs Grafana Editor and the amg CLI extension
# (az extension add --name amg). Rerun after changing a dashboard; it overwrites by uid.
#
#   import-dashboards.sh <grafana-resource-id>
set -euo pipefail

id="${1:?Managed Grafana resource ID}"
name="${id##*/}"
rg=$(cut -d/ -f5 <<<"$id")
dir="$(cd "$(dirname "$0")/../gitops/dashboards" && pwd)"

folder=$(az grafana folder show --name "$name" --resource-group "$rg" --folder GitLab --query uid -o tsv 2>/dev/null || true)
[ -n "$folder" ] || folder=$(az grafana folder create --name "$name" --resource-group "$rg" --title GitLab --query uid -o tsv)

for f in "$dir"/*.json; do
  az grafana dashboard import --name "$name" --resource-group "$rg" --folder "$folder" --overwrite true --definition "@$f" --output none
  echo "imported $(basename "$f")"
done
