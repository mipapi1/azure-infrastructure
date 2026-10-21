#!/usr/bin/env bash
# Runs the Linux STIG hardening (build, then --deployed) in a container and checks the outputs.
#   tests/linux-hardening.sh <ubuntu|rhel> <scap-security-guide-X.zip>
# Containers are not VMs: SSG marks many kernel/boot/service rules notapplicable, so this proves the
# workflow (OpenSCAP install, tailoring, remediation, scan, summary, deploy-time rerun), not the full result.
set -euo pipefail

distro="${1:?ubuntu or rhel}"
ssg_zip="$(cd "$(dirname "${2:?path to scap-security-guide zip}")" && pwd)/$(basename "$2")"
root="$(cd "$(dirname "$0")/.." && pwd)"
case "${distro}" in
  ubuntu) image=ubuntu:24.04; prep='apt-get update -q; apt-get install -y -q python3 openssh-server >/dev/null; ssh-keygen -A' ;;
  rhel) image=registry.access.redhat.com/ubi9/ubi; prep='dnf install -y -q --setopt=retries=10 python3 openssh-server >/dev/null; ssh-keygen -A' ;;
  *) echo "Unknown distro ${distro}" >&2; exit 1 ;;
esac

docker run --rm \
  -v "${root}/workload/scripts/linux:/opt/imagebuilder/linux:ro" \
  -v "${ssg_zip}:/var/tmp/imagebuilder/scap-security-guide.zip:ro" \
  "${image}" bash -c "
    set -euo pipefail
    ${prep}
    bash /opt/imagebuilder/linux/stig/harden.sh --profile stig --exclude 'package_aide_installed'
    bash /usr/local/lib/image-stig/stig/harden.sh --deployed
    python3 - <<'PY'
import glob, json
runs = sorted(glob.glob('/var/log/image-compliance/*/summary.json'))
assert len(runs) == 2, runs
for path in runs:
    s = json.load(open(path))
    assert s['counts'], path
    assert {'rule': 'package_aide_installed', 'reason': 'image parameter excludeRules'} in s['excluded'], s['excluded']
    for name in ('results-arf.xml', 'report.html'):
        assert glob.glob(path.replace('summary.json', name)), name
print('OK', [p.split('/')[-2] for p in runs])
PY
  "
