<#
.SYNOPSIS
    Removes OneDrive and the Internet Explorer capability (both no-ops where not present).
#>
$ErrorActionPreference = 'Stop'

Write-Output 'Optimize: remove legacy Internet Explorer capability'
# Edge IE mode needs this capability; configureEdge.ps1 -IE11 adds it back.
Get-WindowsCapability -Online -Name '*Browser.InternetExplorer*' |
    Where-Object State -eq 'Installed' |
    Remove-WindowsCapability -Online | Out-Null

Write-Output 'Optimize: uninstall OneDrive'
foreach ($setup in @("$Env:SystemRoot\System32\OneDriveSetup.exe", "$Env:SystemRoot\SysWOW64\OneDriveSetup.exe")) {
    if (Test-Path -LiteralPath $setup) {
        $proc = Start-Process -FilePath $setup -ArgumentList '/uninstall' -Wait -PassThru
        Write-Output "  $setup /uninstall exit code $($proc.ExitCode)"
    }
}

# Remove the per-user installer trigger and leftover shortcuts from known locations only.
& reg.exe load HKU\DefaultUser "$Env:SystemDrive\Users\Default\NTUSER.DAT" | Out-Null
try {
    & reg.exe delete 'HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Run' /v OneDriveSetup /f 2>$null | Out-Null
}
finally {
    [GC]::Collect()
    & reg.exe unload HKU\DefaultUser | Out-Null
}
Remove-Item -Force -ErrorAction SilentlyContinue -Path @(
    "$Env:ProgramData\Microsoft\Windows\Start Menu\Programs\OneDrive.lnk"
    "$Env:SystemDrive\Users\Default\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\OneDrive.lnk"
)

Write-Output 'Optimize: Script Complete'
