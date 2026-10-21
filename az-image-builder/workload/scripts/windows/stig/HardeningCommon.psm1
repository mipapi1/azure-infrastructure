# Shared helpers for the configure*.ps1 hardening scripts.
Set-StrictMode -Version Latest

$script:DefaultLgpoPath = 'C:\Temp\LGPO_30\LGPO.exe'

function Invoke-LgpoText {
    <#
    .SYNOPSIS
        Merges LGPO text-format policy into local Group Policy (LGPO /t). Throws on failure.
    .DESCRIPTION
        /t merges into the existing policy (/r + /w would replace it). Text format: blocks of 4 lines
        (Computer|User, key, value name, TYPE:data) separated by blank lines.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$LgpoPath = $script:DefaultLgpoPath,
        [string]$Description = 'policy'
    )
    if (-not (Test-Path -LiteralPath $LgpoPath)) { throw "LGPO.exe not found at $LgpoPath" }
    $file = Join-Path $Env:TEMP "lgpo-$([guid]::NewGuid().ToString('n')).txt"
    try {
        Set-Content -LiteralPath $file -Value $Text -Encoding Unicode
        $output = & $LgpoPath /q /t $file 2>&1
        if ($LASTEXITCODE -ne 0) { throw "LGPO /t failed for $Description (exit $LASTEXITCODE): $output" }
        Write-Output "Applied $Description"
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function New-LgpoEntry {
    <#
    .SYNOPSIS
        One LGPO text block. Scope: Computer|User. Data: 'DWORD:1', 'SZ:text', 'DELETE', etc.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Computer', 'User')][string]$Scope,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Data
    )
    "$Scope`r`n$Key`r`n$Name`r`n$Data`r`n"
}

function Set-RegistryValue {
    <#
    .SYNOPSIS
        Creates the key if needed and sets the value.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord', 'QWord', 'String', 'ExpandString', 'MultiString', 'Binary')][string]$Type = 'DWord'
    )
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Invoke-Native {
    <#
    .SYNOPSIS
        Runs an executable, waits, and throws unless the exit code is in -SuccessCodes.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int[]]$SuccessCodes = @(0),
        [string]$Description = $FilePath
    )
    $params = @{ FilePath = $FilePath; Wait = $true; PassThru = $true; NoNewWindow = $true }
    if ($ArgumentList.Count) { $params.ArgumentList = $ArgumentList }
    $proc = Start-Process @params
    if ($proc.ExitCode -notin $SuccessCodes) { throw "$Description failed with exit code $($proc.ExitCode)" }
    Write-Output "$Description exit code $($proc.ExitCode)"
}

Export-ModuleMember -Function Invoke-LgpoText, New-LgpoEntry, Set-RegistryValue, Invoke-Native
