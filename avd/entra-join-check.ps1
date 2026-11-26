# Fails the deployment if the session host isn't Entra joined. Runs after AADLoginForWindows and
# before the AVD agent registers the host: the extension reports success even when the join fails,
# most often because an Entra device with the same name is left over from a deleted host. Without
# this check the host registers as Unavailable (DomainJoinedCheck failed).
$ErrorActionPreference = 'Stop'
$deadline = (Get-Date).AddMinutes(5)
do {
    if ((dsregcmd /status | Out-String) -match 'AzureAdJoined\s*:\s*YES') {
        Write-Output "$Env:COMPUTERNAME is Entra joined."
        exit 0
    }
    Start-Sleep -Seconds 15
} while ((Get-Date) -lt $deadline)

$log = Get-ChildItem 'C:\WindowsAzure\Logs\Plugins\Microsoft.Azure.ActiveDirectory.AADLoginForWindows' -Recurse -Filter *.log -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime | Select-Object -Last 1
if ($log -and (Get-Content -LiteralPath $log.FullName -Tail 200 | Out-String) -match 'hostname_duplicate') {
    throw "$Env:COMPUTERNAME isn't Entra joined: an Entra device with this name already exists (from a deleted host). Set a new sessionHosts.forceNewHost in avd/main.bicepparam, delete this VM and deploy again."
}
throw "$Env:COMPUTERNAME isn't Entra joined after 5 minutes. See $($log.FullName)."
