#!/usr/bin/env python3
"""Renders a Flux kustomization the way the cluster would see it, for offline checks.

Reads `kustomize build` output on stdin, substitutes ${VARS} from the given ConfigMap files
(Flux postBuild.substituteFrom; unset variables become empty, as in Flux), then replaces every
HelmRelease with the output of `helm template` for its chart, version and values. Everything
else passes through. Writes the combined manifests to stdout.

  kustomize build <dir> | render-gitops.py settings.yaml [more-settings.yaml ...]
"""
import json
import re
import subprocess
import sys
import tempfile

import yaml

# The AKS version the platform runs (cluster.kubernetesVersion).
KUBE_VERSION = "1.34.0"


def settings(paths):
    values = {}
    for path in paths:
        for doc in yaml.safe_load_all(open(path)):
            if doc and doc.get("kind") == "ConfigMap":
                values.update({k: str(v) for k, v in (doc.get("data") or {}).items()})
    return values


def substitute(text, values):
    return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", lambda m: values.get(m.group(1), ""), text)


def main():
    values = settings(sys.argv[1:])
    docs = [d for d in yaml.safe_load_all(substitute(sys.stdin.read(), values)) if d]
    repos = {
        (d["metadata"]["namespace"], d["metadata"]["name"]): d["spec"]
        for d in docs
        if d.get("kind") == "HelmRepository"
    }
    out = []
    for d in docs:
        if d.get("kind") != "HelmRelease":
            out.append(yaml.safe_dump(d, sort_keys=False))
            continue
        chart = d["spec"]["chart"]["spec"]
        ref = chart["sourceRef"]
        repo = repos.get((ref.get("namespace", d["metadata"]["namespace"]), ref["name"]))
        if repo is None:
            sys.exit(f"HelmRelease {d['metadata']['name']}: HelmRepository {ref['name']} not in the build")
        with tempfile.NamedTemporaryFile("w", suffix=".json") as f:
            json.dump(d["spec"].get("values") or {}, f)
            f.flush()
            name = d["spec"].get("releaseName", d["metadata"]["name"])
            ns = d["spec"].get("targetNamespace", d["metadata"]["namespace"])
            if repo.get("type") == "oci":
                source = ["{}/{}".format(repo["url"].rstrip("/"), chart["chart"])]
            else:
                source = [chart["chart"], "--repo", repo["url"]]
            cmd = ["helm", "template", name, *source, "--version", str(chart["version"]),
                   "--namespace", ns, "--include-crds", "--kube-version", KUBE_VERSION,
                   "--api-versions", "networking.k8s.io/v1/Ingress", "-f", f.name]
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode:
                sys.exit(f"helm template {name} failed:\n{result.stderr}")
        out.append(result.stdout)
    sys.stdout.write("\n---\n".join(out))


if __name__ == "__main__":
    main()
