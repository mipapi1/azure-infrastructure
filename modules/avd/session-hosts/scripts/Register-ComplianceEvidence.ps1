<#
.SYNOPSIS
    Run Command: installs the daily compliance evidence task on a session host.

.DESCRIPTION
    Writes Write-ComplianceEvidence.ps1 (embedded at deployment time) to
    C:\ProgramData\STIG\evidence, restricts the folder to SYSTEM and Administrators (write)
    and Users (read), registers a scheduled task that runs it as SYSTEM every day, and runs
    it once now so the first records arrive right after deployment.

.PARAMETER DailyAt
    Local time of the daily run, HH:mm.

.PARAMETER ScapCommand
    Optional SCAP scanner executable on the image, passed to the collector.

.PARAMETER ScapArguments
    Arguments for the scanner.

.PARAMETER ScapResultsPath
    Folder the scanner writes XCCDF results to.
#>
param(
    [string]$DailyAt = '03:00',
    [string]$ScapCommand = '',
    [string]$ScapArguments = '',
    [string]$ScapResultsPath = ''
)

$ErrorActionPreference = 'Stop'

$folder = Join-Path $Env:ProgramData 'STIG\evidence'
$collector = Join-Path $folder 'Write-ComplianceEvidence.ps1'
New-Item -ItemType Directory -Path $folder -Force | Out-Null

# The task runs as SYSTEM, so only SYSTEM and Administrators may change its script.
& icacls.exe $folder /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed with exit code $LASTEXITCODE" }

$content = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__COLLECTOR_BASE64__'))
Set-Content -LiteralPath $collector -Value $content -Encoding UTF8

$arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$collector`""
if ($ScapCommand) {
    $arguments += " -ScapCommand `"$ScapCommand`" -ScapArguments `"$ScapArguments`" -ScapResultsPath `"$ScapResultsPath`""
}
$action = New-ScheduledTaskAction -Execute "$Env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $arguments
$trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($DailyAt, 'HH:mm', $null))
$principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'AVD compliance evidence' -TaskPath '\AVD\' -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Start-ScheduledTask -TaskName 'AVD compliance evidence' -TaskPath '\AVD\'
Write-Output "Compliance evidence task registered (daily at $DailyAt) and started."
