<#
.SYNOPSIS
    Uploads workload/scripts/** to the image builder storage account under an immutable version
    prefix and writes workload/scripts.manifest.json for workload/main.bicep.

.DESCRIPTION
    - Auth: Entra ID only (az CLI --auth-mode login). No keys, no SAS.
      The caller needs 'Storage Blob Data Contributor' on the 'scripts' container
      (landing zone param publishers).
    - Network: if the storage firewall denies by default, a rule for your public IP is added
      for the duration of the upload and removed afterwards (tools/StorageAccess.psm1).
    - Version: 'c' + the first 12 hex characters of a SHA256 over every file's path and hash.
      The same scripts always get the same version, committed or not. Uploads are skipped when
      that version is already recorded in .published.json for the storage account (-Force to
      re-upload). The git commit (with '-dirty' if uncommitted) is recorded in the manifest.
    - Blobs land at  scripts/<version>/<relative path>  e.g. scripts/c3f2a9c1d07b/windows/stig/configureEdge.ps1
    - scripts.manifest.json = { version, files: { "<relative path>": "<SHA256>" } }.
      workload/main.bicep embeds those hashes in the template; the build VM refuses any file that
      doesn't match.

    Deploy-ImageBuilder.ps1 runs it for you. Requires PowerShell 7+ and Azure CLI (az login).

.EXAMPLE
    ./tools/Publish-ImageBuilderContent.ps1 -StorageAccountName aibprodeusst

.EXAMPLE
    # Only regenerate the manifest (e.g. to run 'bicep build' locally). Nothing is uploaded.
    ./tools/Publish-ImageBuilderContent.ps1 -ManifestOnly
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$StorageAccountName,

    # Subscription of the storage account. Default: the current az account.
    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$Version,

    [Parameter()]
    [switch]$ManifestOnly,

    # Upload even if this exact set of scripts was already published to this account.
    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [string[]]$AllowedIpAddresses
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot                   # az-image-builder/
$workload = Join-Path $root 'workload'
$scriptsDir = Join-Path $workload 'scripts'
$manifestPath = Join-Path $workload 'scripts.manifest.json'
$container = 'scripts'

if (-not $ManifestOnly -and -not $StorageAccountName) { throw '-StorageAccountName is required (or -ManifestOnly).' }

# Skip dotfiles (.DS_Store, ._* from external drives, .shellcheckrc).
$files = Get-ChildItem -LiteralPath $scriptsDir -Recurse -File |
    Where-Object { $_.Name -notlike '.*' } |
    Sort-Object FullName
$badNames = @($files | Where-Object { $_.FullName -match '\s' })
if ($badNames) { throw "File paths must not contain spaces (the Linux bootstrap reads 'hash path' lines): $($badNames.FullName -join ', ')" }

# Refuse to publish a script that doesn't parse: otherwise the build only finds out an hour in.
$parseErrors = foreach ($file in @($files | Where-Object Extension -in '.ps1', '.psm1') + (Get-Item (Join-Path $workload 'bootstrap.ps1'))) {
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
    $errors | ForEach-Object { "  $([IO.Path]::GetRelativePath($root, $file.FullName)):$($_.Extent.StartLineNumber)  $($_.Message)" }
}
if (-not $IsWindows -and (Get-Command bash -ErrorAction SilentlyContinue)) {
    $parseErrors = @($parseErrors) + @(foreach ($file in @($files | Where-Object Extension -eq '.sh') + (Get-Item (Join-Path $workload 'bootstrap.sh'))) {
        $output = bash -n $file.FullName 2>&1
        if ($LASTEXITCODE -ne 0) { "  $([IO.Path]::GetRelativePath($root, $file.FullName))  $output" }
    })
}
if ($parseErrors) { throw "Syntax errors, nothing published:`n$($parseErrors -join "`n")" }

$hashes = [ordered]@{}
foreach ($file in $files) {
    $relative = [IO.Path]::GetRelativePath($scriptsDir, $file.FullName).Replace('\', '/')
    $hashes[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
}

# Version = hash of the scripts' content (paths + SHA256s). Same files -> same version, committed or
# not, so testing uncommitted changes still publishes them, but an unchanged set is never pushed twice.
$fingerprint = ($hashes.Keys | ForEach-Object { "$_=$($hashes[$_])" }) -join "`n"
$contentHash = [BitConverter]::ToString(
    [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($fingerprint))).Replace('-', '').Substring(0, 12).ToLower()
if (-not $Version) { $Version = "c$contentHash" }

# Commit, for traceability only (tagged on the gallery image version as scriptsCommit).
$commit = (git -C $root rev-parse --short=12 HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $commit) { $commit = 'unknown' }
elseif (git -C $root status --porcelain -- $scriptsDir) { $commit = "$($commit.Trim())-dirty" }
else { $commit = $commit.Trim() }

# Local record of what this machine already published, per storage account (git-ignored).
$recordPath = Join-Path $root '.published.json'
$record = @{}
if (Test-Path -LiteralPath $recordPath) {
    (Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $record[$_.Name] = @($_.Value) }
}
$alreadyPublished = $record.ContainsKey($StorageAccountName) -and ($Version -in $record[$StorageAccountName])

if (-not $ManifestOnly -and $alreadyPublished -and -not $Force) {
    Write-Host "Scripts unchanged: version $Version is already published to $StorageAccountName. Skipping upload (use -Force to re-upload)."
}
elseif (-not $ManifestOnly) {
    Import-Module (Join-Path $PSScriptRoot 'StorageAccess.psm1') -Force
    $sub = if ($SubscriptionId) { @('--subscription', $SubscriptionId) } else { @() }
    Invoke-WithStorageAccess -StorageAccountName $StorageAccountName -SubscriptionId $SubscriptionId -IpAddress $AllowedIpAddresses -ProbeContainer $container -ScriptBlock {
        Write-Host "Publishing $($hashes.Count) file(s) to $StorageAccountName/$container/$Version/"
        foreach ($relative in $hashes.Keys) {
            az storage blob upload `
                --auth-mode login `
                --account-name $StorageAccountName `
                --container-name $container `
                --name "$Version/$relative" `
                --file (Join-Path $scriptsDir $relative) `
                --overwrite true `
                @sub `
                --only-show-errors | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Upload failed for $relative."
            }
            Write-Host "  $relative  $($hashes[$relative])"
        }
    }
    $record[$StorageAccountName] = @(@($record[$StorageAccountName] | Where-Object { $_ }) + $Version | Select-Object -Unique -Last 50)
    $record | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $recordPath -Encoding utf8NoBOM
}

[ordered]@{
    '$comment' = 'Generated by tools/Publish-ImageBuilderContent.ps1. Do not edit.'
    version    = $Version
    commit     = $commit
    files      = $hashes
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM

Write-Host "Wrote $manifestPath (version $Version, commit $commit)"
