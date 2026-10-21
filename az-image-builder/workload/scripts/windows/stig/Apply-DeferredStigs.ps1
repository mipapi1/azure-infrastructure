<#
.SYNOPSIS
    Applies the STIG settings withheld from the Packer-driven part of the build. Idempotent.

.DESCRIPTION
    Inputs in C:\ProgramData\STIG (placed by Install-StigPackage.ps1): deferred-secedit.inf, deferred-registry.txt.
    -Phase Build   C:\DeprovisioningScript.ps1, before sysprep. Everything except the account steps.
    -Phase Deploy  Each VM after deployment (Run Command): everything again, plus rename the built-in admin to
                   X_Admin, deny it network logon, and disable local administrator accounts.
    Log: C:\ProgramData\STIG\deferred-<phase>-<timestamp>.log. Exits non-zero on failure.
#>
[CmdletBinding()]
param(
    [ValidateSet('Build', 'Deploy')]
    [string]$Phase = 'Deploy',

    [string]$StigPath = "$Env:ProgramData\STIG",

    # Deploy phase (V-253432). $false keeps a local break-glass administrator.
    [bool]$DisableLocalAdministrators = $true
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
$log = Join-Path $StigPath "deferred-$($Phase.ToLower())-$stamp.log"
Start-Transcript -LiteralPath $log | Out-Null

function Invoke-Secedit {
    param([string]$Cfg, [string]$Areas)
    $db = Join-Path $Env:TEMP "stig-$([guid]::NewGuid().ToString('n')).sdb"
    & secedit.exe /configure /db $db /cfg $Cfg /areas $Areas.Split(' ') /quiet
    $code = $LASTEXITCODE
    Remove-Item -LiteralPath $db -Force -ErrorAction SilentlyContinue
    if ($code -ne 0) { throw "secedit /configure $Cfg failed with exit code $code (see %windir%\security\logs\scesrv.log)" }
}

try {
    $lgpo = Join-Path $StigPath 'LGPO.exe'
    $inf = Join-Path $StigPath 'deferred-secedit.inf'
    $registry = Join-Path $StigPath 'deferred-registry.txt'
    foreach ($path in @($lgpo, $inf, $registry)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "$path not found. Was this image built with Install-StigPackage.ps1?" }
    }

    # 1. Security template: deny network logon for local accounts, FilterAdministratorToken,
    #    admin rename. The Build phase leaves out the rename (Azure renames the built-in admin
    #    again when it provisions each VM).
    $cfg = $inf
    if ($Phase -eq 'Build') {
        $cfg = Join-Path $Env:TEMP "stig-build-$([guid]::NewGuid().ToString('n')).inf"
        Get-Content -LiteralPath $inf -Encoding Unicode |
            Where-Object { $_ -notmatch '^\s*NewAdministratorName\s*=' } |
            Set-Content -LiteralPath $cfg -Encoding Unicode
    }
    Write-Output "[$Phase] Applying deferred security template"
    Invoke-Secedit -Cfg $cfg -Areas 'SECURITYPOLICY USER_RIGHTS'
    if ($cfg -ne $inf) { Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue }

    # 2. Registry policies (e.g. WinRM service AllowBasic = 0)
    if ((Get-Content -LiteralPath $registry -Raw -Encoding Unicode).Trim()) {
        Write-Output "[$Phase] Applying deferred registry policies"
        & $lgpo /q /t $registry
        if ($LASTEXITCODE -ne 0) { throw "LGPO /t failed with exit code $LASTEXITCODE" }
    }

    if ($Phase -eq 'Deploy') {
        # 3. Built-in admin (SID ...-500, renamed X_Admin by step 1): deny network logon explicitly.
        $builtInAdmin = Get-LocalUser | Where-Object { $_.SID.Value -like 'S-1-5-21-*-500' }
        $export = Join-Path $Env:TEMP "rights-$([guid]::NewGuid().ToString('n')).inf"
        & secedit.exe /export /cfg $export /areas USER_RIGHTS /quiet
        $current = (Get-Content -LiteralPath $export -Encoding Unicode |
            Where-Object { $_ -match '^SeDenyNetworkLogonRight\s*=' }) -replace '^SeDenyNetworkLogonRight\s*=\s*', ''
        Remove-Item -LiteralPath $export -Force -ErrorAction SilentlyContinue
        $members = @("$current" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $adminSid = "*$($builtInAdmin.SID.Value)"
        if ($adminSid -notin $members) {
            Write-Output "[$Phase] Denying network logon to $($builtInAdmin.Name)"
            $rights = Join-Path $Env:TEMP "rights-$([guid]::NewGuid().ToString('n')).inf"
            Set-Content -LiteralPath $rights -Encoding Unicode -Value @(
                '[Unicode]', 'Unicode=yes', '[Version]', 'signature="$CHICAGO$"', 'Revision=1',
                '[Privilege Rights]', "SeDenyNetworkLogonRight = $((@($members) + $adminSid) -join ',')"
            )
            Invoke-Secedit -Cfg $rights -Areas 'USER_RIGHTS'
            Remove-Item -LiteralPath $rights -Force -ErrorAction SilentlyContinue
        }

        # 4. Disable local administrator accounts (V-253432). Uses ADSI because
        #    Get-LocalGroupMember fails on Entra ID members it can't resolve.
        if ($DisableLocalAdministrators) {
            $group = [ADSI]"WinNT://$Env:COMPUTERNAME/Administrators,group"
            foreach ($member in @($group.psbase.Invoke('Members'))) {
                $path = $member.GetType().InvokeMember('ADsPath', 'GetProperty', $null, $member, $null)
                # Local accounts look like WinNT://<computer>/<name>; Entra ID ones like WinNT://AzureAD/<name>.
                if ($path -match "^WinNT://$([regex]::Escape($Env:COMPUTERNAME))/([^/]+)$") {
                    $user = Get-LocalUser -Name $Matches[1] -ErrorAction SilentlyContinue
                    if ($user -and $user.Enabled) {
                        Write-Output "[$Phase] Disabling local administrator $($user.Name)"
                        Disable-LocalUser -Name $user.Name
                    }
                }
            }
        }
    }

    Write-Output "[$Phase] Refreshing policy"
    & gpupdate.exe /target:computer /force | Out-Null

    Set-Content -LiteralPath (Join-Path $StigPath "deferred-applied-$($Phase.ToLower()).json") -Encoding UTF8 -Value (
        [ordered]@{ phase = $Phase; appliedUtc = (Get-Date).ToUniversalTime().ToString('o'); log = $log } | ConvertTo-Json)
    Write-Output "[$Phase] Deferred STIG settings applied."
}
catch {
    Write-Error $_ -ErrorAction Continue
    Stop-Transcript | Out-Null
    exit 1
}
Stop-Transcript | Out-Null
exit 0
