# Git for Windows (C:\Tools\git.exe, artifact 'git'). No reboot needed.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\Installer.psm1') -Force
$installer = 'C:\Tools\git.exe'
Invoke-Installer -Name 'Git' -FilePath $installer -TimeoutMinutes 15 -SuccessCodes 0 `
    -ArgumentList '/VERYSILENT', '/NORESTART', '/ALLUSERS', '/SUPPRESSMSGBOXES', '/LOG="C:\Windows\Logs\Software\git.log"' | Out-Null
Remove-Item -LiteralPath $installer -Force
