<#
.SYNOPSIS
    Run Command: applies the deferred STIG settings baked into az-image-builder images.

.DESCRIPTION
    Calls C:\ProgramData\STIG\Apply-DeferredStigs.ps1 -Phase Deploy, which renames the built-in
    administrator, denies it network logon and (by default) disables every local administrator.
    Fails when the image has no deferred STIG package, so a marketplace image isn't reported as
    hardened. The script writes its own log to C:\ProgramData\STIG.

.PARAMETER DisableLocalAdministrators
    'true' (default) disables every enabled local administrator (V-253432). A Windows LAPS
    break-glass account is configured after this script and re-enabled by LAPS.
#>
param(
    [string]$DisableLocalAdministrators = 'True'
)

$ErrorActionPreference = 'Stop'

$script = Join-Path $Env:ProgramData 'STIG\Apply-DeferredStigs.ps1'
if (-not (Test-Path -LiteralPath $script)) {
    throw "$script not found. applyDeferredStigs needs an az-image-builder image with the STIG package; set it to false for other images."
}

$disable = [bool]::Parse($DisableLocalAdministrators)
& $script -Phase Deploy -DisableLocalAdministrators $disable
exit $LASTEXITCODE
