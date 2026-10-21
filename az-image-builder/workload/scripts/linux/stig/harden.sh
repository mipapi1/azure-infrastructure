#!/usr/bin/env bash
# DISA STIG hardening with OpenSCAP and the SCAP Security Guide (SSG) STIG profile, plus a compliance scan.
#
#   Build:    harden.sh [--profile stig] [--exclude rule,rule] [--no-scan]
#   Deployed: sudo bash /usr/local/lib/image-stig/stig/harden.sh --deployed      (Azure Run Command)
#
# 1. Installs OpenSCAP and extracts the SSG datastream for this distribution (artifact group linux-stig).
# 2. Tailoring: deselects the rules in exceptions/*.txt plus --exclude.
# 3. oscap xccdf eval --remediate: evaluates every rule and runs the fix for each failing one.
# 4. Scans again and writes results-arf.xml, report.html and summary.json to /var/log/image-compliance/<run>.
#    summary.json sorts every remaining failure: deploy-time, documented open finding, or unexplained.
# 5. Build only: keeps everything in /usr/local/lib/image-stig so the deployed VM can rerun steps 3-4
#    (rules that depend on the deployed VM: provisioned admin account, AIDE database, ...).
# Remaining failed rules do not fail the build; oscap errors and unknown excluded rules do.
# shellcheck source=../lib/common.sh
. "$(dirname "$0")/../lib/common.sh"

profile=stig
extra_excludes=''
scan=1
deployed=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --profile) profile="$2"; shift 2 ;;
    --exclude) extra_excludes="$2"; shift 2 ;;
    --no-scan) scan=0; shift ;;
    --deployed) deployed=1; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

here="$(cd "$(dirname "$0")" && pwd)"
install_root=/usr/local/lib/image-stig
run="$(date -u +%Y%m%dT%H%M%SZ)-$([[ "${deployed}" -eq 1 ]] && echo deployed || echo build)"
out="/var/log/image-compliance/${run}"
install -d -m 0700 "${out}"

case "${OS_FAMILY}" in
  ubuntu) product="ubuntu${VERSION_ID//./}" ;;
  *) product="rhel${VERSION_ID%%.*}" ;;
esac
ds="${install_root}/ssg-${product}-ds.xml"
tailoring="${install_root}/tailoring.xml"

if [[ "${deployed}" -eq 1 ]]; then
  [[ -f "${tailoring}" ]] || die "${tailoring} not found. Was this image built with harden.sh?"
  profile="$(sed -n 's|.*content_profile_\(.*\)_azure_image".*|\1|p' "${tailoring}")"
else
  ssg_zip=/var/tmp/imagebuilder/scap-security-guide.zip
  [[ -f "${ssg_zip}" ]] || die "${ssg_zip} not found. Is artifact group linux-stig downloaded?"
  log "Installing OpenSCAP"
  pkg_install openscap-scanner
  install -d -m 0700 "${install_root}"
  python3 - "${ssg_zip}" "${product}" "${ds}" <<'PY'
import sys, zipfile
src, product, dest = sys.argv[1:]
with zipfile.ZipFile(src) as z:
    names = [n for n in z.namelist() if n.endswith(f"/ssg-{product}-ds.xml")]
    if not names:
        sys.exit(f"The SCAP Security Guide package has no content for {product}. Use a supported release or a newer SSG.")
    with z.open(names[0]) as s, open(dest, "wb") as d:
        d.write(s.read())
PY
fi

base_profile="xccdf_org.ssgproject.content_profile_${profile}"
tailored_profile="${base_profile}_azure_image"
profiles="$(oscap info --profiles "${ds}")"
grep -q "^${base_profile}:" <<<"${profiles}" || die "Profile ${profile} is not in ${ds##*/}. Available: $(cut -d: -f1 <<<"${profiles}" | sed 's/.*_profile_//' | tr '\n' ' ')"

# Rule lists: "rule_id ... # comment". Exclusions = exceptions/common.txt + exceptions/<family>.txt + --exclude.
rules_in() { cat "$@" 2>/dev/null | sed 's/#.*//' | awk 'NF { print $1 }' | sort -u; }
mapfile -t excludes < <(rules_in "${here}/exceptions/common.txt" "${here}/exceptions/${OS_FAMILY}.txt"; tr ',' '\n' <<<"${extra_excludes}" | awk 'NF')
mapfile -t excludes < <(printf '%s\n' "${excludes[@]}" | awk 'NF' | sort -u)
if [[ "${deployed}" -eq 1 ]]; then
  mapfile -t excludes < <(sed -n 's|.*content_rule_\(.*\)" selected="false".*|\1|p' "${tailoring}")
fi

if [[ "${deployed}" -eq 0 ]]; then
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<xccdf:Tailoring xmlns:xccdf="http://checklists.nist.gov/xccdf/1.2" id="xccdf_org.ssgproject.content_tailoring_azure_image">'
    echo "  <xccdf:version time=\"$(date -u +%Y-%m-%dT%H:%M:%S)\">1</xccdf:version>"
    echo "  <xccdf:Profile id=\"${tailored_profile}\" extends=\"${base_profile}\">"
    echo "    <xccdf:title>${profile} for Azure images</xccdf:title>"
    for rule in "${excludes[@]}"; do
      grep -q "content_rule_${rule}\"" "${ds}" || die "Excluded rule ${rule} does not exist in ${ds##*/}. Fix the exceptions list."
      echo "    <xccdf:select idref=\"xccdf_org.ssgproject.content_rule_${rule}\" selected=\"false\"/>"
    done
    echo '  </xccdf:Profile>'
    echo '</xccdf:Tailoring>'
  } > "${tailoring}"
fi
log "Profile ${profile} (${ds##*/}), ${#excludes[@]} rule(s) excluded: ${excludes[*]:-none}"

# The STIG turns on a host firewall: keep SSH open so the build and Azure access keep working.
if [[ "${OS_FAMILY}" = ubuntu ]]; then
  pkg_install ufw
  ufw allow 22/tcp >/dev/null
fi

# oscap exit codes: 0 all pass, 2 at least one rule failed, anything else is an error.
oscap_eval() {
  local rc=0
  oscap xccdf eval --tailoring-file "${tailoring}" --profile "${tailored_profile}" "$@" "${ds}" >/dev/null || rc=$?
  [[ "${rc}" -eq 0 || "${rc}" -eq 2 ]] || die "oscap failed with exit code ${rc}"
}

# Two passes: some fixes depend on packages or files another fix creates (e.g. sssd after its package).
log "Remediating (this takes a while)"
oscap_eval --remediate --results "${out}/remediation-1.xml"
log "Remediating (second pass)"
oscap_eval --remediate --results "${out}/remediation-2.xml"

if [[ "${OS_FAMILY}" = rhel ]] && systemctl is-active -q firewalld; then
  firewall-cmd -q --permanent --add-service=ssh
  firewall-cmd -q --reload
fi
install -d -m 0755 /run/sshd   # privilege separation dir; normally created by the ssh service
sshd -t || die "sshd configuration is invalid after remediation"

if [[ "${scan}" -eq 1 ]]; then
  log "Scanning"
  oscap_eval --results-arf "${out}/results-arf.xml" --report "${out}/report.html"
  python3 "${here}/summarize.py" --arf "${out}/results-arf.xml" --tailoring "${tailoring}" --profile "${profile}" --phase "${run##*-}" \
    --exceptions "${here}/exceptions/common.txt" "${here}/exceptions/${OS_FAMILY}.txt" \
    --findings "${here}/findings/common.txt" "${here}/findings/${OS_FAMILY}.txt" > "${out}/summary.json"
  python3 "${here}/summarize.py" --print "${out}/summary.json"
  log "Results in ${out}"
fi

if [[ "${deployed}" -eq 0 ]]; then
  # Keep the scripts and lists for the deploy-time run (Run Command).
  install -d -m 0700 "${install_root}/lib" "${install_root}/stig"
  cp "${here}/../lib/common.sh" "${install_root}/lib/"
  cp -r "${here}/harden.sh" "${here}/summarize.py" "${here}/exceptions" "${here}/findings" "${install_root}/stig/"
fi
chmod -R go-rwx /var/log/image-compliance "${install_root}"
log "Hardening complete"
