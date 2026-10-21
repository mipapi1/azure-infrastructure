# DISA SCAP Compliance Checker (artifact 'scc', extracted to C:\scap).
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\Installer.psm1') -Force
$setup = Get-ChildItem -Path 'C:\scap' -Recurse -Filter 'SCC_*_Windows_Setup.exe' | Select-Object -First 1
if (-not $setup) { throw "SCC setup not found under C:\scap. Add 'scap' to artifactGroups." }
Unblock-File -LiteralPath $setup.FullName
Invoke-Installer -Name 'SCC' -FilePath $setup.FullName -TimeoutMinutes 20 -SuccessCodes 0 `
    -ArgumentList '/VERYSILENT', '/SP-', '/SUPPRESSMSGBOXES', '/TYPE="Standard"', '/DIR="C:\scap"' | Out-Null
