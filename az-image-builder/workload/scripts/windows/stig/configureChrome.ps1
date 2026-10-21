<#
.SYNOPSIS
    Google Chrome settings on top of the DISA Chrome STIG GPO, per hardening profile.

.DESCRIPTION
    Developer tools: Standard allowed (0), Restricted blocked (2). Standard is a STIG deviation (V-221599).
    Both profiles: Entra single sign-on (CloudAPAuthEnabled), no Google sign-in or extra profiles, no
    default-browser prompt, Gemini off, system proxy, and the Edge STIG settings the Chrome STIG lacks.
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

  [string[]]$AllowedPopups = @(),   # e.g. '[*.]contoso.com'

  [string]$LgpoPath = 'C:\Temp\LGPO_30\LGPO.exe'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HardeningCommon.psm1') -Force

if ($null -eq $DeveloperTools) { $DeveloperTools = if ($SecurityProfile -eq 'Standard') { 0 } else { 2 } }

$Reg = 'Software\Policies\Google\Chrome'

Write-Output "Chrome: configuring for profile $SecurityProfile (developer tools $DeveloperTools)"

$entries = @(
  New-LgpoEntry Computer $Reg DeveloperToolsAvailability "DWORD:$DeveloperTools"   # STIG V-221599 sets 2
  New-LgpoEntry Computer $Reg CloudAPAuthEnabled 'DWORD:1'
  New-LgpoEntry Computer $Reg BrowserSignin 'DWORD:0'
  New-LgpoEntry Computer $Reg BrowserAddPersonEnabled 'DWORD:0'
  New-LgpoEntry Computer $Reg DefaultBrowserSettingEnabled 'DWORD:0'
  New-LgpoEntry Computer $Reg GeminiSettings 'DWORD:1'
  New-LgpoEntry Computer $Reg PromotionalTabsEnabled 'DWORD:0'
  New-LgpoEntry Computer $Reg ProxySettings 'SZ:{ "ProxyMode": "system" }'
  # From the Edge STIG (not in the Chrome STIG)
  New-LgpoEntry Computer $Reg AlternateErrorPagesEnabled 'DWORD:0'
  New-LgpoEntry Computer $Reg AuthSchemes 'SZ:ntlm,negotiate'
  New-LgpoEntry Computer $Reg ImportHistory 'DWORD:0'
  New-LgpoEntry Computer $Reg ImportHomepage 'DWORD:0'
  New-LgpoEntry Computer $Reg SitePerProcess 'DWORD:1'
  New-LgpoEntry Computer $Reg PaymentMethodQueryEnabled 'DWORD:0'
  New-LgpoEntry Computer $Reg RelaunchNotification 'DWORD:2'
  New-LgpoEntry Computer $Reg DisableSafeBrowsingProceedAnyway 'DWORD:1'
  New-LgpoEntry Computer $Reg UserFeedbackAllowed 'DWORD:0'
  New-LgpoEntry Computer $Reg MediaRecommendationsEnabled 'DWORD:0'
)
for ($i = 0; $i -lt @($AllowedPopups).Count; $i++) {
  $entries += New-LgpoEntry Computer "$Reg\PopupsAllowedForUrls" ($i + 1) "SZ:$($AllowedPopups[$i])"
}
# Not a STIG setting; enable to keep roaming (FSLogix) profiles small:
# $entries += New-LgpoEntry Computer "$Reg\ClearBrowsingDataOnExitList" 1 'SZ:cached_images_and_files'

Invoke-LgpoText -Text ($entries -join "`r`n") -LgpoPath $LgpoPath -Description 'Chrome policy'
Write-Output 'Chrome: Script Complete'
