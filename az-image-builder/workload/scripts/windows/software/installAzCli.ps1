# Azure CLI (artifact 'azure-cli') + kubelogin (artifact 'kubelogin') + kubectl (artifact 'kubectl').
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\Installer.psm1') -Force
$msi = 'C:\Tools\AzureCLI.msi'
Invoke-Installer -Name 'Azure CLI' -FilePath "$Env:SystemRoot\System32\msiexec.exe" -TimeoutMinutes 20 `
    -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart', '/l*v', '"C:\Windows\Logs\Software\azure-cli.log"' | Out-Null
Remove-Item -LiteralPath $msi -Force

Write-Output 'kubelogin: installing to System32'
$zip = 'C:\Tools\AzureKubeLogin.zip'
$extract = 'C:\Tools\AzureKubeLogin'
Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
Copy-Item -LiteralPath "$extract\bin\windows_amd64\kubelogin.exe" -Destination "$Env:SystemRoot\System32\kubelogin.exe" -Force
Remove-Item -LiteralPath $extract -Recurse -Force
Remove-Item -LiteralPath $zip -Force

Write-Output 'kubectl: installing to System32'
Move-Item -LiteralPath 'C:\Tools\kubectl.exe' -Destination "$Env:SystemRoot\System32\kubectl.exe" -Force
Write-Output "kubectl: $(& "$Env:SystemRoot\System32\kubectl.exe" version --client=true 2>&1 | Select-Object -First 1)"
Write-Output 'Azure CLI + kubelogin + kubectl: installed'
