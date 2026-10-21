<#
.SYNOPSIS
    Step 1 of 2 for installers: download/collect every installer listed in workload/scripts/artifacts.json
    into a local staging folder and verify its SHA256.

.DESCRIPTION
    Reads workload/scripts/artifacts.json. For each artifact (optionally filtered by -Name / -Group):
      - 'sourceUrl' entries are downloaded from the vendor (skipped if the staged copy already
        matches), then hash-checked.
      - 'manual' entries must be placed in the staging folder by hand. The script prints the exact
        path it expects and where the file comes from (the 'manual' note).

    Staging layout mirrors the blob layout:  <StagingPath>\<blob>
    e.g.  ~/ImageBuilderInstallers/tools/Git-2.47.0.2-64-bit.exe

    Version bumps: point 'sourceUrl' (or drop the new manual file) at the new version, give the
    entry a NEW 'blob' name that includes the version, then run with -UpdateHashes. That writes the
    new SHA256 into artifacts.json. Review the git diff, then run Publish-Installers.ps1.

    Step 2: tools/Publish-Installers.ps1 pushes the staging folder to storage.
    Scripts are separate: tools/Publish-ImageBuilderContent.ps1 (run by Deploy-ImageBuilder.ps1).

    Requires PowerShell 7+. Needs internet access; no Azure access.

.EXAMPLE
    ./tools/Get-Installers.ps1
.EXAMPLE
    ./tools/Get-Installers.ps1 -Name git -UpdateHashes      # after bumping git's sourceUrl + blob
#>
[CmdletBinding()]
param(
    [string]$StagingPath = (Join-Path $HOME 'ImageBuilderInstallers'),

    # Only these artifact names (see artifacts.json). Default: all.
    [string[]]$Name,

    # Only these groups (see artifacts.json). Default: all.
    [string[]]$Group,

    # Write the staged file's SHA256 into artifacts.json instead of failing on a mismatch.
    [switch]$UpdateHashes
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

$artifactsPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'workload' 'scripts' 'artifacts.json'
$manifest = Get-Content -LiteralPath $artifactsPath -Raw | ConvertFrom-Json

$selected = @($manifest.artifacts | Where-Object {
        (-not $Name -or $_.name -in $Name) -and (-not $Group -or $_.group -in $Group)
    })
if ($selected.Count -eq 0) { throw 'No artifacts match -Name/-Group.' }

function Get-Prop($Object, [string]$Property) {
    if ($Object.PSObject.Properties[$Property]) { $Object.$Property } else { $null }
}

New-Item -ItemType Directory -Path $StagingPath -Force | Out-Null
Write-Host "Staging folder: $StagingPath`n"

$results = @()
$changed = $false

foreach ($artifact in $selected) {
    $local = Join-Path $StagingPath ($artifact.blob -replace '/', [IO.Path]::DirectorySeparatorChar)
    New-Item -ItemType Directory -Path (Split-Path -Parent $local) -Force | Out-Null
    $sourceUrl = Get-Prop $artifact 'sourceUrl'
    $status = $null

    try {
        $hash = if (Test-Path -LiteralPath $local) { (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash } else { $null }

        if ($sourceUrl -and $hash -ne $artifact.sha256) {
            Write-Host "[$($artifact.name)] Downloading $sourceUrl"
            $temp = "$local.download"
            Invoke-WebRequest -Uri $sourceUrl -OutFile $temp -UseBasicParsing -MaximumRetryCount 3 -RetryIntervalSec 5
            Move-Item -LiteralPath $temp -Destination $local -Force
            $hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
        }

        if (-not $hash) {
            $status = 'MISSING'
            Write-Warning "[$($artifact.name)] Place the file at: $local`n    Source: $(Get-Prop $artifact 'manual')"
        }
        elseif ($hash -eq $artifact.sha256) {
            $status = 'ok'
        }
        elseif ($UpdateHashes) {
            Write-Warning "[$($artifact.name)] SHA256 updated in artifacts.json: $($artifact.sha256) -> $hash"
            $artifact.sha256 = $hash
            $changed = $true
            $status = 'updated'
        }
        else {
            $status = 'MISMATCH'
            Write-Warning "[$($artifact.name)] SHA256 mismatch. Expected $($artifact.sha256), got $hash. If this is an intentional new version, give it a new 'blob' name and re-run with -UpdateHashes."
        }
    }
    catch {
        $status = 'ERROR'
        Write-Warning "[$($artifact.name)] $($_.Exception.Message)"
    }

    $results += [pscustomobject]@{
        Name   = $artifact.name
        Group  = $artifact.group
        Status = $status
        Source = if ($sourceUrl) { 'download' } else { 'manual' }
        Path   = $local
    }
}

if ($changed) {
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $artifactsPath -Encoding utf8NoBOM
    Write-Warning "artifacts.json updated. Review 'git diff', commit, then run Publish-Installers.ps1."
}

$results | Sort-Object Status, Group, Name | Format-Table Name, Group, Source, Status -AutoSize

$bad = @($results | Where-Object { $_.Status -notin 'ok', 'updated' })
if ($bad.Count -gt 0) {
    Write-Warning "$($bad.Count) artifact(s) not ready. Publish-Installers.ps1 will skip them."
    exit 1
}
Write-Host 'All selected installers are staged and verified. Next: ./tools/Publish-Installers.ps1'
