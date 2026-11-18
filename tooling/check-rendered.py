#!/usr/bin/env python3
"""Policy checks on rendered cluster manifests (render-gitops.py output on stdin).

- Every LoadBalancer Service is internal, and only the namespaces in --lb-namespaces have one
  (D-023 exception for Git over SSH in the gitlab namespace).
- Every NginxIngressController uses an internal load balancer, and every Ingress uses one of
  the rendered controllers' classes or an allowed internal class.
- No privileged containers or host namespaces.
- GitLab Runner jobs (config.toml) are unprivileged and pinned to the tainted CI pool.

  render-gitops.py ... | check-rendered.py [--lb-namespaces gitlab] [--ingress-classes a,b]
"""
import argparse
import re
import sys

import yaml

INTERNAL = "service.beta.kubernetes.io/azure-load-balancer-internal"


def pod_specs(doc):
    kind = doc.get("kind")
    spec = doc.get("spec") or {}
    if kind == "Pod":
        yield spec
    elif kind in ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"):
        yield (spec.get("template") or {}).get("spec") or {}
    elif kind == "CronJob":
        yield ((spec.get("jobTemplate") or {}).get("spec") or {}).get("template", {}).get("spec") or {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lb-namespaces", default="")
    ap.add_argument("--ingress-classes", default="")
    args = ap.parse_args()
    lb_namespaces = {n for n in args.lb_namespaces.split(",") if n}
    classes = {c for c in args.ingress_classes.split(",") if c}
    docs = [d for d in yaml.safe_load_all(sys.stdin) if isinstance(d, dict)]
    errors = []

    for d in docs:
        if d.get("kind") == "NginxIngressController":
            ann = (d["spec"].get("loadBalancerAnnotations") or {})
            if str(ann.get(INTERNAL, "")).lower() != "true":
                errors.append(f"NginxIngressController {d['metadata']['name']}: load balancer is not internal")
            classes.add(d["spec"]["ingressClassName"])

    for d in docs:
        meta = d.get("metadata") or {}
        where = f"{d.get('kind')} {meta.get('namespace', '-')}/{meta.get('name')}"
        if d.get("kind") == "Service" and (d.get("spec") or {}).get("type") == "LoadBalancer":
            if meta.get("namespace") not in lb_namespaces:
                errors.append(f"{where}: LoadBalancer outside {sorted(lb_namespaces) or 'any allowed namespace'}")
            if str((meta.get("annotations") or {}).get(INTERNAL, "")).lower() != "true":
                errors.append(f"{where}: LoadBalancer is not internal")
        if d.get("kind") == "Ingress":
            cls = (d.get("spec") or {}).get("ingressClassName")
            if cls not in classes:
                errors.append(f"{where}: ingress class {cls!r} is not an internal controller")
        for spec in pod_specs(d):
            if spec.get("hostNetwork") or spec.get("hostPID") or spec.get("hostIPC"):
                errors.append(f"{where}: host namespace")
            for c in (spec.get("containers") or []) + (spec.get("initContainers") or []):
                if ((c.get("securityContext") or {}).get("privileged")):
                    errors.append(f"{where}: container {c.get('name')} is privileged")
        if d.get("kind") == "ConfigMap" and "config.template.toml" in (d.get("data") or {}):
            toml = d["data"]["config.template.toml"]
            for needle, message in [
                (r"privileged\s*=\s*false", "runner jobs must set privileged = false"),
                (r'"platform\.workload"\s*=\s*"ci"', "runner jobs must select the CI pool"),
                (r'"workload=ci"\s*=\s*"NoSchedule"', "runner jobs must tolerate the CI pool taint"),
            ]:
                if not re.search(needle, toml):
                    errors.append(f"{where}: {message}")

    for e in errors:
        print(f"FAIL {e}")
    print(f"rendered checks: {len(docs)} objects, {len(errors)} failures")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
