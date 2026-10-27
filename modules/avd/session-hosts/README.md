# AVD session hosts

Session hosts for one host pool, built on the AVM virtual machine module, which provides the VM, NIC, Entra or domain join, Azure Monitor agent with data collection rule associations and antimalware with the FSLogix exclusions. This module adds:

- Host pool registration through the DSC extension. The registration token is read from the host pool during the deployment and only passed in protected settings.
- Trusted Launch, encryption at host and an optional disk encryption set.
- FSLogix profile container settings through a Run Command (`scripts/Set-FslogixConfiguration.ps1`), unless Intune or Group Policy manages them.
  - Azure Files (SMB): `VHDLocations` or SMB Cloud Cache; with Entra Kerberos the script also sets the client Kerberos keys and checks that `WinHttpAutoProxySvc` and `iphlpsvc` can run.
  - Blob Cloud Cache: the module reads the storage account key with `listKeys()` and passes the connection string only as a protected Run Command parameter; the script stores it with `frx add-secure-key` and references it from `CCDLocations` (`type=azure`).

- Guest Attestation extension for boot integrity monitoring (no AVM parameter for it in VM AVM 0.22.3).
- Host hardening Run Commands, in order after FSLogix: the deferred STIG step of `az-image-builder` images (`scripts/Invoke-DeferredStigs.ps1`), a Windows LAPS break-glass account (`scripts/Set-LapsBreakGlass.ps1`) and the daily compliance evidence task (`scripts/Register-ComplianceEvidence.ps1`, which installs `scripts/Write-ComplianceEvidence.ps1`).

Hosts are named `<namePrefix>-<nnn>`. Raise `startIndex` to add hosts without renaming existing ones. See D-012, D-014, D-025 and D-029 in `docs/DECISIONS.md`.

## Parameters

<!-- BEGIN_PARAMS -->
| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `namePrefix` | string | yes |  | Name prefix for VMs and computer names. Hosts are named <prefix>-<nnn>; keep the prefix to 11 characters or fewer. |
| `count` | int | yes |  | Number of session hosts. |
| `startIndex` | int | no | `1` | First host number. Increase it to add hosts without renaming existing ones. |
| `location` | string | no | computed | Location for all resources. |
| `availabilityZones` | int[] | no | `[1,2,3]` | Availability zones to spread hosts across, round-robin. Empty for no zones. |
| `vmSize` | string | yes |  | VM size, for example Standard_D4ads_v5. |
| `osDisk` | object | no | `{}` | OS disk settings. |
| `image` | object | yes |  | Image: either a Marketplace reference or a Compute Gallery image (version) resource ID. |
| `subnetResourceId` | string | yes |  | Resource ID of the session host subnet. |
| `adminUsername` | string | yes |  | Local administrator user name. |
| `adminPassword` | string (secure) | yes |  | Local administrator password. |
| `identityMode` | `DomainJoined` \| `EntraJoined` | no | `"EntraJoined"` | How hosts join a directory. |
| `intuneEnrollment` | bool | no | `false` | Enroll Entra-joined hosts in Intune. |
| `domainJoin` | object | no |  | Domain join settings. Required when identityMode is DomainJoined. |
| `domainJoinPassword` | string (secure) | no | `""` | Password of the domain join account. Required when identityMode is DomainJoined. |
| `hostPoolResourceId` | string | yes |  | Resource ID of the host pool to register with. The host pool deployment must refresh the registration token before this module runs. |
| `dataCollectionRuleResourceIds` | string[] | no | `[]` | Data collection rules to associate (AVD Insights, baseline VM rules). |
| `fslogix` | object | no | `{"enabled":false}` | FSLogix profile container settings. |
| `entraKerberos` | bool | no | computed | Use Entra Kerberos for Azure Files (sets CloudKerberosTicketRetrievalEnabled). Defaults to true for Entra-joined hosts. |
| `cloudOnlyIdentities` | bool | no | `false` | Users are cloud-only Entra identities. The FSLogix Run Command then also checks the documented Windows build for cloud-only Entra Kerberos. |
| `guestAttestation` | bool | no | `true` | Install the Guest Attestation extension (boot integrity monitoring for Trusted Launch, reported in Defender for Cloud). Needs outbound HTTPS to the AzureAttestation service tag. |
| `applyDeferredStigs` | bool | no | computed | Run the deferred STIG step of az-image-builder images (C:\ProgramData\STIG\Apply-DeferredStigs.ps1 -Phase Deploy) after registration and FSLogix. Fails on images without the STIG package. Defaults to true for Compute Gallery images. |
| `disableLocalAdministrators` | bool | no | `true` | With applyDeferredStigs: disable every local administrator (V-253432). A break-glass account from breakGlass is configured afterwards and stays enabled. |
| `breakGlass` | object | no | `{"enabled":false}` | One Windows LAPS-managed local administrator per host for break-glass access. The password is backed up to Microsoft Entra ID (or AD DS) and rotated. |
| `complianceEvidence` | object | no | `{"enabled":false}` | Daily compliance evidence written on each host for Azure Monitor Agent (C:\ProgramData\STIG\evidence). Pair with the AVD monitoring module complianceEvidence rule. |
| `encryptionAtHost` | bool | no | `true` | Enable encryption at host (temp disk and caches encrypted at rest). |
| `diskEncryptionSetResourceId` | string | no |  | Resource ID of a disk encryption set for customer-managed keys. |
| `agentConfigurationZipUri` | string | no | computed | URL of the AVD agent DSC configuration package. Microsoft publishes new versions; update after testing. |
| `lock` | lockType | no |  | Lock applied to the VMs. |
| `tags` | object | no |  | Tags applied to every resource. |
| `enableTelemetry` | bool | no | `true` | Enable AVM usage telemetry. |

| Output | Type | Description |
|---|---|---|
| `names` | string[] | Session host VM names. |
| `resourceIds` | string[] | Session host VM resource IDs. |
| `principalIds` | string[] | System-assigned identity principal IDs of the session hosts. |
<!-- END_PARAMS -->
