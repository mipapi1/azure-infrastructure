metadata name = 'AKS types'
metadata description = 'Parameter types for the AKS workload.'

import { securityRuleType } from '../modules/shared/types.bicep'

@export()
@description('An extra node subnet, for pools that need their own firewall source (IP Group) and egress allowlist.')
type nodeSubnetType = {
  @description('Required. Subnet name, referenced by nodePoolType.subnetName.')
  name: string

  @description('Required. Subnet prefix.')
  addressPrefix: string

  @description('Optional. FQDNs nodes in this subnet may reach over HTTPS, instead of the cluster-wide allowedEgressFqdns. Defaults to none: only the AKS requirements.')
  allowedEgressFqdns: string[]?
}

@export()
@description('A subnet for virtual machines that belong to the cluster workload.')
type vmSubnetType = {
  @description('Required. Subnet name.')
  name: string

  @description('Required. Subnet prefix.')
  addressPrefix: string

  @description('Optional. NSG rules for the subnet.')
  securityRules: securityRuleType[]?
}

@export()
@description('Spoke network for AKS.')
type aksNetworkType = {
  @description('Required. Spoke address space.')
  addressPrefixes: string[]

  @description('Required. Node subnet prefix. With CNI Overlay only nodes take VNet addresses, so a /24 holds about 250 nodes.')
  nodeSubnetPrefix: string

  @description('Required. Private endpoint subnet prefix (registry, key vault, monitor workspace, Grafana).')
  privateEndpointSubnetPrefix: string

  @description('Optional. Extra NSG rules on the private endpoint subnet, for example to keep CI nodes away from a database endpoint. The defaults allow HTTPS from the VNet.')
  privateEndpointSecurityRules: securityRuleType[]?

  @description('Optional. Extra node subnets, each with its own egress allowlist (and IP Group with useFirewallIpGroups).')
  additionalNodeSubnets: nodeSubnetType[]?

  @description('Optional. Subnets for virtual machines in the spoke. Outbound goes through the hub firewall.')
  vmSubnets: vmSubnetType[]?

  @description('Optional. Pod CIDR for CNI Overlay. Must not overlap any routed network. Defaults to 192.168.0.0/16.')
  podCidr: string?

  @description('Optional. Service CIDR. Must not overlap any routed network. Defaults to 172.16.0.0/16.')
  serviceCidr: string?

  @description('Optional. Cluster DNS service IP inside serviceCidr. Defaults to 172.16.0.10.')
  dnsServiceIP: string?
}

@export()
@description('Node pool.')
type nodePoolType = {
  @description('Required. Pool name, 1-12 lowercase alphanumeric characters (Linux).')
  name: string

  @description('Required. VM size.')
  vmSize: string

  @description('Optional. Minimum nodes (autoscaler). Defaults to 2 for system, 1 for user pools.')
  minCount: int?

  @description('Optional. Maximum nodes (autoscaler). Defaults to 5.')
  maxCount: int?

  @description('Optional. Maximum pods per node. Defaults to 110.')
  maxPods: int?

  @description('Optional. OS disk size in GB. Defaults to 128.')
  osDiskSizeGB: int?

  @description('Optional. Ephemeral (default, needs a VM size with enough cache or temp disk) or Managed.')
  osDiskType: ('Ephemeral' | 'Managed')?

  @description('Optional. Availability zones. Defaults to 1, 2, 3 in prod and none in staging.')
  availabilityZones: int[]?

  @description('Optional. Node labels.')
  nodeLabels: object?

  @description('Optional. Node taints, for example "workload=batch:NoSchedule".')
  nodeTaints: string[]?

  @description('Optional. Use Spot VMs (user pools only). Defaults to false.')
  spot: bool?

  @description('Optional. Name of an additionalNodeSubnets entry to place the pool in. Defaults to snet-aks-nodes.')
  subnetName: string?
}

@export()
@description('An artifact cache rule on the cluster registry.')
type registryCacheRuleType = {
  @description('Optional. Rule name. Derived from the source repository when empty.')
  name: string?

  @description('Required. Upstream repository, for example mcr.microsoft.com/azurelinux/base/core.')
  sourceRepository: string

  @description('Optional. Repository in the registry. Defaults to the source path without the registry host.')
  targetRepository: string?

  @description('Optional. Credential set for upstreams that need authentication (Docker Hub). Created outside this template.')
  credentialSetResourceId: string?
}

@export()
@description('Cluster settings.')
type clusterType = {
  @description('Optional. Kubernetes minor version. Defaults to the region default.')
  kubernetesVersion: string?

  @description('Optional. Free or Standard (uptime SLA, recommended for production). Defaults to Standard in prod and Free in staging.')
  skuTier: ('Free' | 'Standard' | 'Premium')?

  @description('Optional. Cluster upgrade channel. Defaults to patch.')
  upgradeChannel: ('none' | 'patch' | 'rapid' | 'stable' | 'node-image')?

  @description('Optional. Node OS upgrade channel. Defaults to NodeImage.')
  nodeOSUpgradeChannel: ('None' | 'Unmanaged' | 'NodeImage' | 'SecurityPatch')?

  @description('Optional. Weekly maintenance window: day of week. Defaults to Sunday.')
  maintenanceDay: ('Monday' | 'Tuesday' | 'Wednesday' | 'Thursday' | 'Friday' | 'Saturday' | 'Sunday')?

  @description('Optional. Maintenance window start, HH:mm. Defaults to 02:00.')
  maintenanceStartTime: string?

  @description('Optional. Maintenance window UTC offset, for example +00:00. Defaults to +00:00.')
  maintenanceUtcOffset: string?

  @description('Required. System node pool. Runs only critical add-ons (CriticalAddonsOnly taint).')
  systemPool: nodePoolType

  @description('Optional. User node pools for workloads.')
  userPools: nodePoolType[]?
}

@export()
@description('Access settings.')
type accessType = {
  @description('Required. Entra group object IDs with cluster admin (Azure Kubernetes Service RBAC Cluster Admin).')
  adminGroupObjectIds: string[]

  @description('Optional. Entra group object IDs with read access to every namespace (Azure Kubernetes Service RBAC Reader).')
  readerGroupObjectIds: string[]?

  @description('Optional. Entra group object IDs that can view Grafana dashboards.')
  grafanaViewerGroupObjectIds: string[]?
}

@export()
@description('GitOps (Flux) settings.')
type gitOpsType = {
  @description('Optional. Install the Flux extension and the configuration below. Defaults to true.')
  enabled: bool?

  @description('Required. HTTPS URL of the Git repository.')
  repositoryUrl: string

  @description('Optional. Branch to follow. Defaults to main.')
  branch: string?

  @description('Optional. Path of the cluster entry point in the repository. Defaults to ./az-aks/gitops/clusters/<environment>.')
  clusterPath: string?
}

@export()
@description('Monitoring settings.')
type aksMonitoringType = {
  @description('Optional. Deploy Managed Grafana. Defaults to true.')
  grafana: bool?

  @description('Optional. Public network access for Grafana. Disabled needs private connectivity to reach the dashboards. Defaults to Disabled.')
  grafanaPublicNetworkAccess: ('Enabled' | 'Disabled')?

  @description('Optional. Deploy the Prometheus alert rules. Defaults to true.')
  alerts: bool?
}

@export()
@description('Optional cluster add-ons, all off by default. The Azure side is deployed here; the in-cluster side is under az-aks/gitops/optional (add it to the cluster kustomization).')
type aksAddonsType = {
  @description('Optional. Azure Backup for AKS: Backup vault, daily operational-tier policy, extension storage and trusted access, in a separate resource group that also holds the snapshots (D-035).')
  backup: {
    @description('Required. Deploy AKS Backup.')
    enabled: bool

    @description('Optional. Days to keep recovery points. Defaults to 14 (prod) or 7 (staging).')
    @minValue(1)
    @maxValue(360)
    retentionDays: int?

    @description('Optional. Daily backup time, UTC HH:mm. Defaults to 02:00.')
    backupTime: string?
  }?

  @description('Optional. Identity for the Kyverno admission controller (AcrPull on the cluster registry, federated to kyverno/kyverno-admission-controller) so it can read image signatures. Use with az-aks/gitops/optional/image-verification. Defaults to false.')
  imageVerification: bool?

  @description('Optional. Identity for external-dns (Private DNS Zone Contributor on these zones, federated to external-dns/external-dns). Use with az-aks/gitops/optional/external-dns. Zones must be in the hub DNS resource group.')
  externalDnsZoneNames: string[]?
}
