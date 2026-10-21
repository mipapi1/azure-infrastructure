# Python for all users, on PATH (artifact 'python'). No reboot needed: new sessions pick up PATH.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\Installer.psm1') -Force
$installer = 'C:\Tools\python.exe'
Invoke-Installer -Name 'Python' -FilePath $installer -TimeoutMinutes 15 `
    -ArgumentList '/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_test=0' | Out-Null
Remove-Item -LiteralPath $installer -Force
