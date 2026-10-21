# Azure Image Builder

Builds hardened Windows and Linux images into an Azure Compute Gallery with [Azure Image Builder](https://learn.microsoft.com/azure/virtual-machines/image-builder-overview), in an isolated network.

| OS | `os` | STIG content |
|---|---|---|
| Windows 11 (incl. multi-session AVD) | `win11` | DISA GPO package |
| Windows Server 2022 / 2025 | `ws2022`, `ws2025` | DISA GPO package (member server) |
| Ubuntu 24.04 LTS | `ubuntu` | SCAP Security Guide `stig` profile |
| RHEL 9 / 10 | `rhel` | SCAP Security Guide `stig` profile |

```
landing-zone/   deployed once per environment: network, storage, identities, gallery, custom roles
workload/       image templates: params/<image>.bicepparam + scripts/ run on the build VM
tools/          deploy, publish scripts, stage installers
tests/          offline checks (no Azure needed)
```

## How it works

- The **landing zone** has a VNet with a build subnet, an ACI-delegated subnet for the Image Builder container and a private endpoint subnet. Nothing has a public IP. Outbound traffic goes either through your **Azure Firewall** (`egress.mode: 'firewall'`, a default route plus an optional rule collection group from `landing-zone/config/firewall-rules.json`) or through a **NAT gateway** (`'natGateway'`).
- **Storage** holds `scripts` and `installers`. Shared keys and anonymous access are off, the firewall defaults to Deny, and the build VM reads over a private endpoint with its managed identity.
- **Identities:**
  - The template identity uses custom roles holding only the documented Image Builder permissions (subnet join, gallery version write).
  - The build VM identity only has blob read.
- Each image is described by one entry in a `workload/params/*.bicepparam` file. The workload turns it into a new template named `<name>-<timestamp>` with these steps: bootstrap (download scripts, verify hashes) → OS updates → artifacts → software → your customizers → STIG → cleanup/deprovision.

## Deploy

PowerShell 7 and Azure CLI, `az login`. Your account needs Owner (or Contributor plus User Access Administrator) on the subscription.

```powershell
# 1. Landing zone. Edit landing-zone/params/landing-zone.bicepparam first; it writes workload/params/landing-zone.json.
./tools/Deploy-ImageBuilder.ps1 -LandingZone -ParamFile landing-zone/params/landing-zone.bicepparam

# 2. Installers: download, verify SHA256, upload (only when artifacts.json changes).
./tools/Get-Installers.ps1
./tools/Publish-Installers.ps1 -StorageAccountName <storage account>

# 3. Image template: publishes scripts (if changed), deploys, prints the build command.
./tools/Deploy-ImageBuilder.ps1 -ParamFile workload/params/ubuntu2404.bicepparam
az image builder run -g <rg> -n <template> --no-wait
```

The publish tools add your public IP to the storage firewall while they run, then remove it. Use `-AllowedIpAddresses` behind NAT/proxy.

## Customize

**Add a script.** Drop it in `workload/scripts/windows/...` or `workload/scripts/linux/...` and reference it. It is published and hash-checked automatically:

```bicep
software: [
  { name: 'installNode', script: 'linux/software/install-nodejs.sh', arguments: '--lts' }
  { name: 'installAgent', script: 'windows/software/installAgent.ps1', restartAfter: true }
]
```

Linux scripts run as root with `bash` and can source `../lib/common.sh` (`log`, `die`, `pkg_install`). Windows scripts run as SYSTEM.

**Add an installer.** Add an entry to `workload/scripts/artifacts.json` (`name`, `group`, `blob`, `sha256`, `destination`, plus `sourceUrl` or `manual`). Then run `Get-Installers.ps1 -Name <name> -UpdateHashes` and `Publish-Installers.ps1`, and list the group in the image's `artifactGroups`.

**Add, remove or reorder steps.** `software` runs in order. `customizers` takes raw [Image Builder customizers](https://learn.microsoft.com/azure/virtual-machines/linux/image-builder-json#properties-customize) (inline Shell/PowerShell, File, WindowsRestart). Set `updates: { enabled: false }` or `hardening: { enabled: false }` to drop those steps.

**Pick the source image.**

```bicep
source: { type: 'PlatformImage', publisher: 'Canonical', offer: 'ubuntu-24_04-lts', sku: 'server', version: '24.04.202510010' }  // default version: latest
source: { type: 'SharedImageVersion', imageVersionId: '/subscriptions/.../galleries/gal/images/ubuntu-2404/versions/1.0.0' }
```

List the available SKUs with `az vm image list-skus -l <region> -p <publisher> -f <offer> -o table`. Gallery versions are named by the build date. Use `distribution.excludeFromLatest: true` for test builds.

**Add an image.** Copy the closest `workload/params/*.bicepparam` and change `name`, `source` and `definition`. One param file can hold several images. A new OS family needs a value in `os` (`types.bicep`) and its scripts.

**Existing gallery.** In the landing zone params, set:

```bicep
gallery: { name: 'shared_gal', create: false, resourceGroupName: 'shared-images-rg', subscriptionId: '<id>' }
```

The template identity gets the distributor role on that gallery. Set `definition.create: false` to use image definitions that already exist.

**Firewall or none.** `egress: { mode: 'firewall', firewallPrivateIpAddress: '10.0.0.4', firewallPolicyResourceId: '<id>' }` adds the rules. Omit the policy ID if the firewall team manages the rules, and give them `config/firewall-rules.json`. To skip the firewall, use `egress: { mode: 'natGateway' }`. Add the FQDNs your own scripts download from.

## STIG

```bicep
hardening: {
  // Linux
  stigProfile: 'stig'                     // any SSG profile id, e.g. stig_gui, cis_level1_server
  excludeRules: [ 'package_aide_installed' ]  // skip a rule; document why
  scan: true
  // Windows
  profile: 'Restricted'                   // or Standard: AppLocker scripts/MSI audit-only, browser dev tools allowed
  browsers: [ 'edge', 'chrome' ]
  additionalStigPackages: [ 'Office 2019-M365 Apps' ]
}
```

Some controls can't be in a generalized image: the admin account Azure creates, per-VM baselines, secrets, and settings that break the build connection. Every one of them is listed with a category and a justification.

| | Linux | Windows |
|---|---|---|
| Not applied, by design | `scripts/linux/stig/exceptions/*.txt` | – |
| Expected findings (`deploy` / `open`) | `scripts/linux/stig/findings/*.txt` | `scripts/windows/stig/findings.txt` |
| Finish on each VM (Run Command) | `sudo bash /usr/local/lib/image-stig/stig/harden.sh --deployed` | `C:\ProgramData\STIG\Apply-DeferredStigs.ps1 -Phase Deploy` |
| Results | `/var/log/image-compliance/<run>/summary.json`, `report.html`, `results-arf.xml` | SCC scan (`installScap.ps1`); deferred-step logs in `C:\ProgramData\STIG` |

`summary.json` counts pass, fail, notapplicable and notchecked (manual review) results. It sorts each failure as `deployTime`, `open` (documented, with the justification) or `unexplained`. Treat `unexplained` as a defect: fix it, or add it to the findings with a reason. Your ISSO approves `exceptions` and `open` items.

These results come from the SSG automated content. They are not a DISA STIG assessment and do not show full compliance. Manual checks still need review. On Windows, run the SCC scan yourself; the build doesn't run it.

## Test

```powershell
./tests/Test-ImageBuilder.ps1          # syntax, lint, and rendered deployments for every param file
./tests/Test-ImageBuilder.ps1 -Docker  # plus Linux hardening in Ubuntu/RHEL containers
```

The rendered checks evaluate each deployment locally (`bicep snapshot`). They catch missing scripts, unknown artifact groups, step order, subnet delegation, storage lockdown, roles, firewall vs NAT, and gallery mode. Containers aren't VMs: kernel, boot, and service rules show as notapplicable there.

## Requirements and limits

- Register `Microsoft.VirtualMachineImages` and `Microsoft.ContainerInstance` (`-LandingZone` does this). Azure Policy must allow container groups and Image Builder's staging resource group (`IT_<rg>_<template>_<guid>`), or pass `stagingResourceGroupResourceId` with an existing, empty RG where the template identity is Contributor.
- Image templates must be in the VNet's region. Distribution can replicate to other regions.
- Trusted Launch is the default. The definition `securityType` must match the source.
- Ubuntu FIPS (`is_fips_mode_enabled`) needs Ubuntu Pro. RHEL partition rules need a custom-partitioned source image. Both are listed as open findings.
- `firewall-rules.json` covers Microsoft, Ubuntu and RHUI endpoints. Check the build log for blocked hosts on the first build.
