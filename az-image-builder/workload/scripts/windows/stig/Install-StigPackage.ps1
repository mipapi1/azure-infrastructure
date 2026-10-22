<#
.SYNOPSIS
    Applies the DISA STIG GPO package during an Image Builder build without cutting Packer's
    WinRM connection, and stages the withheld settings for later.

.DESCRIPTION
    Copies the ADMX/ADML templates, then imports each selected GPO with LGPO.exe /g after removing:
      - Domain controller GPOs from the "MS and DC" server packages (member server GPOs only).
      - $Deferred settings: written to C:\ProgramData\STIG and applied by Apply-DeferredStigs.ps1
        (before sysprep, and on each VM at deploy time).
      - $Dropped settings: set differently by configureWindows.ps1.
      - Domain principals and "ADD YOUR ..." placeholders in user rights (images are not domain-joined at
        build time). Principal names are mapped to SIDs ($PrincipalSids) so they resolve off-domain, and
        SIDs listed without the leading '*' get one.
    Prerequisites (artifact group 'windows-stig'): the package in -StigRoot, LGPO.exe at -LgpoPath.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('win11', 'ws2022', 'ws2025')]
    [string]$Os,

    # Browser STIGs to apply. The browser must be installed.
    [ValidateSet('edge', 'chrome')]
    [string[]]$Browsers = @(),

    # Extra GPO folders, matched against "DoD <name> vXrY", e.g. 'Office 2019-M365 Apps'.
    [string[]]$AdditionalPackages = @(),

    [string]$StigRoot = 'C:\Temp\stig',
    [string]$LgpoPath = 'C:\Temp\LGPO_30\LGPO.exe',

    [string]$OutputPath = "$Env:ProgramData\STIG"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#######################################################################################
# Settings withheld until deprovisioning. Keep this list as small as possible; every entry
# is a setting that is NOT in effect while Packer runs the customization steps.
#######################################################################################
$Deferred = @{
    # [Privilege Rights]: SIDs removed from a right at build, re-added at deploy.
    PrivilegeSids = @{
        # "Local account" and "Local account and member of Administrators group". Deny network logon
        # to the local accounts Packer authenticates with over WinRM. This is the main build breaker.
        SeDenyNetworkLogonRight = @('*S-1-5-113', '*S-1-5-114')
    }
    # [System Access] keys withheld at build.
    SystemAccess = @(
        # Renames the built-in Administrator (Packer's account). Applied per host at deploy time.
        'NewAdministratorName'
    )
    # [Registry Values] (security options) withheld at build.
    SecurityOptions = @(
        # Admin Approval Mode for the built-in Administrator (Packer's account): its remote
        # WinRM sessions would get a filtered, non-admin token.
        'MACHINE\Software\Microsoft\Windows\CurrentVersion\Policies\System\FilterAdministratorToken'
    )
    # registry.pol values (machine scope) withheld at build.
    Registry = @(
        # WinRM service Basic auth. Withheld as a precaution; Packer may authenticate with it.
        'SOFTWARE\Policies\Microsoft\Windows\WinRM\Service|AllowBasic'
        # UAC remote restrictions: a filtered token for local admins over the network (Packer's WinRM session).
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System|LocalAccountTokenFilterPolicy'
    )
}

# registry.pol values removed and not deferred: configureWindows.ps1 sets them differently.
$Dropped = @(
    'SOFTWARE\Policies\Microsoft\WindowsFirewall\PublicProfile|AllowLocalPolicyMerge'   # deleted: local rules merge off-domain
)

# User-rights principals given by name in some packages (Server 2025), mapped to their well-known SIDs.
$PrincipalSids = @{
    'Local account'                                   = '*S-1-5-113'
    'Local account and member of Administrators group' = '*S-1-5-114'
    'Local Account and member of Administrators'      = '*S-1-5-114'
}
# Removed from user rights: domain groups and placeholders that don't exist on a non-domain machine.
$DropPrincipalPattern = '^(ADD YOUR |(.+\\)?(Domain Admins|Enterprise Admins)$)'

$osPackages = @{
    win11  = 'Windows 11'
    ws2022 = 'WinSvr 2022 MS and DC'
    ws2025 = 'WinSvr 2025 MS and DC'
}
$browserPackages = @{ edge = 'Microsoft Edge'; chrome = 'Google Chrome' }
$Include = @(
    $osPackages[$Os]
    'Windows Defender Firewall'
    'Microsoft Defender Antivirus'
    $Browsers | ForEach-Object { $browserPackages[$_] }
    $AdditionalPackages
) | Where-Object { $_ } | Select-Object -Unique

#######################################################################################

function Invoke-Lgpo {
    param([string[]]$Arguments)
    $output = & $LgpoPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "LGPO.exe $($Arguments -join ' ') failed with exit code $LASTEXITCODE`n$output"
    }
    $output
}

# Splits LGPO /parse output into 4-line blocks: scope, key, value, action.
function ConvertFrom-LgpoText {
    param([string[]]$Lines)
    $blocks = @()
    $current = @()
    foreach ($line in $Lines) {
        if ($line -match '^\s*;') { continue }
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($current.Count -eq 4) { $blocks += , $current }
            $current = @()
            continue
        }
        $current += $line.Trim()
    }
    if ($current.Count -eq 4) { $blocks += , $current }
    $blocks
}

function ConvertTo-LgpoText {
    param([object[]]$Blocks)
    ($Blocks | ForEach-Object { ($_ -join "`r`n") + "`r`n" }) -join "`r`n"
}

foreach ($path in @($StigRoot, $LgpoPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "$path not found. Did the 'windows-stig' artifact group download?" }
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$work = Join-Path $Env:TEMP "stig-$([guid]::NewGuid().ToString('n'))"
New-Item -ItemType Directory -Path $work | Out-Null

$deferredRegistry = @()
$deferredPrivileges = [ordered]@{}
$deferredSystemAccess = @()
$deferredSecurityOptions = @()

try {
    # 1. Policy templates
    Write-Output 'STIG: Copying ADMX/ADML templates'
    $admxRoot = Join-Path $StigRoot 'ADMX Templates'
    Get-ChildItem -LiteralPath $admxRoot -Recurse -Filter *.admx | Copy-Item -Destination "$Env:SystemRoot\PolicyDefinitions\" -Force
    Get-ChildItem -LiteralPath $admxRoot -Recurse -Filter *.adml |
        Where-Object { $_.Directory.Name -eq 'en-US' } |
        Copy-Item -Destination "$Env:SystemRoot\PolicyDefinitions\en-US\" -Force

    # 2. Select and copy GPO packages
    $pattern = '^DoD (' + (($Include | ForEach-Object { [regex]::Escape($_) }) -join '|') + ') '
    $packages = @(Get-ChildItem -LiteralPath $StigRoot -Directory | Where-Object { $_.Name -match $pattern })
    $missing = @($Include | Where-Object { $i = $_; -not ($packages | Where-Object { $_.Name -match "^DoD $([regex]::Escape($i)) " }) })
    if ($missing.Count -gt 0) { throw "STIG package(s) not found under ${StigRoot}: $($missing -join ', ')" }

    foreach ($package in $packages) {
        Write-Output "STIG: Preparing $($package.Name)"
        $copy = Join-Path $work $package.Name
        Copy-Item -LiteralPath $package.FullName -Destination $copy -Recurse

        # Server packages hold member server (MS) and domain controller (DC) GPO backups. Keep MS only.
        foreach ($backup in Get-ChildItem -LiteralPath (Join-Path $copy 'GPOs') -Directory) {
            $info = Join-Path $backup.FullName 'bkupInfo.xml'
            if ((Test-Path -LiteralPath $info) -and ((Get-Content -LiteralPath $info -Raw) -match '<GPODisplayName><!\[CDATA\[([^\]]*)\]\]>')) {
                if ($Matches[1] -match '\bDC STIG\b') {
                    Write-Output "  skipped (domain controller): $($Matches[1])"
                    Remove-Item -LiteralPath $backup.FullName -Recurse -Force
                }
            }
        }

        # 2a. Security templates (GptTmpl.inf, UTF-16)
        foreach ($inf in Get-ChildItem -LiteralPath $copy -Recurse -Filter GptTmpl.inf) {
            $section = ''
            $lines = foreach ($line in Get-Content -LiteralPath $inf.FullName -Encoding Unicode) {
                if ($line -match '^\s*\[(.+)\]\s*$') { $section = $Matches[1]; $line; continue }

                if ($section -eq 'Privilege Rights' -and $line -match '^\s*(\w+)\s*=\s*(.*)$') {
                    $right = $Matches[1]
                    $members = @($Matches[2] -split ',' | ForEach-Object { $_.Trim() } |
                        Where-Object { $_ -and $_ -notmatch $DropPrincipalPattern } |
                        ForEach-Object { if ($PrincipalSids.ContainsKey($_)) { $PrincipalSids[$_] } else { $_ } } |
                        # secedit reads a SID without the leading '*' as an account name. Some packages (Windows 11
                        # v2r11, the Protected Print service SID in SeImpersonatePrivilege) list one that way.
                        ForEach-Object { if ($_ -match '^S-1-\d+(-\d+)+$') { "*$_" } else { $_ } } |
                        Select-Object -Unique)
                    $withhold = @($Deferred.PrivilegeSids[$right] | Where-Object { $_ -and $_ -in $members })
                    if ($withhold.Count -gt 0) {
                        $deferredPrivileges[$right] = $members           # full STIG value, applied at deploy
                        $members = @($members | Where-Object { $_ -notin $withhold })
                        Write-Output "  deferred: $right += $($withhold -join ',')"
                    }
                    "$right = $($members -join ',')"
                    continue
                }
                if ($section -eq 'System Access' -and $line -match '^\s*(\w+)\s*=') {
                    if ($Matches[1] -in $Deferred.SystemAccess) {
                        $deferredSystemAccess += $line.Trim()
                        Write-Output "  deferred: $($line.Trim())"
                        continue
                    }
                }
                if ($section -eq 'Registry Values' -and $line -match '^\s*([^=]+)=') {
                    if ($Matches[1].Trim() -in $Deferred.SecurityOptions) {
                        $deferredSecurityOptions += $line.Trim()
                        Write-Output "  deferred: $($line.Trim())"
                        continue
                    }
                }
                $line
            }
            Set-Content -LiteralPath $inf.FullName -Value $lines -Encoding Unicode
        }

        # 2b. Machine registry.pol
        foreach ($pol in Get-ChildItem -LiteralPath $copy -Recurse -Filter registry.pol | Where-Object { $_.Directory.Name -eq 'Machine' }) {
            $parsed = Invoke-Lgpo @('/parse', '/q', '/m', $pol.FullName)
            $keep = @()
            foreach ($block in ConvertFrom-LgpoText -Lines $parsed) {
                $id = "$($block[1])|$($block[2])"
                if ($Deferred.Registry -contains $id) {
                    $deferredRegistry += , $block
                    Write-Output "  deferred: $id = $($block[3])"
                }
                elseif ($Dropped -contains $id) {
                    Write-Output "  dropped (set by configureWindows.ps1): $id"
                }
                else {
                    $keep += , $block
                }
            }
            $text = Join-Path $work "$([guid]::NewGuid().ToString('n')).txt"
            Set-Content -LiteralPath $text -Value (ConvertTo-LgpoText -Blocks $keep) -Encoding Unicode
            Invoke-Lgpo @('/q', '/r', $text, '/w', $pol.FullName) | Out-Null
        }

        # 3. Import the edited GPO backup(s)
        Write-Output "STIG: Applying $($package.Name)"
        Invoke-Lgpo @('/q', '/g', (Join-Path $copy 'GPOs')) | Out-Null
    }

    # 4. Stage deferred settings for Apply-DeferredStigs.ps1
    $inf = @('[Unicode]', 'Unicode=yes', '[Version]', 'signature="$CHICAGO$"', 'Revision=1')
    if ($deferredSystemAccess) { $inf += '[System Access]'; $inf += $deferredSystemAccess }
    if ($deferredSecurityOptions) { $inf += '[Registry Values]'; $inf += $deferredSecurityOptions }
    if ($deferredPrivileges.Count) {
        $inf += '[Privilege Rights]'
        $inf += $deferredPrivileges.Keys | ForEach-Object { "$_ = $($deferredPrivileges[$_] -join ',')" }
    }
    Set-Content -LiteralPath (Join-Path $OutputPath 'deferred-secedit.inf') -Value $inf -Encoding Unicode
    Set-Content -LiteralPath (Join-Path $OutputPath 'deferred-registry.txt') -Value (ConvertTo-LgpoText -Blocks $deferredRegistry) -Encoding Unicode
    Copy-Item -LiteralPath $LgpoPath -Destination (Join-Path $OutputPath 'LGPO.exe') -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Apply-DeferredStigs.ps1') -Destination $OutputPath -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'findings.txt') -Destination $OutputPath -Force

    [ordered]@{
        builtUtc  = (Get-Date).ToUniversalTime().ToString('o')
        os        = $Os
        packages  = @($packages.Name)
        deferred  = [ordered]@{
            privileges      = $deferredPrivileges
            systemAccess    = $deferredSystemAccess
            securityOptions = $deferredSecurityOptions
            registry        = @($deferredRegistry | ForEach-Object { "$($_[1])|$($_[2]) = $($_[3])" })
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputPath 'build-manifest.json') -Encoding UTF8

    # Only SYSTEM and Administrators may change what runs as SYSTEM at deploy time.
    & icacls.exe $OutputPath /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $OutputPath" }

    $expected = $Deferred.PrivilegeSids.Count + $Deferred.SystemAccess.Count + $Deferred.SecurityOptions.Count + $Deferred.Registry.Count
    $found = $deferredPrivileges.Count + $deferredSystemAccess.Count + $deferredSecurityOptions.Count + $deferredRegistry.Count
    if ($found -ne $expected) {
        Write-Warning "Expected $expected deferred setting(s) in the package but found $found. The STIG package may have changed; review build-manifest.json."
    }
    Write-Output "STIG: Package applied. $found setting(s) deferred to deploy time ($OutputPath)."
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
