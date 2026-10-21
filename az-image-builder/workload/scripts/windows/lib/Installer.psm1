# Runs installers on the build VM with a timeout, so an installer waiting for input can't hang the build.
Set-StrictMode -Version Latest

function Invoke-Installer {
    <#
    .SYNOPSIS
        Start an installer, wait up to -TimeoutMinutes, check the exit code.
    .DESCRIPTION
        On timeout the installer and its child processes are killed. Then:
          - default: throw (the build fails at this step, with a clear message)
          - -Optional: write a warning and return $false (the build continues without it)
        Returns $true on success.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutMinutes = 20,
        [int[]]$SuccessCodes = @(0, 3010),   # 3010 = success, reboot required
        [string]$WorkingDirectory,
        [switch]$Optional
    )

    $params = @{ FilePath = $FilePath; PassThru = $true }
    if ($ArgumentList.Count) { $params.ArgumentList = $ArgumentList }
    if ($WorkingDirectory) { $params.WorkingDirectory = $WorkingDirectory }

    Write-Host "[$Name] starting: $FilePath $($ArgumentList -join ' ') (timeout $TimeoutMinutes min)"
    $started = Get-Date
    $proc = Start-Process @params
    $null = $proc.Handle   # cache the handle so ExitCode is available after WaitForExit

    if (-not $proc.WaitForExit($TimeoutMinutes * 60 * 1000)) {
        # Kill the whole tree: setup wrappers often spawn the real installer as a child.
        & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null
        $message = "[$Name] did not finish within $TimeoutMinutes minutes and was killed. It is probably waiting for input: check its silent-install switch."
        if ($Optional) { Write-Warning $message; return $false }
        throw $message
    }

    $code = $proc.ExitCode
    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    if ($code -notin $SuccessCodes) {
        $message = "[$Name] failed with exit code $code after $elapsed s."
        if ($Optional) { Write-Warning $message; return $false }
        throw $message
    }
    Write-Host "[$Name] exit code $code after $elapsed s"
    return $true
}

Export-ModuleMember -Function Invoke-Installer
