# Blockers and open decisions

Items found while hardening the platform. Each lists what was tried, the default chosen, and what needs a decision.

## Prompt and scope

### B-001 Phase 5 text was truncated in the first copy of the brief
- **What happened:** the brief was pasted twice; the first copy stops at Phase 5 item 4 ("Two").
- **Default:** the complete second copy is followed.
- **Decision needed:** none, unless the first copy was meant to differ.

### B-002 Phase 7 and Phase 7b overlap
- **What happened:** Phase 7 puts GitLab on tainted node pools of the existing cluster; Phase 7b puts it in a separate tools cluster in its own spoke (prod) with an optional shared-cluster mode (staging).
- **Default:** Phase 7b, which includes Phase 7's GitLab requirements, is implemented; Phase 7's layout is the staging shared-cluster mode.
- **Decision needed:** confirm.

### B-003 GitLab source repository path
- **What happened:** the brief says `<path to local repo>` for the gitlab-aks project.
- **Default:** the gitlab-aks folder next to this repository.
- **Decision needed:** confirm the path if it's a different checkout.

## Phase 1: cloud-only identities

### B-004 No assert in parameter files
- **What was tried:** Bicep `assert` statements. They're experimental (`assertions` and `testFramework` flags), only run under `bicep test`, and can only be written in `.bicep` files, not `.bicepparam`.
- **Default:** a `fail()` guard in `az-avd/main.bicep` (D-026), tested offline with `bicep snapshot` and the `az-avd/tests/invalid/` files. `fail()` exists in Bicep 0.47, contrary to the brief.
- **Decision needed:** none, unless parameter-file asserts are required once the feature is stable.

### B-005 Cloud-only group tag and private link URIs are a manual post-deploy step
- **What was tried:** the storage AVM (0.33.1) and the storage resource provider have no property for either; only Microsoft Graph can set them on the auto-generated application.
- **Default:** `az-avd/scripts/Set-CloudOnlyKerberos.ps1`, run by a Cloud Application Administrator after deployment. No deployment script (it would need `Application.ReadWrite.All`).
- **Decision needed:** whether an automation identity may hold `Application.ReadWrite.All` so a pipeline can run the script.

### B-006 Preview status conflicts in Microsoft's documentation
- **What was found:** Azure Files lists cloud-only identities as GA (2026 Q2); the Entra Kerberos overview still says preview, and the `kdc_enable_cloud_group_sids` tag is documented as preview.
- **Default:** supported and documented, with the tag marked preview.
- **Decision needed:** whether a preview dependency is acceptable for prod cloud-only pools, or prod should use `BlobCloudCache` until the tag is GA.

### B-007 Government-cloud rejection can't be tested offline
- **What was tried:** `bicep snapshot` can't resolve `environment()`, so the US Gov/China guard is only exercised at deployment time.
- **Default:** the guard is separate from the parameter-only guards (which are tested); the Gov case relies on code review.
- **Decision needed:** none; a what-if run in a Gov subscription would confirm it.

### B-008 Root folder permissions for cloud-only users are a portal step
- **What was found:** File Explorer can't set ACLs for cloud-only identities; Microsoft's documented method is the share's **Manage access** page in the Azure portal. No CLI or API equivalent is documented.
- **Default:** documented as a post-deploy step in `az-avd/README.md`.
- **Decision needed:** none; revisit when a scriptable method is documented.

## Phase 3: host additions

### B-009 LAPS without Intune uses a registry root Microsoft calls test-only
- **What was found:** Windows LAPS on Entra-joined devices is configured through the CSP (Intune); LAPS Group Policy applies to domain-joined devices. The Local Configuration root (`HKLM\Software\Microsoft\Windows\CurrentVersion\LAPS\Config`) works but is "primarily intended to be used for testing and development".
- **Default:** `localAdmin.breakGlass.configurationMethod` is `Intune` when hosts are Intune-enrolled (nothing written, README lists the policy), `RunCommand` (Local Configuration root) otherwise. Break-glass is off by default.
- **Decision needed:** whether Local Configuration is acceptable for non-Intune pools, or break-glass should require Intune or Group Policy.

### B-010 Intune LAPS profile and automatic account management
- **What was found:** Intune's LAPS article says its policies manage an existing account and don't create one; the Windows LAPS CSP documents automatic account management for 24H2. Whether the Intune profile exposes those settings in every tenant wasn't confirmed.
- **Default:** README says to use them when offered, otherwise create the account first and set Administrator Account Name.
- **Decision needed:** none; confirm in the Intune admin center.

### B-011 Break-glass account and V-253432
- **What was found:** the deferred STIG step disables every local administrator (V-253432); the brief keeps one break-glass account.
- **Default:** LAPS runs after the STIG step and keeps its account enabled. Documented as an exception for the system security plan; no compliance claim is made.
- **Decision needed:** ISSO acceptance of the exception.

### B-012 Not verified against Microsoft Learn
- AppLocker event channel names (`Microsoft-Windows-AppLocker/EXE and DLL`, `/MSI and Script`, `/Packaged app-Deployment`, `/Packaged app-Execution`): the AppLocker article lists the event IDs and levels but not the channel paths; the names follow Event Viewer.
- Run Command script size limit with the embedded evidence collector (about 14 KB base64): no limit found in the documentation for managed Run Commands.
- The JSON log article says to create the custom table only with its PowerShell sample; the deployment uses the same Tables API through the workspace table AVM. A what-if or test deployment should confirm it.
- **Default:** used as written; listed here for the first test deployment.

### B-013 No SCAP scanner bundled
- **What was found:** no Microsoft-documented SCAP scanner ships with Windows, and scanner licensing differs.
- **Default:** `compliance.scapCommand` runs a scanner already on the image and parses its XCCDF results; without it, evidence covers the image's deferred settings, AppLocker and Defender only.
- **Decision needed:** which scanner, if any, to add to the image build.

## Phase 4: FSLogix storage operations

### B-014 Runbook content is a post-deploy step
- **What was tried:** the Automation AVM creates runbooks only from a `publishContentLink` URI; ARM can't take inline content.
- **Default:** the deployment creates the account, identity, role and schedule; `az-avd/scripts/Publish-FslogixAutoGrowRunbook.ps1` publishes and links the runbook.
- **Decision needed:** whether to host the runbook at a pinned URL (repository raw link or a storage blob with SAS) so the deployment can publish it.

### B-015 Deployment resets the grown quota
- **What was found:** `fslogix.shareQuotaGiB` is applied on every deployment, so an auto-grown quota is set back unless the parameter file is updated.
- **Default:** documented; the runbook and script print the value to write back.
- **Decision needed:** whether pipelines should read the live quota (for example with a pre-deployment `az storage share-rm show`) and pass it in.

### B-016 Not verified
- Automation cloud jobs with `publicNetworkAccess: Disabled` and no private endpoint: expected to work (cloud jobs don't use the public webhook or agent endpoints) but not confirmed in the documentation read.
- `Get-AzRmStorageShare -GetShareUsage` and `Unregister-AzAutomationScheduledRunbook -JobScheduleId`: used from the Az module; only `Update-AzRmStorageShare` and `Import-AzAutomationRunbook` were checked on Microsoft Learn.
- Workbook metric item JSON (`MetricsItem/2.0`, `chartType`, metric id format): no schema reference on Microsoft Learn; written to the format the portal exports. Check the workbook renders after the first deployment.
- `StorageFileLogs` column names (`StatusCode`, `StatusText`, `ServerLatencyMs`, `DurationMs`, `AuthenticationType`, `CallerIpAddress`): written from memory of the table schema; not checked against the reference or run against a workspace.

## Phase 5: privileged access

### B-017 Eligibility requests need requestType changes after the first deployment
- **What was found:** PIM rejects `AdminAssign` for an eligibility that already exists, so redeploying the same entries fails.
- **Default:** `requestType` per entry (default `AdminAssign`), changed to `AdminUpdate` after the first run; documented in the governance README.
- **Decision needed:** whether to accept that, or wrap eligibilities in a deployment script that checks for existing ones (needs an identity with User Access Administrator on the hierarchy).

### B-018 Tenant-level prerequisites outside the deployments
- Microsoft Entra diagnostic settings (sign-in and audit logs to the workspace), the Temporary Access Pass method, the Conditional Access exclusion group and PIM licensing are tenant settings. Documented, not automated.
- **Decision needed:** who owns these settings and whether a tenant-scope pipeline identity should apply them.

### B-019 Not verified
- `Get-AzRoleAssignmentScheduleInstance` property names (`AssignmentType`, `EndDateTime`, `PrincipalDisplayName`, `RoleDefinitionDisplayName`, `MemberType`) and the `isPrivileged` property in the v1.0 Graph role definition: written from the API shape, not checked against a tenant.
- PIM for Groups policy lookup filter (`scopeId`/`scopeType eq 'Group'`/`roleDefinitionId eq 'member'`) on `roleManagementPolicyAssignments`: from the Graph PIM for Groups overview's linked APIs; the exact filter wasn't confirmed on the List page.
- The `microsoft.aadiam/diagnosticSettings` API version (2017-04-01) and the category names in the README command.
- PIM's default Azure resource role setting for permanent eligibility (the template uses 365-day eligibilities so it doesn't depend on it).
