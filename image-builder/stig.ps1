# DISA STIG hardening for the Windows 11 AVD image. Runs as the last Image Builder step when
# `stig = true` in its image param file (images/).
#
# How it works:
#   1. bootstrap.ps1 has already downloaded the DISA GPO package, LGPO and SCC from the image builder
#      storage account and checked their SHA256. This step installs SCC, prepares the GPOs in
#      C:\ProgramData\STIG, and applies settings the GPO package doesn't
#      cover (TLS protocols and ciphers, .NET strong crypto, DEP, PowerShell 2.0, password expiry,
#      auditing).
#   2. It replaces C:\DeprovisioningScript.ps1, which Image Builder runs last. That script imports
#      the GPOs with LGPO and then runs sysprep. The STIG is applied at that point because it denies
#      network logon to local accounts, which would cut off Image Builder's WinRM session if it were
#      applied earlier.
#
# Every choice comes from the image param file and main.bicep defaults: which GPOs, the GPO package, LGPO, the
# supplemental settings, and the DISA SCAP Compliance Checker (SCC). New GPO package: DISA releases
# one each quarter; update windowsStigPackage and run publish.sh.
#
# Not applied, with the reason (report these as findings):
#   NewAdministratorName      Azure names the admin account at deploy time; rename per VM if required.
#   Domain principals         "Domain Admins"/"Enterprise Admins" user-rights entries are removed: hosts
#                             are Entra-joined, not domain-joined.
#   Firewall local merge      Public profile AllowLocalPolicyMerge is removed: without a domain, the
#                             Azure agent and extensions need local firewall rules.
#   BitLocker                 Policy is set, but Azure VMs have no pre-boot PIN; disks use platform
#                             encryption instead.
#   Settings outside the GPO  The GPO package and the supplemental settings don't cover every
#                             check. Scan a host with DISA SCC (installed when windowsScc is set)
#                             and record what's left.
# Check on the first build: Windows 11 STIG sets "Always prompt for password" for Remote Desktop
# (fPromptForPassword), which can make AVD users enter their password again after Entra SSO.

param(
    # GPO folders in the package, matched as "DoD <name> ...", e.g. 'Windows 11', 'Microsoft Edge'.
    [Parameter(Mandatory)][string[]]$GpoNames,
    # Local zip files written and checked by bootstrap.ps1.
    [Parameter(Mandatory)][string]$PackagePath,
    [Parameter(Mandatory)][string]$LgpoPath,
    [bool]$Supplemental = $true,
    # DISA SCC bundle (zip with SCC_*_Windows_Setup.exe). Empty: not installed.
    [string]$SccPath = ''
)
$ErrorActionPreference = 'Stop'
trap { Write-Output "STIG: $_"; exit 1 }

$root = "$Env:ProgramData\STIG"
$gpoDir = "$root\GPOs"
New-Item -ItemType Directory -Path $gpoDir -Force | Out-Null

Expand-Archive -LiteralPath $PackagePath -DestinationPath "$Env:TEMP\stig" -Force
Expand-Archive -LiteralPath $LgpoPath -DestinationPath "$Env:TEMP\lgpo" -Force
Copy-Item -LiteralPath (Get-ChildItem "$Env:TEMP\lgpo" -Recurse -Filter LGPO.exe | Select-Object -First 1).FullName -Destination "$root\LGPO.exe"

Write-Output 'STIG: Copying ADMX/ADML templates'
Get-ChildItem "$Env:TEMP\stig\ADMX Templates" -Recurse -Filter *.admx | Copy-Item -Destination "$Env:SystemRoot\PolicyDefinitions\" -Force
Get-ChildItem "$Env:TEMP\stig\ADMX Templates" -Recurse -Filter *.adml | Where-Object { $_.Directory.Name -eq 'en-US' } |
    Copy-Item -Destination "$Env:SystemRoot\PolicyDefinitions\en-US\" -Force

foreach ($name in $GpoNames) {
    $package = Get-ChildItem "$Env:TEMP\stig" -Directory | Where-Object Name -Match "^DoD $([regex]::Escape($name)) " | Select-Object -First 1
    if (-not $package) { throw "No '$name' GPO in the STIG package" }
    Write-Output "STIG: Preparing $($package.Name)"
    Copy-Item -LiteralPath "$($package.FullName)\GPOs" -Destination "$gpoDir\$($package.Name)" -Recurse
}

# Security templates: drop the settings listed in the header.
foreach ($inf in Get-ChildItem $gpoDir -Recurse -Filter GptTmpl.inf) {
    $lines = foreach ($line in Get-Content -LiteralPath $inf.FullName -Encoding Unicode) {
        if ($line -match '^\s*NewAdministratorName\s*=') { continue }
        if ($line -match '^\s*(Se\w+)\s*=\s*(.*)$') {
            $members = $Matches[2] -split ',' | ForEach-Object Trim | Where-Object { $_ -and $_ -notmatch '^(ADD YOUR |(.+\\)?(Domain Admins|Enterprise Admins)$)' }
            "$($Matches[1]) = $($members -join ',')"
            continue
        }
        $line
    }
    Set-Content -LiteralPath $inf.FullName -Value $lines -Encoding Unicode
}

# STIG and baseline settings the GPO package doesn't set. Applied now: none affect the build connection.
if ($Supplemental) {
    Write-Output 'STIG: Supplemental settings'
    function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
        New-Item -Path $Path -Force | Out-Null
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    }
    # Protocols: SSL 2.0/3.0 and TLS 1.0/1.1 off, TLS 1.2/1.3 on.
    $schannel = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'
    foreach ($protocol in 'SSL 2.0', 'SSL 3.0', 'TLS 1.0', 'TLS 1.1') {
        foreach ($side in 'Server', 'Client') {
            Set-Reg "$schannel\$protocol\$side" Enabled 0
            Set-Reg "$schannel\$protocol\$side" DisabledByDefault 1
        }
    }
    foreach ($protocol in 'TLS 1.2', 'TLS 1.3') { foreach ($side in 'Server', 'Client') { Set-Reg "$schannel\$protocol\$side" Enabled 1 } }
    # Weak cipher suites and key exchanges out of the TLS cipher list.
    $suites = 'HKLM:\SYSTEM\CurrentControlSet\Control\Cryptography\Configuration\Local\SSL\00010002'
    $functions = (Get-ItemProperty -Path $suites -Name Functions -ErrorAction SilentlyContinue).Functions
    if ($functions) {
        $strong = @($functions | Where-Object { $_ -notmatch '_(NULL|RC2|RC4|DES|IDEA|3DES|PSK|EXPORT|ANON)_' })
        Set-Reg $suites Functions $strong MultiString
    }
    # .NET uses the OS TLS defaults and strong cryptography.
    foreach ($net in 'Microsoft', 'Wow6432Node\Microsoft') {
        foreach ($version in 'v2.0.50727', 'v4.0.30319') {
            Set-Reg "HKLM:\SOFTWARE\$net\.NETFramework\$version" SchUseStrongCrypto 1
            Set-Reg "HKLM:\SOFTWARE\$net\.NETFramework\$version" SystemDefaultTlsVersions 1
        }
    }
    # V-253359: no "Run as different user" in context menus.
    foreach ($class in 'batfile', 'cmdfile', 'exefile', 'mscfile') {
        Set-Reg "HKLM:\SOFTWARE\Classes\$class\shell\runasuser" SuppressionPolicy 4096
    }
    # V-253283: DEP for everything except opt-outs.
    & bcdedit.exe /set '{current}' nx OptOut | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "bcdedit nx OptOut failed with exit code $LASTEXITCODE" }
    # V-253285: PowerShell 2.0 removed (recent builds don't ship it).
    foreach ($feature in 'MicrosoftWindowsPowerShellV2Root', 'MicrosoftWindowsPowerShellV2') {
        $state = Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction SilentlyContinue
        if ($state -and $state.State -eq 'Enabled') { Disable-WindowsOptionalFeature -Online -FeatureName $feature -NoRestart | Out-Null }
    }
    # V-253273: local account passwords expire.
    Get-LocalUser | Where-Object Enabled | Set-LocalUser -PasswordNeverExpires $false
    # Audit Other Policy Change Events (success).
    & auditpol.exe /set /subcategory:"Other Policy Change Events" /success:enable | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "auditpol failed with exit code $LASTEXITCODE" }
}

# DISA SCAP Compliance Checker, to scan VMs built from this image.
if ($SccPath) {
    Expand-Archive -LiteralPath $SccPath -DestinationPath "$Env:TEMP\scc" -Force
    $setup = Get-ChildItem "$Env:TEMP\scc" -Recurse -Filter 'SCC_*_Windows_Setup.exe' | Select-Object -First 1
    if (-not $setup) { throw "No SCC_*_Windows_Setup.exe in $SccPath" }
    Write-Output "STIG: Installing $($setup.Name)"
    $process = Start-Process -FilePath $setup.FullName -Wait -PassThru -ArgumentList '/VERYSILENT', '/SP-', '/SUPPRESSMSGBOXES', '/NORESTART'
    if ($process.ExitCode -ne 0) { throw "SCC setup failed with exit code $($process.ExitCode)" }
    Remove-Item "$Env:TEMP\scc" -Recurse -Force
}

# Registry policy applied after the GPOs (LGPO text format).
Set-Content -LiteralPath "$root\overrides.txt" -Encoding Unicode -Value @(
    'Computer', 'SOFTWARE\Policies\Microsoft\WindowsFirewall\PublicProfile', 'AllowLocalPolicyMerge', 'DELETE', ''
)

Write-Output 'STIG: Staging C:\DeprovisioningScript.ps1'
Set-Content -LiteralPath 'C:\DeprovisioningScript.ps1' -Encoding UTF8 -Value @'
$ErrorActionPreference = 'Stop'
$root = "$Env:ProgramData\STIG"
foreach ($gpo in Get-ChildItem "$root\GPOs" -Directory) {
    Write-Output ">>> Applying $($gpo.Name)"
    & "$root\LGPO.exe" /q /g $gpo.FullName
    if ($LASTEXITCODE -ne 0) { throw "LGPO /g $($gpo.Name) failed with exit code $LASTEXITCODE" }
}
& "$root\LGPO.exe" /q /t "$root\overrides.txt"
if ($LASTEXITCODE -ne 0) { throw "LGPO /t overrides.txt failed with exit code $LASTEXITCODE" }

Write-Output '>>> Waiting for the Azure guest agent ...'
while ((Get-Service RdAgent).Status -ne 'Running') { Start-Sleep -s 5 }
while ((Get-Service WindowsAzureGuestAgent).Status -ne 'Running') { Start-Sleep -s 5 }
Remove-Item "$Env:SystemRoot\System32\Sysprep\unattend.xml", "$Env:SystemRoot\Panther\unattend.xml" -Force -ErrorAction SilentlyContinue

Write-Output '>>> Sysprepping VM ...'
& "$Env:SystemRoot\System32\Sysprep\Sysprep.exe" /oobe /generalize /quiet /quit /mode:vm
while ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { Start-Sleep -s 5 }
Write-Output '>>> Sysprep complete ...'
'@

Remove-Item "$Env:TEMP\stig", "$Env:TEMP\lgpo" -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "STIG: Ready. $($GpoNames.Count) GPO set(s) apply before sysprep."
