<#
.SYNOPSIS
    AppLocker policy per hardening profile. Standard = developer friendly, Restricted = locked down.

.DESCRIPTION
                                   Standard                      Restricted
      Exe / Dll / Appx             Enforced                      Enforced
      Script (ps1/bat/cmd/vbs/js)  Audit only                    Enforced
      Msi                          Audit only                    Enforced
      Run from C:\Users\...        Allowed                       Blocked
      cmd / PowerShell             Allowed                       Allowed (Constrained Language Mode)
      PowerShell ISE / mshta       Allowed                       Blocked for interactive logons

    Both profiles: members of Administrators may not run Edge, Chrome, Teams, OneDrive or Outlook (STIG:
    no internet-facing apps for administrative accounts). -AllowAdminsToBrowse drops those rules.
    Restricted deny rules target INTERACTIVE (S-1-5-4), not Users: WinRM (Packer) and SYSTEM (Run Command)
    must keep working.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet('Standard', 'Restricted')]
  [string]$SecurityProfile,

  # Extra folders (no trailing \*) that Everyone may run code from, e.g. 'C:\Tools\MyApp'.
  [string[]]$AdditionalAllowedFolders = @(),

  [switch]$AllowAdminsToBrowse
)

$ErrorActionPreference = 'Stop'

$admins = 'S-1-5-32-544'
$interactive = 'S-1-5-4'
$everyone = 'S-1-1-0'
$msPublisher = 'O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US'
$msAppxPublisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'

$enforceScripts = if ($SecurityProfile -eq 'Restricted') { 'Enabled' } else { 'AuditOnly' }
$enforceMsi = if ($SecurityProfile -eq 'Restricted') { 'Enabled' } else { 'AuditOnly' }

# Folders under %WINDIR% that standard users can write to; they must not be allowed.
# Find more with Sysinternals: accesschk -w -s -q -u Users "C:\Windows"
$winDirExceptions = @(
  '%SYSTEM32%\catroot2\*', '%SYSTEM32%\com\dmp\*', '%SYSTEM32%\FxsTmp\*',
  '%SYSTEM32%\Microsoft\Crypto\RSA\MachineKeys\*', '%SYSTEM32%\spool\drivers\color\*',
  '%SYSTEM32%\spool\PRINTERS\*', '%SYSTEM32%\spool\SERVERS\*', '%SYSTEM32%\Tasks\*',
  '%SYSTEM32%\winevt\Logs\*', '%WINDIR%\CCM\logs\*', '%WINDIR%\CCM\inventory\noidmifs\*',
  '%WINDIR%\CCM\systemtemp\appvtempdata\appvcommandoutput\*', '%WINDIR%\Debug\*',
  '%WINDIR%\Registration\*', '%WINDIR%\Tasks\*', '%WINDIR%\Temp\*', '%WINDIR%\tracing\*'
)
$programFilesExceptions = @(
  '%PROGRAMFILES%\Adobe\SLCache\*', '%PROGRAMFILES%\Google\Chrome\Application\SetupMetrics\*',
  '%PROGRAMFILES%\Microsoft\Edge\Application\SetupMetrics\*',
  '%PROGRAMFILES%\Microsoft\EdgeWebView\Application\SetupMetrics\*'
)

function ConvertTo-XmlText([string]$Text) { [Security.SecurityElement]::Escape($Text) }

function New-PathRule {
  param([string]$Path, [string]$Sid = $everyone, [string]$Action = 'Allow', [string]$Label, [string[]]$Exceptions)
  $exceptionXml = if ($Exceptions) {
    '<Exceptions>' + (($Exceptions | ForEach-Object { "<FilePathCondition Path=`"$(ConvertTo-XmlText $_)`" />" }) -join '') + '</Exceptions>'
  }
  "<FilePathRule Id=`"$(New-Guid)`" Name=`"$(ConvertTo-XmlText "$Action $Label $Path")`" Description=`"`" UserOrGroupSid=`"$Sid`" Action=`"$Action`"><Conditions><FilePathCondition Path=`"$(ConvertTo-XmlText $Path)`" /></Conditions>$exceptionXml</FilePathRule>"
}

function New-PublisherRule {
  param([string]$Publisher = '*', [string]$Product = '*', [string]$Binary = '*', [string]$Sid = $admins, [string]$Action = 'Deny', [string]$Label)
  "<FilePublisherRule Id=`"$(New-Guid)`" Name=`"$(ConvertTo-XmlText "$Action $Label $Product")`" Description=`"`" UserOrGroupSid=`"$Sid`" Action=`"$Action`"><Conditions><FilePublisherCondition PublisherName=`"$(ConvertTo-XmlText $Publisher)`" ProductName=`"$(ConvertTo-XmlText $Product)`" BinaryName=`"$(ConvertTo-XmlText $Binary)`"><BinaryVersionRange LowSection=`"*`" HighSection=`"*`" /></FilePublisherCondition></Conditions></FilePublisherRule>"
}

# Where code may run from (Exe, Dll, Script).
function New-BaseRules([string]$Label) {
  $folders = @(
    '%OSDRIVE%\Packages\Plugins'                                              # Azure VM extensions
    '%OSDRIVE%\ProgramData\Microsoft\Windows Defender'
    '%OSDRIVE%\ProgramData\Microsoft\Windows Defender Advanced Threat Protection'
    '%OSDRIVE%\ProgramData\Microsoft\VisualStudio'
    '%OSDRIVE%\ProgramData\Microsoft\Windows\AppRepository\Packages'      # packaged-app registration (not user-writable)
  ) + $AdditionalAllowedFolders
  if ($SecurityProfile -eq 'Standard') { $folders += '%OSDRIVE%\Users' }

  @(
    New-PathRule -Path '*' -Sid $admins -Label "$Label (Administrators)"
    New-PathRule -Path '%PROGRAMFILES%\*' -Label $Label -Exceptions $programFilesExceptions
    New-PathRule -Path '%WINDIR%\*' -Label $Label -Exceptions $winDirExceptions
    $folders | ForEach-Object { New-PathRule -Path "$($_.TrimEnd('\'))\*" -Label $Label }
  ) -join ''
}

# Exe-only rules
$exeRules = @()
if (-not $AllowAdminsToBrowse) {
  $exeRules += New-PublisherRule -Publisher 'O=GOOGLE LLC, L=MOUNTAIN VIEW, S=CALIFORNIA, C=US' -Product 'GOOGLE CHROME' -Binary 'CHROME.EXE' -Label 'Administrators:'
  $exeRules += New-PublisherRule -Publisher $msPublisher -Product 'MICROSOFT EDGE' -Binary 'MSEDGE.EXE' -Label 'Administrators:'
  $exeRules += New-PublisherRule -Publisher $msPublisher -Product 'MICROSOFT ONEDRIVE' -Binary 'ONEDRIVE.EXE' -Label 'Administrators:'
  $exeRules += New-PublisherRule -Publisher $msPublisher -Product 'MICROSOFT OUTLOOK' -Binary 'OUTLOOK.EXE' -Label 'Administrators:'
  $exeRules += New-PublisherRule -Publisher $msPublisher -Product 'MICROSOFT TEAMS (WORK OR SCHOOL)' -Binary 'MS-TEAMS.EXE' -Label 'Administrators:'
}
if ($SecurityProfile -eq 'Restricted') {
  # Script hosts nobody needs interactively. cmd/powershell.exe stay allowed. Path rules are enough
  # because the Restricted profile doesn't allow running copies from writable folders.
  foreach ($path in @(
      '%SYSTEM32%\WindowsPowerShell\v1.0\powershell_ise.exe', '%WINDIR%\SysWOW64\WindowsPowerShell\v1.0\powershell_ise.exe',
      '%SYSTEM32%\mshta.exe', '%WINDIR%\SysWOW64\mshta.exe'
    )) {
    $exeRules += New-PathRule -Path $path -Sid $interactive -Action 'Deny' -Label 'Interactive logons:'
  }
}

$appxDenies = if ($AllowAdminsToBrowse) { '' } else {
  (New-PublisherRule -Publisher $msAppxPublisher -Product 'Microsoft.MicrosoftEdge.Stable' -Label 'Administrators:') +
  (New-PublisherRule -Publisher $msAppxPublisher -Product 'MSTeams' -Label 'Administrators:') +
  (New-PublisherRule -Publisher $msAppxPublisher -Product 'Microsoft.OneDriveSync' -Label 'Administrators:')
}

$policy = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Appx" EnforcementMode="Enabled">
    $(New-PublisherRule -Sid $everyone -Action 'Allow' -Label 'Everyone: signed packaged apps')
    $appxDenies
  </RuleCollection>
  <RuleCollection Type="Dll" EnforcementMode="Enabled">
    $(New-BaseRules 'DLLs')
  </RuleCollection>
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    $($exeRules -join '')
    $(New-BaseRules 'executables')
  </RuleCollection>
  <RuleCollection Type="Msi" EnforcementMode="$enforceMsi">
    $(New-PublisherRule -Sid $everyone -Action 'Allow' -Label 'Everyone: signed installers')
    $(New-PathRule -Path '*' -Sid $admins -Label 'installers (Administrators)')
    $(New-PathRule -Path '%WINDIR%\Installer\*' -Label 'installers')
    $(New-PathRule -Path '%PROGRAMFILES%\WindowsApps\*' -Label 'installers')
  </RuleCollection>
  <RuleCollection Type="Script" EnforcementMode="$enforceScripts">
    $(New-BaseRules 'scripts')
  </RuleCollection>
</AppLockerPolicy>
"@

$xml = [xml]$policy   # throws on malformed XML, failing the build
$file = Join-Path $Env:TEMP 'AppLocker.xml'
$xml.Save($file)
Write-Output "AppLocker: $SecurityProfile policy (scripts $enforceScripts, msi $enforceMsi) written to $file"

Write-Output 'AppLocker: clear cache, apply policy, start Application Identity'
Remove-Item "$Env:SystemRoot\System32\AppLocker\*.AppLocker" -Force -ErrorAction SilentlyContinue
Set-AppLockerPolicy -XmlPolicy $file
Set-Service -Name AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue   # policy also sets Start=2
Write-Output 'AppLocker: Script Complete'
