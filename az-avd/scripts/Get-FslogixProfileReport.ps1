<#
.SYNOPSIS
    Lists FSLogix profile containers on the profile share: size, age and in-use state.

.DESCRIPTION
    Walks the share (SMB, so run it from a host that can reach the private endpoint, with
    Storage File Data SMB Share Reader or higher) and reports each VHD(X): user folder,
    allocated size, percent of the configured maximum, last write time and whether a host
    has it open. Writes a CSV when -OutputPath is given, otherwise objects to the pipeline.

    The folder name is <SID>_<user> by default (or <user>_<SID> with FlipFlopProfileDirectoryName).

.EXAMPLE
    ./Get-FslogixProfileReport.ps1 -SharePath '\\<account>.file.core.windows.net\profiles' -MaxSizeMB 30000 -OutputPath ./profiles.csv
#>
param(
    [Parameter(Mandatory)]
    [string]$SharePath,

    [int]$MaxSizeMB = 30000,

    [int]$StaleDays = 90,

    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$rows = foreach ($file in Get-ChildItem -LiteralPath $SharePath -Recurse -File -Include *.vhd, *.vhdx) {
    $inUse = $false
    try { [IO.File]::Open($file.FullName, 'Open', 'Read', 'None').Dispose() } catch { $inUse = $true }
    $folder = $file.Directory.Name
    $sid = ($folder -split '_' | Where-Object { $_ -match '^S-1-' } | Select-Object -First 1)
    [pscustomobject]@{
        Folder         = $folder
        Sid            = $sid
        User           = (($folder -split '_') | Where-Object { $_ -ne $sid }) -join '_'
        File           = $file.Name
        SizeMB         = [math]::Round($file.Length / 1MB)
        PercentOfMax   = [math]::Round(100 * ($file.Length / 1MB) / $MaxSizeMB, 1)
        LastWriteUtc   = $file.LastWriteTimeUtc
        Stale          = $file.LastWriteTimeUtc -lt (Get-Date).ToUniversalTime().AddDays(-$StaleDays)
        InUse          = $inUse
        Path           = $file.FullName
    }
}

$rows = $rows | Sort-Object SizeMB -Descending
if ($OutputPath) {
    $rows | Export-Csv -LiteralPath $OutputPath -NoTypeInformation
    $total = ($rows | Measure-Object SizeMB -Sum).Sum
    Write-Output "$(@($rows).Count) containers, $([math]::Round($total / 1024, 1)) GB, $(@($rows | Where-Object Stale).Count) not written in $StaleDays days. Written to $OutputPath."
}
else { $rows }
