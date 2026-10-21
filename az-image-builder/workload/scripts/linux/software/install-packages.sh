#!/usr/bin/env bash
# Installs distribution packages: install-packages.sh <package> [package...]
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"

[ "$#" -gt 0 ] || die "Usage: install-packages.sh <package> [package...]"
pkg_install "$@"
log "Installed: $*"
