metadata name = 'GitLab types'
metadata description = 'Parameter types for GitLab on AKS.'

@export()
@description('The cluster GitLab runs on (az-aks outputs of the tools cluster, or of the application cluster in shared mode).')
type clusterReferenceType = {
  @description('Required. az-aks output clusterResourceId.')
  clusterResourceId: string

  @description('Required. az-aks output oidcIssuerUrl.')
  oidcIssuerUrl: string

  @description('Required. az-aks output keyVaultResourceId. GitLab secrets live in this vault and reach the cluster through its External Secrets Operator.')
  keyVaultResourceId: string

  @description('Required. az-aks output registryResourceId. CI jobs push here.')
  registryResourceId: string

  @description('Required. az-aks output subnetResourceIds.')
  subnetResourceIds: object

  @description('Optional. Node subnet of the GitLab pool. Defaults to snet-aks-nodes.')
  gitlabSubnetName: string?

  @description('Optional. Node subnet of the runner pool. Defaults to snet-aks-runners.')
  runnerSubnetName: string?

  @description('Optional. Private endpoint subnet. Defaults to snet-private-endpoints.')
  privateEndpointSubnetName: string?
}

@export()
@description('Host names and the internal addresses they resolve to.')
type gitlabDnsType = {
  @description('Required. Private DNS zone for GitLab, for example git.example.internal. It must be in the hub DNS resource group and linked to the hub (az-landing-zone additionalPrivateDnsZones), so every spoke resolves it through the firewall DNS proxy.')
  zoneName: string

  @description('Optional. Web host label. Defaults to gitlab.')
  gitlabHost: string?

  @description('Optional. Container registry host label. Defaults to registry.')
  registryHost: string?

  @description('Optional. Kubernetes agent server host label. Defaults to kas.')
  kasHost: string?

  @description('Optional. Git over SSH host label. Defaults to ssh.')
  sshHost: string?

  @description('Required. Static private IP of the GitLab ingress controller load balancer, in the GitLab node subnet.')
  ingressIp: string

  @description('Required. Static private IP of the Git over SSH load balancer, in the GitLab node subnet.')
  sshIp: string
}

@export()
@description('Azure Database for PostgreSQL flexible server.')
type gitlabPostgresType = {
  @description('Optional. PostgreSQL major version. GitLab 19 needs 17 or later. Defaults to 17.')
  version: ('17' | '18')?

  @description('Optional. SKU. Defaults to Standard_D4ds_v5 (prod) or Standard_B2ms (staging).')
  skuName: string?

  @description('Optional. Tier matching the SKU. Defaults to GeneralPurpose (prod) or Burstable (staging).')
  tier: ('Burstable' | 'GeneralPurpose' | 'MemoryOptimized')?

  @description('Optional. Storage in GB. Defaults to 128.')
  storageSizeGB: int?

  @description('Optional. High availability. Defaults to ZoneRedundant (prod) or Disabled (staging).')
  highAvailability: ('Disabled' | 'SameZone' | 'ZoneRedundant')?

  @description('Optional. Backup retention days (7-35). Defaults to 35 (prod) or 7 (staging).')
  @minValue(7)
  @maxValue(35)
  backupRetentionDays: int?

  @description('Optional. Administrator login GitLab connects with. Defaults to gitlab.')
  administratorLogin: string?

  @description('Optional. Entra ID administrators of the GitLab and Keycloak servers, for people (GitLab itself uses the password login). Use a group. Defaults to none.')
  entraAdministrators: {
    @description('Required. Object ID of the group, user or service principal.')
    objectId: string

    @description('Required. Display name of the principal, used as its PostgreSQL role name.')
    principalName: string

    @description('Required. Principal type.')
    principalType: 'Group' | 'ServicePrincipal' | 'User'
  }[]?
}

@export()
@description('Azure Managed Redis.')
type gitlabRedisType = {
  @description('Optional. SKU. Defaults to Balanced_B3 (prod) or Balanced_B0 (staging).')
  skuName: (
    | 'Balanced_B0'
    | 'Balanced_B1'
    | 'Balanced_B3'
    | 'Balanced_B5'
    | 'Balanced_B10'
    | 'Balanced_B20'
    | 'Balanced_B50')?

  @description('Optional. Replicate for high availability. Defaults to Enabled (prod) or Disabled (staging).')
  highAvailability: ('Enabled' | 'Disabled')?
}

@export()
@description('Gitaly (Git repository storage). Gitaly runs in the cluster as the chart\'s StatefulSet (D-033).')
type gitalyType = {
  @description('Optional. Repository disk size in GB. Defaults to 256 (prod) or 64 (staging).')
  diskSizeGB: int?
}

@export()
@description('Network access to GitLab through the hub firewall.')
type gitlabAccessType = {
  @description('Optional. IP Groups that may reach GitLab on 443 and 22, for example the AVD session host group (az-avd output ipGroupResourceIds.sessionHosts) and the application cluster nodes (for Flux).')
  clientIpGroupResourceIds: string[]?

  @description('Optional. Address prefixes that may reach GitLab on 443 and 22, for example VPN or ExpressRoute client ranges.')
  clientAddressPrefixes: string[]?

  @description('Optional. Priority of the GitLab rule collection group in the hub firewall policy. Defaults to 1160.')
  firewallRulePriority: int?
}

@export()
@description('CI runners.')
type gitlabRunnersType = {
  @description('Optional. Registries CI jobs push to, besides the cluster registry (for example the application cluster registry). Their private endpoints are reached through the hub firewall.')
  pushRegistryResourceIds: string[]?

  @description('Optional. Private endpoint prefixes of those registries, allowed from the runner nodes on 443.')
  pushRegistryPrivateEndpointPrefixes: string[]?

  @description('Optional. Runner node IP Group (az-aks output ipGroupResourceIds["snet-aks-runners"]). Without it the runner subnet prefix is used.')
  runnerIpGroupResourceId: string?

  @description('Optional. Runner node subnet prefix, used when there is no IP Group.')
  runnerSubnetPrefix: string?
}

@export()
@description('Optional Keycloak identity broker. Off by default; see D-034 for when it is justified.')
type keycloakType = {
  @description('Optional. Deploy the Keycloak database and identity. Defaults to false.')
  enabled: bool?

  @description('Optional. Zone-redundant database and two or more Keycloak replicas. Defaults to true in prod.')
  highAvailability: bool?

  @description('Optional. Host label in the GitLab zone. Defaults to sso.')
  host: string?
}
