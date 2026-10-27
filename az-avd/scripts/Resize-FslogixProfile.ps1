<#
.SYNOPSIS
    Grows one user's FSLogix profile container (VHDX) on the profile share.

.DESCRIPTION
    For a single user who needs more space than fslogix.profileSizeInMBs. Raising
    profileSizeInMBs grows every user's container at next sign-in; this script grows one.

    Run on a Windows machine (for example a session host in drain mode) as a local
    administrator, signed in with an account that has Storage File Data SMB Share Elevated
    Contributor on the share. The user must be signed out: the script opens the VHDX
    exclusively first and stops if FSLogix still has it attached.

    Steps: copy the VHDX to <name>.vhdx.bak-<timestamp> (unless -SkipBackup), then diskpart
    'expand vdisk maximum=<MB>' on the detached disk, attach it, extend the volume, detach.
    FSLogix only grows a container up to SizeInMBs on its own, so a container grown here keeps
    its size; it isn't shrunk at sign-in.

.EXAMPLE
    ./Resize-FslogixProfile.ps1 -Path '\\<account>.file.core.windows.net\profiles\S-1-12-1-..._jdoe\Profile_jdoe.VHDX' -SizeGB 60 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ $_ -match '\.vhdx?$' })]
    [string]$Path,

    [Parameter(Mandatory)]
    [ValidateRange(1, 2040)]
    [int]$SizeGB,

    [switch]$SkipBackup
)

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run as a local administrator (diskpart needs it).'
}
if (-not (Test-Path -LiteralPath $Path)) { throw "$Path not found." }

# Fails while the container is attached by a session host.
try { [IO.File]::Open($Path, 'Open', 'ReadWrite', 'None').Dispose() }
catch { throw "$Path is in use (the user is probably signed in). Sign the user out and retry." }

function Invoke-Diskpart {
    param([string[]]$Commands)
    $file = Join-Path $Env:TEMP "diskpart-$([guid]::NewGuid().ToString('n')).txt"
    Set-Content -LiteralPath $file -Value $Commands -Encoding ASCII
    try {
        $output = & diskpart.exe /s $file
        if ($LASTEXITCODE -ne 0) { throw "diskpart failed ($LASTEXITCODE):`n$($output -join "`n")" }
        $output
    }
    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}

$detail = Invoke-Diskpart @("select vdisk file=`"$Path`"", 'detail vdisk')
$virtual = ($detail | Select-String -Pattern 'Virtual size:\s+([\d.,]+)\s+(MB|GB|TB)').Matches | Select-Object -First 1
if ($virtual) {
    $sizeMB = [double]($virtual.Groups[1].Value -replace ',', '') * @{ MB = 1; GB = 1024; TB = 1048576 }[$virtual.Groups[2].Value]
    if ($SizeGB * 1024 -le $sizeMB) { throw "$Path is already $([math]::Round($sizeMB / 1024, 1)) GB; containers can't be shrunk this way." }
}

if (-not $SkipBackup -and $PSCmdlet.ShouldProcess($Path, 'Back up container')) {
    $backup = "$Path.bak-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))"
    Copy-Item -LiteralPath $Path -Destination $backup
    Write-Output "Backup: $backup (delete it once the user has signed in successfully)."
}

if ($PSCmdlet.ShouldProcess($Path, "Expand to $SizeGB GB")) {
    Invoke-Diskpart @(
        "select vdisk file=`"$Path`""
        "expand vdisk maximum=$($SizeGB * 1024)"
        'attach vdisk'
    ) | Out-Null
    try {
        # The container has one data volume; extend it into the new space.
        $disk = Get-DiskImage -ImagePath $Path | Get-Disk
        $partition = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Type -ne 'Reserved' } | Sort-Object Size -Descending | Select-Object -First 1
        $max = (Get-PartitionSupportedSize -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber).SizeMax
        if ($max -gt $partition.Size) { Resize-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -Size $max }
    }
    finally {
        Invoke-Diskpart @("select vdisk file=`"$Path`"", 'detach vdisk') | Out-Null
    }
    Write-Output "$Path expanded to $SizeGB GB."
}
