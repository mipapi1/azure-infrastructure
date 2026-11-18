#!/usr/bin/env bash
# Copies the secrets the chart generates, and that GitLab backups do not contain, to Key Vault:
# the Rails secrets (needed to decrypt CI variables, 2FA and tokens after a restore) and the SSH
# host keys (so clients don't see a host key change). Run after the first install and after
# any rotation. Needs kubectl access to the gitlab namespace and Key Vault Secrets Officer.
#
#   backup-gitlab-secrets.sh <key-vault-name> [release]          default release: gitlab
set -euo pipefail

vault="${1:?key vault name}"
release="${2:-gitlab}"
ns=gitlab

backup() {
  local secret="$1" name="$2" data
  data=$(kubectl --namespace "$ns" get secret "$secret" -o json \
    | python3 -c 'import json,sys; s=json.load(sys.stdin); print(json.dumps({"type": s.get("type","Opaque"), "data": s["data"]}))')
  az keyvault secret set --vault-name "$vault" --name "$name" --value "$data" \
    --content-type application/json --output none
  echo "saved   $secret -> $name"
}

backup "${release}-rails-secret" gitlab-rails-secret
backup "${release}-gitlab-shell-host-keys" gitlab-shell-host-keys
