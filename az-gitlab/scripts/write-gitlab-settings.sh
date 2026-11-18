#!/usr/bin/env bash
# Writes the az-gitlab deployment output gitlabSettings into the cluster's gitlab-settings
# ConfigMap (az-aks/gitops/clusters/<cluster>/gitlab-settings.yaml). Commit the result; Flux
# substitutes the values into az-gitlab/gitops. Nothing secret is in the output.
#
#   write-gitlab-settings.sh <deployment-name> <cluster-directory>   e.g. gitlab-prod tools-prod
set -euo pipefail

deployment="${1:?subscription deployment name}"
cluster="${2:?cluster directory under az-aks/gitops/clusters}"
cd "$(git rev-parse --show-toplevel)"
out="az-aks/gitops/clusters/${cluster}/gitlab-settings.yaml"
[ -d "$(dirname "$out")" ] || { echo "no cluster directory: $(dirname "$out")" >&2; exit 2; }

settings=$(az deployment sub show --name "$deployment" --query properties.outputs.gitlabSettings.value -o json)
{
  echo "# az-gitlab output gitlabSettings (scripts/write-gitlab-settings.sh regenerates this file)."
  echo "# No secrets."
  echo "apiVersion: v1"
  echo "kind: ConfigMap"
  echo "metadata:"
  echo "  name: gitlab-settings"
  echo "  namespace: flux-system"
  echo "data:"
  python3 -c 'import json,sys; [print(f"  {k}: {json.dumps(str(v))}") for k,v in json.load(sys.stdin).items()]' <<<"$settings"
} > "$out"
echo "wrote $out"
