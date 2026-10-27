<#
.SYNOPSIS
    Publishes the FSLogix share auto-grow runbook and links it to the deployed schedule.

.DESCRIPTION
    The deployment (fslogix.autoGrow.enabled) creates the Automation account, its managed
    identity with Storage Account Contributor on the profile storage account, and the schedule.
    ARM can't upload runbook content from a local file, so this script imports
    runbooks/Invoke-FslogixShareAutoGrow.ps1, publishes it and registers it on the schedule with
    the share parameters. Idempotent: rerun it after changing the runbook or the parameters.

    Values come from the deployment outputs (fslogixAutoGrow).

.EXAMPLE
    $o = (Get-AzSubscriptionDeployment -Name <deployment>).Outputs.fslogixAutoGrow.Value
    ./Publish-FslogixAutoGrowRunbook.ps1 -ResourceGroupName $o.resourceGroupName.Value -AutomationAccountName $o.automationAccountName.Value `
        -ScheduleName $o.scheduleName.Value -StorageAccountResourceId $o.storageAccountResourceId.Value -MaxQuotaGiB 4096
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$AutomationAccountName,

    [Parameter(Mandatory)]
    [string]$ScheduleName,

    [Parameter(Mandatory)]
    [string]$StorageAccountResourceId,

    [string]$ShareName = 'profiles',

    [ValidateRange(50, 95)]
    [int]$ThresholdPercent = 80,

    [ValidateRange(5, 100)]
    [int]$GrowPercent = 20,

    [Parameter(Mandatory)]
    [ValidateRange(100, 102400)]
    [int]$MaxQuotaGiB
)

$ErrorActionPreference = 'Stop'
$runbookName = 'Invoke-FslogixShareAutoGrow'
$path = Join-Path $PSScriptRoot "runbooks/$runbookName.ps1"
$account = @{ ResourceGroupName = $ResourceGroupName; AutomationAccountName = $AutomationAccountName }

if ($PSCmdlet.ShouldProcess("$AutomationAccountName/$runbookName", 'Import and publish runbook')) {
    Import-AzAutomationRunbook @account -Path $path -Name $runbookName -Type PowerShell -Published -Force | Out-Null
}

$parameters = @{
    StorageAccountResourceId = $StorageAccountResourceId
    ShareName                = $ShareName
    ThresholdPercent         = $ThresholdPercent
    GrowPercent              = $GrowPercent
    MaxQuotaGiB              = $MaxQuotaGiB
}
# A runbook can be registered on a schedule once; re-registering replaces the parameters.
Get-AzAutomationScheduledRunbook @account -RunbookName $runbookName -ErrorAction SilentlyContinue |
    Where-Object ScheduleName -eq $ScheduleName |
    ForEach-Object {
        if ($PSCmdlet.ShouldProcess($ScheduleName, 'Unregister previous link')) {
            Unregister-AzAutomationScheduledRunbook @account -JobScheduleId $_.JobScheduleId -Force
        }
    }
if ($PSCmdlet.ShouldProcess($ScheduleName, "Link $runbookName")) {
    Register-AzAutomationScheduledRunbook @account -RunbookName $runbookName -ScheduleName $ScheduleName -Parameters $parameters | Out-Null
    Write-Output "$runbookName published and linked to $ScheduleName (threshold $ThresholdPercent%, grow $GrowPercent%, cap $MaxQuotaGiB GiB)."
}
