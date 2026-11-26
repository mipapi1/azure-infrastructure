# Visual Studio Code for all users. Example app: copy this file for another app, then add it to
# windowsApps in main.bicepparam with its installer. $args[0] is the installer's local path.
$ErrorActionPreference = 'Stop'
$process = Start-Process -FilePath $args[0] -Wait -PassThru -ArgumentList '/VERYSILENT', '/NORESTART', '/MERGETASKS=!runcode'
if ($process.ExitCode -ne 0) { throw "VS Code setup failed with exit code $($process.ExitCode)" }
