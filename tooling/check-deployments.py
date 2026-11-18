#!/usr/bin/env python3
"""Offline checks across deployments (needs bicep on PATH).

- Address plan: VNet prefixes of all deployments peered to the same hub (same environment)
  don't overlap, and AKS pod and service ranges don't overlap any of them.
- CI runner pools: a pool labelled platform.workload=ci is tainted workload=ci:NoSchedule,
  runs in its own subnet from additionalNodeSubnets, and no other pool shares that subnet.
- GitLab data services: storage, PostgreSQL and Redis have private endpoints and public
  network access disabled.

  check-deployments.py
"""
import ipaddress
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
errors = []


def build_params(path):
    out = subprocess.run(["bicep", "build-params", str(path), "--stdout"], capture_output=True, text=True, check=True)
    params = json.loads(json.loads(out.stdout)["parametersJson"])["parameters"]
    return {k: v.get("value") for k, v in params.items()}


def network_prefixes(p):
    net = p.get("network") or {}
    prefixes = list(net.get("addressPrefixes") or [])
    if net.get("addressPrefix"):
        prefixes.append(net["addressPrefix"])
    return prefixes


def check_address_plan(files):
    by_env = {}
    k8s_ranges = []
    for f in files:
        p = build_params(f)
        env = p.get("environment") or (p.get("tags") or {}).get("environment") or "unknown"
        for prefix in network_prefixes(p):
            by_env.setdefault(env, []).append((ipaddress.ip_network(prefix), f))
        net = p.get("network") or {}
        if f.parts[-3] == "az-aks":
            for key, default in (("podCidr", "192.168.0.0/16"), ("serviceCidr", "172.16.0.0/16")):
                k8s_ranges.append((env, key, ipaddress.ip_network(net.get(key) or default), f))
    for env, nets in by_env.items():
        for i, (a, fa) in enumerate(nets):
            for b, fb in nets[i + 1:]:
                if a.overlaps(b):
                    errors.append(f"address plan ({env}): {a} ({fa.relative_to(ROOT)}) overlaps {b} ({fb.relative_to(ROOT)})")
    for env, key, rng, f in k8s_ranges:
        for n, fn in by_env.get(env, []):
            if rng.overlaps(n):
                errors.append(f"address plan ({env}): {f.relative_to(ROOT)} {key} {rng} overlaps {n} ({fn.relative_to(ROOT)})")
    print(f"address plan: {sum(len(v) for v in by_env.values())} prefixes in {len(by_env)} environments")


def check_runner_pools(files):
    for f in files:
        p = build_params(f)
        pools = (p.get("cluster") or {}).get("userPools") or []
        extra = {s["name"] for s in (p.get("network") or {}).get("additionalNodeSubnets") or []}
        for pool in pools:
            if (pool.get("nodeLabels") or {}).get("platform.workload") != "ci":
                continue
            where = f"{f.relative_to(ROOT)} pool {pool['name']}"
            if "workload=ci:NoSchedule" not in (pool.get("nodeTaints") or []):
                errors.append(f"{where}: CI pool is not tainted workload=ci:NoSchedule")
            subnet = pool.get("subnetName")
            if subnet not in extra:
                errors.append(f"{where}: CI pool is not in its own subnet (additionalNodeSubnets)")
            shared = [o["name"] for o in pools if o is not pool and o.get("subnetName") == subnet]
            if subnet and shared:
                errors.append(f"{where}: subnet {subnet} is shared with {shared}")
            print(f"runner pool: {where} tainted, subnet {subnet}")


def check_gitlab_private_endpoints():
    path = ROOT / "az-gitlab" / "main.bicep"
    out = subprocess.run(["bicep", "build", str(path), "--stdout"], capture_output=True, text=True, check=True)
    resources = json.loads(out.stdout)["resources"]
    items = resources.values() if isinstance(resources, dict) else resources
    # Matched on the AVM module names, so a renamed symbol doesn't hide a missing endpoint.
    wanted = {
        "storage": "Storage Accounts",
        "postgres": "DBforPostgreSQL Flexible Servers",
        "redis": "Redis Enterprise and Azure Managed Redis",
    }
    found = {}
    for r in items:
        if r.get("type") != "Microsoft.Resources/deployments":
            continue
        name = (r.get("properties", {}).get("template", {}).get("metadata") or {}).get("name")
        params = r.get("properties", {}).get("parameters", {})
        for key, module in wanted.items():
            if name == module:
                found.setdefault(key, []).append(params)
    for key in wanted:
        if key not in found:
            errors.append(f"az-gitlab: no {key} deployment found")
        for params in found.get(key, []):
            if "privateEndpoints" not in params:
                errors.append(f"az-gitlab: {key} has no private endpoint")
            if params.get("publicNetworkAccess", {}).get("value") != "Disabled":
                errors.append(f"az-gitlab: {key} public network access is not Disabled")
    print("gitlab private endpoints: " + ", ".join(f"{k} x{len(v)}" for k, v in sorted(found.items())))


def main():
    params = sorted(p for p in ROOT.glob("az-*/**/params/*.bicepparam") if ".work" not in p.parts)
    check_address_plan(params)
    check_runner_pools([p for p in params if p.parts[-3] == "az-aks"])
    check_gitlab_private_endpoints()
    for e in errors:
        print(f"FAIL {e}")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
