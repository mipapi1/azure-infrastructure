#########
#SYSPREP#
#########
function Sysprep-VM {
    Write-Output '>>> Waiting for GA Service (RdAgent) to start ...'
    while ((Get-Service RdAgent).Status -ne 'Running') {
        Start-Sleep -s 5
    }

    # Safely handle WindowsAzureTelemetryService (it may not exist)
    try {
        $waTelemetryService = Get-Service -Name 'WindowsAzureTelemetryService' -ErrorAction Stop
        Write-Output '>>> Waiting for GA Service (WindowsAzureTelemetryService) to start ...'
        while ($waTelemetryService.Status -ne 'Running') {
            Start-Sleep -s 5
            $waTelemetryService.Refresh()
        }
    } catch {
        Write-Output '>>> WindowsAzureTelemetryService not found. Skipping ...'
    }

    Write-Output '>>> Waiting for GA Service (WindowsAzureGuestAgent) to start ...'
    while ((Get-Service WindowsAzureGuestAgent).Status -ne 'Running') {
        Start-Sleep -s 5
    }

    # Remove unattend.xml if it exists (common cleanup before Sysprep)
    if (Test-Path "$Env:SystemRoot\System32\Sysprep\unattend.xml") {
        Write-Output '>>> Removing Sysprep\unattend.xml ...'
        Remove-Item "$Env:SystemRoot\System32\Sysprep\unattend.xml" -Force
    }

    if (Test-Path "$Env:SystemRoot\Panther\unattend.xml") {
        Write-Output '>>> Removing Panther\unattend.xml ...'
        Remove-Item "$Env:SystemRoot\Panther\unattend.xml" -Force
    }

    Write-Output '>>> Sysprepping VM ...'
    & "$Env:SystemRoot\System32\Sysprep\Sysprep.exe" /oobe /generalize /quit /mode:vm

    # Wait until Sysprep completes
    while ($true) {
        $imageState = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState
        Write-Output $imageState
        if ($imageState -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { break }
        Start-Sleep -s 5
    }

    Write-Output '>>> Sysprep complete ...'
}

# Last build step: apply the STIG settings withheld during the build (Packer no longer needs WinRM),
# remove the build scripts, then sysprep. Per-VM account steps run at deploy time.
$deferred = "$Env:ProgramData\STIG\Apply-DeferredStigs.ps1"
if (Test-Path -LiteralPath $deferred) {
    & $deferred -Phase Build
    if ($LASTEXITCODE -ne 0) {
        throw "Apply-DeferredStigs.ps1 -Phase Build failed with exit code $LASTEXITCODE. Not sysprepping."
    }
}
Remove-Item -LiteralPath 'C:\ImageBuilder' -Recurse -Force -ErrorAction SilentlyContinue

# Now run Sysprep
Sysprep-VM
