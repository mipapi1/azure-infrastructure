<#
.SYNOPSIS
    Windows 11 / Windows Server hardening and configuration on top of the DISA STIG package.
    Runs after Install-StigPackage.ps1. All policy is merged with LGPO /t.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet('win11', 'ws2022', 'ws2025')]
  [string]$Os,

  [Parameter(Mandatory)]
  [ValidateSet('Standard', 'Restricted')]
  [string]$SecurityProfile,

  # MaxDisconnectionTime in ms. 0 = no limit.
  [ValidateRange(0, [int]::MaxValue)]
  [int]$DisconnectedSessionLimitMs = 0,

  [string[]]$AppsToRemove = @(
    'WindowsFeedbackHub'
    'WindowsCommunicationsApps'
    'WindowsMaps'
    'ZuneMusic'
    'MicrosoftOfficeHub'
    'ClipChamp'
    'ZuneVideo'
    'BingNews'
    'QuickAssist'
    'MicrosoftSolitaireCollection'
    'Getstarted'
    'WindowsSoundRecorder'
    'BingWeather'
    'WebExperience'
    'GamingApp'
    'XboxApp'
    'Xbox.TCUI'
    'OutlookForWindows'
  ),
  [string]$PrimaryDNSSuffix,      # Sets the IP configuration for primary DNS suffix
  [string[]]$DNSSuffixSearchList, # Sets the IP configuration for DNS suffix search list
  [string]$ProxyScript,           # Url of proxy autoconfig script
  [string]$NtpServer,             # NTP server; default: Azure host time sync

  # Logon banner. Default: the DISA banner from the STIG package.
  [string]$LegalNoticeCaption,
  [string]$LegalNoticeTextBase64,

  [string]$LgpoPath = 'C:\Temp\LGPO_30\LGPO.exe'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HardeningCommon.psm1') -Force
$client = $Os -eq 'win11'
Write-Output "Windows ($Os): configuring for profile $SecurityProfile"

########################
# Remove inbox apps    #
########################
if ($client) {
  foreach ($app in $AppsToRemove) {
    Write-Output "Windows: Removing app $app"
    Get-AppxPackage ('*' + $app + '*') | Remove-AppxPackage -AllUsers
    Get-AppxProvisionedPackage -Online | Where-Object {$_.PackageName -like ('*' + $app + '*')} | Remove-AppxProvisionedPackage -Online -AllUsers | Out-Null
  }
}

########################
# Policy (LGPO merge)  #
########################
Write-Output @"
Windows: STIG Overrides
- Session timeouts
- Disable BitLocker
- Allow local firewall policy merge (for non-domain)
- Enable App Locker
- Disable .NET RC4 Cipher
- Notify on Bluetooth connect
- Restrict remote SAM
- Limit Windows update delivery optimization download mode to Tenant
- Disable voice activation of apps while locked
- Minimize the number of simultaneous connections to the internet by preventing wi-fi when on ethernet
Windows: Other Configuration
- Enable non-default account for security scanning
- Disable Windows Store, but allow updates
- Enable Entra Kerberos (for non-domain)
- Hide the Windows Update settings page (Windows 11)
- Delete user firewall rules on logout (firewall bloat)
- Turn on multiple privacy settings
- Disable Cortona in search
- Turn on file extensions in file explorer
- Skip the first-logon privacy questions, lock Internet zone settings to HKLM
- Defender signature updates hourly via Microsoft Update
Windows: Microsoft Security Baseline (settings the DISA package doesn't set)
- Password reveal, last user name, account details on sign-in, feedback/lock screen notifications
- LLMNR off, NetBT P-node, no network bridge, no device metadata download, safe DLL search mode
- CredSSP oracle remediation, printer drivers admin-only, exploit protection override blocked
- Firewall notifications off, firewall log paths, security log warning at 90%
"@
$GpoFile = Join-Path $Env:TEMP "win11-$([guid]::NewGuid().ToString('n')).txt"
# Disconnected sessions: signed out after -DisconnectedSessionLimitMs; 0 = never.
$disconnectLimit = if ($DisconnectedSessionLimitMs -gt 0) { "Computer`r`nSoftware\Policies\Microsoft\Windows NT\Terminal Services`r`nMaxDisconnectionTime`r`nDWORD:$DisconnectedSessionLimitMs`r`n" } else { '' }
Write-Output "Disconnected session limit: $(if ($DisconnectedSessionLimitMs) { "$($DisconnectedSessionLimitMs / 60000) min" } else { 'none' })"
$Reg = 'Software\Policies\Microsoft'
$Cs = 'System\CurrentControlSet'
Set-Content $GpoFile @"
Computer
$Reg\Windows NT\Terminal Services
MaxConnectionTime
DWORD:32400000

$disconnectLimit
Computer
$Reg\Windows NT\Terminal Services
MaxIdleTime
DWORD:900000

Computer
$Reg\Windows NT\Terminal Services
RemoteAppLogoffTimeLimit
DWORD:300000

Computer
$Reg\FVE
*
DELETEALLVALUES

Computer
$Reg\FVE
MinimumPIN
DWORD:6

Computer
$Reg\WindowsFirewall\PublicProfile
AllowLocalPolicyMerge
DELETE

Computer
$Cs\Services\AppIDSvc
Start
DWORD:2

Computer
Software\Microsoft\.NETFramework
AllowStrongNameBypass
DWORD:0

Computer
Software\Wow6432Node\Microsoft\.NETFramework
AllowStrongNameBypass
DWORD:0

User
Software\Microsoft\BluetoothAuthenticationAgent
AcceptIncomingRequests
DWORD:1

Computer
$Cs\Control\Lsa
RestrictRemoteSam
SZ:O:BAG:BAD:(A;;RC;;;BA)

Computer
$Reg\Windows\DeliveryOptimization
DODownloadMode
DWORD:2

Computer
$Reg\Windows\DeliveryOptimization
DOGroupIdSource
DWORD:5

Computer
$Reg\Windows\AppPrivacy
LetAppsActivateWithVoiceAboveLock
DWORD:2

Computer
$Reg\Windows\WcmSvc\GroupPolicy
fMinimizeConnections
DWORD:3

User
$Reg\WindowsStore
RemoveWindowsStore
DWORD:1

Computer
$Reg\WindowsStore
AutoDownload
DWORD:4

Computer
$Cs\Control\Lsa\Kerberos\Parameters
CloudKerberosTicketRetrievalEnabled
DWORD:1

Computer
$Reg\AzureADAccount
LoadCredKeyFromProfile
DWORD:1

Computer
$Cs\Services\SharedAccess\Parameters\FirewallPolicy
DeleteUserAppContainersOnLogoff
DWORD:1

User
Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo
Enabled
DWORD:0

User
Control Panel\International\User Profile
HttpAcceptLanguageOptOut
DWORD:1

USER
Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy
HasAccepted
DWORD:0

USER
Software\Microsoft\Input\TIPC
Enabled
DWORD:0

Computer
SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection
AllowTelemetry
DWORD:0

USER
Software\Microsoft\InputPersonalization
RestrictImplicitInkCollection
DWORD:1

USER
Software\Microsoft\InputPersonalization
RestrictImplicitTextCollection
DWORD:1

USER
Software\Microsoft\InputPersonalization\TrainedDataStore
HarvestContacts
DWORD:0

USER
Software\Microsoft\Personalization\Settings
AcceptedPrivacyPolicy
DWORD:0

User
Software\Microsoft\Windows\CurrentVersion\Privacy
TailoredExperiencesWithDiagnosticDataEnabled
DWORD:0

Computer
SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection
DisableDiagnosticDataViewer
DWORD:1

USER
SOFTWARE\Microsoft\Siuf\Rules
NumberOfSIUFInPeriod
DWORD:0

Computer
$Reg\Windows\System
UploadUserActivities
DWORD:0

Computer
$Reg\Windows\Windows Search
AllowCortana
DWORD:0

Computer
$Reg\Windows\Windows Search
CortanaConsent
DWORD:0

User
Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced
HideFileExt
DWORD:0
"@

# Configure .NET for strong cryptography and disable the RC4 stream cipher
foreach ($base in @("Microsoft","Wow6432Node\Microsoft")) {
  foreach ($ver in @("v2.0.50727","v4.0.30319")) {
    Add-Content $GpoFile @"

Computer
Software\$base\.NETFramework\$ver
SchUseStrongCrypto
DWORD:1

Computer
Software\$base\.NETFramework\$ver
SystemDefaultTlsVersions
DWORD:1
"@
  }
}

# Disable outdated security protocols
$regP = "$Cs\Control\SecurityProviders\SCHANNEL\Protocols"
foreach ($prot in @("SSL 2.0","SSL 3.0","TLS 1.0","DTLS 1.0","TLS 1.1")) {
  Write-Output "- Disable $prot protocol"
  foreach ($end in @("Server","Client")) {
    Add-Content $GpoFile @"

Computer
$regP\$prot\$end
Enabled
DWORD:0

Computer
$regP\$prot\$end
DisabledByDefault
DWORD:1
"@
  }
}
# Explicitly enable modern security protocols (already the default; makes scans unambiguous)
foreach ($prot in @("TLS 1.2","DTLS 1.2","TLS 1.3","DTLS 1.3")) {
  Write-Output "- Enable $prot protocol"
  foreach ($end in @("Server","Client")) {
    Add-Content $GpoFile @"

Computer
$regP\$prot\$end
Enabled
DWORD:1
"@
  }
}

# Disable weak cipher suites (NULL, RC2, RC4, DES, IDEA, TDES/3DES), protocols (PSK), and key exchanges (EXPORT, ANON)
$regC = "$Cs\Control\Cryptography\Configuration\Local\SSL\00010002"
$ciphers = Get-ItemPropertyValue "HKLM:\$regC" "Functions" -ErrorAction SilentlyContinue
if (-not $ciphers) {
  Write-Warning "- Cipher suite list not found at HKLM:\$regC; leaving the OS default cipher suites."
}
else {
  foreach ($weak in @("NULL","RC2","RC4","DES","IDEA","3DES","PSK","EXPORT","ANON")) {
    $ciphers = $ciphers | Where-Object { $_ -notlike "*_$($weak)_*" }
  }
  Write-Output "- Disable weak cipher suites and key exchanges"
  Add-Content $GpoFile @"

Computer
$regC
Functions
MULTISZ:$($ciphers -join '\0')
"@
}

if ($client) {
  Add-Content $GpoFile "`r`n$(New-LgpoEntry Computer 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' SettingsPageVisibility 'SZ:hide:windowsupdate')"
}

if ($NtpServer) {
  Write-Output "- NTP server $NtpServer"
  Add-Content $GpoFile @"

$(New-LgpoEntry Computer "$Reg\W32time\TimeProviders\NtpClient" Enabled 'DWORD:1')
$(New-LgpoEntry Computer "$Reg\W32time\Parameters" Type 'SZ:NTP')
$(New-LgpoEntry Computer "$Reg\W32time\Parameters" NtpServer "SZ:$NtpServer,0x9")
"@
}

# Set Primary DNS suffix
if($PrimaryDNSSuffix) {
  Write-Output "- Update Primary DNS Suffix"
  Add-Content $GpoFile @"

Computer
$Cs\Services\Tcpip\Parameters
Domain
SZ:$PrimaryDNSSuffix

Computer
$Cs\Services\Tcpip\Parameters
NV Domain
SZ:$PrimaryDNSSuffix
"@
}

if($DNSSuffixSearchList) {
  Write-Output "- Update DNS Suffix Search List"
  Add-Content $GpoFile @"

Computer
$Cs\Services\Tcpip\Parameters
SearchList
SZ:$($DNSSuffixSearchList -join ',')
"@
}

if($ProxyScript) {
  Write-Output "- Set system proxy autoconfig script"
  Add-Content $GpoFile @"

User
Software\Microsoft\Windows\CurrentVersion\Internet Settings
AutoConfigUrl
SZ:$ProxyScript
"@
}

Write-Output '- Time zone redirection, lock screen notifications, third-party suggestions, supplemental STIG values'
Add-Content $GpoFile @"

$(New-LgpoEntry Computer "$Reg\Windows NT\Terminal Services" fEnableTimeZoneRedirection 'DWORD:1')
$(New-LgpoEntry User "$Reg\Windows\CloudContent" DisableThirdPartySuggestions 'DWORD:1')
$(New-LgpoEntry User "$Reg\Windows\CurrentVersion\PushNotifications" NoToastApplicationNotificationOnLockScreen 'DWORD:1')
$(New-LgpoEntry Computer 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Kerberos\Parameters' SupportedEncryptionTypes 'DWORD:2147483640')
$(New-LgpoEntry Computer "$Cs\Control\Session Manager" ProtectionMode 'DWORD:1')
$(New-LgpoEntry Computer "$Reg\Internet Explorer\Feeds" AllowBasicAuthInClear 'DWORD:0')
$(New-LgpoEntry Computer "$Cs\Services\LanManWorkstation\Parameters" RequireSecuritySignature 'DWORD:1')
$(New-LgpoEntry Computer "$Cs\Services\LanManWorkstation\Parameters" EnableSecuritySignature 'DWORD:1')
$(New-LgpoEntry Computer "$Cs\Services\LanManServer\Parameters" RequireSecuritySignature 'DWORD:1')
$(New-LgpoEntry Computer "$Cs\Services\LanManServer\Parameters" EnableSecuritySignature 'DWORD:1')
$(New-LgpoEntry Computer 'SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam' Value 'SZ:Deny')
"@

# Microsoft Security Baseline / Azure guest configuration settings the DISA GPOs don't set.
# Values that would weaken a DISA setting are left out.
Write-Output '- Microsoft Security Baseline settings not covered by the DISA package'
Add-Content $GpoFile @"

$(New-LgpoEntry Computer "$Reg\InputPersonalization" AllowInputPersonalization 'DWORD:0')
$(New-LgpoEntry Computer "$Reg\Windows\System" BlockUserFromShowingAccountDetailsOnSignin 'DWORD:1')
$(New-LgpoEntry Computer "$Reg\Windows\CredUI" DisablePasswordReveal 'DWORD:1')
$(New-LgpoEntry Computer "$Reg\Windows\DataCollection" DoNotShowFeedbackNotifications 'DWORD:1')
$(New-LgpoEntry Computer 'Software\Microsoft\Windows\CurrentVersion\Policies\System' DontDisplayLastUserName 'DWORD:1')
$(New-LgpoEntry Computer "$Cs\Control\Lsa" UseMachineId 'DWORD:1')
$(New-LgpoEntry Computer "$Reg\Windows\Network Connections" NC_AllowNetBridge_NLA 'DWORD:0')
$(New-LgpoEntry Computer "$Reg\Windows\EventLog\Setup" MaxSize 'DWORD:32768')
$(New-LgpoEntry Computer "$Reg\Windows\System" DisableLockScreenAppNotifications 'DWORD:1')
$(New-LgpoEntry Computer "$Reg\Windows\Internet Connection Wizard" ExitOnMSICW 'DWORD:1')
$(New-LgpoEntry Computer "$Reg\Windows NT\DNSClient" EnableMulticast 'DWORD:0')
$(New-LgpoEntry Computer "$Reg\WindowsFirewall\DomainProfile" DisableNotifications 'DWORD:1')
$(New-LgpoEntry Computer "$Reg\WindowsFirewall\PrivateProfile" DisableNotifications 'DWORD:1')
$(New-LgpoEntry Computer "$Reg\WindowsFirewall\PublicProfile" DisableNotifications 'DWORD:1')
$(New-LgpoEntry Computer "$Reg\WindowsFirewall\DomainProfile" DisableUnicastResponsesToMulticastBroadcast 'DWORD:0')
$(New-LgpoEntry Computer "$Reg\WindowsFirewall\PrivateProfile" DisableUnicastResponsesToMulticastBroadcast 'DWORD:0')
$(New-LgpoEntry Computer "$Reg\WindowsFirewall\PublicProfile" DisableUnicastResponsesToMulticastBroadcast 'DWORD:1')
$(New-LgpoEntry Computer "$Reg\WindowsFirewall\DomainProfile\Logging" LogFilePath 'SZ:%SystemRoot%\System32\logfiles\firewall\domainfw.log')
$(New-LgpoEntry Computer "$Reg\WindowsFirewall\PrivateProfile\Logging" LogFilePath 'SZ:%SystemRoot%\System32\logfiles\firewall\privatefw.log')
$(New-LgpoEntry Computer "$Reg\WindowsFirewall\PublicProfile\Logging" LogFilePath 'SZ:%SystemRoot%\System32\logfiles\firewall\publicfw.log')
$(New-LgpoEntry Computer 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters' AllowEncryptionOracle 'DWORD:0')
$(New-LgpoEntry Computer "$Reg\Windows NT\Printers\PointAndPrint" RestrictDriverInstallationToAdministrators 'DWORD:1')
$(New-LgpoEntry Computer "$Reg\Windows Defender Security Center\App and Browser protection" DisallowExploitProtectionOverride 'DWORD:1')
$(New-LgpoEntry Computer "$Cs\Services\NetBT\Parameters" NodeType 'DWORD:2')
$(New-LgpoEntry Computer "$Cs\Services\Eventlog\Security" WarningLevel 'DWORD:90')
$(New-LgpoEntry Computer "$Cs\Control\Session Manager" SafeDllSearchMode 'DWORD:1')
$(New-LgpoEntry Computer "$Reg\Windows\System" DontEnumerateConnectedUsers 'DWORD:1')
$(New-LgpoEntry Computer "$Reg\Windows\CloudContent" DisableConsumerAccountStateContent 'DWORD:1')
$(New-LgpoEntry Computer "$Reg\Windows Defender" DisableAntiSpyware 'DWORD:0')
$(New-LgpoEntry Computer "$Reg\Windows Defender\Real-Time Protection" DisableRealtimeMonitoring 'DWORD:0')
$(New-LgpoEntry Computer "$Reg\Windows Defender\Signature Updates" ForceUpdateFromMU 'DWORD:1')
$(New-LgpoEntry Computer "$Reg\Windows Defender\Signature Updates" SignatureUpdateInterval 'DWORD:1')
$(New-LgpoEntry Computer "$Cs\Services\LanManServer\Parameters" SMBServerNameHardeningLevel 'DWORD:1')
$(New-LgpoEntry Computer "$Reg\Windows\Device Metadata" PreventDeviceMetadataFromNetwork 'DWORD:1')
$(New-LgpoEntry Computer "$Reg\Windows\OOBE" DisablePrivacyExperience 'DWORD:1')
$(New-LgpoEntry Computer "$Reg\Windows\CurrentVersion\Internet Settings" Security_HKLM_only 'DWORD:1')
$(New-LgpoEntry Computer 'Software\Microsoft\Cryptography\Wintrust\Config' EnableCertPaddingCheck 'DWORD:1')
$(New-LgpoEntry Computer 'Software\Wow6432Node\Microsoft\Cryptography\Wintrust\Config' EnableCertPaddingCheck 'DWORD:1')
"@

foreach ($prot in @('Multi-Protocol Unified Hello', 'PCT 1.0')) {
  foreach ($end in @('Server', 'Client')) {
    Add-Content $GpoFile "`r`n$(New-LgpoEntry Computer "$Cs\Control\SecurityProviders\SCHANNEL\Protocols\$prot\$end" Enabled 'DWORD:0')`r`n$(New-LgpoEntry Computer "$Cs\Control\SecurityProviders\SCHANNEL\Protocols\$prot\$end" DisabledByDefault 'DWORD:1')"
  }
}

if ($SecurityProfile -eq 'Restricted') {
  Write-Output '- User profile: disable registry editing tools'
  Add-Content $GpoFile "`r`n$(New-LgpoEntry User 'Software\Microsoft\Windows\CurrentVersion\Policies\System' DisableRegistryTools 'DWORD:1')"
}

Invoke-LgpoText -Text (Get-Content -LiteralPath $GpoFile -Raw) -LgpoPath $LgpoPath -Description 'Windows policy'
Remove-Item -LiteralPath $GpoFile -Force

# V-253359: remove "Run as different user" from context menus (HKLM\SOFTWARE\Classes, not a policy key)
foreach ($class in @('batfile', 'cmdfile', 'exefile', 'mscfile')) {
  Set-RegistryValue -Path "HKLM:\SOFTWARE\Classes\$class\shell\runasuser" -Name SuppressionPolicy -Value 4096
}

########################
# Legal notice         #
########################
if ($LegalNoticeCaption) {
  $legalNoticeText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($LegalNoticeTextBase64))
  $system = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
  Set-RegistryValue -Path $system -Name LegalNoticeCaption -Value $LegalNoticeCaption -Type String
  Set-RegistryValue -Path $system -Name LegalNoticeText -Value $legalNoticeText -Type String
  Write-Output "Windows: legal notice '$LegalNoticeCaption'"
}

########################
# Accounts and OS      #
########################
Write-Output 'Windows: STIG - local account passwords expire (V-253273)'
Get-LocalUser | Set-LocalUser -PasswordNeverExpires $false

Write-Output 'Windows: STIG - DEP OptOut (V-253283)'
Invoke-Native -FilePath bcdedit.exe -ArgumentList '/set', '{current}', 'nx', 'OptOut' -Description 'bcdedit nx OptOut'

Write-Output 'Windows: STIG - disable PowerShell 2.0 (V-253285)'
# Recent Windows builds don't ship PowerShell 2.0.
foreach ($feature in @('MicrosoftWindowsPowerShellV2Root', 'MicrosoftWindowsPowerShellV2')) {
  $state = Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction SilentlyContinue
  if ($state -and $state.State -eq 'Enabled') {
    Disable-WindowsOptionalFeature -Online -FeatureName $feature -NoRestart | Out-Null
    Write-Output "  disabled $feature"
  }
}

if ($client) {
  # Azure VMs have no wireless hardware, so this normally finds nothing; it keeps the image compliant
  # if a driver adds the virtual adapter.
  Write-Output 'Windows: STIG - disable Wi-Fi Direct adapters (V-288475)'
  Get-NetAdapter -InterfaceDescription 'Microsoft Wi-Fi Direct*' -IncludeHidden -ErrorAction SilentlyContinue |
    ForEach-Object {
      Disable-NetAdapter -InputObject $_ -Confirm:$false
      Write-Output "  disabled $($_.Name)"
    }
}

Write-Output 'Windows: STIG - audit Other Policy Change Events'
Invoke-Native -FilePath auditpol.exe -ArgumentList '/set', '/subcategory:"Other Policy Change Events"', '/success:enable' -Description 'auditpol'

Write-Output 'Updating policy'
gpupdate.exe /target:computer /force | Out-Null
Write-Output 'Windows: Script Complete'
