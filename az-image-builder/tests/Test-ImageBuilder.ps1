<#
.SYNOPSIS
    Offline checks: PowerShell/shell/JSON syntax, Bicep build and lint, and rendered deployments (bicep snapshot)
    for every param file in landing-zone/params, workload/params and tests/. No Azure access needed.

.DESCRIPTION
    Snapshots evaluate the templates locally, so the asserts check what would be deployed: Image Builder
    customizers, subnet delegation, storage lockdown, role assignments, firewall/NAT egress, gallery mode.
    -Docker also runs tests/linux-hardening.sh for Ubuntu and RHEL (needs Docker and the SSG zip staged by
    tools/Get-Installers.ps1 -Name scap-security-guide).

    Requires PowerShell 7+ and the Bicep CLI (bicep on PATH, or installed by 'az bicep install').

.EXAMPLE
    ./tests/Test-ImageBuilder.ps1
.EXAMPLE
    ./tests/Test-ImageBuilder.ps1 -Docker
#>
[CmdletBinding()]
param(
    [string]$BicepPath,
    [switch]$Docker,
    [string]$StagingPath = (Join-Path $HOME 'ImageBuilderInstallers')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$scripts = Join-Path $root 'workload' 'scripts'
$failures = [System.Collections.Generic.List[string]]::new()
$checks = 0

function Assert([bool]$Condition, [string]$Message) {
    $script:checks++
    if (-not $Condition) { $script:failures.Add($Message); Write-Host "  FAIL $Message" -ForegroundColor Red }
}
function Section([string]$Name) { Write-Host "`n== $Name" -ForegroundColor Cyan }
function Rel([string]$Path) { [IO.Path]::GetRelativePath($root, $Path) }

if (-not $BicepPath) {
    $BicepPath = (Get-Command bicep -ErrorAction SilentlyContinue)?.Source ??
        @(Join-Path $HOME '.azure' 'bin' ($IsWindows ? 'bicep.exe' : 'bicep')) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $BicepPath) { throw "Bicep CLI not found. Install it with 'az bicep install' or pass -BicepPath." }

# 1. Syntax
Section 'PowerShell parse'
foreach ($file in Get-ChildItem $root -Recurse -Include *.ps1, *.psm1) {
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
    Assert (-not $errors) "$(Rel $file.FullName): $($errors | Select-Object -First 1)"
}

Section 'Shell syntax / ShellCheck'
$shell = @(Get-ChildItem $root -Recurse -Filter *.sh)
if (-not $IsWindows -and (Get-Command bash -ErrorAction SilentlyContinue)) {
    foreach ($file in $shell) { $out = bash -n $file.FullName 2>&1; Assert ($LASTEXITCODE -eq 0) "$(Rel $file.FullName): $out" }
}
else { Write-Host '  bash not available: skipped' }
if (Get-Command shellcheck -ErrorAction SilentlyContinue) {
    Push-Location (Join-Path $scripts 'linux')
    try { $out = shellcheck -x ($shell.FullName); Assert ($LASTEXITCODE -eq 0) "shellcheck:`n$($out -join "`n")" }
    finally { Pop-Location }
}
else { Write-Host '  shellcheck not installed: skipped' }

Section 'JSON and artifacts.json'
foreach ($file in Get-ChildItem $root -Recurse -Filter *.json | Where-Object Name -notlike '*.snapshot.json') {
    try { $null = Get-Content $file.FullName -Raw | ConvertFrom-Json } catch { Assert $false "$(Rel $file.FullName): $_" }
}
$artifacts = (Get-Content (Join-Path $scripts 'artifacts.json') -Raw | ConvertFrom-Json).artifacts
foreach ($a in $artifacts) {
    foreach ($p in 'name', 'group', 'blob', 'sha256', 'destination') { Assert ([bool]$a.PSObject.Properties[$p]) "artifact $($a.name): missing $p" }
    Assert ($a.sha256 -match '^[0-9A-Fa-f]{64}$') "artifact $($a.name): sha256 is not 64 hex characters"
    Assert ([bool]($a.PSObject.Properties['sourceUrl'] ?? $a.PSObject.Properties['manual'])) "artifact $($a.name): needs sourceUrl or manual"
}
Assert (@($artifacts.name | Group-Object | Where-Object Count -gt 1).Count -eq 0) 'artifacts.json: duplicate names'
Assert (@($artifacts.blob | Group-Object | Where-Object Count -gt 1).Count -eq 0) 'artifacts.json: duplicate blobs'

# 2. Bicep
Section 'Bicep build and lint'
if (-not (Test-Path (Join-Path $root 'workload' 'scripts.manifest.json'))) {
    & (Join-Path $root 'tools' 'Publish-ImageBuilderContent.ps1') -ManifestOnly | Out-Null
}
foreach ($template in 'landing-zone/main.bicep', 'workload/main.bicep') {
    $out = & $BicepPath lint (Join-Path $root $template) 2>&1
    Assert ($LASTEXITCODE -eq 0) "lint ${template}:`n$($out -join "`n")"
    $warnings = @($out | Where-Object { $_ -match ': (Warning|Error) ' })
    Assert ($warnings.Count -eq 0) "lint ${template}:`n$($warnings -join "`n")"
}

# 3. Rendered deployments
$work = Join-Path ([IO.Path]::GetTempPath()) "aib-tests-$([guid]::NewGuid().ToString('n'))"
New-Item -ItemType Directory $work | Out-Null
function Get-Snapshot([string]$ParamFile) {
    $out = & $BicepPath snapshot $ParamFile --mode overwrite --subscription-id 00000000-0000-0000-0000-000000000001 `
        --tenant-id 00000000-0000-0000-0000-000000000002 --location eastus 2>&1
    $file = [IO.Path]::ChangeExtension($ParamFile, '.snapshot.json')
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $file)) { Assert $false "snapshot $(Rel $ParamFile): $out"; return $null }
    $target = Join-Path $work ([IO.Path]::GetFileName($file))
    Move-Item $file $target -Force
    $snapshot = Get-Content $target -Raw | ConvertFrom-Json -Depth 100
    Assert (@($snapshot.diagnostics).Count -eq 0) "snapshot $(Rel $ParamFile): $($snapshot.diagnostics | ConvertTo-Json -Compress)"
    $snapshot.predictedResources
}
function Get-Params([string]$ParamFile) {
    (& $BicepPath build-params $ParamFile --stdout | ConvertFrom-Json -Depth 100).parametersJson | ConvertFrom-Json -Depth 100 | Select-Object -ExpandProperty parameters
}
function Of($Resources, [string]$Type) { @($Resources | Where-Object type -eq $Type) }

try {
    Section 'Landing zone deployments'
    $lzFiles = @(Get-ChildItem (Join-Path $root 'landing-zone' 'params'), (Join-Path $root 'tests' 'landing-zone') -Filter *.bicepparam)
    foreach ($file in $lzFiles) {
        Write-Host "  $(Rel $file.FullName)"
        $p = Get-Params $file.FullName
        # Example files with <placeholders> only need to resolve; tests/ covers the rendering.
        if ((Get-Content $file.FullName -Raw) -match "'[^'\n]*<[a-z-]+>") { Write-Host '    placeholders: parameters resolved, not rendered'; continue }
        $r = Get-Snapshot $file.FullName
        if (-not $r) { continue }
        $name = Rel $file.FullName
        $egress = $p.network.value.egress

        $subnets = @(Of $r 'Microsoft.Network/virtualNetworks/subnets')
        $aci = $subnets | Where-Object { $_.name -like "*/$($p.network.value.containerInstanceSubnet.name)" }
        Assert ($aci.properties.delegations.properties.serviceName -eq 'Microsoft.ContainerInstance/containerGroups') "${name}: ACI subnet delegation"
        Assert (@($subnets | Where-Object { $_.properties.defaultOutboundAccess -ne $false }).Count -eq 0) "${name}: default outbound access must be off"
        $buildNsg = Of $r 'Microsoft.Network/networkSecurityGroups' | Where-Object name -like '*-build-nsg'
        Assert ([bool]($buildNsg.properties.securityRules | Where-Object { $_.properties.destinationPortRanges -contains '5986' -and $_.properties.destinationPortRanges -contains '22' })) "${name}: build NSG allows WinRM/SSH from ACI"

        $routes = @(Of $r 'Microsoft.Network/routeTables')
        $nat = @(Of $r 'Microsoft.Network/natGateways')
        $rcg = @(Of $r 'Microsoft.Network/firewallPolicies/ruleCollectionGroups')
        if ($egress.mode -eq 'firewall') {
            Assert ($routes.properties.routes.properties.nextHopIpAddress -eq $egress.firewallPrivateIpAddress) "${name}: default route to the firewall"
            Assert ($nat.Count -eq 0) "${name}: no NAT gateway behind a firewall"
            Assert ($rcg.Count -eq [int][bool]$egress.PSObject.Properties['firewallPolicyResourceId']) "${name}: rule collection group only with firewallPolicyResourceId"
            foreach ($sub in $subnets | Where-Object { $_.name -notlike '*-pe' -and $_.name -notlike '*/snet-pe' }) {
                Assert ([bool]$sub.properties.routeTable) "${name}: $($sub.name) has the route table"
            }
        }
        else {
            Assert ($nat.Count -eq 1 -and $routes.Count -eq 0 -and $rcg.Count -eq 0) "${name}: NAT gateway egress only"
        }

        $st = @(Of $r 'Microsoft.Storage/storageAccounts')[0]
        Assert ($st.properties.allowSharedKeyAccess -eq $false) "${name}: storage shared key access off"
        Assert ($st.properties.allowBlobPublicAccess -eq $false) "${name}: storage blob public access off"
        Assert ($st.properties.networkAcls.defaultAction -eq 'Deny') "${name}: storage firewall default Deny"
        Assert (@(Of $r 'Microsoft.Network/privateEndpoints').Count -eq 1) "${name}: blob private endpoint"
        $zones = @(Of $r 'Microsoft.Network/privateDnsZones')
        Assert ($zones.Count -eq [int](-not $p.storage.value.PSObject.Properties['privateDnsZoneResourceId'])) "${name}: private DNS zone created only without privateDnsZoneResourceId"

        $roles = @(Of $r 'Microsoft.Authorization/roleDefinitions')
        $actions = @($roles.properties.permissions.actions)
        Assert ($actions -contains 'Microsoft.Compute/galleries/images/versions/write' -and $actions -contains 'Microsoft.Network/virtualNetworks/subnets/join/action') "${name}: Image Builder custom roles"
        Assert (@($actions | Where-Object { $_ -like '*/*' -and $_ -match '\*' }).Count -eq 0) "${name}: custom roles use no wildcards"
        $created = @(Of $r 'Microsoft.Compute/galleries').Count
        Assert ($created -eq [int]($p.gallery.value.PSObject.Properties['create'] ? $p.gallery.value.create : $true)) "${name}: gallery created only when create is true"
        $assignments = @(Of $r 'Microsoft.Authorization/roleAssignments')
        Assert ([bool]($assignments | Where-Object { "$($_.name)$($_.properties.roleDefinitionId)" -match '/galleries/' })) "${name}: gallery role assignment"
        Assert ([bool]($assignments | Where-Object { $_.name -match '/virtualNetworks/' })) "${name}: VNet role assignment"
        Assert (@($assignments | Where-Object { $_.name -match 'f1a07417-d97a-45cb-824c-7a7467783830' }).Count -eq 1) "${name}: Managed Identity Operator on the build VM identity"
        Assert (@($assignments | Where-Object { $_.name -match '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1' }).Count -eq 2) "${name}: build VM Blob Data Reader on scripts and installers"
        Assert (@(Of $r 'Microsoft.Authorization/locks' | Where-Object name -eq "lock-$($p.resourceGroupConfig.value.name)").Count -eq 0) "${name}: no lock on the resource group"
    }

    Section 'Image deployments'
    $manifest = Get-Content (Join-Path $root 'workload' 'scripts.manifest.json') -Raw | ConvertFrom-Json -AsHashtable
    $imageFiles = @(Get-ChildItem (Join-Path $root 'workload' 'params'), (Join-Path $root 'tests' 'workload') -Filter *.bicepparam)
    foreach ($file in $imageFiles) {
        Write-Host "  $(Rel $file.FullName)"
        $p = Get-Params $file.FullName
        $r = Get-Snapshot $file.FullName
        if (-not $r) { continue }
        $templates = @(Of $r 'Microsoft.VirtualMachineImages/imageTemplates')
        Assert ($templates.Count -eq @($p.images.value).Count) "$(Rel $file.FullName): one template per image"
        foreach ($image in $p.images.value) {
            $name = "$(Rel $file.FullName) [$($image.name)]"
            $t = $templates | Where-Object { $_.name -match "'$([regex]::Escape($image.name))'" }
            if (-not $t) { Assert $false "${name}: template not found"; continue }
            $linux = $image.os -in 'ubuntu', 'rhel'
            $steps = @($t.properties.customize)
            $vnet = $t.properties.vmProfile.vnetConfig
            Assert ($vnet.subnetId -and $vnet.containerInstanceSubnetId -and -not $vnet.PSObject.Properties['proxyVmSize']) "${name}: isolated build subnets, no proxyVmSize"
            Assert ($t.properties.autoRun.state -eq 'Disabled') "${name}: autoRun disabled"
            Assert (@($t.properties.vmProfile.userAssignedIdentities).Count -eq 1) "${name}: build VM identity attached"
            Assert ($steps[0].name -eq 'bootstrapScripts') "${name}: bootstrap runs first"
            $hardening = -not ($image.PSObject.Properties['hardening'] -and $image.hardening.PSObject.Properties['enabled'] -and -not $image.hardening.enabled)
            $text = ($steps | Select-Object -Skip 1 | ForEach-Object { $_.PSObject.Properties['inline']?.Value } | Out-String)

            if ($linux) {
                Assert (@($steps | Where-Object type -notin 'Shell', 'File').Count -eq 0) "${name}: Linux uses Shell customizers only"
                Assert ($steps[-1].name -eq 'cleanup') "${name}: cleanup runs last"
                Assert (($text -match 'linux/stig/harden\.sh') -eq $hardening) "${name}: STIG hardening step matches hardening.enabled"
                foreach ($path in [regex]::Matches(($steps[0].inline -join "`n"), '(?m)^[0-9A-F]{64} (\S+)$') | ForEach-Object { $_.Groups[1].Value }) {
                    Assert ($path -like 'linux/*' -or $path -eq 'artifacts.json') "${name}: bootstrap downloads only Linux scripts ($path)"
                }
            }
            else {
                Assert (@($steps | Where-Object type -eq 'Shell').Count -eq 0) "${name}: Windows has no Shell customizers"
                Assert ($steps[-1].name -eq 'installDeprovisioningScript') "${name}: deprovisioning script installed last"
                Assert (($text -match 'Install-StigPackage\.ps1') -eq $hardening) "${name}: STIG steps match hardening.enabled"
                Assert ($steps[0].inline -join '' -notmatch 'linux/') "${name}: bootstrap downloads only Windows scripts"
            }
            # Every referenced script must exist and be in the manifest.
            foreach ($m in [regex]::Matches($text, '(?:C:\\ImageBuilder\\|/opt/imagebuilder/)((?:windows|linux)[\\/][^"''\s]+\.(?:ps1|sh|py))')) {
                $rel = $m.Groups[1].Value.Replace('\', '/')
                Assert ($manifest.files.ContainsKey($rel)) "${name}: $rel is not published (missing from workload/scripts?)"
            }
            # Every artifact group must exist in artifacts.json.
            foreach ($m in [regex]::Matches($text, '-(?:-)?[Gg]roup ([\w,-]+)')) {
                foreach ($g in $m.Groups[1].Value.Split(',')) { Assert ($g -in $artifacts.group) "${name}: artifact group $g not in artifacts.json" }
            }
            $dist = $t.properties.distribute[0]
            Assert ($dist.type -eq 'SharedImage' -and @($dist.targetRegions).Count -ge 1) "${name}: gallery distribution with target regions"
        }
        $definitions = @(Of $r 'Microsoft.Compute/galleries/images')
        $expected = @($p.images.value | Where-Object { -not ($_.definition.PSObject.Properties['create'] -and -not $_.definition.create) })
        Assert ($definitions.Count -eq $expected.Count) "$(Rel $file.FullName): image definitions only where definition.create"
        foreach ($d in $definitions) {
            $image = $p.images.value | Where-Object { $d.name -like "*/$($_.definition.name)" }
            Assert ($d.properties.osType -eq (($image.os -in 'ubuntu', 'rhel') ? 'Linux' : 'Windows')) "$($d.name): osType"
        }
    }
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Docker) {
    Section 'Linux hardening in containers'
    $zip = Get-ChildItem $StagingPath -Recurse -Filter 'scap-security-guide-*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $zip) { Assert $false "SSG zip not staged under $StagingPath. Run tools/Get-Installers.ps1 -Name scap-security-guide." }
    else {
        foreach ($distro in 'ubuntu', 'rhel') {
            bash (Join-Path $PSScriptRoot 'linux-hardening.sh') $distro $zip.FullName | Select-Object -Last 3 | ForEach-Object { "  $_" }
            Assert ($LASTEXITCODE -eq 0) "linux-hardening.sh $distro failed"
        }
    }
}

Write-Host "`n$checks checks, $($failures.Count) failed." -ForegroundColor ($failures.Count ? 'Red' : 'Green')
if ($failures.Count) { exit 1 }
