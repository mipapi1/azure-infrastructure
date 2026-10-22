metadata name = 'Naming convention'
metadata description = 'Shared naming helpers. Names follow <workload>-<environment>-<region>-<abbreviation>, with compact variants for resources that do not allow hyphens.'

@export()
@description('Short region codes used in resource names. Add a region here before deploying to it.')
var regionShortNames = {
  australiaeast: 'aue'
  brazilsouth: 'brs'
  canadacentral: 'cac'
  centralindia: 'inc'
  centralus: 'cus'
  eastus: 'eus'
  eastus2: 'eus2'
  francecentral: 'frc'
  germanywestcentral: 'gwc'
  japaneast: 'jpe'
  northcentralus: 'ncus'
  northeurope: 'neu'
  southcentralus: 'scus'
  southeastasia: 'sea'
  swedencentral: 'sec'
  switzerlandnorth: 'chn'
  uksouth: 'uks'
  ukwest: 'ukw'
  westeurope: 'weu'
  westus: 'wus'
  westus2: 'wus2'
  westus3: 'wus3'
  usgovvirginia: 'usgva'
  usgovarizona: 'usgaz'
  usgovtexas: 'usgtx'
}

@export()
@description('Resource abbreviations, based on the Cloud Adoption Framework list.')
var abbreviations = {
  actionGroup: 'ag'
  aksCluster: 'aks'
  ampls: 'ampls'
  applicationGroup: 'vdag'
  azureMonitorWorkspace: 'amw'
  bastion: 'bas'
  budget: 'budget'
  containerRegistry: 'cr'
  dataCollectionEndpoint: 'dce'
  dataCollectionRule: 'dcr'
  ddosPlan: 'ddos'
  diskEncryptionSet: 'des'
  firewall: 'afw'
  firewallPolicy: 'afwp'
  grafana: 'amg'
  hostPool: 'vdpool'
  keyVault: 'kv'
  logAnalytics: 'law'
  managedIdentity: 'uami'
  networkSecurityGroup: 'nsg'
  privateEndpoint: 'pe'
  publicIp: 'pip'
  resourceGroup: 'rg'
  routeTable: 'rt'
  scalingPlan: 'vdscaling'
  storageAccount: 'st'
  virtualMachine: 'vm'
  virtualNetwork: 'vnet'
  virtualNetworkGateway: 'vgw'
  workspace: 'vdws'
}

@export()
@description('Builds a hyphenated name: <workload>-<environment>-<region>-<abbreviation>.')
func resourceName(workload string, environment string, location string, abbreviation string) string =>
  '${workload}-${environment}-${regionShortNames[location]}-${abbreviation}'

@export()
@description('Builds a compact, lower-case name with no separators (storage accounts, registries). The suffix keeps globally unique names stable per scope.')
func compactName(
  workload string,
  environment string,
  location string,
  abbreviation string,
  uniqueSuffix string,
  maxLength int
) string =>
  take(
    toLower(replace('${workload}${environment}${regionShortNames[location]}${abbreviation}${uniqueSuffix}', '-', '')),
    maxLength
  )
