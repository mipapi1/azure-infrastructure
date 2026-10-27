# NIST SP 800-53 Rev. 5 control mapping

This page maps NIST SP 800-53 Rev. 5 control families to two things: the platform features that
support them, and the evidence Azure Policy and the platform collect for them.

It is an engineering aid. It is **not** a compliance claim, an assessment or a System Security Plan.
Azure Policy compliance means that the evaluated resource settings match the policy. It does not
show that a control is implemented, and many controls are organizational, procedural or physical.
An assessor decides whether a control is met.

## Where the data comes from

| Source | What it shows | Where |
| --- | --- | --- |
| NIST SP 800-53 Rev. 5 initiative (built-in `179d1daa-458f-4e47-8086-2a68d0d6c38f`, version 14.21.0 when this page was written) | Per-control policy results for Azure resources. Assigned at the root management group by `modules/governance/compliance-policy`. | Policy > Compliance; Defender for Cloud > Regulatory compliance (needs a paid Defender plan other than Servers Plan 1 or API Plan 1) |
| Platform guardrails initiative (custom) | Whether resources keep the platform security defaults (see the table below) | Policy > Compliance |
| AVD compliance evidence (`AvdComplianceEvidence_CL`) | STIG and SCAP results per host, and the AppLocker, Defender, registry and security policy state | AVD compliance workbook (az-avd `compliance.evidence`) |
| AppLocker and Defender events | Blocked executables and Defender detections or configuration changes | `Event` table through the security DCR (az-avd `compliance.securityEvents`) |
| Emergency access alerts | Every sign-in or directory change made by a break-glass account | Scheduled query alerts (az-landing-zone `breakGlassAccountObjectIds`) |
| Standing access inventory | Permanent privileged assignments | `az-landing-zone/governance/scripts/Get-StandingPrivilegedAccess.ps1` |

The initiative has 970 control groups and 693 policy references. Many references are
Microsoft-managed controls or manual attestations, not checks on your resources. The table
counts them per family as of version 14.21.0. Run the query under
[Refreshing the counts](#refreshing-the-counts) for the current numbers.

## Families

| Family | Controls in initiative | Controls with policies | Policy references | Platform features that support the family |
| --- | ---: | ---: | ---: | --- |
| AC Access Control | 131 | 45 | 166 | Entra ID authentication on AVD, storage and Key Vault. Shared key access is disabled except where a tag records the exception (guardrail). PIM-eligible role assignments (`eligibleRoleAssignments`) and PIM for Groups. Private endpoints with public network access disabled (guardrails). AVD RBAC on application groups. |
| AT Awareness and Training | 15 | 6 | 12 | None. This family is organizational. |
| AU Audit and Accountability | 56 | 25 | 64 | Central Log Analytics workspace. Diagnostic settings and activity log policies (governance, after the second pass). AVD and FSLogix logs. The compliance evidence table and security event DCR. |
| CA Assessment, Authorization and Monitoring | 25 | 13 | 22 | Azure Policy continuous evaluation. The canary hierarchy is used to test policy changes. Defender for Cloud regulatory dashboard. |
| CM Configuration Management | 56 | 25 | 63 | Infrastructure as code with pinned AVM versions. Gallery images built by Image Builder with STIGs applied at build and deploy time (deferred STIG run command). AppLocker. Daily evidence of drift. |
| CP Contingency Planning | 49 | 28 | 45 | Zone-redundant storage in prod. Soft delete on blobs and file shares. Resource locks in prod. |
| IA Identification and Authentication | 55 | 20 | 53 | Entra ID join and cloud-only identities. Emergency access accounts with passkeys. Windows LAPS for the host break-glass account. |
| IR Incident Response | 40 | 24 | 45 | Action group alerts. Emergency access sign-in alerts. Defender event forwarding. |
| MA Maintenance | 28 | 13 | 13 | Scaling plan paused during host deployment. Run commands instead of interactive maintenance. |
| MP Media Protection | 20 | 9 | 7 | Encryption at host (guardrail). Storage encryption at rest (service default). |
| PE Physical and Environmental Protection | 51 | 17 | 14 | None. Azure inherits this family. |
| PL Planning | 11 | 5 | 18 | `docs/ARCHITECTURE.md` and `docs/DECISIONS.md`. |
| PS Personnel Security | 17 | 10 | 27 | None. This family is organizational. |
| PT PII Processing and Transparency | 21 | 0 | 0 | None. |
| RA Risk Assessment | 22 | 11 | 48 | Defender for Cloud recommendations. SCAP results in the compliance evidence when a scanner is configured. |
| SA System and Services Acquisition | 106 | 21 | 55 | Pinned module and image versions. Renovate updates. Pre-commit, lint and PSRule checks in CI. |
| SC System and Communications Protection | 139 | 35 | 158 | Hub-spoke network through Azure Firewall (IP Groups, service tags). Private endpoints, with public network access disabled on storage, Key Vault and Automation (guardrails). TLS 1.2 minimum. Trusted launch and guest attestation on session hosts. |
| SI System and Information Integrity | 101 | 24 | 68 | Defender Antivirus state and events. Guest attestation. Image rebuilds for patching. |
| SR Supply Chain Risk Management | 27 | 0 | 0 | Pinned AVM versions from the public registry. |

## Platform guardrails

The guardrails initiative (`platform-guardrails`) checks the defaults that `docs/CONVENTIONS.md`
requires. The effect defaults to Audit and the assignment to DoNotEnforce.

| Reference | Definition | Related controls (examples) |
| --- | --- | --- |
| storage-shared-key-exception | Custom `platform-storage-shared-key-exception`. Shared key access must be disabled unless the `shared-key-exception` tag has an approved value. | AC-3, IA-2 |
| storage-no-public-network | Built-in `b2982f36-99f2-4db5-8eff-283140c09693` | AC-4, SC-7 |
| keyvault-no-public-network | Built-in `405c5871-3e91-4644-8a63-58e19d68ff5b` | AC-4, SC-7 |
| automation-no-public-network | Built-in `955a914f-bf86-4f0e-acd5-e0766b0efcb6` | AC-4, SC-7 |
| automation-no-local-auth | Built-in `48c5f1cb-14ad-4797-8e3b-f78ab3f8d700` | AC-2, IA-2 |
| vm-encryption-at-host | Built-in `fc4d8e41-e223-45ea-9bf5-eada37891d87` | SC-28 |

The control references in the last column are examples for orientation. They are not an
assessed mapping.

### Shared key exceptions

| Tag value | Resource | Why |
| --- | --- | --- |
| `fslogix-cloud-cache` | FSLogix Cloud Cache blob account (az-avd, `fslogix.storageType: 'BlobCloudCache'`) | FSLogix authenticates to page blobs with an account key only (D-025). The key is read during deployment and passed only as a protected run command parameter. |

To add an exception, put the value in `compliancePolicy.sharedKeyExceptionValues`, tag the
account, and record why in DECISIONS.md. For a one-off, a policy exemption is the better tool.

## Refreshing the counts

```bash
az policy set-definition show --name 179d1daa-458f-4e47-8086-2a68d0d6c38f --query properties.metadata.version
```

```bash
az policy set-definition show --name 179d1daa-458f-4e47-8086-2a68d0d6c38f -o json \
  | python3 -c 'import json,sys,collections as c; p=json.load(sys.stdin); n=c.Counter(r.split("_")[-1].split("-")[0] for x in p["policyDefinitions"] for r in x.get("groupNames",[])); print(sorted(n.items()))'
```
