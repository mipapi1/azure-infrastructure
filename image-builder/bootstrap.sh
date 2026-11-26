#!/usr/bin/env bash
# First Image Builder step on Linux. Downloads the build scripts and installers from the image builder
# storage account with the build VM's managed identity (over the private endpoint) and checks each
# file's SHA256 against the value in the template. Any mismatch stops the build.
# Embedded in the template by main.bicep. Usage: bootstrap.sh <client-id> <files-base64>, where the
# decoded files list has one "uri sha256 path" per line.
set -euo pipefail
client_id=$1
files=$(echo "$2" | base64 -d)

token_uri="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F&client_id=${client_id}"
token=""
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  token=$(curl -fsS -H Metadata:true "$token_uri" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p') && [[ -n "$token" ]] && break
  sleep $((5 * attempt))
done
[[ -n "$token" ]] || { echo "Bootstrap: no storage token for identity ${client_id}"; exit 1; }

count=0
while read -r uri sha256 path; do
  [[ -n "$uri" ]] || continue
  echo "Bootstrap: ${uri}"
  install -d "$(dirname "$path")"
  curl -fsSL -H "Authorization: Bearer ${token}" -H "x-ms-version: 2023-11-03" -o "$path" "$uri"
  echo "${sha256,,}  ${path}" | sha256sum -c --quiet - || { echo "Bootstrap: SHA256 mismatch for ${uri}. Run image-builder/publish.sh."; exit 1; }
  count=$((count + 1))
done <<< "$files"
echo "Bootstrap: ${count} file(s) verified."
