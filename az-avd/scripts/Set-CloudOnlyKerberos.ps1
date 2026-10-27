<#
.SYNOPSIS
    Finishes Entra Kerberos setup on the FSLogix storage account's Entra application.

.DESCRIPTION
    Enabling Entra Kerberos on a storage account creates an application named
    "[Storage Account] <account>.file.<storage suffix>". Microsoft documents two edits to it,
    which this script makes idempotently (existing values are kept, nothing is removed):

    1. Cloud-only groups: adds the tag kdc_enable_cloud_group_sids (preview), so Kerberos
       tickets carry cloud-only group SIDs. Mandatory when users are cloud-only identities.
       Skip with -SkipCloudGroupTag for hybrid-only tenants.
    2. Private link: for every identifier URI on <account>.file.<suffix>, adds the matching
       <account>.privatelink.file.<suffix> URI. Without it, clients that reach the share through
       a private endpoint fall back to NTLM and fail with error 1326. This applies to hybrid
       identities too. Skip with -SkipPrivateLink.

    Admin consent (openid, profile, User.Read) and the Conditional Access MFA exclusion are
    separate steps in the README; this script doesn't grant consent.

    Requires the Microsoft.Graph.Applications module and an account that can update the
    application (Cloud Application Administrator or Application Administrator, or the
    Application.ReadWrite.All scope). Run it after every deployment that creates a new
    storage account, or when Entra Kerberos is re-enabled on one.

.PARAMETER StorageAccountName
    FSLogix storage account name (the az-avd output profileStorageAccountResourceId ends with it).

.PARAMETER TenantId
    Entra tenant ID.

.PARAMETER StorageSuffix
    Storage endpoint suffix of the cloud. Defaults to core.windows.net (Azure public cloud,
    the only cloud that supports cloud-only identities on Azure Files).

.EXAMPLE
    ./Set-CloudOnlyKerberos.ps1 -StorageAccountName avdprodeusfslx7k2 -TenantId <tenant-id> -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9]{3,24}$')] [string] $StorageAccountName,
    [Parameter(Mandatory)] [guid] $TenantId,
    [string] $StorageSuffix = 'core.windows.net',
    [switch] $SkipCloudGroupTag,
    [switch] $SkipPrivateLink
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$cloudGroupTag = 'kdc_enable_cloud_group_sids'
$publicHost = "$StorageAccountName.file.$StorageSuffix"
$privateHost = "$StorageAccountName.privatelink.file.$StorageSuffix"
$displayName = "[Storage Account] $publicHost"

Import-Module Microsoft.Graph.Applications -ErrorAction Stop
if (-not (Get-MgContext)) {
    Connect-MgGraph -TenantId $TenantId -Scopes 'Application.ReadWrite.All' -NoWelcome
}

$apps = @(Get-MgApplication -Filter "displayName eq '$displayName'" -Property 'id,displayName,tags,identifierUris')
if ($apps.Count -ne 1) {
    throw "Expected one application named '$displayName', found $($apps.Count). Is Entra Kerberos enabled on the storage account?"
}
$app = $apps[0]

$tags = @($app.Tags)
$newTags = $tags
if (-not $SkipCloudGroupTag -and $cloudGroupTag -notin $tags) { $newTags = $tags + $cloudGroupTag }

$uris = @($app.IdentifierUris)
$newUris = $uris
if (-not $SkipPrivateLink) {
    $missing = $uris |
        Where-Object { $_ -like "*/$publicHost" } |
        ForEach-Object { $_.Substring(0, $_.Length - $publicHost.Length) + $privateHost } |
        Where-Object { $_ -notin $uris }
    $newUris = $uris + @($missing)
}

$changes = @{}
if ($newTags.Count -ne $tags.Count) { $changes.Tags = $newTags }
if ($newUris.Count -ne $uris.Count) { $changes.IdentifierUris = $newUris }

if (-not $changes.Count) {
    Write-Output "$displayName is already configured."
    return
}

foreach ($key in $changes.Keys) {
    $added = Compare-Object -ReferenceObject @($app.$key) -DifferenceObject @($changes[$key]) -PassThru
    Write-Output "${key}: adding $($added -join ', ')"
}
if ($PSCmdlet.ShouldProcess($displayName, "Update $($changes.Keys -join ' and ')")) {
    Update-MgApplication -ApplicationId $app.Id -BodyParameter $changes
    Write-Output "Updated $displayName. Users get the change at their next sign-in."
}
