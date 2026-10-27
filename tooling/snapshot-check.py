#!/usr/bin/env python3
"""Evaluate deployments offline with `bicep snapshot` and check the predicted resources.

Every az-*/params/*.bicepparam and az-*/tests/**/*.bicepparam file is snapshotted
(placeholder tenant and subscription, no Azure access). Files whose first line is

    // expect-error: <text>

must fail, with <text> in the error (parameter-validation guards). Every other
file must succeed and pass the checks below. Snapshots are written to
out/snapshot/. Run it with `make snapshot`.
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "out" / "snapshot"
ZERO = "00000000-0000-0000-0000-000000000000"
EXPECT = re.compile(r"^//\s*expect-error:\s*(.+)$")

# Output names or values that look like secrets.
SECRET_OUTPUT = re.compile(r"(?i)(token|password|connectionstring|accountkey|sharedaccesssignature|secret$|secretvalue)")


def param_files() -> list[pathlib.Path]:
    files = sorted(ROOT.glob("az-*/params/*.bicepparam"))
    files += sorted(ROOT.glob("az-*/tests/**/*.bicepparam"))
    return [f for f in files if "az-image-builder/tests" not in f.as_posix()]


def snapshot(path: pathlib.Path) -> tuple[bool, str]:
    args = ["bicep", "snapshot", str(path), "--mode", "overwrite", "--tenant-id", ZERO, "--location", "eastus"]
    using = re.search(r"^using '(.+)'", path.read_text(), re.M)
    template = (path.parent / using.group(1)).read_text() if using else ""
    scope = re.search(r"^targetScope\s*=\s*'(\w+)'", template, re.M)
    scope = scope.group(1) if scope else "resourceGroup"
    if scope in ("subscription", "resourceGroup"):
        args += ["--subscription-id", ZERO]
    if scope == "resourceGroup":
        args += ["--resource-group", "snapshot-rg"]
    if scope == "managementGroup":
        args += ["--management-group-id", "snapshot-mg"]
    proc = subprocess.run(args, capture_output=True, text=True)
    return proc.returncode == 0, (proc.stdout + proc.stderr).strip()


def rtype(r: dict) -> str:
    return r.get("type", "").lower()


def check_common(snap: dict) -> list[str]:
    errors = []
    for name, out in (snap.get("outputs") or {}).items():
        value = out.get("value", "") if isinstance(out, dict) else out
        if SECRET_OUTPUT.search(name) or SECRET_OUTPUT.search(json.dumps(value)):
            errors.append(f"output '{name}' looks like a secret")
    return errors


def check_avd(snap: dict) -> list[str]:
    errors = []
    resources = snap.get("predictedResources", [])
    for r in resources:
        t, p = rtype(r), r.get("properties") or {}
        if t == "microsoft.storage/storageaccounts":
            exception = (r.get("tags") or {}).get("shared-key-exception")
            if p.get("allowSharedKeyAccess") and not exception:
                errors.append(f"{r['name']}: shared key access without the shared-key-exception tag")
            if p.get("publicNetworkAccess") != "Disabled":
                errors.append(f"{r['name']}: public network access is not disabled")
        if t == "microsoft.compute/virtualmachines/runcommands":
            # Only references to protected parameters may carry the connection string.
            for prm in p.get("parameters") or []:
                if re.search(r"(?i)accountkey|listkeys", json.dumps(prm.get("value", ""))):
                    errors.append(f"{r['name']}: storage key in a non-protected Run Command parameter")
        if t == "microsoft.network/networkinterfaces":
            for ipc in p.get("ipConfigurations") or []:
                if (ipc.get("properties") or {}).get("publicIPAddress"):
                    errors.append(f"{r['name']}: session host NIC has a public IP")
    errors += check_ip_groups(resources)
    errors += check_host_order(resources)
    return errors


# Run Commands that must run in this order on each host. bicep snapshot lists resources in
# dependency order, so a later step listed before an earlier one means a missing dependsOn.
HOST_STEPS = ["configure-fslogix", "apply-deferred-stigs", "configure-laps-break-glass", "register-compliance-evidence"]


def check_host_order(resources: list[dict]) -> list[str]:
    errors = []
    seen: dict[str, list[str]] = {}
    for r in resources:
        if rtype(r) == "microsoft.compute/virtualmachines/runcommands":
            host, _, step = r["name"].partition("/")
            if step in HOST_STEPS:
                seen.setdefault(host, []).append(step)
    for host, steps in seen.items():
        if steps != sorted(steps, key=HOST_STEPS.index):
            errors.append(f"{host}: Run Commands out of order: {', '.join(steps)}")
    # The scaling plan may be paused while hosts deploy, but its last state must be enabled.
    plans = [r for r in resources if rtype(r) == "microsoft.desktopvirtualization/scalingplans"]
    if plans:
        refs = (plans[-1].get("properties") or {}).get("hostPoolReferences") or []
        if not all(ref.get("scalingPlanEnabled") for ref in refs):
            errors.append(f"{plans[-1]['name']}: scaling plan left disabled after the session hosts deploy")
    return errors


def check_ip_groups(resources: list[dict]) -> list[str]:
    """When the deployment creates IP Groups, its own rules must not fall back to literal prefixes."""
    if not any(rtype(r) == "microsoft.network/ipgroups" for r in resources):
        return []
    errors = []
    for r in resources:
        if rtype(r) != "microsoft.network/firewallpolicies/rulecollectiongroups":
            continue
        for c in (r.get("properties") or {}).get("ruleCollections") or []:
            for rule in c.get("rules") or []:
                if rule.get("sourceAddresses") or not rule.get("sourceIpGroups"):
                    errors.append(f"{r['name']}/{rule.get('name')}: IP Groups enabled but rule uses literal source addresses")
    return errors


CHECKS = {"az-avd": check_avd, "az-aks": lambda s: check_ip_groups(s.get("predictedResources", []))}

# Deployments bicep snapshot can't evaluate offline.
SKIP = {
    "az-landing-zone": "the private DNS zone loop count depends on environment(), unknown offline",
}


def main() -> int:
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    failed = 0
    for path in param_files():
        rel = path.relative_to(ROOT).as_posix()
        if rel.split("/")[0] in SKIP:
            print(f"skip {rel} ({SKIP[rel.split('/')[0]]})")
            continue
        first = path.read_text().splitlines()[0] if path.read_text() else ""
        expect = EXPECT.match(first)
        ok, log = snapshot(path)
        generated = path.with_suffix(".snapshot.json")
        # bicep snapshot exits 0 even when evaluation fails; trust the message and the file.
        ok = ok and "could not be completed" not in log and generated.exists()
        errors: list[str] = []
        if expect:
            if ok:
                errors.append("expected the deployment to be rejected, but the snapshot succeeded")
            elif expect.group(1).strip() not in log:
                errors.append(f"rejected, but without the expected message: {log[-300:]}")
        elif not ok:
            errors.append(log[-500:])
        else:
            snap = json.loads(generated.read_text())
            errors += check_common(snap)
            errors += CHECKS.get(rel.split("/")[0], lambda s: [])(snap)
        if generated.exists():
            generated.replace(OUT / (rel.replace("/", "_").removesuffix(".bicepparam") + ".snapshot.json"))
        status = "FAIL" if errors else "ok  "
        print(f"{status} {rel}{' (rejected as expected)' if expect and not errors else ''}")
        for e in errors:
            print(f"     {e}")
        failed += bool(errors)
    print(f"\n{failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
