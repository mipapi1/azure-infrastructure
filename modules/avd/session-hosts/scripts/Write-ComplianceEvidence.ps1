<#
.SYNOPSIS
    Scheduled task: records STIG configuration evidence as JSON lines for Azure Monitor Agent.

.DESCRIPTION
    Installed by Register-ComplianceEvidence.ps1 and run daily as SYSTEM. Each run appends one
    record per check to <OutputPath>\compliance-<yyyyMMdd>.json (UTF-8, one JSON object per
    line), which a data collection rule sends to the AvdComplianceEvidence_CL table.

    Checks:
    - DeferredStig    the deploy-time STIG step ran (deferred-applied-deploy.json)
    - Registry        each policy in deferred-registry.txt (LGPO text format) has its value
    - SecurityPolicy  each setting in deferred-secedit.inf matches secedit /export
    - AppLocker       enforcement mode of each effective rule collection
    - Defender        real-time protection and signature age
    - Scap            optional: rule results from an XCCDF file written by a SCAP scanner
                      installed on the image (ScapCommand). No scanner ships with this repo.

    The records are configuration evidence for review, not an authorization decision.

.PARAMETER ScapCommand
    Optional path of a SCAP scanner executable. Run with ScapArguments before parsing.

.PARAMETER ScapResultsPath
    Folder the scanner writes XCCDF results to. The newest *.xml file is parsed.
#>
param(
    [string]$StigPath = "$Env:ProgramData\STIG",
    [string]$OutputPath = "$Env:ProgramData\STIG\evidence",
    [string]$ScapCommand = '',
    [string]$ScapArguments = '',
    [string]$ScapResultsPath = '',
    [int]$RetentionDays = 7
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$runId = [guid]::NewGuid().ToString()
$now = (Get-Date).ToUniversalTime().ToString('o')
$file = Join-Path $OutputPath "compliance-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd')).json"
$records = [System.Collections.Generic.List[object]]::new()

function Add-Record {
    param([string]$Source, [string]$RuleId = '', [string]$Item, [string]$Expected = '', [string]$Actual = '', [string]$Status)
    $records.Add([ordered]@{
            TimeGenerated = $now; RunId = $runId; Source = $Source; RuleId = $RuleId
            Item = $Item; Expected = $Expected; Actual = $Actual; Status = $Status
        })
}

function Read-InfSections {
    param([string]$Path)
    $sections = @{}
    $current = $null
    foreach ($line in Get-Content -LiteralPath $Path -Encoding Unicode) {
        if ($line -match '^\s*\[(.+)\]\s*$') { $current = $Matches[1]; $sections[$current] = [ordered]@{}; continue }
        if ($current -and $line -match '^\s*([^=;]+?)\s*=\s*(.*)$') { $sections[$current][$Matches[1]] = $Matches[2].Trim() }
    }
    $sections
}

function ConvertTo-Comparable {
    param([string]$Section, [string]$Value)
    if ($Section -eq 'Privilege Rights') { return ((($Value -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object) -join ',') }
    $Value.Trim('"')
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# 1. Deploy-time STIG step
$marker = Join-Path $StigPath 'deferred-applied-deploy.json'
if (Test-Path -LiteralPath $marker) {
    $applied = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    Add-Record -Source 'DeferredStig' -Item 'Apply-DeferredStigs -Phase Deploy' -Actual $applied.appliedUtc -Status 'Pass'
}
else {
    Add-Record -Source 'DeferredStig' -Item 'Apply-DeferredStigs -Phase Deploy' -Actual 'not run' -Status 'Fail'
}

# 2. Registry policies (LGPO text: scope, key, value name, TYPE:data, separated by blank lines)
$registry = Join-Path $StigPath 'deferred-registry.txt'
if (Test-Path -LiteralPath $registry) {
    $blocks = ((Get-Content -LiteralPath $registry -Raw -Encoding Unicode) -split '(\r?\n){2,}') | Where-Object { $_.Trim() }
    foreach ($block in $blocks) {
        $lines = @($block -split '\r?\n' | Where-Object { $_.Trim() -and $_ -notmatch '^\s*;' })
        if ($lines.Count -lt 4 -or $lines[0].Trim() -ne 'Computer') { continue }
        $key = "HKLM:\$($lines[1].Trim())"
        $name = $lines[2].Trim()
        $action = $lines[3].Trim()
        $actual = (Get-ItemProperty -LiteralPath $key -Name $name -ErrorAction SilentlyContinue).$name
        if ($action -eq 'DELETE') {
            Add-Record -Source 'Registry' -Item "$key\$name" -Expected '(absent)' -Actual "$actual" -Status ($(if ($null -eq $actual) { 'Pass' } else { 'Fail' }))
            continue
        }
        $expected = ($action -split ':', 2)[1]
        $status = if ($null -ne $actual -and "$actual" -eq "$expected") { 'Pass' } else { 'Fail' }
        Add-Record -Source 'Registry' -Item "$key\$name" -Expected $expected -Actual "$actual" -Status $status
    }
}

# 3. Security template settings
$inf = Join-Path $StigPath 'deferred-secedit.inf'
if (Test-Path -LiteralPath $inf) {
    $export = Join-Path $Env:TEMP "evidence-$runId.inf"
    & secedit.exe /export /cfg $export /areas SECURITYPOLICY USER_RIGHTS /quiet
    $current = Read-InfSections -Path $export
    Remove-Item -LiteralPath $export -Force -ErrorAction SilentlyContinue
    $wanted = Read-InfSections -Path $inf
    foreach ($section in @('System Access', 'Privilege Rights', 'Registry Values')) {
        if (-not $wanted.ContainsKey($section)) { continue }
        foreach ($name in $wanted[$section].Keys) {
            $expected = ConvertTo-Comparable -Section $section -Value $wanted[$section][$name]
            $actual = if ($current.ContainsKey($section) -and $current[$section].Contains($name)) { ConvertTo-Comparable -Section $section -Value $current[$section][$name] } else { '' }
            Add-Record -Source 'SecurityPolicy' -Item "[$section] $name" -Expected $expected -Actual $actual -Status ($(if ($expected -eq $actual) { 'Pass' } else { 'Fail' }))
        }
    }
}

# 4. AppLocker enforcement
try {
    [xml]$policy = Get-AppLockerPolicy -Effective -Xml
    foreach ($collection in $policy.AppLockerPolicy.RuleCollection) {
        $mode = $collection.EnforcementMode
        Add-Record -Source 'AppLocker' -Item "RuleCollection $($collection.Type)" -Expected 'Enabled' -Actual $mode -Status ($(if ($mode -eq 'Enabled') { 'Pass' } else { 'Fail' }))
    }
}
catch {
    Add-Record -Source 'AppLocker' -Item 'Get-AppLockerPolicy' -Actual $_.Exception.Message -Status 'Error'
}

# 5. Microsoft Defender Antivirus
try {
    $mp = Get-MpComputerStatus
    Add-Record -Source 'Defender' -Item 'RealTimeProtectionEnabled' -Expected 'True' -Actual "$($mp.RealTimeProtectionEnabled)" -Status ($(if ($mp.RealTimeProtectionEnabled) { 'Pass' } else { 'Fail' }))
    Add-Record -Source 'Defender' -Item 'AntivirusSignatureAge (days)' -Expected '<= 1' -Actual "$($mp.AntivirusSignatureAge)" -Status ($(if ($mp.AntivirusSignatureAge -le 1) { 'Pass' } else { 'Fail' }))
}
catch {
    Add-Record -Source 'Defender' -Item 'Get-MpComputerStatus' -Actual $_.Exception.Message -Status 'Error'
}

# 6. Optional SCAP scan (XCCDF rule-result elements, any XCCDF version)
if ($ScapCommand) {
    try {
        if (-not (Test-Path -LiteralPath $ScapCommand)) { throw "$ScapCommand not found" }
        $process = Start-Process -FilePath $ScapCommand -ArgumentList $ScapArguments -Wait -PassThru -NoNewWindow
        $result = Get-ChildItem -LiteralPath $ScapResultsPath -Filter *.xml -Recurse | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if (-not $result) { throw "no XCCDF results in $ScapResultsPath (scanner exit code $($process.ExitCode))" }
        [xml]$xccdf = Get-Content -LiteralPath $result.FullName -Raw
        foreach ($rule in $xccdf.SelectNodes("//*[local-name()='rule-result']")) {
            $outcome = ($rule.ChildNodes | Where-Object { $_.LocalName -eq 'result' } | Select-Object -First 1).InnerText
            $status = switch ($outcome) { 'pass' { 'Pass' } 'fail' { 'Fail' } 'error' { 'Error' } default { 'NotApplicable' } }
            Add-Record -Source 'Scap' -RuleId $rule.GetAttribute('idref') -Item $result.Name -Actual $outcome -Status $status
        }
    }
    catch {
        Add-Record -Source 'Scap' -Item $ScapCommand -Actual $_.Exception.Message -Status 'Error'
    }
}

# Append as UTF-8 without a BOM; the agent reads new lines only.
$encoding = [System.Text.UTF8Encoding]::new($false)
$lines = $records | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 3 }
[System.IO.File]::AppendAllText($file, (($lines -join "`n") + "`n"), $encoding)

# Keep a few days so the agent has time to read every file.
Get-ChildItem -LiteralPath $OutputPath -Filter 'compliance-*.json' |
    Where-Object { $_.LastWriteTimeUtc -lt (Get-Date).ToUniversalTime().AddDays(-$RetentionDays) } |
    Remove-Item -Force

$failed = @($records | Where-Object { $_.Status -ne 'Pass' -and $_.Status -ne 'NotApplicable' }).Count
Write-Output "Compliance evidence: $($records.Count) checks, $failed not passing, written to $file"
