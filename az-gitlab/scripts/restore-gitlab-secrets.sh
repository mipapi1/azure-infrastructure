#!/usr/bin/env bash
# Recreates the chart-generated secrets from Key Vault (backup-gitlab-secrets.sh) on a new
# cluster, before Flux installs the chart, so the shared-secrets job keeps them. Part of the
# restore procedure in the README.
#
#   restore-gitlab-secrets.sh <key-vault-name> [release]         default release: gitlab
set -euo pipefail

vault="${1:?key vault name}"
release="${2:-gitlab}"
ns=gitlab

kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns"

restore() {
  local name="$1" secret="$2"
  az keyvault secret show --vault-name "$vault" --name "$name" --query value -o tsv \
    | python3 -c '
import json, sys
s = json.load(sys.stdin)
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": s["type"], "data": s["data"],
                  "metadata": {"name": sys.argv[1], "namespace": sys.argv[2]}}))' "$secret" "$ns" \
    | kubectl apply -f -
  echo "restored $name -> $secret"
}

restore gitlab-rails-secret "${release}-rails-secret"
restore gitlab-shell-host-keys "${release}-gitlab-shell-host-keys"
