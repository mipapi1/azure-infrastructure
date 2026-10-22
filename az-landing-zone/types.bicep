metadata name = 'Landing zone types'
metadata description = 'Parameter types for the connectivity and management landing zone.'

@export()
@description('Hub virtual network layout.')
type hubNetworkType = {
  @description('Required. Address space of the hub virtual network, for example 10.0.0.0/22.')
  addressPrefix: string

  @description('Required. AzureFirewallSubnet prefix (/26 minimum).')
  firewallSubnetPrefix: string

  @description('Optional. AzureFirewallManagementSubnet prefix (/26). Only needed for forced tunnelling.')
  firewallManagementSubnetPrefix: string?

  @description('Required. AzureBastionSubnet prefix (/26 minimum).')
  bastionSubnetPrefix: string

  @description('Required. GatewaySubnet prefix (/27 minimum). Created even when no gateway is deployed so one can be added later.')
  gatewaySubnetPrefix: string

  @description('Required. Subnet for private endpoints of shared platform services (Key Vault, AMPLS).')
  privateEndpointSubnetPrefix: string

  @description('Optional. Address ranges allowed as sources in the default firewall rules. Defaults to the RFC 1918 ranges.')
  internalAddressRanges: string[]?
}

@export()
@description('Azure Firewall settings.')
type firewallType = {
  @description('Optional. SKU tier. Defaults to Premium in prod and Standard in staging.')
  tier: ('Basic' | 'Standard' | 'Premium')?

  @description('Optional. Threat intelligence mode. Defaults to Deny.')
  threatIntelMode: ('Alert' | 'Deny' | 'Off')?

  @description('Optional. Intrusion detection mode (Premium only). Defaults to Deny in prod and Alert in staging.')
  intrusionDetectionMode: ('Alert' | 'Deny' | 'Off')?

  @description('Optional. Availability zones. Defaults to 1, 2, 3 in prod and none in staging.')
  availabilityZones: int[]?

  @description('Optional. Enable DNS proxy so spokes can use the firewall as their DNS server. Defaults to true.')
  dnsProxyEnabled: bool?
}

@export()
@description('Optional hybrid connectivity gateway.')
type gatewayType = {
  @description('Required. Gateway type. None skips the deployment.')
  type: 'None' | 'Vpn' | 'ExpressRoute'

  @description('Optional. Gateway SKU. Defaults to VpnGw1AZ or ErGw1AZ.')
  skuName: (
    | 'VpnGw1AZ'
    | 'VpnGw2AZ'
    | 'VpnGw3AZ'
    | 'VpnGw4AZ'
    | 'VpnGw5AZ'
    | 'ErGw1AZ'
    | 'ErGw2AZ'
    | 'ErGw3AZ'
    | 'ErGwScale')?

  @description('Optional. Active-active (VPN only). Defaults to true in prod.')
  activeActive: bool?
}

@export()
@description('Central monitoring settings.')
type monitoringType = {
  @description('Optional. Data retention in days. Defaults to 365 in prod and 30 in staging.')
  retentionInDays: int?

  @description('Optional. Daily ingestion cap in GB, -1 for none. Defaults to none in prod and 5 GB in staging.')
  dailyQuotaGb: string?

  @description('Optional. Onboard the workspace to Microsoft Sentinel. Defaults to false.')
  enableSentinel: bool?

  @description('Optional. Region to replicate the workspace to. Defaults to none. Recommended for prod.')
  replicationLocation: string?

  @description('Optional. Public network access for ingestion. Defaults to Disabled (AMPLS only).')
  publicNetworkAccessForIngestion: ('Enabled' | 'Disabled')?

  @description('Optional. Public network access for queries. Defaults to Enabled so the portal works from outside the network; set Disabled for private-only.')
  publicNetworkAccessForQuery: ('Enabled' | 'Disabled')?

  @description('Optional. AMPLS ingestion access mode. Defaults to PrivateOnly.')
  amplsIngestionAccessMode: ('Open' | 'PrivateOnly')?

  @description('Optional. AMPLS query access mode. Defaults to Open.')
  amplsQueryAccessMode: ('Open' | 'PrivateOnly')?

  @description('Optional. Email addresses for the platform action group.')
  alertEmails: string[]?
}

@export()
@description('Monthly subscription budget.')
type budgetType = {
  @description('Required. Monthly amount in the billing currency.')
  amount: int

  @description('Required. Email addresses notified when a threshold is crossed.')
  contactEmails: string[]

  @description('Optional. Percent thresholds. Defaults to 50, 80, 100 and 120 (forecast).')
  thresholds: int[]?

  @description('Optional. First day of the budget period (yyyy-MM-01). Defaults to the first day of the deployment month.')
  startDate: string?
}

@export()
@description('Microsoft Defender for Cloud settings.')
type defenderType = {
  @description('Optional. Plans to enable on the Standard tier. Defaults to CloudPosture, VirtualMachines (P2), StorageAccounts, KeyVaults, Arm, Containers and Dns in prod, and CloudPosture only in staging.')
  plans: string[]?

  @description('Optional. Security contact email.')
  securityContactEmail: string?
}

@export()
@description('Platform Key Vault for keys and secrets shared across workloads (CMK, certificates).')
type keyVaultType = {
  @description('Optional. Deploy the vault. Defaults to true.')
  enabled: bool?

  @description('Optional. Vault SKU. Defaults to premium in prod (HSM-backed keys) and standard in staging.')
  sku: ('standard' | 'premium')?
}
