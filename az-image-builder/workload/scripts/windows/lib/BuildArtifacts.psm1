#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads the installers listed in artifacts.json onto the build VM with the VM's managed
    identity (IMDS), verifying every SHA256. Any failure fails the build step.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Invoke-WebRequest progress rendering slows large downloads by 10x+ on Windows PowerShell 5.1.
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:ImdsTokenUri = 'http://169.254.169.254/metadata/identity/oauth2/token'
$script:StorageResource = 'https://storage.azure.com/'
# x-ms-version 2017-11-09 or later is required for OAuth bearer tokens against Blob storage.
$script:StorageApiVersion = '2023-11-03'

function Get-StorageAccessToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [int]$MaxAttempts = 10
    )

    $uri = '{0}?api-version=2018-02-01&resource={1}&client_id={2}' -f $script:ImdsTokenUri, [Uri]::EscapeDataString($script:StorageResource), $ClientId

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $response = Invoke-RestMethod -Uri $uri -Headers @{ Metadata = 'true' } -Method Get -UseBasicParsing -TimeoutSec 30
            return $response.access_token
        }
        catch {
            # IMDS can return 404/410/429/5xx briefly after boot or identity attach. Back off and retry.
            if ($attempt -eq $MaxAttempts) {
                throw "Failed to acquire storage token from IMDS for client id '$ClientId' after $MaxAttempts attempts: $_"
            }
            $delay = [Math]::Min(60, [Math]::Pow(2, $attempt))
            Write-Warning "IMDS token request failed (attempt $attempt/$MaxAttempts): $($_.Exception.Message). Retrying in $delay s."
            Start-Sleep -Seconds $delay
        }
    }
}

function ConvertTo-BlobUri {
    param(
        [Parameter(Mandatory)][string]$BlobEndpoint,
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$BlobPath
    )
    # Escape each path segment so blob names with spaces etc. work ("My Tool 1.4.exe").
    $escaped = ($BlobPath -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    return '{0}/{1}/{2}' -f $BlobEndpoint.TrimEnd('/'), $Container, $escaped
}

function Save-BuildArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Artifact,
        [Parameter(Mandatory)][string]$BlobEndpoint,
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$Token
    )

    $destination = [Environment]::ExpandEnvironmentVariables($Artifact.destination)
    $uri = ConvertTo-BlobUri -BlobEndpoint $BlobEndpoint -Container $Container -BlobPath $Artifact.blob

    $parent = Split-Path -Path $destination -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Write-Output "[$($Artifact.name)] Downloading $($Artifact.blob) -> $destination"
    $headers = @{
        Authorization  = "Bearer $Token"
        'x-ms-version' = $script:StorageApiVersion
    }
    Invoke-WebRequest -Uri $uri -Headers $headers -OutFile $destination -UseBasicParsing -TimeoutSec 3600

    $actual = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    if ($actual -ne $Artifact.sha256) {
        Remove-Item -LiteralPath $destination -Force
        throw "[$($Artifact.name)] SHA256 mismatch for $($Artifact.blob). Expected $($Artifact.sha256), got $actual."
    }
    Write-Output "[$($Artifact.name)] SHA256 verified."

    $extractTo = $null
    if ($Artifact.PSObject.Properties['extractTo'] -and $Artifact.extractTo) {
        $extractTo = [Environment]::ExpandEnvironmentVariables($Artifact.extractTo)
    }
    if ($extractTo) {
        Write-Output "[$($Artifact.name)] Extracting to $extractTo"
        New-Item -ItemType Directory -Path $extractTo -Force | Out-Null
        Expand-Archive -LiteralPath $destination -DestinationPath $extractTo -Force
    }
}

function Get-BuildArtifacts {
    <#
    .SYNOPSIS
        Download every artifact in the manifest whose 'group' is in -Group.
    .EXAMPLE
        Get-BuildArtifacts -ManifestPath C:\ImageBuilder\artifacts.json -Group stig,chrome `
            -BlobEndpoint https://<account>.blob.core.windows.net/ -ClientId <guid>
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string[]]$Group,
        [Parameter(Mandatory)][string]$BlobEndpoint,
        [Parameter(Mandatory)][string]$ClientId
    )

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $selected = @($manifest.artifacts | Where-Object { $Group -contains $_.group })

    $unknown = @($Group | Where-Object { $_ -notin @($manifest.artifacts.group) })
    if ($unknown.Count -gt 0) {
        throw "Unknown artifact group(s): $($unknown -join ', '). Check artifacts.json."
    }

    Write-Output "Downloading $($selected.Count) artifact(s) for group(s): $($Group -join ', ')"
    $token = Get-StorageAccessToken -ClientId $ClientId

    $failures = @()
    foreach ($artifact in $selected) {
        try {
            Save-BuildArtifact -Artifact $artifact -BlobEndpoint $BlobEndpoint -Container $manifest.container -Token $token
        }
        catch {
            Write-Warning $_
            $failures += $artifact.name
        }
    }

    if ($failures.Count -gt 0) {
        throw "Failed to download/verify $($failures.Count) artifact(s): $($failures -join ', ')"
    }
    Write-Output 'All artifacts downloaded and verified.'
}

Export-ModuleMember -Function Get-BuildArtifacts, Get-StorageAccessToken
