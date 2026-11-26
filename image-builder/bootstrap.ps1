# First Image Builder step on Windows. Downloads the build scripts and installers from the image
# builder storage account with the build VM's managed identity (over the private endpoint) and checks
# each file's SHA256 against the value in the template. Any mismatch stops the build.
# Embedded in the template by main.bicep; the file list comes from the image param file and scripts.json.
param(
    # Base64 JSON: [{ "uri": "...", "sha256": "...", "path": "C:\\BuildArtifacts\\..." }]
    [Parameter(Mandatory)][string]$FilesBase64,
    [Parameter(Mandatory)][string]$ClientId
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
trap { Write-Output "Bootstrap: $_"; exit 1 }

$files = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($FilesBase64)) | ConvertFrom-Json

$tokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F&client_id=$ClientId"
$token = $null
for ($attempt = 1; -not $token; $attempt++) {
    try { $token = (Invoke-RestMethod -Uri $tokenUri -Headers @{ Metadata = 'true' } -UseBasicParsing -TimeoutSec 30).access_token }
    catch {
        if ($attempt -ge 10) { throw "No storage token for identity $ClientId : $_" }
        Start-Sleep -Seconds (5 * $attempt)
    }
}
$headers = @{ Authorization = "Bearer $token"; 'x-ms-version' = '2023-11-03' }

foreach ($file in $files) {
    New-Item -ItemType Directory -Path (Split-Path $file.path -Parent) -Force | Out-Null
    Write-Output "Bootstrap: $($file.uri)"
    Invoke-WebRequest -Uri $file.uri -Headers $headers -OutFile $file.path -UseBasicParsing
    $actual = (Get-FileHash -LiteralPath $file.path -Algorithm SHA256).Hash
    if ($actual -ne $file.sha256) { throw "SHA256 mismatch for $($file.uri): expected $($file.sha256), got $actual. Run image-builder/publish.sh." }
}
Write-Output "Bootstrap: $(@($files).Count) file(s) verified."
