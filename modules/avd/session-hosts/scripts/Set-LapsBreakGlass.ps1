<#
.SYNOPSIS
    Run Command: one Windows LAPS-managed break-glass administrator per session host.

.DESCRIPTION
    Writes Windows LAPS policy to the Local Configuration root
    (HKLM\Software\Microsoft\Windows\CurrentVersion\LAPS\Config) and processes it at once:
    automatic account management creates a custom local administrator, keeps it enabled,
    rotates its password and backs the password up to Microsoft Entra ID (or AD DS).

    Use this when no MDM or Group Policy delivers LAPS. Windows LAPS reads the CSP and Group
    Policy roots first; when either has a setting, this root is ignored. Microsoft describes
    the Local Configuration root as primarily intended for testing and development, and no
    management tool targets it.

    Needs Windows 11 24H2 or later (automatic account management) and the tenant setting
    Devices > Device settings > Enable Local Administrator Password Solution (LAPS) for
    BackupDirectory EntraID.

.PARAMETER AccountName
    Name of the managed account (20 characters or fewer).

.PARAMETER BackupDirectory
    EntraID (1) or ActiveDirectory (2).

.PARAMETER PasswordAgeDays
    Maximum password age, 7-365 with EntraID, 1-365 with ActiveDirectory.

.PARAMETER PasswordLength
    Password length, 8-64.

.PARAMETER PostAuthenticationResetDelay
    Hours after a sign-in before the password is reset and the session signed out (0 disables).
#>
param(
    [string]$AccountName = 'WLapsAdmin',
    [ValidateSet('EntraID', 'ActiveDirectory')]
    [string]$BackupDirectory = 'EntraID',
    [string]$PasswordAgeDays = '30',
    [string]$PasswordLength = '20',
    [string]$PostAuthenticationResetDelay = '8'
)

$ErrorActionPreference = 'Stop'

$build = [Environment]::OSVersion.Version.Build
if ($build -lt 26100) {
    throw "Windows build $build is older than Windows 11 24H2 (26100); LAPS automatic account management is not available."
}
if ($AccountName.Length -gt 20) { throw "AccountName '$AccountName' is longer than 20 characters." }

$root = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\LAPS\Config'
foreach ($policyRoot in @('HKLM:\Software\Microsoft\Policies\LAPS', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\LAPS')) {
    if ((Test-Path -LiteralPath $policyRoot) -and (Get-Item -LiteralPath $policyRoot).ValueCount -gt 0) {
        Write-Warning "$policyRoot has LAPS settings; Windows LAPS uses that root and ignores this configuration."
    }
}

New-Item -Path $root -Force | Out-Null
$settings = [ordered]@{
    BackupDirectory                         = @{ EntraID = 1; ActiveDirectory = 2 }[$BackupDirectory]
    PasswordAgeDays                         = [int]$PasswordAgeDays
    PasswordComplexity                      = 4
    PasswordLength                          = [int]$PasswordLength
    # 3: reset the password and sign the account out when the delay expires.
    PostAuthenticationActions               = 3
    PostAuthenticationResetDelay            = [int]$PostAuthenticationResetDelay
    AutomaticAccountManagementEnabled       = 1
    # 1: a new custom account, not the built-in administrator (renamed and denied network logon by the STIG step).
    AutomaticAccountManagementTarget        = 1
    AutomaticAccountManagementEnableAccount = 1
    AutomaticAccountManagementRandomizeName = 0
}
foreach ($name in $settings.Keys) {
    New-ItemProperty -Path $root -Name $name -PropertyType DWord -Value $settings[$name] -Force | Out-Null
}
New-ItemProperty -Path $root -Name 'AutomaticAccountManagementNameOrPrefix' -PropertyType String -Value $AccountName -Force | Out-Null

Write-Output "LAPS: processing policy for $AccountName (backup to $BackupDirectory)"
Invoke-LapsPolicyProcessing

$user = Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
if (-not $user) {
    throw "LAPS did not create $AccountName. See the Microsoft-Windows-LAPS/Operational event log."
}
if (-not $user.Enabled) {
    # The deferred STIG step disables local administrators; LAPS keeps the managed one enabled.
    Enable-LocalUser -Name $AccountName
}
Write-Output "LAPS: $AccountName is managed and enabled."
