metadata name = 'AKS types'
metadata description = 'Parameter types for the AKS workload.'

@export()
@description('Spoke network for AKS.')
type aksNetworkType = {
  @description('Required. Spoke address space.')
  addressPrefixes: string[]

  @description('Required. Node subnet prefix. With CNI Overlay only nodes take VNet addresses, so a /24 holds about 250 nodes.')
  nodeSubnetPrefix: string

  @description('Required. Private endpoint subnet prefix (registry, key vault, monitor workspace, Grafana).')
  privateEndpointSubnetPrefix: string

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
