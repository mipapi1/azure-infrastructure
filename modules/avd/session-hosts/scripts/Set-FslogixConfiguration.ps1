<#
.SYNOPSIS
    Configures FSLogix profile containers on an AVD session host.

.DESCRIPTION
    Runs once per host through a VM Run Command. Settings follow Microsoft's
    recommended profile container configuration. When Intune or Group Policy
    manages FSLogix, set fslogix.configurationMethod to None and this script
    isn't deployed.

    Two profile stores are supported:
    - AzureFiles: SMB shares (VHDLocations, or CCDLocations with type=smb when
      CloudCache is 'true'). With Entra Kerberos, the client Kerberos settings
      are written and the services Entra Kerberos depends on are checked.
    - BlobCloudCache: Cloud Cache on Azure page blobs (type=azure). The
      connection string is stored in Credential Manager with
      frx add-secure-key and referenced as |fslogix/<key>|; no Kerberos
      settings apply.

.PARAMETER StorageType
    AzureFiles (default) or BlobCloudCache.

.PARAMETER ProfileLocations
    AzureFiles: semicolon-separated UNC paths, for example \\account.file.core.windows.net\profiles.

.PARAMETER CloudCache
    AzureFiles: 'true' to use Cloud Cache (CCDLocations) instead of VHDLocations.

.PARAMETER SizeInMBs
    Maximum size of a new profile container.

.PARAMETER EntraKerberos
    AzureFiles: 'true' to enable Kerberos ticket retrieval from Microsoft Entra ID,
    required for Azure Files with Entra Kerberos authentication.

.PARAMETER CloudOnly
    'true' when users are cloud-only Entra identities: warns when the Windows
    build is older than the documented minimum for cloud-only Entra Kerberos.

.PARAMETER BlobKeyName
    BlobCloudCache: storage account key in use (key1 or key2). Only used in the
    secure key name, so switching keys replaces the stored secret.

.PARAMETER BlobConnectionString
    BlobCloudCache: storage connection string. Passed as a protected Run Command
    parameter; never logged.
#>
param(
    [ValidateSet('AzureFiles', 'BlobCloudCache')] [string] $StorageType = 'AzureFiles',
    [string] $ProfileLocations = '',
    [string] $CloudCache = 'false',
    [int] $SizeInMBs = 30000,
    [string] $EntraKerberos = 'false',
    [string] $CloudOnly = 'false',
    [string] $BlobKeyName = '',
    [string] $BlobConnectionString = ''
)

$ErrorActionPreference = 'Stop'

function Set-RegistryValue {
    param([string] $Path, [string] $Name, $Value, [string] $Type = 'DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

# Entra Kerberos needs both services running; disabling WinHttpAutoProxySvc also breaks KDC proxy requests.
function Assert-KerberosService {
    param([string] $Name)
    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) { throw "Service $Name not found; Entra Kerberos for Azure Files requires it." }
    if ($service.StartType -eq 'Disabled') { throw "Service $Name is disabled; Entra Kerberos for Azure Files requires it running. Re-enable it in the image or policy." }
    if ($service.Status -ne 'Running') {
        try { Start-Service -Name $Name } catch { Write-Warning "Service $Name is $($service.Status) and could not be started: $_" }
    }
}

# Documented minimum for cloud-only Entra Kerberos: 24H2/25H2 build .8116 (KB5079391), 26H1 build 28000.1764.
function Test-CloudOnlyBuild {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$cv.CurrentBuildNumber
    $ubr = [int]$cv.UBR
    $ok = switch ($build) {
        { $_ -in 26100, 26200 } { $ubr -ge 8116; break }
        28000 { $ubr -ge 1764; break }
        { $_ -gt 28000 } { $true; break }
        default { $false }
    }
    if (-not $ok) { Write-Warning "OS build $build.$ubr is older than the documented minimum for cloud-only Entra Kerberos. Update the image." }
    else { Write-Output "OS build $build.$ubr meets the cloud-only Entra Kerberos minimum" }
}

$profiles = 'HKLM:\SOFTWARE\FSLogix\Profiles'

Set-RegistryValue $profiles 'Enabled' 1
Set-RegistryValue $profiles 'VolumeType' 'VHDX' 'String'
Set-RegistryValue $profiles 'IsDynamic' 1
Set-RegistryValue $profiles 'SizeInMBs' $SizeInMBs
Set-RegistryValue $profiles 'DeleteLocalProfileWhenVHDShouldApply' 1
Set-RegistryValue $profiles 'FlipFlopProfileDirectoryName' 1
Set-RegistryValue $profiles 'LockedRetryCount' 3
Set-RegistryValue $profiles 'LockedRetryInterval' 15
Set-RegistryValue $profiles 'ReAttachIntervalSeconds' 15
Set-RegistryValue $profiles 'ReAttachRetryCount' 3
Set-RegistryValue $profiles 'PreventLoginWithFailure' 1
Set-RegistryValue $profiles 'PreventLoginWithTempProfile' 1

if ($StorageType -eq 'BlobCloudCache') {
    if (-not $BlobConnectionString) { throw 'BlobCloudCache needs BlobConnectionString.' }
    $frx = Join-Path $Env:ProgramFiles 'FSLogix\Apps\frx.exe'
    if (-not (Test-Path -LiteralPath $frx)) { throw "$frx not found. Install FSLogix in the image." }

    # Replace the stored secret so a key switch or rotation takes effect; the old one may not exist.
    $keyName = "profiles-$BlobKeyName"
    foreach ($old in 'profiles-key1', 'profiles-key2') {
        & $frx del-secure-key -key $old *> $null
    }
    & $frx add-secure-key -key $keyName -value $BlobConnectionString | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "frx add-secure-key failed with exit code $LASTEXITCODE" }

    Set-RegistryValue $profiles 'CCDLocations' @("type=azure,name=""PROFILE BLOB"",connectionString=""|fslogix/$keyName|""") 'MultiString'
    Set-RegistryValue $profiles 'ClearCacheOnLogoff' 1
    Remove-ItemProperty -Path $profiles -Name 'VHDLocations' -ErrorAction SilentlyContinue
    $summary = "Cloud Cache on blob storage (secure key $keyName)"
}
else {
    $locations = $ProfileLocations.Split(';', [StringSplitOptions]::RemoveEmptyEntries)
    if (-not $locations) { throw 'AzureFiles needs at least one ProfileLocations entry.' }

    if ($CloudCache -eq 'true') {
        # Cloud Cache: each location is a provider; the list is ordered by priority.
        $ccd = ($locations | ForEach-Object { "type=smb,name=""$(($_ -split '\\')[2])"",connectionString=$_" }) -join ';'
        Set-RegistryValue $profiles 'CCDLocations' $ccd 'MultiString'
        Set-RegistryValue $profiles 'ClearCacheOnLogoff' 1
        Remove-ItemProperty -Path $profiles -Name 'VHDLocations' -ErrorAction SilentlyContinue
    }
    else {
        Set-RegistryValue $profiles 'VHDLocations' $locations 'MultiString'
        Remove-ItemProperty -Path $profiles -Name 'CCDLocations' -ErrorAction SilentlyContinue
    }

    if ($EntraKerberos -eq 'true') {
        Set-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters' 'CloudKerberosTicketRetrievalEnabled' 1
        Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\AzureADAccount' 'LoadCredKeyFromProfile' 1
        Assert-KerberosService 'WinHttpAutoProxySvc'
        Assert-KerberosService 'iphlpsvc'
        if ($CloudOnly -eq 'true') { Test-CloudOnlyBuild }
    }
    $summary = "$($locations.Count) SMB location(s), CloudCache=$CloudCache, EntraKerberos=$EntraKerberos"
}

# Keep local administrators on local profiles so break-glass sign-in works if storage is down.
$exclude = 'FSLogix Profile Exclude List'
if (Get-LocalGroup -Name $exclude -ErrorAction SilentlyContinue) {
    $admins = Get-LocalGroup -SID 'S-1-5-32-544'
    if (-not (Get-LocalGroupMember -Group $exclude -ErrorAction SilentlyContinue | Where-Object SID -eq $admins.SID)) {
        Add-LocalGroupMember -Group $exclude -Member $admins.Name
    }
}

Write-Output "FSLogix configured: $summary"
