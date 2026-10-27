<#
.SYNOPSIS
    Applies the platform's PIM for Groups settings to one group's membership (or ownership).

.DESCRIPTION
    Privileged Azure roles are granted to groups (eligibleRoleAssignments in governance, or
    standing role assignments to a group) and people get into the group just in time through
    PIM for Groups. This script sets the group's PIM policy rules through Microsoft Graph:

    - activation: maximum duration (-MaxActivationHours), MFA and justification required,
      optional ticket, optional approval by -ApproverGroupId members
    - assignment: eligible assignments expire after -EligibleExpirationDays (0 allows permanent),
      active assignments expire after -ActiveExpirationDays and need MFA and justification
    - notification: activation alerts to -NotificationRecipients in addition to the defaults

    Each rule is read, changed and written back (PATCH), so properties this script doesn't set
    keep their current values. Updating a group's policy onboards the group to PIM (this can't
    be undone). Idempotent; supports -WhatIf.

    Needs Microsoft.Graph.Authentication and RoleManagementPolicy.ReadWrite.AzureADGroup, and a
    Microsoft Entra ID Governance or P2 license in the tenant. Dynamic and on-premises-synced
    groups aren't supported by PIM for Groups.

.EXAMPLE
    Connect-MgGraph -Scopes RoleManagementPolicy.ReadWrite.AzureADGroup
    ./Set-PimGroupPolicy.ps1 -GroupId <platform-owners-group-id> -ApproverGroupId <approvers-group-id> -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$GroupId,

    [ValidateSet('member', 'owner')]
    [string]$AccessId = 'member',

    # PIM for Groups activations are limited to eight hours.
    [ValidateRange(1, 8)]
    [int]$MaxActivationHours = 4,

    [switch]$RequireTicket,

    # Members of this group approve activations. Empty: no approval.
    [string]$ApproverGroupId = '',

    [ValidateRange(0, 3650)]
    [int]$EligibleExpirationDays = 365,

    [ValidateRange(1, 3650)]
    [int]$ActiveExpirationDays = 15,

    [string[]]$NotificationRecipients = @()
)

$ErrorActionPreference = 'Stop'

$filter = "scopeId eq '$GroupId' and scopeType eq 'Group' and roleDefinitionId eq '$AccessId'"
$assignment = (Invoke-MgGraphRequest -Method GET -Uri "/v1.0/policies/roleManagementPolicyAssignments?`$filter=$filter").value | Select-Object -First 1
if (-not $assignment) { throw "No PIM policy found for group $GroupId ($AccessId)." }
$policyId = $assignment.policyId

function Update-Rule {
    param([string]$RuleId, [scriptblock]$Change)
    $uri = "/v1.0/policies/roleManagementPolicies/$policyId/rules/$RuleId"
    $rule = Invoke-MgGraphRequest -Method GET -Uri $uri
    $rule.Remove('@odata.context')
    & $Change $rule
    if ($PSCmdlet.ShouldProcess("$GroupId/$AccessId", "Update $RuleId")) {
        Invoke-MgGraphRequest -Method PATCH -Uri $uri -Body ($rule | ConvertTo-Json -Depth 10) -ContentType 'application/json' | Out-Null
        Write-Output "Updated $RuleId"
    }
}

Update-Rule 'Expiration_EndUser_Assignment' {
    param($r) $r.isExpirationRequired = $true; $r.maximumDuration = "PT$($MaxActivationHours)H"
}
Update-Rule 'Enablement_EndUser_Assignment' {
    param($r) $r.enabledRules = @('MultiFactorAuthentication', 'Justification') + $(if ($RequireTicket) { @('Ticketing') } else { @() })
}
Update-Rule 'Approval_EndUser_Assignment' {
    param($r)
    $approvers = if ($ApproverGroupId) { @(@{ '@odata.type' = '#microsoft.graph.groupMembers'; groupId = $ApproverGroupId }) } else { @() }
    $r.setting = @{
        isApprovalRequired               = [bool]$ApproverGroupId
        isApprovalRequiredForExtension   = $false
        isRequestorJustificationRequired = $true
        approvalMode                     = 'SingleStage'
        approvalStages                   = @(@{
                approvalStageTimeOutInDays      = 1
                isApproverJustificationRequired = $true
                escalationTimeInMinutes         = 0
                isEscalationEnabled             = $false
                primaryApprovers                = $approvers
                escalationApprovers             = @()
            })
    }
}
Update-Rule 'Expiration_Admin_Eligibility' {
    param($r)
    $r.isExpirationRequired = $EligibleExpirationDays -gt 0
    if ($EligibleExpirationDays -gt 0) { $r.maximumDuration = "P$($EligibleExpirationDays)D" }
}
Update-Rule 'Expiration_Admin_Assignment' {
    param($r) $r.isExpirationRequired = $true; $r.maximumDuration = "P$($ActiveExpirationDays)D"
}
Update-Rule 'Enablement_Admin_Assignment' {
    param($r) $r.enabledRules = @('MultiFactorAuthentication', 'Justification')
}
if ($NotificationRecipients) {
    Update-Rule 'Notification_Admin_EndUser_Assignment' {
        param($r) $r.notificationRecipients = $NotificationRecipients; $r.isDefaultRecipientsEnabled = $true; $r.notificationLevel = 'All'
    }
}
