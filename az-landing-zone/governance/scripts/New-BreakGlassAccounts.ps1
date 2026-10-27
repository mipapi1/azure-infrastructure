<#
.SYNOPSIS
    Creates the two emergency access (break-glass) accounts and gives them Global Administrator.

.DESCRIPTION
    Microsoft recommends two or more cloud-only emergency access accounts on the tenant's
    *.onmicrosoft.com domain, permanently active Global Administrator, a passwordless
    phishing-resistant method (passkey/FIDO2) different from normal admin accounts, exclusion
    from Conditional Access policies that block or restrict sign-in, alerts on every sign-in,
    and a validation drill at least every 90 days. This script:

    1. creates <Prefix>01 and <Prefix>02 on the initial onmicrosoft.com domain (no license,
       no mailbox, password never expires),
    2. assigns Global Administrator as a permanent active assignment (the one intended
       exception to the no-standing-access rule),
    3. optionally adds both to -ExclusionGroupId (the group your Conditional Access policies
       exclude for emergency access),
    4. sets a random password that is never shown or stored, and prints a one-time Temporary
       Access Pass (60 minutes) per new account. Use it on a privileged access workstation to
       register a FIDO2 security key (passkey) for the account, then store the keys in separate
       secure locations. The Temporary Access Pass method must be enabled in the
       authentication methods policy.

    The object IDs it prints go into the landing zone parameter breakGlassAccountObjectIds,
    which deploys the sign-in and change alerts. Idempotent: existing accounts are left alone
    and only missing role assignments or group memberships are added (no new password).

    Needs Microsoft.Graph.Authentication with User.ReadWrite.All,
    RoleManagement.ReadWrite.Directory, GroupMember.ReadWrite.All and
    UserAuthenticationMethod.ReadWrite.All, run by a Privileged Role
    Administrator or Global Administrator.

.EXAMPLE
    Connect-MgGraph -Scopes User.ReadWrite.All, RoleManagement.ReadWrite.Directory, GroupMember.ReadWrite.All, UserAuthenticationMethod.ReadWrite.All
    ./New-BreakGlassAccounts.ps1 -ExclusionGroupId <ca-emergency-exclusion-group-id> -WhatIf
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[a-z][a-z0-9-]{2,30}$')]
    [string]$Prefix = 'breakglass',

    [string]$ExclusionGroupId = ''
)

$ErrorActionPreference = 'Stop'
$globalAdministrator = '62e90394-69f5-4237-9190-012177145e10'

$domain = ((Invoke-MgGraphRequest -Method GET -Uri '/v1.0/domains').value | Where-Object isInitial).id
if (-not $domain) { throw 'Initial onmicrosoft.com domain not found.' }

function New-Password {
    $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!#%*+-=?@^_'
    $bytes = [byte[]]::new(64)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

foreach ($n in 1..2) {
    $upn = "$Prefix$('{0:d2}' -f $n)@$domain"
    $user = (Invoke-MgGraphRequest -Method GET -Uri "/v1.0/users?`$filter=userPrincipalName eq '$upn'&`$select=id,userPrincipalName").value | Select-Object -First 1

    if (-not $user) {
        if ($PSCmdlet.ShouldProcess($upn, 'Create emergency access account')) {
            $password = New-Password
            $user = Invoke-MgGraphRequest -Method POST -Uri '/v1.0/users' -ContentType 'application/json' -Body (@{
                    accountEnabled    = $true
                    displayName       = "Emergency access $('{0:d2}' -f $n)"
                    mailNickname      = "$Prefix$('{0:d2}' -f $n)"
                    userPrincipalName = $upn
                    usageLocation     = 'US'
                    passwordPolicies  = 'DisablePasswordExpiration'
                    passwordProfile   = @{ password = $password; forceChangePasswordNextSignIn = $false }
                } | ConvertTo-Json)
            Remove-Variable password
            # Bootstrap credential for passkey registration only; the password is never used.
            $tap = Invoke-MgGraphRequest -Method POST -Uri "/v1.0/users/$($user.id)/authentication/temporaryAccessPassMethods" -ContentType 'application/json' -Body (@{
                    lifetimeInMinutes = 60
                    isUsableOnce      = $true
                } | ConvertTo-Json)
            Write-Host "Created $upn ($($user.id)). Temporary Access Pass (one use, 60 minutes), shown once:" -ForegroundColor Yellow
            Write-Host $tap.temporaryAccessPass
            Remove-Variable tap
        }
    }
    else { Write-Output "$upn exists ($($user.id))." }
    if (-not $user) { continue }

    $existing = (Invoke-MgGraphRequest -Method GET -Uri "/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$($user.id)' and roleDefinitionId eq '$globalAdministrator'").value
    if (-not $existing -and $PSCmdlet.ShouldProcess($upn, 'Assign Global Administrator (permanent)')) {
        Invoke-MgGraphRequest -Method POST -Uri '/v1.0/roleManagement/directory/roleAssignments' -ContentType 'application/json' -Body (@{
                principalId      = $user.id
                roleDefinitionId = $globalAdministrator
                directoryScopeId = '/'
            } | ConvertTo-Json) | Out-Null
        Write-Output "Assigned Global Administrator to $upn."
    }

    if ($ExclusionGroupId) {
        $isMember = (Invoke-MgGraphRequest -Method POST -Uri "/v1.0/directoryObjects/$($user.id)/checkMemberGroups" -ContentType 'application/json' -Body (@{ groupIds = @($ExclusionGroupId) } | ConvertTo-Json)).value
        if (-not $isMember -and $PSCmdlet.ShouldProcess($upn, "Add to $ExclusionGroupId")) {
            Invoke-MgGraphRequest -Method POST -Uri "/v1.0/groups/$ExclusionGroupId/members/`$ref" -ContentType 'application/json' -Body (@{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($user.id)" } | ConvertTo-Json) | Out-Null
            Write-Output "Added $upn to the exclusion group."
        }
    }
    Write-Output "breakGlassAccountObjectIds entry: $($user.id)"
}
