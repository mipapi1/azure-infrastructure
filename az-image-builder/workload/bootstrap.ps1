# Image Builder bootstrap (first customizer). Embedded in the template by main.bicep, so the expected
# SHA256 of every script comes from the template. Downloads the scripts to C:\ImageBuilder with the build VM's
# managed identity and verifies each hash.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$files = '__FILES_JSON__' | ConvertFrom-Json
$baseUri = "__SCRIPTS_BASE_URI__"
$clientId = "__CLIENT_ID__"
$root = "C:\ImageBuilder"

foreach ($dir in @($root, "C:\Temp", "C:\Tools", "C:\Windows\Logs\Software")) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$tokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F&client_id=$clientId"
$token = $null
for ($attempt = 1; -not $token; $attempt++) {
    try {
        $token = (Invoke-RestMethod -Uri $tokenUri -Headers @{ Metadata = "true" } -UseBasicParsing -TimeoutSec 30).access_token
    }
    catch {
        if ($attempt -ge 10) { throw "Could not get a storage token from IMDS for $clientId : $_" }
        Write-Warning "IMDS token attempt $attempt failed: $($_.Exception.Message)"
        Start-Sleep -Seconds (5 * $attempt)
    }
}
$headers = @{ Authorization = "Bearer $token"; "x-ms-version" = "2023-11-03" }

foreach ($file in $files.PSObject.Properties) {
    $destination = Join-Path $root ($file.Name -replace "/", "\")
    New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
    Write-Output "Fetching $($file.Name)"
    Invoke-WebRequest -Uri "$baseUri/$($file.Name)" -Headers $headers -OutFile $destination -UseBasicParsing
    $actual = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    if ($actual -ne $file.Value) {
        throw "SHA256 mismatch for $($file.Name): expected $($file.Value), got $actual. Re-run Publish-ImageBuilderContent.ps1 and redeploy."
    }
}
Write-Output "Bootstrap complete: $(@($files.PSObject.Properties).Count) file(s) verified."
