#!/usr/bin/env python3
"""Compliance summary from an OpenSCAP ARF result.

  summarize.py --arf results-arf.xml --tailoring tailoring.xml --phase build --exceptions <files> --findings <files> > summary.json
  summarize.py --print summary.json

Every failed rule is classified: deployTime / open (documented in findings/*.txt) or unexplained."""
import argparse
import collections
import datetime
import json
import os
import xml.etree.ElementTree as ET

XCCDF = "{http://checklists.nist.gov/xccdf/1.2}"
PREFIX = "xccdf_org.ssgproject.content_rule_"


def read_list(paths):
    """'rule_id [category] # reason' lines -> {rule: (category, reason)}."""
    entries = {}
    for path in paths:
        if not os.path.exists(path):
            continue
        for line in open(path, encoding="utf-8"):
            body, _, reason = line.partition("#")
            fields = body.split()
            if fields:
                entries[fields[0]] = (fields[1] if len(fields) > 1 else "", reason.strip())
    return entries


def summarize(a):
    results, benchmark = {}, ""
    for _, el in ET.iterparse(a.arf):
        if el.tag == f"{XCCDF}rule-result":
            results[el.get("idref").replace(PREFIX, "")] = el.findtext(f"{XCCDF}result")
        elif el.tag == f"{XCCDF}benchmark" and el.get("href"):
            benchmark = el.get("href")

    # Excluded = deselected in the tailoring file; the reason comes from exceptions/*.txt.
    reasons = read_list(a.exceptions)
    excluded = sorted(
        el.get("idref").replace(PREFIX, "")
        for el in ET.parse(a.tailoring).iter(f"{XCCDF}select")
        if el.get("selected") == "false"
    )
    findings = read_list(a.findings)
    failed = sorted(k for k, v in results.items() if v == "fail")

    def reason(rule):
        return {"rule": rule, "reason": findings[rule][1]}

    return {
        "generatedUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "phase": a.phase,
        "profile": a.profile,
        "benchmark": benchmark,
        "note": "OpenSCAP scan with the SCAP Security Guide STIG profile. Supports, but is not, an authoritative DISA STIG assessment.",
        "counts": dict(sorted(collections.Counter(v for v in results.values() if v != "notselected").items())),
        "excluded": [{"rule": r, "reason": reasons.get(r, ("", "image parameter excludeRules"))[1]} for r in excluded],
        "failed": {
            "deployTime": [reason(r) for r in failed if findings.get(r, ("",))[0] == "deploy"],
            "open": [reason(r) for r in failed if findings.get(r, ("",))[0] == "open"],
            "unexplained": [r for r in failed if r not in findings],
        },
        "manualReview": sorted(k for k, v in results.items() if v in ("notchecked", "informational")),
        "errors": sorted(k for k, v in results.items() if v in ("error", "unknown")),
    }


def show(path):
    s = json.load(open(path, encoding="utf-8"))
    f = s["failed"]
    print(f"[{s['phase']}] {s['profile']}: " + ", ".join(f"{k} {v}" for k, v in s["counts"].items()))
    print(f"  excluded {len(s['excluded'])}, failed: deploy-time {len(f['deployTime'])}, open {len(f['open'])}, unexplained {len(f['unexplained'])}, manual review {len(s['manualReview'])}")
    for rule in f["unexplained"]:
        print(f"  UNEXPLAINED fail: {rule}  (remediate, or add it to findings/*.txt with a justification)")


p = argparse.ArgumentParser()
p.add_argument("--arf")
p.add_argument("--profile", default="stig")
p.add_argument("--phase", default="build")
p.add_argument("--exceptions", nargs="*", default=[])
p.add_argument("--findings", nargs="*", default=[])
p.add_argument("--tailoring")
p.add_argument("--print", dest="show")
args = p.parse_args()
if args.show:
    show(args.show)
else:
    print(json.dumps(summarize(args), indent=2))
