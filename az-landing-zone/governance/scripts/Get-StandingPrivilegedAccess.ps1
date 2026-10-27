<#
.SYNOPSIS
    Inventory of standing (always-on) privileged access in Azure RBAC and Microsoft Entra roles.

.DESCRIPTION
    Lists assignments that are active without a PIM activation and without an end date:
    - Azure RBAC: Owner, Contributor, User Access Administrator, Role Based Access Control
      Administrator (and -AdditionalAzureRoles) on the management group tree under
      -ManagementGroupId and on every subscription below it, from the PIM schedule instances
      (AssignmentType 'Assigned', no end date). Activated (just-in-time) assignments are left out.
    - Microsoft Entra: active role assignment schedule instances for roles Microsoft marks as
      privileged (isPrivileged), with no end date.

    The output is the starting list for converting standing access to PIM eligibility
    (eligibleRoleAssignments in governance, Set-PimGroupPolicy.ps1 for groups). Break-glass
    accounts are expected in the list; pass their object IDs with -ExcludePrincipalIds.

    Needs Az.Resources (Reader on the tree) and Microsoft.Graph.Authentication with
    RoleManagement.Read.Directory.

.EXAMPLE
    Connect-AzAccount; Connect-MgGraph -Scopes RoleManagement.Read.Directory
    ./Get-StandingPrivilegedAccess.ps1 -ManagementGroupId alz -OutputPath standing.csv
#>
param(
    [Parameter(Mandatory)]
    [string]$ManagementGroupId,

    [string[]]$AdditionalAzureRoles = @(),

    [string[]]$ExcludePrincipalIds = @(),

    [switch]$SkipEntra,

    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$privilegedRoles = @('Owner', 'Contributor', 'User Access Administrator', 'Role Based Access Control Administrator') + $AdditionalAzureRoles
$rows = [System.Collections.Generic.List[object]]::new()

# Management groups and subscriptions under the root, depth first.
function Get-Scopes {
    param([string]$GroupId)
    $group = Get-AzManagementGroup -GroupId $GroupId -Expand
    "/providers/Microsoft.Management/managementGroups/$GroupId"
    foreach ($child in @($group.Children)) {
        if ($child.Type -eq '/subscriptions') { "/subscriptions/$($child.Name)" }
        elseif ($child.Type -like '*managementGroups') { Get-Scopes -GroupId $child.Name }
    }
}

foreach ($scope in Get-Scopes -GroupId $ManagementGroupId) {
    foreach ($instance in @(Get-AzRoleAssignmentScheduleInstance -Scope $scope)) {
        # Instances inherited from a parent scope are reported at the parent.
        if ($instance.Scope -ne $scope) { continue }
        if ($instance.RoleDefinitionDisplayName -notin $privilegedRoles) { continue }
        if ($instance.AssignmentType -ne 'Assigned' -or $instance.EndDateTime) { continue }
        if ($instance.PrincipalId -in $ExcludePrincipalIds) { continue }
        $rows.Add([pscustomobject]@{
                Plane         = 'Azure'
                Scope         = $scope
                Role          = $instance.RoleDefinitionDisplayName
                PrincipalId   = $instance.PrincipalId
                PrincipalName = $instance.PrincipalDisplayName
                PrincipalType = $instance.PrincipalType
                MemberType    = $instance.MemberType
            })
    }
}

if (-not $SkipEntra) {
    $uri = "/v1.0/roleManagement/directory/roleAssignmentScheduleInstances?`$expand=roleDefinition,principal&`$filter=assignmentType eq 'Assigned'"
    while ($uri) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $uri
        foreach ($instance in $page.value) {
            if (-not $instance.roleDefinition.isPrivileged -or $instance.endDateTime) { continue }
            if ($instance.principalId -in $ExcludePrincipalIds) { continue }
            $rows.Add([pscustomobject]@{
                    Plane         = 'Entra'
                    Scope         = $instance.directoryScopeId
                    Role          = $instance.roleDefinition.displayName
                    PrincipalId   = $instance.principalId
                    PrincipalName = $instance.principal.displayName
                    PrincipalType = ($instance.principal.'@odata.type' -replace '#microsoft.graph.', '')
                    MemberType    = $instance.memberType
                })
        }
        $uri = $page.'@odata.nextLink'
    }
}

if ($OutputPath) {
    $rows | Export-Csv -LiteralPath $OutputPath -NoTypeInformation
    Write-Output "$($rows.Count) standing privileged assignments written to $OutputPath."
}
else { $rows }
