<#
.SYNOPSIS
    Azure Automation runbook: grows the FSLogix profile share before it fills up.

.DESCRIPTION
    Runs on a schedule with the Automation account's system-assigned managed identity. When the
    share's usage reaches ThresholdPercent of its quota, the quota grows by GrowPercent, capped
    at MaxQuotaGiB. It never shrinks the share. Output goes to the job stream (and the
    workspace through the account's diagnostic settings).

    The deployment sets the quota from fslogix.shareQuotaGiB on every run; the job output says
    which value to put there after a grow.

    Published by Publish-FslogixAutoGrowRunbook.ps1 (Windows PowerShell 5.1 runbook type).
#>
param(
    [Parameter(Mandatory)]
    [string]$StorageAccountResourceId,

    [string]$ShareName = 'profiles',

    [int]$ThresholdPercent = 80,

    [int]$GrowPercent = 20,

    [Parameter(Mandatory)]
    [int]$MaxQuotaGiB
)

$ErrorActionPreference = 'Stop'

$segments = $StorageAccountResourceId.Split('/')
$subscriptionId = $segments[2]
$resourceGroupName = $segments[4]
$accountName = $segments[8]

Connect-AzAccount -Identity -Subscription $subscriptionId | Out-Null

$share = Get-AzRmStorageShare -ResourceGroupName $resourceGroupName -StorageAccountName $accountName -Name $ShareName -GetShareUsage
$quota = $share.QuotaGiB
$usedGiB = $share.ShareUsageBytes / 1GB
$percent = [math]::Round(100 * $usedGiB / $quota, 1)
Write-Output "$accountName/$ShareName : $([math]::Round($usedGiB, 1)) GiB of $quota GiB ($percent%)."

if ($percent -lt $ThresholdPercent) {
    Write-Output "Below $ThresholdPercent%; nothing to do."
    return
}
if ($quota -ge $MaxQuotaGiB) {
    Write-Error "Share is at $percent% and already at MaxQuotaGiB ($MaxQuotaGiB GiB). Raise the cap or reduce profile sizes."
    return
}

$target = [math]::Min($MaxQuotaGiB, [int][math]::Ceiling($quota * (1 + $GrowPercent / 100)))
Update-AzRmStorageShare -ResourceGroupName $resourceGroupName -StorageAccountName $accountName -Name $ShareName -QuotaGiB $target | Out-Null
Write-Warning "Grew $accountName/$ShareName from $quota to $target GiB. Set fslogix.shareQuotaGiB = $target in the parameter file."
