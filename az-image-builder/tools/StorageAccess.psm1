<#
.SYNOPSIS
    Temporarily lets this machine through the image builder storage account's firewall.

.DESCRIPTION
    The storage account and its firewall belong to the landing zone. This module never changes
    them permanently. Invoke-WithStorageAccess:
      1. Reads the account's current network settings.
      2. If the firewall's default action is Deny, adds an IP rule for your public IP
         (or -IpAddress) unless one already exists.
      3. Waits until a blob list call succeeds. That covers firewall propagation and any
         just-created role assignment.
      4. Runs your script block.
      5. Always removes the IP rule(s) it added, even on failure.

    If the account's public network access is Disabled, IP rules don't apply. The script
    then only works when this machine reaches the private endpoint (e.g. over VPN).
#>

Set-StrictMode -Version Latest

function Invoke-AzQuiet {
    $output = az @args --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "az $($args[0..3] -join ' ') failed" }
    $output
}

function Invoke-WithStorageAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StorageAccountName,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string[]]$IpAddress,
        [string]$SubscriptionId,
        [string]$ProbeContainer = 'scripts'
    )

    $sub = if ($SubscriptionId) { @('--subscription', $SubscriptionId) } else { @() }

    # Fail fast on an expired sign-in; the blob probe below would otherwise retry for 4 minutes.
    $tokenError = az account get-access-token --resource https://storage.azure.com/ -o none --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI can't get a storage token. Your sign-in has probably expired. Run 'az login' and try again.`n$(($tokenError | Out-String).Trim())"
    }

    $account = Invoke-AzQuiet storage account show --name $StorageAccountName @sub -o json | ConvertFrom-Json
    $resourceGroup = $account.resourceGroup
    $rules = $account.networkRuleSet
    $existing = @($rules.ipRules | ForEach-Object { $_.ipAddressOrRange })
    $added = @()

    try {
        if ($account.publicNetworkAccess -eq 'Disabled') {
            Write-Warning "$StorageAccountName has public network access disabled. Continuing; this only works if this machine reaches the private endpoint (VPN)."
        }
        elseif ($rules.defaultAction -eq 'Deny') {
            if (-not $IpAddress) {
                # Asks a public service which address you appear as on the internet. Pass -IpAddress to skip.
                $IpAddress = @((Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 15).Trim())
            }
            foreach ($ip in $IpAddress) {
                if ($ip -in $existing) { continue }
                Write-Host "Opening $StorageAccountName firewall for $ip (temporary)"
                Invoke-AzQuiet storage account network-rule add --resource-group $resourceGroup --account-name $StorageAccountName --ip-address $ip @sub -o none | Out-Null
                $added += $ip
            }
        }

        # Firewall rules and new role assignments take a minute or two to apply.
        for ($attempt = 1; ; $attempt++) {
            $probeError = az storage blob list --auth-mode login --account-name $StorageAccountName --container-name $ProbeContainer --num-results 1 @sub -o none --only-show-errors 2>&1
            if ($LASTEXITCODE -eq 0) { break }
            if ($attempt -ge 16) {
                $signedIn = az ad signed-in-user show --query userPrincipalName -o tsv 2>$null
                throw @"
Still can't read $StorageAccountName/$ProbeContainer after ~4 minutes.
Azure says: $(($probeError | Out-String).Trim())
Signed in to Azure CLI as: $signedIn. IP opened in the firewall: $($IpAddress -join ', ')
- AuthorizationPermissionMismatch: this account lacks Storage Blob Data Contributor (container or account), or az is signed in as a different account than the portal.
- AuthorizationFailure: the firewall doesn't see that IP (VPN/proxy). Pass the real one: -AllowedIpAddresses <ip>.
- DNS/connection error: the name resolves to the private endpoint; you need a route to it (VPN), or use a network that resolves it publicly.
"@
            }
            Write-Host "Waiting for storage access to apply (attempt $attempt)..."
            Start-Sleep -Seconds 15
        }

        & $ScriptBlock
    }
    finally {
        foreach ($ip in $added) {
            Write-Host "Closing $StorageAccountName firewall for $ip"
            az storage account network-rule remove --resource-group $resourceGroup --account-name $StorageAccountName --ip-address $ip @sub -o none --only-show-errors
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Could not remove the IP rule for $ip. Remove it manually: Storage account > Networking."
            }
        }

        # This module only adds/removes IP rules; it never changes the default action or public network
        # access. Confirm nothing else did while it ran, and that no rule it added is left behind.
        $after = az storage account show --name $StorageAccountName @sub --query "{defaultAction:networkRuleSet.defaultAction, public:publicNetworkAccess, ips:networkRuleSet.ipRules[].ipAddressOrRange}" -o json --only-show-errors 2>$null | ConvertFrom-Json
        if ($after) {
            if ($after.defaultAction -ne $rules.defaultAction -or $after.public -ne $account.publicNetworkAccess) {
                Write-Warning "$StorageAccountName network settings changed while this ran: default action $($rules.defaultAction) -> $($after.defaultAction), public access $($account.publicNetworkAccess) -> $($after.public). Check Storage account > Networking."
            }
            $leftOver = @($added | Where-Object { $_ -in @($after.ips) })
            if ($leftOver) {
                Write-Warning "IP rule(s) still present on ${StorageAccountName}: $($leftOver -join ', '). Remove them: Storage account > Networking."
            }
        }
        if ($rules.defaultAction -eq 'Allow' -and $account.publicNetworkAccess -ne 'Disabled') {
            Write-Warning "$StorageAccountName is open to all networks (default action Allow). Redeploy the landing zone to restore 'Enabled from selected networks'."
        }
    }
}

Export-ModuleMember -Function Invoke-WithStorageAccess
