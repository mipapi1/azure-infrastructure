<#
.SYNOPSIS
    Changes the quota of the FSLogix profile share (premium Azure Files is billed on the quota).

.DESCRIPTION
    Reads the share's current quota and usage, then sets a new quota: an explicit -QuotaGiB, or
    the current quota grown by -GrowPercent. Refuses a quota that would leave less than
    -MinimumFreePercent free, so it can't shrink the share under its users.

    The deployment sets the quota from fslogix.shareQuotaGiB on every run. After resizing here,
    update shareQuotaGiB in the parameter file, or the next deployment sets it back.

    Needs Az.Storage and a role with Microsoft.Storage/storageAccounts/fileServices/shares/write
    on the account (for example Storage Account Contributor).

.EXAMPLE
    ./Resize-FslogixShare.ps1 -ResourceGroupName avd-prod-eus-storage-rg -StorageAccountName <account> -GrowPercent 25 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Grow')]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$StorageAccountName,

    [string]$ShareName = 'profiles',

    [Parameter(Mandatory, ParameterSetName = 'Quota')]
    [ValidateRange(100, 102400)]
    [int]$QuotaGiB,

    [Parameter(Mandatory, ParameterSetName = 'Grow')]
    [ValidateRange(1, 500)]
    [int]$GrowPercent,

    [ValidateRange(0, 90)]
    [int]$MinimumFreePercent = 10
)

$ErrorActionPreference = 'Stop'

$share = Get-AzRmStorageShare -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName -Name $ShareName -GetShareUsage
$usedGiB = [math]::Round($share.ShareUsageBytes / 1GB, 1)
$current = $share.QuotaGiB
$target = if ($PSCmdlet.ParameterSetName -eq 'Quota') { $QuotaGiB } else { [int][math]::Ceiling($current * (1 + $GrowPercent / 100)) }

$minimum = [int][math]::Ceiling($usedGiB / (1 - $MinimumFreePercent / 100))
if ($target -lt $minimum) {
    throw "A quota of $target GiB would leave less than $MinimumFreePercent% free ($usedGiB GiB used). Use at least $minimum GiB."
}

Write-Output "Share $StorageAccountName/$ShareName : $usedGiB GiB used of $current GiB."
if ($target -eq $current) { Write-Output 'Quota unchanged.'; return }
if ($PSCmdlet.ShouldProcess("$StorageAccountName/$ShareName", "Set quota $current -> $target GiB")) {
    Update-AzRmStorageShare -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName -Name $ShareName -QuotaGiB $target | Out-Null
    Write-Output "Quota set to $target GiB. Set fslogix.shareQuotaGiB = $target in the parameter file so the next deployment keeps it."
}
