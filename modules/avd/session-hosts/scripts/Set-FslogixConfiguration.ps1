<#
.SYNOPSIS
    Configures FSLogix profile containers on an AVD session host.

.DESCRIPTION
    Runs once per host through a VM Run Command. Settings follow Microsoft's
    recommended profile container configuration. When Intune or Group Policy
    manages FSLogix, set fslogix.configurationMethod to None and this script
    isn't deployed.

.PARAMETER ProfileLocations
    Semicolon-separated UNC paths, for example \\account.file.core.windows.net\profiles.

.PARAMETER CloudCache
    'true' to use Cloud Cache (CCDLocations) instead of VHDLocations.

.PARAMETER SizeInMBs
    Maximum size of a new profile container.

.PARAMETER EntraKerberos
    'true' to enable Kerberos ticket retrieval from Microsoft Entra ID, required
    for Azure Files with Entra Kerberos authentication.
#>
param(
    [Parameter(Mandatory)] [string] $ProfileLocations,
    [string] $CloudCache = 'false',
    [int] $SizeInMBs = 30000,
    [string] $EntraKerberos = 'false'
)

$ErrorActionPreference = 'Stop'

function Set-RegistryValue {
    param([string] $Path, [string] $Name, $Value, [string] $Type = 'DWord')
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

$profiles = 'HKLM:\SOFTWARE\FSLogix\Profiles'
$locations = $ProfileLocations.Split(';', [StringSplitOptions]::RemoveEmptyEntries)

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
}

# Keep local administrators on local profiles so break-glass sign-in works if storage is down.
$exclude = 'FSLogix Profile Exclude List'
if (Get-LocalGroup -Name $exclude -ErrorAction SilentlyContinue) {
    $admins = Get-LocalGroup -SID 'S-1-5-32-544'
    if (-not (Get-LocalGroupMember -Group $exclude -ErrorAction SilentlyContinue | Where-Object SID -eq $admins.SID)) {
        Add-LocalGroupMember -Group $exclude -Member $admins.Name
    }
}

Write-Output "FSLogix configured: $($locations.Count) location(s), CloudCache=$CloudCache, EntraKerberos=$EntraKerberos"
