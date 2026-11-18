#!/usr/bin/env bash
# Installs the GitLab Linux package on this VM and configures it as a Gitaly-only server.
# Run by a managed run command. Named parameters arrive as environment variables:
#   PACKAGE_VERSION    gitlab-ee package version, matching the chart's GitLab version
#   INTERNAL_API_URL   GitLab URL Gitaly calls back for authorization (git push)
#   DISK_LUN           LUN of the repository data disk
#   GITALY_TOKEN       (protected) shared token between Gitaly and its clients
#   SHELL_SECRET       (protected) GitLab Shell secret, the same value as the chart's
#   TRUSTED_CA_PEM     optional CA certificate (PEM) that signs the GitLab certificate, when it
#                      is not publicly trusted (the platform internal CA)
set -euo pipefail

: "${PACKAGE_VERSION:?}" "${INTERNAL_API_URL:?}" "${DISK_LUN:?}" "${GITALY_TOKEN:?}" "${SHELL_SECRET:?}"

data_dir=/var/opt/gitlab/git-data

# Repository disk: format once, mount by UUID.
device=$(readlink -f "/dev/disk/azure/scsi1/lun${DISK_LUN}")
if ! blkid "$device" >/dev/null 2>&1; then
  mkfs.ext4 -q -L gitaly "$device"
fi
mkdir -p "$data_dir"
uuid=$(blkid -s UUID -o value "$device")
grep -q "$uuid" /etc/fstab || echo "UUID=$uuid $data_dir ext4 defaults,nofail,noatime 0 2" >> /etc/fstab
mountpoint -q "$data_dir" || mount "$data_dir"

# Package repository and pinned package. apt is held so unattended upgrades never move
# Gitaly ahead of (or behind) the chart.
if ! dpkg -s gitlab-ee >/dev/null 2>&1 || [ "$(dpkg-query -W -f='${Version}' gitlab-ee)" != "$PACKAGE_VERSION" ]; then
  if [ ! -f /etc/apt/sources.list.d/gitlab_gitlab-ee.list ]; then
    curl -fsSL https://packages.gitlab.com/install/repositories/gitlab/gitlab-ee/script.deb.sh | bash
  fi
  apt-mark unhold gitlab-ee >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive GITLAB_SKIP_RECONFIGURE=1 apt-get install -y "gitlab-ee=${PACKAGE_VERSION}"
  apt-mark hold gitlab-ee
fi

if [ -n "${TRUSTED_CA_PEM:-}" ]; then
  install -d -m 755 /etc/gitlab/trusted-certs
  printf '%s\n' "$TRUSTED_CA_PEM" > /etc/gitlab/trusted-certs/platform-internal-ca.crt
fi

umask 077
cat > /etc/gitlab/gitlab.rb <<RB
# Managed by the gitaly-vm module; changes are overwritten on the next deployment.
postgresql['enable'] = false
redis['enable'] = false
nginx['enable'] = false
puma['enable'] = false
sidekiq['enable'] = false
gitlab_workhorse['enable'] = false
gitlab_exporter['enable'] = false
gitlab_kas['enable'] = false
prometheus['enable'] = false
alertmanager['enable'] = false
node_exporter['enable'] = true
gitlab_rails['auto_migrate'] = false
gitlab_rails['internal_api_url'] = '${INTERNAL_API_URL}'

gitaly['enable'] = true
gitaly['gitlab_secret'] = '${SHELL_SECRET}'
gitaly['configuration'] = {
  listen_addr: '0.0.0.0:8075',
  prometheus_listen_addr: '0.0.0.0:9236',
  auth: { token: '${GITALY_TOKEN}' },
  storage: [{ name: 'default', path: '${data_dir}/repositories' }],
}
RB

gitlab-ctl reconfigure
gitlab-ctl status gitaly
