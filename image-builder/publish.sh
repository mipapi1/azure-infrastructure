#!/usr/bin/env bash
# Publishes the image builder content to its storage account:
#   1. Installers: every { url, sha256 } with a url in the image param files (default: all of
#      images/) and the pinned STIG defaults in main.bicep is downloaded once to
#      ~/.cache/image-builder, checked against its SHA256 and uploaded to the 'installers'
#      container under its file name. Installers already published are skipped.
#   2. Scripts: stig.ps1, stig-linux.sh and every script in apps/ are uploaded to the 'scripts'
#      container and their SHA256 is written to scripts.json. The templates read scripts.json, and
#      the build checks every file.
# Your public IP is allowed on the storage firewall only while this runs.
#
# Usage: ./image-builder/publish.sh [images/<name>.bicepparam ...]
# Run it after deploying image-builder, and again after changing a script or an installer. If it
# changes scripts.json, delete the template and deploy the image again (templates can't be updated).
# Needs az (signed in; publisherIds in the image param files grants the upload role), curl and python3.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
rg=rg-image-builder
cache=${XDG_CACHE_HOME:-$HOME/.cache}/image-builder
mkdir -p "$cache"

sha() { if command -v sha256sum > /dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

account=$(az storage account list -g "$rg" --query "[?starts_with(name, 'stimagebuilder')].name | [0]" -o tsv)
[[ -n "$account" ]] || { echo "No stimagebuilder<suffix> storage account in $rg. Deploy image-builder first."; exit 1; }

images=("$@")
[[ ${#images[@]} -gt 0 ]] || images=("$here"/images/*.bicepparam)

# One "url sha256" line per installer, wherever it sits in the parameters or their defaults.
installers=$(for f in "${images[@]}"; do az bicep build-params --file "$f" --stdout; done | python3 -I -c '
import json, sys
def walk(value):
    if isinstance(value, dict):
        if value.get("url") and value.get("sha256"):
            print(value["url"], value["sha256"].lower())
        for v in value.values():
            walk(v)
    elif isinstance(value, list):
        for v in value:
            walk(v)
text, decoder, pos = sys.stdin.read(), json.JSONDecoder(), 0
while pos < len(text.strip()):
    out, pos = decoder.raw_decode(text, pos)
    while pos < len(text) and text[pos].isspace():
        pos += 1
    defaults = {k: p.get("defaultValue") for k, p in json.loads(out["templateJson"])["parameters"].items()}
    values = {k: p["value"] for k, p in json.loads(out["parametersJson"])["parameters"].items()}
    walk({**defaults, **values})
' | sort -u)

ip=$(curl -fsS https://api.ipify.org)
echo "Allowing $ip on $account while publishing"
az storage account network-rule add -g "$rg" --account-name "$account" --ip-address "$ip" -o none
trap 'az storage account network-rule remove -g "$rg" --account-name "$account" --ip-address "$ip" -o none && echo "Removed $ip from $account"' EXIT
blob=(--account-name "$account" --auth-mode login --only-show-errors)
until az storage container exists "${blob[@]}" -n installers -o none 2> /dev/null; do sleep 10; done

while read -r url sha256; do
  [[ -n "$url" ]] || continue
  name=${url##*/}
  if [[ $(az storage blob exists "${blob[@]}" -c installers -n "$name" --query exists -o tsv) == true ]]; then
    echo "installers/$name: already published"
    continue
  fi
  file="$cache/$name"
  [[ -f "$file" && $(sha "$file") == "$sha256" ]] || { echo "Downloading $url"; curl -fsSL -o "$file" "$url"; }
  [[ $(sha "$file") == "$sha256" ]] || { echo "SHA256 mismatch for $url: got $(sha "$file"). Fix the param file."; exit 1; }
  az storage blob upload "${blob[@]}" -c installers -n "$name" -f "$file" --metadata sha256="$sha256" -o none
  echo "installers/$name: uploaded"
done <<< "$installers"

hashes=()
for script in stig.ps1 stig-linux.sh $(cd "$here" && find apps -type f | sort); do
  az storage blob upload "${blob[@]}" -c scripts -n "$script" -f "$here/$script" --overwrite -o none
  hashes+=("$script=$(sha "$here/$script")")
  echo "scripts/$script: uploaded"
done
python3 -I -c '
import json, sys
print(json.dumps(dict(h.split("=", 1) for h in sys.argv[1:]), indent=2))
' "${hashes[@]}" > "$here/scripts.json"
git -C "$here" diff --quiet -- scripts.json 2> /dev/null || echo "scripts.json changed: delete the templates and deploy image-builder again."
