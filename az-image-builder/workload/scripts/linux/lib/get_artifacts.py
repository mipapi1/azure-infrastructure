#!/usr/bin/env python3
"""Download artifacts.json entries for the given groups with the build VM's managed identity (IMDS),
verify each SHA256 and extract .zip / .tar.* archives that have extractTo. Any failure exits non-zero."""
import argparse
import hashlib
import json
import os
import sys
import tarfile
import time
import urllib.parse
import urllib.request
import zipfile

IMDS = "http://169.254.169.254/metadata/identity/oauth2/token"


def token(client_id):
    query = urllib.parse.urlencode({"api-version": "2018-02-01", "resource": "https://storage.azure.com/", "client_id": client_id})
    for attempt in range(1, 11):
        try:
            req = urllib.request.Request(f"{IMDS}?{query}", headers={"Metadata": "true"})
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)["access_token"]
        except Exception as e:  # IMDS can briefly fail after boot or identity attach
            if attempt == 10:
                raise SystemExit(f"Could not get a storage token for {client_id}: {e}")
            time.sleep(min(60, 2 ** attempt))


def download(artifact, endpoint, container, bearer):
    dest = artifact["destination"]
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    blob = "/".join(urllib.parse.quote(p) for p in artifact["blob"].split("/"))
    url = f"{endpoint.rstrip('/')}/{container}/{blob}"
    print(f"[{artifact['name']}] {artifact['blob']} -> {dest}", flush=True)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {bearer}", "x-ms-version": "2023-11-03"})
    digest = hashlib.sha256()
    with urllib.request.urlopen(req, timeout=3600) as r, open(dest, "wb") as f:
        for chunk in iter(lambda: r.read(1 << 20), b""):
            digest.update(chunk)
            f.write(chunk)
    if digest.hexdigest().upper() != artifact["sha256"].upper():
        os.remove(dest)
        raise RuntimeError(f"SHA256 mismatch: expected {artifact['sha256']}, got {digest.hexdigest().upper()}")
    extract_to = artifact.get("extractTo")
    if extract_to:
        os.makedirs(extract_to, exist_ok=True)
        if zipfile.is_zipfile(dest):
            with zipfile.ZipFile(dest) as z:
                z.extractall(extract_to)
        else:
            safe = {"filter": "data"} if hasattr(tarfile, "data_filter") else {}
            with tarfile.open(dest) as t:
                t.extractall(extract_to, **safe)
        print(f"[{artifact['name']}] extracted to {extract_to}", flush=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--manifest", required=True)
    p.add_argument("--group", required=True, help="comma-separated groups")
    p.add_argument("--blob-endpoint", required=True)
    p.add_argument("--client-id", required=True)
    a = p.parse_args()

    with open(a.manifest) as f:
        manifest = json.load(f)
    groups = [g for g in a.group.split(",") if g]
    unknown = sorted(set(groups) - {x["group"] for x in manifest["artifacts"]})
    if unknown:
        raise SystemExit(f"Unknown artifact group(s): {', '.join(unknown)}. Check artifacts.json.")

    selected = [x for x in manifest["artifacts"] if x["group"] in groups]
    bearer = token(a.client_id)
    failed = []
    for artifact in selected:
        try:
            download(artifact, a.blob_endpoint, manifest["container"], bearer)
        except Exception as e:
            print(f"[{artifact['name']}] {e}", file=sys.stderr)
            failed.append(artifact["name"])
    if failed:
        raise SystemExit(f"Failed to download/verify: {', '.join(failed)}")
    print(f"{len(selected)} artifact(s) downloaded and verified.")


if __name__ == "__main__":
    main()
