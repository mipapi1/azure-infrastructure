# Shared helpers for the Linux build scripts. Source it: . "$(dirname "$0")/../lib/common.sh"
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

log() { echo "[$(basename "$0")] $*"; }
die() { echo "[$(basename "$0")] ERROR: $*" >&2; exit 1; }

# shellcheck disable=SC1091  # ID and VERSION_ID come from os-release
. /etc/os-release
: "${ID:?}" "${VERSION_ID:?}"
case "${ID}" in
  ubuntu) OS_FAMILY=ubuntu ;;
  rhel) OS_FAMILY=rhel ;;
  *) die "Unsupported distribution: ${ID} ${VERSION_ID}" ;;
esac
export OS_FAMILY

pkg_install() {
  if [ "$OS_FAMILY" = ubuntu ]; then
    apt-get update -q
    apt-get install -y -q --no-install-recommends "$@"
  else
    dnf install -y -q "$@"
  fi
}
