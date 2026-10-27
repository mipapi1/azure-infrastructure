# Decisions

Short records of choices made while building out the platform. Newest last.

## D-001 Keep suffix-style names
Existing hub and image builder resources are named `<workload>-<env>-<region>-<abbr>`. CAF also allows abbreviation-first names, but renaming deployed resources means replacing them. The shared naming module keeps the existing pattern.

## D-002 Containerized toolchain on linux/amd64
The PowerShell base image (needed for PSRule) is published for amd64 only. The tooling image is pinned to `linux/amd64` and runs under emulation on Apple silicon. PSRule's Bicep expansion timeout is raised to 180 s to allow for it.

## D-003 PSRule scans Azure IaC; Checkov scans everything else
Checkov's Bicep parser fails on current syntax (user-defined types, imports, lambdas), and scanning the compiled ARM output (with every AVM module inlined) ran for hours without finishing. Trivy reads the ARM JSON as CloudFormation and finds nothing. PSRule for Azure expands `.bicepparam` files natively and applies the Well-Architected rules, so it's the Azure IaC gate. Checkov covers Kubernetes, Helm, GitHub workflows, Dockerfiles and secrets. `validate.sh arm` is kept for anyone who wants the compiled templates. CKV_DOCKER_2 (HEALTHCHECK) is skipped because the tooling image is a CLI.

## D-004 Image builder: lateral SSH/RDP deny, gallery what-if suppression
Added an outbound deny for TCP 22/3389 to `VirtualNetwork` on the build, ACI and private endpoint NSGs (the ACI subnet keeps an explicit allow to the build subnet). The `what-if-short-circuiting` warning on the gallery role assignment is suppressed: the principal ID is part of the existing assignment name, and changing it would recreate the assignment.

## D-005 Image builder storage stays LRS (PSRule Azure.Storage.UseReplication)
The account holds scripts and installers that the publish tools can recreate. Converting an existing account from LRS to ZRS is a separate migration, not a template change.

## D-006 Landing zone: AVM called directly, typed parameters, names preserved
The local wrappers in `az-landing-zone/modules` only translated `enableLock`/`lockKind` into the AVM `lock` object. They were removed and `main.bicep` calls AVM directly with typed parameters (`az-landing-zone/types.bicep`). Every resource name produced by `params/prod.bicepparam` matches the earlier `hub.bicepparam` (including `-bastion` and the firewall `-pip`), so an existing prod deployment updates in place. The private DNS zone list moved from JSON into `main.bicep` so cloud-specific suffixes come from `environment()`.

## D-007 PSRule suppressions in the landing zone
- Staging firewall, its public IP and the staging workspace have no zones or replication. That is a cost choice for a non-production hub.
- The Bastion subnet NSG must allow 22/3389 to the VNet (Microsoft's required rule set), which `Azure.NSG.LateralTraversal` flags.
- `Azure.Deployment.SecureParameter` flags the Key Vault AVM `keys` parameter. It holds key definitions, not secret values. The Key Vault module deployment has a stable name so the suppression is narrow.

## D-008 Spoke DNS through the firewall DNS proxy
Recommended ALZ option for hub-and-spoke without a DNS Private Resolver. Spokes set the firewall private IP as their DNS server. Private DNS zones are linked only to the hub. A Private Resolver can replace this later without changing spokes beyond `dnsServers`.

## D-009 Monitoring ingestion private, queries open by default
AMPLS ingestion is `PrivateOnly` and workspace public ingestion is disabled, so agents must use private link. Query access stays `Open` by default because a fully private workspace breaks portal access from outside the network. prod disables public query access in its parameter file.

## D-010 Governance: ALZ hierarchy with built-in policy baseline, canary for staging
Management groups follow ALZ (platform: connectivity, identity, management; landing zones: corp, online; sandbox; decommissioned). Only built-in policy definitions are assigned, all IDs verified against the Azure Policy and ALZ library repositories: MCSB (audit), allowed locations (resources and resource groups), required and inherited `environment`/`workload` tags, no public IPs on NICs in corp, secure transfer for storage, and, once the hub exists, resource logs to Log Analytics (ALZ `Deploy-Diag-LogsCat` initiative), activity log to Log Analytics, and Azure Monitor Agent for VMs. The full ALZ custom policy set is better consumed from the ALZ library than re-implemented. Staging deploys a separate `alz-canary` hierarchy in DoNotEnforce mode, which is the ALZ canary approach.

## D-011 Defender for Cloud defaults
prod: CSPM, Servers P2, Storage (with on-upload malware scanning and sensitive data discovery), Key Vault, Resource Manager, Containers, DNS. staging: CSPM only. Plans are a parameter so cost can be tuned per subscription.

## D-012 AVD: AVM for service objects and storage, custom session host and monitoring modules
Host pool (0.8.2), application groups (0.4.2), workspace (0.9.2), scaling plan (0.5.0), storage account (0.33.1) and virtual machine (0.22.3) come from AVM. Two local modules fill gaps:
- `modules/avd/session-hosts` wraps the VM AVM. The AVM's `extensionHostPoolRegistration` always sets `aadJoin: true` (wrong for domain-joined hosts) and takes the registration token in a non-secure object parameter, which writes it to deployment history. The local module adds the DSC registration extension itself, reads the token with `listRegistrationTokens()` straight into protected settings, and adds the FSLogix Run Command. Replace with the AVM extension once it accepts a secure token and an `aadJoin` setting.
- `modules/avd/monitoring` groups the AVD Insights data collection rule and the alert rules. It only composes AVM modules (data collection rule, scheduled query rule, metric alert); a future AVD monitoring pattern module would replace it.
- `modules/network/firewall-rule-collection-group` adds one rule collection group to the hub policy. The firewall policy AVM manages every group at once, so a workload can't use it to add only its own rules.

## D-013 AVD PSRule exceptions
- `Azure.VNET.SingleDNS` is excluded repository-wide: spokes use the firewall DNS proxy, which is one IP backed by a zone-redundant firewall.
- `Azure.VM.MaintenanceConfig` is suppressed for VMs tagged `avd-host-pool`. Pooled session hosts are patched by Windows Update during off-peak hours and replaced from new images, which is Microsoft's recommended AVD servicing model; Update Manager maintenance windows conflict with scaling plans.
- `Azure.Storage.FileShareSoftDelete` requires exactly 7 days, so both environments use 7.

## D-014 FSLogix configured by Run Command, Intune preferred when present
Microsoft recommends Intune (settings catalog) or Group Policy for FSLogix. Entra-joined hosts have no Group Policy, and Intune isn't always available, so the module writes Microsoft's recommended profile container registry settings with a VM Run Command by default. Set `fslogix.configurationMethod: 'None'` when Intune or GPO manages FSLogix. Antimalware exclusions for FSLogix are set on the Microsoft Antimalware extension.

## D-015 AVD defaults
- Entra-joined hosts with Entra Kerberos for Azure Files, the Microsoft-recommended cloud-only design. Domain join is a parameter (`identity.mode`).
- Host pool `publicNetworkAccess: EnabledForClientsOnly`: session hosts reach the service over private link, users connect over the internet. `Disabled` needs client private connectivity (VPN or ExpressRoute).
- Registration token valid for four hours and refreshed on every deployment.
- Windows 11 Enterprise multi-session 25H2 (`MicrosoftWindowsDesktop/windows-11/win11-25h2-avd`) unless a gallery image is given.
- DSC agent configuration package pinned to `Configuration_1.0.03211.1002.zip` (confirmed to exist). Microsoft publishes newer packages; update the parameter after testing in staging.
- Premium file shares (ZRS in prod), SMB 3.1.1 with Kerberos and AES-256 only, shared key access disabled, no default share permission (RBAC per group).

## D-016 AKS network: private cluster, CNI Overlay with Cilium, UDR egress
Azure CNI Overlay powered by Cilium is Microsoft's recommended networking for new clusters: pods don't consume VNet addresses, and Cilium provides the data plane and network policy (Azure Network Policy Manager is being retired). The API server is private with the zone in the hub, so every spoke resolves it the same way; a user-assigned control plane identity gets Private DNS Zone Contributor on that zone and Network Contributor on the VNet and route table before the cluster is created. Egress uses `userDefinedRouting` to the hub firewall. Pod `192.168.0.0/16` and service `172.16.0.0/16` ranges stay outside the `10.0.0.0/8` space the landing zone allocates from. API server VNet integration was not used because private cluster with private link is generally available in every region and matches the rest of the platform.

## D-017 AKS identity and access
Entra ID with Azure RBAC for Kubernetes authorization and local accounts disabled, so all access is through Entra groups and auditable in the Activity Log. Workload identity (with the OIDC issuer) is the only way pods get Azure tokens; pod-managed identity is deprecated. The kubelet identity is user-assigned so AcrPull can be granted before the cluster exists. The node resource group is read-only.

## D-018 AKS add-ons and exceptions
- Flux through the AKS GitOps extension rather than Argo CD: it is a Microsoft-supported extension, deployed and upgraded with the cluster, and the `fluxConfigurations` resource keeps the bootstrap in Bicep.
- External Secrets Operator (workload identity, one ClusterSecretStore gated by a namespace label) syncs Key Vault into Kubernetes secrets for charts that expect them. The Key Vault CSI driver add-on stays on for workloads that mount secrets as files.
- cert-manager with an internal CA issuer by default; public certificates need an ACME issuer with DNS validation, which depends on the DNS provider and is left to the consumer.
- Application routing (managed NGINX) with an internal load balancer as default ingress, KEDA, Azure Policy, image cleaner and Defender for Containers are on. AKS Backup and Istio are not deployed: both add components that only some workloads need.
- PSRule exceptions: `Azure.AKS.NetworkPolicy` (the rule doesn't recognise Cilium), `Azure.ACR.GeoReplica` (single region until a second region exists), and zones and uptime SLA in staging (`Azure.AKS.AvailabilityZone`, `Azure.AKS.UptimeSLA`, `Azure.Grafana.AvailabilityZone`) for cost.
- The Flux configuration is named `cluster-config` through a property the AVM extension module reads but leaves out of its type, so the Bicep line suppresses BCP037.

## D-019 AKS monitoring module
There is no AVM module for Azure Monitor workspaces, Managed Grafana or Prometheus rule groups, so `modules/aks/monitoring` declares them and uses AVM for the data collection rules and private endpoints. Ingestion goes through the landing zone data collection endpoint (in the private link scope); the workspace and Grafana have public access disabled, and Grafana reaches the workspace through a managed private endpoint. The recording rules are the subset of Microsoft's defaults that the built-in Grafana Kubernetes dashboards need, and the alert rules cover node readiness, crash loops, OOM kills, replica mismatches, CPU and volume space.

## D-020 AKS egress allowlist
The `AzureKubernetesService` FQDN tag covers the cluster's own requirements. Git hosting and public chart and image registries (Flux, External Secrets, cert-manager) are allowed by explicit FQDNs in the parameter files until images are mirrored into the registry. Mirroring through ACR cache rules is the recommended next step and removes those entries.

## D-021 Application delivery: one chart, promotion by digest through Git
Applications are Helm charts reconciled by Flux `HelmRelease` objects that read the chart from this repository, so the chart, its values and the deployed digest are all versioned together. CI never talks to the cluster: it pushes a signed image and opens a pull or merge request that changes `image.digest` in `values-<env>.yaml`. Tags are mutable, so the chart refuses anything but a digest. Staging promotion is automatic up to the request; prod needs an approval on a protected environment. The same steps exist for GitHub Actions and GitLab CI.

## D-022 Image supply chain
- Build with BuildKit and attach an SBOM and max-mode provenance on GitHub; scan with Trivy and fail on fixable high and critical findings, uploading results to the platform's security view (GitHub code scanning, GitLab container scanning report).
- Push with workload identity federation (no registry passwords or admin user). The registry is private, so pushing needs a runner with network access to it; build and scan don't.
- Sign keyless with cosign and the CI OIDC identity; no signing keys to store or rotate. Enforcing signatures in the cluster (Ratify with Azure Policy, or a Kyverno policy) is the next step and is not deployed yet.

## D-023 Namespace guardrails
Each application namespace enforces Pod Security `restricted`, has a ResourceQuota (no LoadBalancer or NodePort services) and a LimitRange, and starts from default-deny ingress and egress with only DNS allowed. Workloads add narrow allow rules in their chart. Kubernetes NetworkPolicy is used rather than Cilium-specific policy so the same manifests run on kind for the smoke test. Charts set CPU requests and memory limits but no CPU limits, which throttle bursty workloads without protecting neighbours (requests already reserve CPU); Checkov's CKV_K8S_11 is skipped for that reason. Pods run as a high UID (10101) to avoid overlap with host accounts.

## D-024 Dependency updates and local hooks
Renovate rather than Dependabot: Renovate understands Bicep registry modules (`br/public:avm/...`), Flux `HelmRelease` charts, digests in GitHub Actions and container images, and annotated versions in the tooling Dockerfile and CI files, while Dependabot covers only some of them. Updates arrive weekly, AVM modules and actions grouped, Kubernetes tooling held to the AKS minor version. pre-commit runs generic hygiene hooks, gitleaks, and the Bicep, README and Kubernetes checks through the same `make` targets as CI, so a passing commit locally passes CI.

## D-025 AVD: cloud-only users and a Kerberos-free profile store
- `identity.userIdentitySource` (`Hybrid` default, `CloudOnly`) is separate from `identity.mode`, because where users live and how hosts join are different questions. Cloud-only users always use `AADKERB` and never `activeDirectoryProperties`.
- Microsoft lists cloud-only identities on Azure Files SMB as generally available (2026 Q2), while the Entra Kerberos overview and the group SID tag still say preview. The template supports it, and the README marks the tag as preview.
- Cloud-only groups need the `kdc_enable_cloud_group_sids` tag on the storage account's auto-generated Entra application, and private endpoints need the `privatelink.file` identifier URIs on the same application. Neither is a storage account property: the storage AVM (0.33.1) and the `Microsoft.Storage` API can't set them. A deployment script could, but it would need a managed identity with `Application.ReadWrite.All`, a tenant-wide permission far broader than this workload should hold. They're a post-deploy step instead (`az-avd/scripts/Set-CloudOnlyKerberos.ps1`, idempotent, `-WhatIf`), run by a Cloud Application Administrator. If the tenant later accepts that permission for an automation identity, the same script can run from a pipeline.
- `fslogix.storageType: 'BlobCloudCache'` is the Kerberos-free option: Cloud Cache with a `type=azure` provider on a separate StorageV2 account behind a blob private endpoint. It works in every cloud and avoids the Entra Kerberos limits (1,010 group SIDs, no TGT renewal after about 10 hours on Entra-only clients). FSLogix only authenticates to page blobs with an account key, so this account is the one exception to "no shared keys" (CONVENTIONS): shared key access on, tagged `shared-key-exception: fslogix-cloud-cache`. The key is read with `listKeys()` in the session host module and only travels as a protected Run Command parameter; on the host it's stored with `frx add-secure-key`. A host administrator can recover it, and any holder of the key can read every profile. Rotation alternates `key1`/`key2` through `fslogix.blobKeyName`.
- Standard StorageV2 (ZRS in prod, LRS in staging) rather than premium page blobs: ZRS is supported for blob data on StorageV2, it matches the file share's zone redundancy in prod, and premium page blob accounts are LRS only.
- Not built: Azure Files SMB with managed identities (GA in 2026 Q2). It authenticates workloads, not users, so it can't back per-user profile containers.

## D-026 Parameter-validation guards with fail()
Bicep (0.47) has `fail()`. `az-avd/main.bicep` collects invalid combinations into `configurationErrors` and fails before any resource is created; `baseName`, which every resource name uses, references the result so ARM always evaluates it. The cloud check (`environment().name`) is a separate guard because `bicep snapshot` can't resolve `environment()` offline and would otherwise leave the parameter-only checks unevaluated too. Bicep `assert` statements were not used: they're experimental, only run under `bicep test`, and can't be written in `.bicepparam` files.

## D-027 Offline deployment checks with bicep snapshot
`make snapshot` (`tooling/snapshot-check.py`) runs `bicep snapshot` on every parameter file and checks the predicted resources: no secrets in outputs, no storage account with shared key access unless it carries the exception tag, no storage key in non-protected Run Command parameters, no public IPs on session host NICs. Files under `tests/invalid/` start with `// expect-error: <text>` and must be rejected with that message. `bicep snapshot` exits 0 even when evaluation fails, so the checker also looks for the error text and the generated file. `az-landing-zone` is skipped: its private DNS zone loop count depends on `environment()`, which isn't known offline. The Azure US Government rejection for cloud-only users can't be tested offline for the same reason.

## D-028 Azure Firewall IP Groups, opt in per deployment
- IP Groups (AVM `avm/res/network/ip-group` 0.4.0) are created by the deployment that owns the addresses: the hub for its internal range (`firewall.useIpGroups`), and AVD, AKS and the image builder for their own subnets (`useFirewallIpGroups`, `egress.useIpGroups`). Each lives in the owner's network resource group with the owner's lock, so a spoke's IP Groups go away with the spoke, and other workloads consume them through outputs (`ipGroupResourceIds`, `internalIpGroupResourceId`).
- Off by default: with the switch off the rules are byte-for-byte what they were. Turning it on changes the rules' source from `sourceAddresses` to `sourceIpGroups` in place.
- Ordering: rules reference IP Groups by compile-time resource ID (precise what-if), and each rule collection group depends on its IP Group deployments, because a rule can't reference an IP Group that doesn't exist yet. Azure Firewall now updates up to 20 IP Groups in parallel with the firewall and policy, so IP Group changes no longer have to be serialized behind policy updates. An IP Group can't be deleted while a rule uses it: remove the reference first (redeploy with the switch off), then delete.
- Limits (Azure subscription and service limits, Azure Firewall): 5,000 addresses or prefixes per IP Group, 600 IP Groups per firewall policy, and a soft limit of 50 firewalls referencing one IP Group. This platform uses two to three per spoke.
- Where IP Groups apply: as the source of network and application rules and as the destination of network rules. Application rules can't use IP Groups as destinations, so FQDN-based rules keep their targets. The image builder's KMS destinations stay literal: they're Azure's published activation addresses, not something this platform owns.
- `snapshot-check.py` asserts that a deployment which creates IP Groups has no rule left with literal source addresses (`az-avd/tests/valid/ipgroups.bicepparam`).

## D-029 AVD host hardening after registration
- Order on each host: Guest Attestation extension before the DSC registration (one extension operation at a time per VM), then the Run Commands FSLogix, deferred STIG step, LAPS break-glass account, compliance evidence task. The STIG step disables every local administrator; LAPS runs after it so the one managed account ends up enabled, and the evidence task runs last so its first record reflects the final state. `snapshot-check.py` fails when the predicted order differs.
- `sessionHosts.applyDeferredStigs` defaults to on only for Compute Gallery images, because only `az-image-builder` images carry `C:\ProgramData\STIG`. Setting it with a Marketplace image is rejected by the `fail()` guard (D-026); a gallery image without the package fails the Run Command rather than being reported as hardened.
- Break-glass with Windows LAPS automatic account management (Windows 11 24H2+): LAPS creates, enables and rotates a custom account and backs it up to Entra ID, so no password is stored by this platform. Without Intune or Group Policy the only host-side way to configure LAPS is the Local Configuration registry root, which Microsoft calls primarily for testing; it's the default only when hosts aren't Intune-enrolled, and LAPS ignores it as soon as a CSP or Group Policy LAPS policy exists. With Intune the deployment writes nothing and the README lists the policy to create. Off by default.
- Guest Attestation as a raw extension resource: VM AVM 0.22.3 has no parameter for it. On by default (Trusted Launch is always on here), and the AVD firewall rule gains the `AzureAttestation` service tag only when it's enabled.
- Scaling plan paused during host deployment: the same plan is deployed twice, first with `scalingPlanEnabled: false`, then with `true` after the session host module, so the plan can't deallocate or drain a host mid-configuration. A failed deployment leaves it off until the next successful one; that is safer than a plan that shuts down half-configured hosts.
- Compliance evidence: a scheduled task writes JSON lines that Azure Monitor Agent sends to `AvdComplianceEvidence_CL` through a second rule. JSON log collection needs a DCE and a table that exists first, so the table is created in the workspace's resource group with the AVM child module `avm/res/operational-insights/workspace/table` 0.1.0, and missing DCE is a deploy-time error. The collector compares the image's own deferred settings and AppLocker and Defender state with the host; it doesn't evaluate the full STIG, and an XCCDF file from a customer-supplied SCAP scanner is parsed when configured. No scanner is bundled (licensing and distribution differ per scanner). The workbook is a raw `Microsoft.Insights/workbooks` resource: there is no AVM for workbooks. AppLocker and Defender events use XPath filters for warnings and errors, as Microsoft recommends for the verbose AppLocker logs.

## D-030 FSLogix storage operations
- Share auto-grow runs in Azure Automation (AVM `avm/res/automation/automation-account` 0.19.3) with a system-assigned identity, not in a Function or Logic App: a scheduled PowerShell job is the smallest moving part, needs no code package or storage, and the identity only needs Storage Account Contributor on one account (share quota is a control-plane change; no data-plane role is granted). Local auth and public network access are off; the runbook runs as a cloud job and only calls ARM (see B-016 for what wasn't confirmed).
- ARM has no way to upload runbook content from a local file (only a `publishContentLink` URI that Automation downloads). Rather than host the script at a public or SAS URL, the deployment creates the account and schedule and `Publish-FslogixAutoGrowRunbook.ps1` imports, publishes and links the runbook. The runbook type is Windows PowerShell 5.1 (`PowerShell`), the runtime available to every Automation account without a runtime environment.
- The deployment owns the quota (`fslogix.shareQuotaGiB`), so grows by the runbook or `Resize-FslogixShare.ps1` must be written back to the parameter file. Reading the live quota back into the deployment would need a reference to the share that fails on first deployment; the scripts print the value to use instead.
- One user's container is grown with `diskpart expand vdisk` (inbox Windows, no Hyper-V module needed), after an exclusive open proves FSLogix has detached it and a backup copy is taken. `frx` has no expand command; `migrate-vhd` creates a new disk.
- The KQL in `az-avd/kql` is the single source for the FSLogix operations workbook, which embeds it at build time. Share capacity comes from metrics in the workbook because only the Transaction metric category goes to the workspace.

## D-031 Privileged access through PIM
- Eligible Azure role assignments are declared in governance (`eligibleRoleAssignments`, AVM `avm/ptn/authorization/pim-role-assignment` 0.1.2) on management groups, because that's where the hierarchy is owned and inheritance covers every subscription. Eligibilities go to groups; group membership is just in time through PIM for Groups. Groups policies aren't ARM resources, so `Set-PimGroupPolicy.ps1` sets them through Microsoft Graph by reading and patching each rule.
- Eligibility schedule requests aren't idempotent: PIM rejects `AdminAssign` for an eligibility that exists. Rather than hide that with a deployment script, each entry carries `requestType` (default `AdminAssign`), switched to `AdminUpdate` after the first deployment. Eligibilities are time-bound (365 days by default) because PIM's default Azure role settings may not allow permanent eligibility.
- The inventory reads PIM schedule instances, not role assignments, so it can tell standing assignments (`Assigned`, no end date) from just-in-time activations.
- Emergency access follows Microsoft's guidance: two cloud-only accounts, permanent active Global Administrator, passkey (FIDO2) via a one-time Temporary Access Pass with a password nobody knows, Conditional Access exclusion through a group, and Sev 0 log alerts on any sign-in or directory change. Accounts are created by script (Graph), not ARM. The alerts live in the landing zone because the workspace and action group are there; Microsoft Entra diagnostic settings are a tenant-level resource the platform deployments don't hold permissions for, so they're a one-time command.
