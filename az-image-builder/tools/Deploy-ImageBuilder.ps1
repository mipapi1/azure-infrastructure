<#
.SYNOPSIS
    Deploys the image builder landing zone, or creates image templates on it. Builds are started separately.

.DESCRIPTION
    -LandingZone: registers the resource providers Image Builder needs, deploys landing-zone/main.bicep with
    -ParamFile and writes its landingZone output to workload/params/landing-zone.json (or -LandingZoneFile),
    which the image param files load.

    Otherwise (workload):
      1. Publishes workload/scripts to the landing zone storage account under a content-hash version
         (skipped when unchanged; -SkipPublish skips it always) and writes workload/scripts.manifest.json.
      2. Deploys workload/main.bicep with -ParamFile: one new image template per image, <name>-<timestamp>.
      3. Prints the command to start each build.
    It does not start builds, wait for them, or delete old templates.

    Requires PowerShell 7+ and Azure CLI, signed in with 'az login'.

.EXAMPLE
    ./tools/Deploy-ImageBuilder.ps1 -LandingZone -ParamFile landing-zone/params/landing-zone.bicepparam
.EXAMPLE
    ./tools/Deploy-ImageBuilder.ps1 -ParamFile workload/params/win11-avd.bicepparam
.EXAMPLE
    ./tools/Deploy-ImageBuilder.ps1 -ParamFile workload/params/ws2022.bicepparam -SkipPublish
#>
[CmdletBinding()]
param(
    # .bicepparam file, relative to az-image-builder/ or absolute.
    [Parameter(Mandatory)]
    [string]$ParamFile,

    # Deploy the landing zone instead of image templates.
    [switch]$LandingZone,

    # Where -LandingZone writes the landingZone output, relative to az-image-builder/.
    [string]$LandingZoneFile = 'workload/params/landing-zone.json',

    # Default: the current az account.
    [string]$SubscriptionId,

    # Don't upload scripts (unchanged scripts are skipped automatically anyway).
    [switch]$SkipPublish,

    # Public IP(s) to allow through the storage firewall while publishing. Default: your current IP.
    [string[]]$AllowedIpAddresses
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
if (-not [IO.Path]::IsPathRooted($ParamFile)) { $ParamFile = Join-Path $root $ParamFile }
if (-not (Test-Path -LiteralPath $ParamFile)) { throw "$ParamFile not found." }
$publish = Join-Path $PSScriptRoot 'Publish-ImageBuilderContent.ps1'

function Invoke-AzJson {
    $output = az @args -o json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "az $($args[0..2] -join ' ') failed" }
    if ($output) { $output | ConvertFrom-Json }
}

# Resolved parameter values of a .bicepparam file.
function Get-BicepParams([string]$Path) {
    $out = Join-Path ([IO.Path]::GetTempPath()) "$([guid]::NewGuid().ToString('n')).json"
    try {
        az bicep build-params --file $Path --outfile $out --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "az bicep build-params $Path failed" }
        (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).parameters
    }
    finally { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
}

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) { throw "az account set failed. Run 'az login' first." }
}
$account = Invoke-AzJson account show
Write-Host "Subscription: $($account.name) ($($account.id))"

if ($LandingZone) {
    $params = Get-BicepParams $ParamFile
    $location = $params.location.value

    foreach ($provider in 'Microsoft.VirtualMachineImages', 'Microsoft.ContainerInstance', 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.ManagedIdentity') {
        $state = az provider show --namespace $provider --query registrationState -o tsv --only-show-errors
        if ($state -ne 'Registered') {
            Write-Host "Registering $provider"
            az provider register --namespace $provider --wait --only-show-errors
            if ($LASTEXITCODE -ne 0) { throw "az provider register $provider failed" }
        }
    }

    Write-Host "Deploying landing zone ($location)"
    $outputs = (Invoke-AzJson deployment sub create --name "aib-landing-zone-$($params.resourceGroupConfig.value.name)" --location $location `
            --template-file (Join-Path $root 'landing-zone' 'main.bicep') --parameters $ParamFile).properties.outputs
    if (-not [IO.Path]::IsPathRooted($LandingZoneFile)) { $LandingZoneFile = Join-Path $root $LandingZoneFile }
    $outputs.landingZone.value | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $LandingZoneFile -Encoding utf8NoBOM
    Write-Host "`nLanding zone deployed. Wrote $LandingZoneFile (loaded by the image param files)."
    return
}

# 1. Scripts. The manifest must exist before the param file can be resolved.
& $publish -ManifestOnly | Out-Null
$params = Get-BicepParams $ParamFile
$lz = $params.landingZone.value
$storageSubscription = if ($lz.PSObject.Properties['subscriptionId'] -and $lz.subscriptionId) { $lz.subscriptionId } else { $account.id }

if ($SkipPublish) {
    Write-Host '[1/2] Publishing scripts: skipped (-SkipPublish).'
}
else {
    Write-Host "[1/2] Publishing scripts to $($lz.storageAccountName) (skipped automatically if unchanged)"
    & $publish -StorageAccountName $lz.storageAccountName -SubscriptionId $storageSubscription -AllowedIpAddresses $AllowedIpAddresses
}

# 2. Templates
$baseTime = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
$names = @($params.images.value | ForEach-Object { $_.name })
Write-Host "`n[2/2] Creating image template(s): $($names -join ', ')"
$outputs = (Invoke-AzJson deployment sub create --name "aib-templates-$baseTime" --location $lz.location `
        --template-file (Join-Path $root 'workload' 'main.bicep') --parameters $ParamFile `
        --parameters "baseTime=$baseTime").properties.outputs

$resourceGroup = $outputs.resourceGroupName.value
Write-Host "`nCreated (scripts version $($outputs.scriptsVersion.value)). Start a build with:"
foreach ($name in @($outputs.imageTemplateNames.value)) {
    Write-Host "  az image builder run -g $resourceGroup -n $name --no-wait"
}
Write-Host "Or in the portal: $resourceGroup > Image Templates > <template> > Start build."
