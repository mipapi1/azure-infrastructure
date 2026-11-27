# VLC media player for all users. $args[0] is the installer's local path.
$ErrorActionPreference = 'Stop'
$process = Start-Process -FilePath $args[0] -Wait -PassThru -ArgumentList '/L=1033', '/S'
if ($process.ExitCode -ne 0) { throw "VLC setup failed with exit code $($process.ExitCode)" }
