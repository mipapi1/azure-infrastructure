# Gitaly VM

A standalone Gitaly server for GitLab on AKS, used by `az-gitlab` when `gitaly.mode` is `VirtualMachine` (the prod default, D-033).

- Ubuntu 24.04 LTS, trusted launch, encryption at host, platform-orchestrated patching (`AutomaticByPlatform`).
- Static private IP in the Gitaly subnet. The chart values point at it, so it must not change.
- A premium repository disk (zone-redundant when the VM is zonal) mounted at `/var/opt/gitlab/git-data`. It is set to detach, not delete, when the VM is deleted.
- Entra ID SSH sign-in (Virtual Machine Administrator Login or User Login roles). The SSH key is only for break-glass.
- Azure Monitor Agent with the given data collection rules.
- A managed run command (`scripts/configure-gitaly.sh`) that formats and mounts the disk, installs and holds the pinned `gitlab-ee` package, trusts the platform CA and writes a Gitaly-only `gitlab.rb`. The Gitaly token and GitLab Shell secret are protected parameters, never outputs.

Upgrade Gitaly with the chart: change `gitaly.packageVersion` in `az-gitlab` to the chart's GitLab version and redeploy before Flux upgrades the chart.

## Parameters

<!-- BEGIN_PARAMS -->
| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `name` | string | yes |  | VM name. |
| `location` | string | no | computed | Location. |
| `subnetResourceId` | string | yes |  | Subnet for the VM NIC. |
| `privateIp` | string | yes |  | Static private IP in the subnet. The chart points at it (Helm values in Git), so it must not change. |
| `vmSize` | string | no | `"Standard_D4ds_v5"` | VM size. |
| `zone` | `-1` \| `1` \| `2` \| `3` | no | `-1` | Availability zone, -1 for none. |
| `diskSizeGB` | int | no | `256` | Repository disk size in GB. |
| `adminSshPublicKey` | string | yes |  | SSH public key of the break-glass admin account. |
| `adminUsername` | string | no | `"gitalyadmin"` | Break-glass admin user name. |
| `packageVersion` | string | yes |  | gitlab-ee package version, for example 19.4.3-ee.0. Must match the chart's GitLab version. |
| `internalApiUrl` | string | yes |  | GitLab URL that Gitaly calls back on (https://<gitlab host>). |
| `trustedCaPem` | string | no | `""` | PEM CA certificate that signs the GitLab certificate, when it is not publicly trusted. |
| `gitalyAuthToken` | string (secure) | yes |  | Gitaly authentication token (shared with the chart through Key Vault). |
| `gitlabShellSecret` | string (secure) | yes |  | GitLab Shell secret (shared with the chart through Key Vault). |
| `dataCollectionRuleResourceIds` | string[] | no | `[]` | Data collection rules to associate (Linux VM insights or syslog). |
| `lock` | object | no |  | Lock. |
| `tags` | object | no | `{}` | Tags. |
| `enableTelemetry` | bool | no | `true` | Enable AVM usage telemetry. |

| Output | Type | Description |
|---|---|---|
| `resourceId` | string | Resource ID of the VM. |
| `name` | string | Name of the VM. |
| `privateIp` | string | Private IP address of the VM (the Gitaly address for the chart). |
<!-- END_PARAMS -->
