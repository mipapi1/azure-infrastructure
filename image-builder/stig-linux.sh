#!/usr/bin/env bash
# DISA STIG hardening for the Ubuntu 24.04 image. Runs as an Image Builder step (root).
# Applies the SCAP Security Guide (ComplianceAsCode) STIG profile fixes, minus the rules in
# `excludes`, and installs `stig-scan` to check a VM built from the image.
#
# New SSG release: update ssg_version and ssg_sha256 (sha256sum <zip>).
#
# Not applied, with the reason (report these as findings):
#   sudo_remove_nopasswd,  The Azure admin account is key-only and has no password, so it needs
#   sudo_require_authentication  passwordless sudo (both rules remove NOPASSWD). Image Builder's
#                          build user does too: without it the build hangs at a sudo prompt.
#   FIPS mode              FIPS modules need Ubuntu Pro.
#   GRUB password          Needs a per-VM secret and would stop unattended boots; the serial
#                          console already requires Azure RBAC.
#   Manual checks          `stig-scan` reports them as notchecked; review them by hand.
set -euo pipefail

ssg_version=0.1.82
ssg_sha256=765e84bdce7f9055f9b9c2dd0ee2b713d4255f8eec94eac6d35ea4973c28919c
excludes=(sudo_remove_nopasswd sudo_require_authentication)

dir=/usr/local/share/stig
log=/var/log/stig
install -d -m 0755 "$dir"
install -d -m 0700 "$log"
export DEBIAN_FRONTEND=noninteractive

apt-get update -q
apt-get install -y -q unzip ufw openscap-scanner

curl -fsSL -o /tmp/ssg.zip "https://github.com/ComplianceAsCode/content/releases/download/v${ssg_version}/scap-security-guide-${ssg_version}.zip"
echo "${ssg_sha256}  /tmp/ssg.zip" | sha256sum -c -
unzip -q -o -j /tmp/ssg.zip "*/ssg-ubuntu2404-ds.xml" "*/bash/ubuntu2404-script-stig.sh" -d "$dir"
rm -f /tmp/ssg.zip

# Drop the excluded rules from the generated fix script.
awk -v list="${excludes[*]}" '
  BEGIN { n = split(list, r, " "); for (i = 1; i <= n; i++) skip["xccdf_org.ssgproject.content_rule_" r[i]] = 1 }
  /^# BEGIN fix / { id = $0; sub(/^.*for \047/, "", id); sub(/\047.*$/, "", id); if (id in skip) dropping = 1 }
  !dropping { print }
  /^# END fix / { dropping = 0 }
' "$dir/ubuntu2404-script-stig.sh" > "$dir/fixes.sh"

# One fix turns the firewall on: allow SSH first so VMs stay reachable.
ufw allow 22/tcp > /dev/null

# Two passes: some fixes depend on packages or files that another fix creates.
for pass in 1 2; do
  echo "STIG: applying fixes, pass ${pass}"
  bash "$dir/fixes.sh" > "$log/fixes-${pass}.log" 2>&1 || echo "STIG: pass ${pass} exited $?; see $log/fixes-${pass}.log"
done
ufw limit 22/tcp > /dev/null
ufw --force enable > /dev/null

install -d -m 0755 /run/sshd
sshd -t

cat > /usr/local/sbin/stig-scan <<'EOF'
#!/bin/sh
# Scans this VM against the STIG profile and prints the result counts.
# Report: /var/log/stig/report.html
oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_stig \
  --results /var/log/stig/results.xml --report /var/log/stig/report.html \
  /usr/local/share/stig/ssg-ubuntu2404-ds.xml > /var/log/stig/scan.txt 2>&1
awk -F'\t' '/^Result/ { n[$2]++ } END { for (r in n) print r, n[r] }' /var/log/stig/scan.txt | sort
EOF
chmod 0750 /usr/local/sbin/stig-scan
echo "STIG: done. Run 'sudo stig-scan' on a VM built from this image."
