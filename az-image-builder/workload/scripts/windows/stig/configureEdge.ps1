<#
.SYNOPSIS
    Microsoft Edge settings on top of the DISA Edge STIG GPO, per hardening profile.

.DESCRIPTION
    Developer tools: Standard allowed (0), Restricted blocked (2). Standard is a STIG deviation (V-235727).
    Enhanced security mode: Standard balanced (1), Restricted strict (2).
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet('Standard', 'Restricted')]
  [string]$SecurityProfile,

  # 0 = allowed (except force-installed extensions), 1 = allowed everywhere, 2 = blocked.
  # Default: Standard 0, Restricted 2.
  [ValidateSet(0, 1, 2)]
  [Nullable[int]]$DeveloperTools,

  # 0 = off, 1 = balanced, 2 = strict. Default: Standard 1, Restricted 2. Strict disables JIT on
  # unfamiliar sites; use 1 if internal web apps feel slow.
  [ValidateSet(0, 1, 2)]
  [Nullable[int]]$EnhancedSecurityMode,

  [switch]$IE11,                # Enable IE mode (re-adds the IE capability that optimizeWindows.ps1 removes)
  [string[]]$AllowedPopups = @(),  # e.g. '[*.]contoso.com'
  [string[]]$ExtensionAllowlist = @(),  # extension IDs allowed despite the STIG's block-all
  [string]$Bookmarks,           # JSON for ManagedFavorites
  [string]$Proxy = '{ "ProxyMode": "system" }',  # JSON for ProxySettings

  [string]$LgpoPath = 'C:\Temp\LGPO_30\LGPO.exe'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HardeningCommon.psm1') -Force

if ($null -eq $DeveloperTools) { $DeveloperTools = if ($SecurityProfile -eq 'Standard') { 0 } else { 2 } }
if ($null -eq $EnhancedSecurityMode) { $EnhancedSecurityMode = if ($SecurityProfile -eq 'Standard') { 1 } else { 2 } }

$Reg = 'Software\Policies\Microsoft\Edge'

Write-Output "Edge: configuring for profile $SecurityProfile (developer tools $DeveloperTools, enhanced security $EnhancedSecurityMode)"

$entries = @(
  # STIG override (the package ships a placeholder)
  New-LgpoEntry Computer $Reg ProxySettings "SZ:$Proxy"                              # V-235719 (package ships a placeholder)
  New-LgpoEntry Computer $Reg DeveloperToolsAvailability "DWORD:$DeveloperTools"
  # Hardening from the Chrome STIG
  New-LgpoEntry Computer $Reg DiagnosticData 'DWORD:1'
  New-LgpoEntry Computer "$Reg\URLBlocklist" 1 'SZ:javascript://*'
  # Extra hardening
  New-LgpoEntry Computer $Reg EnhanceSecurityMode "DWORD:$EnhancedSecurityMode"
  New-LgpoEntry Computer $Reg EdgeShoppingAssistantEnabled 'DWORD:0'
  # Not a STIG setting; enable to keep roaming (FSLogix) profiles small:
  # New-LgpoEntry Computer $Reg ClearCachedImagesAndFilesOnExit 'DWORD:1'
  # Experience
  New-LgpoEntry Computer "$($Reg)Update" CreateDesktopShortcutDefault 'DWORD:0'
  New-LgpoEntry Computer "$($Reg)Update" RemoveDesktopShortcutDefault 'DWORD:1'
  New-LgpoEntry Computer $Reg NewTabPageAppLauncherEnabled 'DWORD:0'
  New-LgpoEntry Computer $Reg NewTabPageContentEnabled 'DWORD:0'
)
for ($i = 0; $i -lt @($ExtensionAllowlist).Count; $i++) {
  $entries += New-LgpoEntry Computer "$Reg\ExtensionInstallAllowlist" ($i + 1) "SZ:$($ExtensionAllowlist[$i])"
}

if ($IE11) {
  Write-Output '- Enable IE mode'
  $entries += New-LgpoEntry Computer $Reg InternetExplorerIntegrationLevel 'DWORD:1'
  $entries += New-LgpoEntry Computer $Reg InternetExplorerIntegrationReloadInIEModeAllowed 'DWORD:1'
}
for ($i = 0; $i -lt @($AllowedPopups).Count; $i++) {
  $entries += New-LgpoEntry Computer "$Reg\PopupsAllowedForUrls" ($i + 1) "SZ:$($AllowedPopups[$i])"
}
if ($Bookmarks) {
  $entries += New-LgpoEntry Computer $Reg ManagedFavorites "SZ:$Bookmarks"
}

Invoke-LgpoText -Text ($entries -join "`r`n") -LgpoPath $LgpoPath -Description 'Edge policy'

Remove-Item "$Env:Public\Desktop\Microsoft Edge.lnk" -Force -ErrorAction SilentlyContinue
if ($IE11) {
  Get-WindowsCapability -Online -Name '*InternetExplorer*' | Where-Object State -ne 'Installed' | Add-WindowsCapability -Online | Out-Null
}
Write-Output 'Edge: Script Complete'
