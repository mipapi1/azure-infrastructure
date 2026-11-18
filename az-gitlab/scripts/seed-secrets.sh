#!/usr/bin/env bash
# Creates the GitLab secrets in the cluster key vault (az-aks output keyVaultResourceId) before
# the first az-gitlab deployment. The External Secrets Operator syncs them into the cluster.
# Existing secrets are kept, so rerunning is safe; pass --rotate NAME to replace one.
#
#   seed-secrets.sh <key-vault-name> [--oidc-client-id ID --oidc-tenant-id ID --gitlab-url URL]
#                   [--keycloak] [--rotate NAME]
#
# The OIDC client secret is read from GITLAB_OIDC_CLIENT_SECRET (README, "Entra ID sign-in").
# The deployment reads the same values back: export them before az deployment, for example
#   export GITLAB_POSTGRES_PASSWORD=$(az keyvault secret show --vault-name <kv> -n gitlab-postgres-password --query value -o tsv)
set -euo pipefail

vault="${1:?key vault name}"; shift
oidc_client="" oidc_tenant="" gitlab_url="" keycloak=0 rotate=""
while [ $# -gt 0 ]; do
  case "$1" in
    --oidc-client-id) oidc_client="$2"; shift 2 ;;
    --oidc-tenant-id) oidc_tenant="$2"; shift 2 ;;
    --gitlab-url) gitlab_url="${2%/}"; shift 2 ;;
    --keycloak) keycloak=1; shift ;;
    --rotate) rotate="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

random() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-48}"; }

set_if_missing() {
  local name="$1" value="$2"
  if [ "$name" != "$rotate" ] && az keyvault secret show --vault-name "$vault" --name "$name" --query id -o tsv >/dev/null 2>&1; then
    echo "keep    $name"
    return
  fi
  az keyvault secret set --vault-name "$vault" --name "$name" --value "$value" --content-type text/plain --output none
  echo "set     $name"
}

set_if_missing gitlab-postgres-password "$(random 40)"
set_if_missing gitlab-gitaly-token "$(random 64)"
set_if_missing gitlab-shell-secret "$(random 64)"
if [ "$keycloak" -eq 1 ]; then
  set_if_missing gitlab-keycloak-db-password "$(random 40)"
  set_if_missing gitlab-keycloak-bootstrap-admin "$(random 32)"
fi

# Placeholder until the runner is created in GitLab (Admin > CI/CD > Runners); then
#   az keyvault secret set --vault-name <kv> -n gitlab-runner-token --value glrt-...
set_if_missing gitlab-runner-token "not-set"

if [ -n "$oidc_client" ]; then
  : "${oidc_tenant:?--oidc-tenant-id is required with --oidc-client-id}"
  : "${gitlab_url:?--gitlab-url is required with --oidc-client-id}"
  : "${GITLAB_OIDC_CLIENT_SECRET:?set GITLAB_OIDC_CLIENT_SECRET}"
  # GitLab omniauth provider for Microsoft Entra ID (OpenID Connect).
  provider=$(cat <<YAML
name: openid_connect
label: Microsoft Entra ID
args:
  name: openid_connect
  scope: [openid, profile, email]
  response_type: code
  issuer: https://login.microsoftonline.com/${oidc_tenant}/v2.0
  discovery: true
  client_auth_method: query
  uid_field: oid
  pkce: true
  client_options:
    identifier: ${oidc_client}
    secret: ${GITLAB_OIDC_CLIENT_SECRET}
    redirect_uri: ${gitlab_url}/users/auth/openid_connect/callback
YAML
)
  # Always written when the OIDC options are given, so a new client secret takes effect.
  az keyvault secret set --vault-name "$vault" --name gitlab-oidc-provider --value "$provider" --content-type application/yaml --output none
  echo "set     gitlab-oidc-provider"
fi
