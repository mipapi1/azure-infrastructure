# FSLogix profile containers for Entra-joined session hosts (no domain, no Kerberos).
# Run on each host by avd/main.bicep as a Run Command (SYSTEM).
#   AzureFiles      VHDX files on an SMB share. The account key is saved as SYSTEM's credential and
#                   FSLogix opens the share as the computer (AccessNetworkAsComputerObject).
#   BlobCloudCache  Cloud Cache on page blobs. frx stores the connection string encrypted.
param(
    [Parameter(Mandatory)][ValidateSet('AzureFiles', 'BlobCloudCache')][string]$StorageType,
    [Parameter(Mandatory)][string]$AccountName,
    [Parameter(Mandatory)][string]$AccountKey,
    [Parameter(Mandatory)][string]$EndpointSuffix,
    [string]$ShareName = 'profiles',
    [int]$SizeInMBs = 30000
)
$ErrorActionPreference = 'Stop'

$frx = "$Env:ProgramFiles\FSLogix\Apps\frx.exe"
if (-not (Test-Path -LiteralPath $frx)) { throw "FSLogix not found at $frx. Use a Windows 11 multi-session image (FSLogix is preinstalled)." }

$settings = [ordered]@{
    Enabled                              = 1
    VolumeType                           = 'VHDX'
    IsDynamic                            = 1
    SizeInMBs                            = $SizeInMBs
    ProfileType                          = 0
    DeleteLocalProfileWhenVHDShouldApply = 1
    FlipFlopProfileDirectoryName         = 1
    LockedRetryCount                     = 3
    LockedRetryInterval                  = 15
    ReAttachIntervalSeconds              = 15
    ReAttachRetryCount                   = 3
    RedirXMLSourceFolder                 = "$Env:ProgramData\FSLogix"
}

if ($StorageType -eq 'AzureFiles') {
    $server = "$AccountName.file.$EndpointSuffix"
    & cmdkey.exe /add:$server /user:"localhost\$AccountName" /pass:$AccountKey | Out-Null
    # Fails if policy blocks saved network credentials (STIG "Do not allow storage of passwords and
    # credentials for network authentication"); use BlobCloudCache on such images.
    if (-not ((& cmdkey.exe /list:$server) -match [regex]::Escape($server))) { throw "Could not save the credential for $server." }
    $settings.VHDLocations = "\\$server\$ShareName"
    $settings.AccessNetworkAsComputerObject = 1
}
else {
    $connection = "DefaultEndpointsProtocol=https;AccountName=$AccountName;AccountKey=$AccountKey;EndpointSuffix=$EndpointSuffix"
    $output = & $frx add-secure-key -key=fslogixstorage -value="$connection" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "frx add-secure-key failed ($LASTEXITCODE): $output" }
    $settings.CCDLocations = 'type=azure,connectionString="|fslogix/fslogixstorage|"'
    $settings.ClearCacheOnLogoff = 1
    $settings.HealthyProvidersRequiredForRegister = 1
}

$profiles = 'HKLM:\SOFTWARE\FSLogix\Profiles'
New-Item -Path $profiles -Force | Out-Null
foreach ($name in $settings.Keys) {
    $value = $settings[$name]
    $type = if ($value -is [int]) { 'DWord' } else { 'String' }
    New-ItemProperty -Path $profiles -Name $name -Value $value -PropertyType $type -Force | Out-Null
}

# Caches and downloads stay out of the container, which keeps profiles small and sign-in fast.
New-Item -ItemType Directory -Path "$Env:ProgramData\FSLogix" -Force | Out-Null
Set-Content -LiteralPath "$Env:ProgramData\FSLogix\redirections.xml" -Encoding UTF8 -Value @'
<?xml version="1.0" encoding="UTF-8"?>
<FrxProfileFolderRedirection ExcludeCommonFolders="0">
  <Excludes>
    <Exclude Copy="0">AppData\Local\Temp</Exclude>
    <Exclude Copy="0">AppData\Local\Microsoft\Edge\User Data\Default\Cache</Exclude>
    <Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs</Exclude>
    <Exclude Copy="0">AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_tfw\GPUCache</Exclude>
    <Exclude Copy="0">AppData\Local\Microsoft\olk\cache</Exclude>
    <Exclude Copy="0">Downloads</Exclude>
  </Excludes>
  <Includes></Includes>
</FrxProfileFolderRedirection>
'@

# Local administrators keep local profiles, so break-glass sign-in works if storage is down.
Add-LocalGroupMember -Group 'FSLogix Profile Exclude List' -Member (Get-LocalGroup -SID 'S-1-5-32-544').Name -ErrorAction SilentlyContinue

# Microsoft's Defender exclusions for FSLogix. Variables stay literal; Defender expands them per user.
$paths = @(
    '%TEMP%\*\*.VHD', '%TEMP%\*\*.VHDX', '%Windir%\TEMP\*\*.VHD', '%Windir%\TEMP\*\*.VHDX',
    '%ProgramData%\FSLogix\Cache\*', '%ProgramData%\FSLogix\Proxy\*'
)
if ($settings.Contains('VHDLocations')) { $paths += "$($settings.VHDLocations)\*\*.VHDX", "$($settings.VHDLocations)\*\*.VHDX.lock", "$($settings.VHDLocations)\*\*.VHDX.meta" }
Add-MpPreference -ExclusionPath $paths -ExclusionProcess @(
    '%ProgramFiles%\FSLogix\Apps\frxccd.exe', '%ProgramFiles%\FSLogix\Apps\frxccds.exe', '%ProgramFiles%\FSLogix\Apps\frxsvc.exe'
)

Write-Output "FSLogix configured ($StorageType)."
