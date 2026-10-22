# AVD session hosts

Session hosts for one host pool, built on the AVM virtual machine module, which provides the VM, NIC, Entra or domain join, Azure Monitor agent with data collection rule associations and antimalware with the FSLogix exclusions. This module adds:

- Host pool registration through the DSC extension. The registration token is read from the host pool during the deployment and only passed in protected settings.
- Trusted Launch, encryption at host and an optional disk encryption set.
- FSLogix profile container settings through a Run Command (`scripts/Set-FslogixConfiguration.ps1`), unless Intune or Group Policy manages them.

Hosts are named `<namePrefix>-<nnn>`. Raise `startIndex` to add hosts without renaming existing ones. See D-012 and D-014 in `docs/DECISIONS.md`.

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
