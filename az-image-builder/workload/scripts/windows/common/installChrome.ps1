# Google Chrome Enterprise (artifact 'chrome'). Policies: DISA Chrome STIG + stig/configureChrome.ps1.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\Installer.psm1') -Force
$msi = 'C:\Tools\GoogleChromeEnterprise.msi'
Invoke-Installer -Name 'Google Chrome' -FilePath "$Env:SystemRoot\System32\msiexec.exe" -TimeoutMinutes 20 `
    -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart', '/l*v', '"C:\Windows\Logs\Software\chrome.log"' | Out-Null
Remove-Item -LiteralPath $msi -Force

$exe = Join-Path $Env:ProgramFiles 'Google\Chrome\Application\chrome.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "Chrome not found at $exe after install" }
Remove-Item "$Env:Public\Desktop\Google Chrome.lnk" -Force -ErrorAction SilentlyContinue

# No per-user desktop shortcut on first run either (initial_preferences next to chrome.exe).
$prefFile = Join-Path (Split-Path -Parent $exe) 'initial_preferences'
$prefs = if (Test-Path -LiteralPath $prefFile) { Get-Content -LiteralPath $prefFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
if (-not $prefs.PSObject.Properties['distribution']) { $prefs | Add-Member -NotePropertyName distribution -NotePropertyValue ([pscustomobject]@{}) }
$prefs.distribution | Add-Member -NotePropertyName do_not_create_desktop_shortcut -NotePropertyValue $true -Force
[IO.File]::WriteAllText($prefFile, ($prefs | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))   # no BOM
Write-Output "Google Chrome $((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion): installed"
