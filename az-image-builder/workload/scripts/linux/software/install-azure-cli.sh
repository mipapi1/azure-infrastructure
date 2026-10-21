#!/usr/bin/env bash
# Azure CLI from the Microsoft package repository (packages.microsoft.com must be reachable).
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"

if [ "$OS_FAMILY" = ubuntu ]; then
  pkg_install ca-certificates curl gnupg lsb-release
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
  chmod 0644 /etc/apt/keyrings/microsoft.gpg
  echo "Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: $(lsb_release -cs)
Components: main
Architectures: $(dpkg --print-architecture)
Signed-by: /etc/apt/keyrings/microsoft.gpg" > /etc/apt/sources.list.d/azure-cli.sources
  pkg_install azure-cli
else
  rpm --import https://packages.microsoft.com/keys/microsoft.asc
  dnf install -y -q "https://packages.microsoft.com/config/rhel/${VERSION_ID%%.*}/packages-microsoft-prod.rpm"
  pkg_install azure-cli
fi
log "Azure CLI $(az version --query '"azure-cli"' -o tsv)"
