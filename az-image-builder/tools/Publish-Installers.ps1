<#
.SYNOPSIS
    Step 2 of 2 for installers: push the staged installers to the 'installers' container.

.DESCRIPTION
    For each artifact in workload/scripts/artifacts.json (optionally filtered by -Name / -Group):
      1. The staged file (<StagingPath>\<blob>, from Get-Installers.ps1) must exist and match the
         SHA256 in artifacts.json, or it is NOT uploaded.
      2. If the blob already exists:
           - same SHA256 (blob metadata 'sha256')  -> skipped
           - different SHA256                      -> error. Blobs are immutable: a new version
                                                      needs a new 'blob' name in artifacts.json.
           - no 'sha256' metadata (older upload)   -> downloaded and hashed once; metadata is
                                                      added if it matches.
      3. Otherwise it is uploaded with metadata sha256=<hash>.

    Auth: Entra ID only (--auth-mode login). You need 'Storage Blob Data Contributor' on the
    container (landing zone param publishers). If the storage firewall denies
    by default, your public IP is allowed only while this runs (tools/StorageAccess.psm1).

    Scripts are published separately by tools/Publish-ImageBuilderContent.ps1.

.EXAMPLE
    ./tools/Publish-Installers.ps1 -StorageAccountName aibprodeusst
.EXAMPLE
    ./tools/Publish-Installers.ps1 -StorageAccountName aibprodeusst -Name git -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$StorageAccountName,

    # Subscription of the storage account. Default: the current az account.
    [string]$SubscriptionId,

    [string]$StagingPath = (Join-Path $HOME 'ImageBuilderInstallers'),

    [string[]]$Name,

    [string[]]$Group,

    [string[]]$AllowedIpAddresses
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$manifest = Get-Content -LiteralPath (Join-Path $root 'workload' 'scripts' 'artifacts.json') -Raw | ConvertFrom-Json
$container = $manifest.container
$sub = if ($SubscriptionId) { @('--subscription', $SubscriptionId) } else { @() }

$selected = @($manifest.artifacts | Where-Object {
        (-not $Name -or $_.name -in $Name) -and (-not $Group -or $_.group -in $Group)
    })
if ($selected.Count -eq 0) { throw 'No artifacts match -Name/-Group.' }

function Get-BlobSha256 {
    param([string]$Blob)
    $json = az storage blob show --auth-mode login --account-name $StorageAccountName --container-name $container `
        --name $Blob --query '{exists: name, sha256: metadata.sha256}' -o json @sub --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }   # not found
    $info = $json | ConvertFrom-Json
    if ($info.sha256) { return $info.sha256 } else { return '' }   # '' = exists, no metadata
}

$results = [System.Collections.Generic.List[object]]::new()

Import-Module (Join-Path $PSScriptRoot 'StorageAccess.psm1') -Force
Invoke-WithStorageAccess -StorageAccountName $StorageAccountName -SubscriptionId $SubscriptionId -IpAddress $AllowedIpAddresses -ProbeContainer $container -ScriptBlock {
    foreach ($artifact in $selected) {
        $local = Join-Path $StagingPath ($artifact.blob -replace '/', [IO.Path]::DirectorySeparatorChar)
        $status = $null
        try {
            # Already in storage with the expected hash: nothing to do, no local copy needed.
            $remote = Get-BlobSha256 -Blob $artifact.blob
            if ($remote -and $remote -eq $artifact.sha256) { $status = 'already published'; continue }

            if (-not (Test-Path -LiteralPath $local)) {
                $status = if ($null -eq $remote) { 'not staged' } else { 'not staged (blob exists, unverified)' }
                continue
            }
            $hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
            if ($hash -ne $artifact.sha256) {
                $status = 'LOCAL MISMATCH'
                Write-Warning "[$($artifact.name)] Staged file doesn't match artifacts.json ($hash). Run Get-Installers.ps1."
                continue
            }
            if ($remote) {
                $status = 'BLOB CONFLICT'
                Write-Warning "[$($artifact.name)] $container/$($artifact.blob) already holds a different file (sha256 $remote). Give the new version a new 'blob' name."
                continue
            }

            if ($remote -eq '') {
                # Exists without metadata: verify once, then tag it.
                $temp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('n'))
                az storage blob download --auth-mode login --account-name $StorageAccountName --container-name $container `
                    --name $artifact.blob --file $temp @sub --only-show-errors -o none
                if ($LASTEXITCODE -ne 0) { throw "download of existing blob failed" }
                $existing = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash
                Remove-Item -LiteralPath $temp -Force
                if ($existing -ne $hash) {
                    $status = 'BLOB CONFLICT'
                    Write-Warning "[$($artifact.name)] Existing blob differs from artifacts.json ($existing). Give the new version a new 'blob' name."
                    continue
                }
                if ($PSCmdlet.ShouldProcess("$container/$($artifact.blob)", 'add sha256 metadata')) {
                    az storage blob metadata update --auth-mode login --account-name $StorageAccountName --container-name $container `
                        --name $artifact.blob --metadata "sha256=$hash" @sub --only-show-errors -o none
                    if ($LASTEXITCODE -ne 0) { throw 'metadata update failed' }
                }
                $status = 'already published (tagged)'
                continue
            }

            if ($PSCmdlet.ShouldProcess("$container/$($artifact.blob)", "upload $local")) {
                Write-Host "[$($artifact.name)] Uploading to $container/$($artifact.blob)"
                az storage blob upload --auth-mode login --account-name $StorageAccountName --container-name $container `
                    --name $artifact.blob --file $local --metadata "sha256=$hash" --overwrite false @sub --only-show-errors -o none
                if ($LASTEXITCODE -ne 0) { throw 'upload failed' }
                $status = 'uploaded'
            }
            else {
                $status = 'would upload'
            }
        }
        catch {
            $status = 'ERROR'
            Write-Warning "[$($artifact.name)] $($_.Exception.Message)"
        }
        finally {
            $results.Add([pscustomobject]@{ Name = $artifact.name; Group = $artifact.group; Blob = $artifact.blob; Status = $status })
        }
    }
}

$results | Sort-Object Status, Group, Name | Format-Table Name, Group, Status, Blob -AutoSize

$failed = @($results | Where-Object { $_.Status -in 'LOCAL MISMATCH', 'BLOB CONFLICT', 'ERROR' })
$missing = @($results | Where-Object { $_.Status -like 'not staged*' })
if ($missing.Count -gt 0) {
    Write-Warning "$($missing.Count) artifact(s) are neither in storage with the expected hash nor staged locally. Run Get-Installers.ps1 for them; builds that need them will fail until they're published."
}
if ($failed.Count -gt 0) { exit 1 }
