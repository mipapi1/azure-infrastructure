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
