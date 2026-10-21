#!/usr/bin/env bash
# Installs all available package updates. A new kernel takes effect when the image is deployed.
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"

if [ "$OS_FAMILY" = ubuntu ]; then
  apt-get update -q
  apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade
  apt-get -y -q autoremove --purge
else
  dnf -y -q upgrade --refresh
fi
log "Packages updated"
