# Compliance policy

Regulatory compliance and platform guardrail policies for one management group. It is called by `az-landing-zone/governance` (`compliancePolicy`) at the root of the prod and canary hierarchies.

| Assignment | Definition | Default |
|---|---|---|
| `NIST-800-53-R5` | Built-in initiative `179d1daa-458f-4e47-8086-2a68d0d6c38f` (NIST SP 800-53 Rev. 5) | `DoNotEnforce`. The initiative's own effects are Audit or Disabled, so no identity is needed. |
| `Platform-Guardrails` | Custom initiative `platform-guardrails`, created on this management group | `DoNotEnforce`, Audit |

The guardrails initiative contains:

- `platform-storage-shared-key-exception` (custom): flags storage accounts that allow shared key access, unless the account's `shared-key-exception` tag has a value in `sharedKeyExceptionValues`. This replaces the built-in `8c6a50c6`, which has no exception path.
- Built-ins:
  - Storage public network access disabled (`b2982f36`)
  - Key Vault public network access disabled (`405c5871`)
  - Automation public network access disabled (`955a914f`)
  - Automation local authentication disabled (`48c5f1cb`)
  - Encryption at host (`fc4d8e41`)

See `docs/CONTROL-MAPPING.md` and D-032.

## Parameters

<!-- BEGIN_PARAMS -->
| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `managementGroupId` | string | no | computed | Management group the definitions live on and the initiatives are assigned to. Defaults to the deployment scope. |
| `location` | string | yes |  | Location of the deployment metadata. |
| `assignNist` | bool | no | `true` | Assign the NIST SP 800-53 Rev. 5 initiative. Defaults to true. |
| `nistParameters` | object | no | `{}` | Parameter values for the NIST initiative, in assignment format ({ name: { value: x } }). Defaults to the initiative defaults. |
| `enforcementMode` | `Default` \| `DoNotEnforce` | no | `"DoNotEnforce"` | Enforcement of both assignments. DoNotEnforce (default) evaluates and reports without blocking or remediating. |
| `guardrailEffect` | `Audit` \| `Deny` \| `Disabled` | no | `"Audit"` | Effect of the guardrail policies. Audit (default) reports; Deny blocks non-compliant changes once enforcementMode is Default. |
| `sharedKeyExceptionValues` | string[] | no | `["fslogix-cloud-cache"]` | Values the shared-key-exception tag may take. Each value names a documented exception (D-025). |
| `enableTelemetry` | bool | no | `true` | Enable AVM usage telemetry. |

| Output | Type | Description |
|---|---|---|
| `guardrailsInitiativeResourceId` | string | Resource ID of the guardrails initiative. |
| `nistAssignmentResourceId` | string | Resource ID of the NIST SP 800-53 Rev. 5 assignment, empty when assignNist is false. |
| `guardrailsAssignmentResourceId` | string | Resource ID of the guardrails assignment. |
<!-- END_PARAMS -->
