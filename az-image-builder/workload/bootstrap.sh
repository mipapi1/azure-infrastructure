#!/usr/bin/env bash
# Image Builder bootstrap for Linux (first customizer). Embedded in the template by main.bicep, so the
# expected SHA256 of every script comes from the template. Downloads the scripts to /opt/imagebuilder with
# the build VM's managed identity and verifies each hash.
set -euo pipefail

base_uri='__SCRIPTS_BASE_URI__'
client_id='__CLIENT_ID__'
root=/opt/imagebuilder

install -d -m 0700 "$root"

token=''
for attempt in $(seq 1 10); do
  token=$(curl -fsS --max-time 30 -H 'Metadata: true' \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F&client_id=${client_id}" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])') && break
  echo "IMDS token attempt ${attempt} failed" >&2
  sleep $((5 * attempt))
done
[ -n "$token" ] || { echo "Could not get a storage token from IMDS for ${client_id}" >&2; exit 1; }

count=0
while read -r hash path; do
  [ -n "$hash" ] || continue
  dest="${root}/${path}"
  install -d -m 0700 "$(dirname "$dest")"
  echo "Fetching ${path}"
  curl -fsS --retry 3 -H "Authorization: Bearer ${token}" -H 'x-ms-version: 2023-11-03' -o "$dest" "${base_uri}/${path}"
  if ! echo "${hash,,}  ${dest}" | sha256sum -c --quiet -; then
    echo "SHA256 mismatch for ${path}. Re-run Publish-ImageBuilderContent.ps1 and redeploy." >&2
    exit 1
  fi
  count=$((count + 1))
done <<'FILES'
__FILES__
FILES
chmod -R u+rwX,go-rwx "$root"
echo "Bootstrap complete: ${count} file(s) verified."
