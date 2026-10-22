metadata name = 'AKS monitoring'
metadata description = 'Managed Prometheus (Azure Monitor workspace and data collection), Container Insights with Entra authentication, Managed Grafana and Prometheus recording and alert rules for one AKS cluster. All ingestion and queries go over private link.'

import { lockType } from 'br/public:avm/utl/types/avm-common-types:0.7.0'

@description('Required. Name prefix for the resources.')
param namePrefix string

@description('Optional. Location for all resources.')
param location string = resourceGroup().location

@description('Required. Name of the AKS cluster, in this resource group.')
param clusterName string

@description('Required. Resource ID of the central Log Analytics workspace (Container Insights destination).')
param logAnalyticsWorkspaceResourceId string

@description('Required. Resource ID of a data collection endpoint in the same region, linked to the Azure Monitor private link scope.')
param dataCollectionEndpointResourceId string

@description('Required. Subnet for the private endpoints.')
param privateEndpointSubnetResourceId string

@description('Required. Resource ID of the privatelink.<region>.prometheus.monitor.azure.com zone.')
param prometheusPrivateDnsZoneResourceId string

@description('Optional. Deploy Managed Grafana.')
param deployGrafana bool = true

@description('Conditional. Resource ID of the privatelink.grafana.azure.com zone. Required with Grafana.')
param grafanaPrivateDnsZoneResourceId string = ''

@description('Optional. Public network access for Grafana.')
param grafanaPublicNetworkAccess ('Enabled' | 'Disabled') = 'Disabled'

@description('Optional. Zone redundant Grafana.')
param grafanaZoneRedundancy bool = false

@description('Optional. Entra group object IDs with Grafana Admin.')
param grafanaAdminGroupObjectIds string[] = []

@description('Optional. Entra group object IDs with Grafana Viewer.')
param grafanaViewerGroupObjectIds string[] = []

@description('Optional. Deploy the Prometheus alert rules.')
param deployAlerts bool = true

@description('Optional. Action group notified by the Prometheus alerts.')
param actionGroupResourceId string = ''

@description('Optional. Lock applied to the workspace and Grafana.')
param lock lockType?

@description('Optional. Tags applied to every resource.')
param tags resourceInput<'Microsoft.Monitor/accounts@2025-10-03'>.tags?

@description('Optional. Enable AVM usage telemetry.')
param enableTelemetry bool = true

var roleIds = {
  grafanaAdmin: '22926164-76b3-42b3-bc55-97df8dab3e41'
  grafanaViewer: '60921a7e-fef1-4a43-9b16-a26c52ad4769'
  monitoringDataReader: 'b0d8363b-8ddd-447d-831f-62ca05bff136'
}

resource cluster 'Microsoft.ContainerService/managedClusters@2025-10-01' existing = {
  name: clusterName
}

// ---------------------------------------------------------------------------
// Managed Prometheus
// ---------------------------------------------------------------------------

resource monitorWorkspace 'Microsoft.Monitor/accounts@2025-10-03' = {
  name: '${namePrefix}-amw'
  location: location
  tags: tags
  properties: {
    publicNetworkAccess: 'Disabled'
  }
}

resource monitorWorkspaceLock 'Microsoft.Authorization/locks@2020-05-01' = if (!empty(lock ?? {}) && lock.?kind != 'None') {
  name: '${monitorWorkspace.name}-lock'
  scope: monitorWorkspace
  properties: {
    level: lock.?kind ?? 'CanNotDelete'
    notes: 'Protects the cluster metrics store.'
  }
}

module monitorWorkspacePrivateEndpoint 'br/public:avm/res/network/private-endpoint:0.12.1' = {
  name: '${uniqueString(deployment().name, location)}-amw-pe'
  params: {
    name: '${monitorWorkspace.name}-pe'
    location: location
    subnetResourceId: privateEndpointSubnetResourceId
    privateLinkServiceConnections: [
      {
        name: 'prometheusMetrics'
        properties: {
          privateLinkServiceId: monitorWorkspace.id
          groupIds: ['prometheusMetrics']
        }
      }
    ]
    privateDnsZoneGroup: {
      privateDnsZoneGroupConfigs: [{ privateDnsZoneResourceId: prometheusPrivateDnsZoneResourceId }]
    }
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

module prometheusRule 'br/public:avm/res/insights/data-collection-rule:0.11.0' = {
  name: '${uniqueString(deployment().name, location)}-dcr-prom'
  params: {
    name: 'MSProm-${location}-${clusterName}'
    location: location
    dataCollectionRuleProperties: {
      kind: 'Linux'
      description: 'Managed Prometheus metrics from ${clusterName}.'
      dataCollectionEndpointResourceId: dataCollectionEndpointResourceId
      dataSources: {
        prometheusForwarder: [
          {
            name: 'PrometheusDataSource'
            streams: ['Microsoft-PrometheusMetrics']
            labelIncludeFilter: {}
          }
        ]
      }
      destinations: {
        monitoringAccounts: [{ name: 'MonitoringAccount1', accountResourceId: monitorWorkspace.id }]
      }
      dataFlows: [{ streams: ['Microsoft-PrometheusMetrics'], destinations: ['MonitoringAccount1'] }]
    }
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

// ---------------------------------------------------------------------------
// Container Insights (Entra authentication, ContainerLogV2)
// ---------------------------------------------------------------------------

module containerInsightsRule 'br/public:avm/res/insights/data-collection-rule:0.11.0' = {
  name: '${uniqueString(deployment().name, location)}-dcr-ci'
  params: {
    name: 'MSCI-${location}-${clusterName}'
    location: location
    dataCollectionRuleProperties: {
      kind: 'Linux'
      description: 'Container Insights logs and inventory from ${clusterName}.'
      dataCollectionEndpointResourceId: dataCollectionEndpointResourceId
      dataSources: {
        extensions: [
          {
            name: 'ContainerInsightsExtension'
            extensionName: 'ContainerInsights'
            streams: ['Microsoft-ContainerInsights-Group-Default']
            extensionSettings: {
              dataCollectionSettings: {
                interval: '1m'
                namespaceFilteringMode: 'Off'
                enableContainerLogV2: true
              }
            }
          }
        ]
      }
      destinations: {
        logAnalytics: [{ name: 'ciworkspace', workspaceResourceId: logAnalyticsWorkspaceResourceId }]
      }
      dataFlows: [{ streams: ['Microsoft-ContainerInsights-Group-Default'], destinations: ['ciworkspace'] }]
    }
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

// The endpoint association routes agent configuration over private link.
resource endpointAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2024-03-11' = {
  name: 'configurationAccessEndpoint'
  scope: cluster
  properties: {
    dataCollectionEndpointId: dataCollectionEndpointResourceId
  }
}

resource prometheusAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2024-03-11' = {
  name: 'ContainerInsightsMetricsExtension'
  scope: cluster
  properties: {
    dataCollectionRuleId: prometheusRule.outputs.resourceId
    description: 'Managed Prometheus collection.'
  }
}

resource containerInsightsAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2024-03-11' = {
  name: 'ContainerInsightsExtension'
  scope: cluster
  properties: {
    dataCollectionRuleId: containerInsightsRule.outputs.resourceId
    description: 'Container Insights collection.'
  }
}

// ---------------------------------------------------------------------------
// Managed Grafana
// ---------------------------------------------------------------------------

resource grafana 'Microsoft.Dashboard/grafana@2025-08-01' = if (deployGrafana) {
  name: take('${namePrefix}-amg', 23)
  location: location
  tags: tags
  sku: { name: 'Standard' }
  identity: { type: 'SystemAssigned' }
  properties: {
    publicNetworkAccess: grafanaPublicNetworkAccess
    zoneRedundancy: grafanaZoneRedundancy ? 'Enabled' : 'Disabled'
    grafanaMajorVersion: '12'
    apiKey: 'Disabled'
    deterministicOutboundIP: 'Disabled'
    grafanaIntegrations: {
      azureMonitorWorkspaceIntegrations: [{ azureMonitorWorkspaceResourceId: monitorWorkspace.id }]
    }
  }
}

resource grafanaLock 'Microsoft.Authorization/locks@2020-05-01' = if (deployGrafana && !empty(lock ?? {}) && lock.?kind != 'None') {
  name: '${namePrefix}-amg-lock'
  scope: grafana
  properties: {
    level: lock.?kind ?? 'CanNotDelete'
    notes: 'Protects the cluster dashboards.'
  }
}

// Grafana reaches the workspace through a managed private endpoint because the
// workspace has no public access. The connection is approved on the workspace.
resource grafanaToWorkspace 'Microsoft.Dashboard/grafana/managedPrivateEndpoints@2025-08-01' = if (deployGrafana) {
  parent: grafana
  name: 'amw'
  location: location
  properties: {
    privateLinkResourceId: monitorWorkspace.id
    privateLinkResourceRegion: location
    groupIds: ['prometheusMetrics']
    requestMessage: 'Managed Grafana query access'
  }
}

module grafanaPrivateEndpoint 'br/public:avm/res/network/private-endpoint:0.12.1' = if (deployGrafana) {
  name: '${uniqueString(deployment().name, location)}-amg-pe'
  params: {
    name: '${namePrefix}-amg-pe'
    location: location
    subnetResourceId: privateEndpointSubnetResourceId
    privateLinkServiceConnections: [
      {
        name: 'grafana'
        properties: {
          privateLinkServiceId: grafana.id
          groupIds: ['grafana']
        }
      }
    ]
    privateDnsZoneGroup: { privateDnsZoneGroupConfigs: [{ privateDnsZoneResourceId: grafanaPrivateDnsZoneResourceId }] }
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

resource grafanaReadsWorkspace 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployGrafana) {
  name: guid(monitorWorkspace.id, '${namePrefix}-amg', roleIds.monitoringDataReader)
  scope: monitorWorkspace
  properties: {
    principalId: grafana!.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.monitoringDataReader)
  }
}

var grafanaAccess = concat(
  map(grafanaAdminGroupObjectIds, g => { principalId: g, role: roleIds.grafanaAdmin }),
  map(grafanaViewerGroupObjectIds, g => { principalId: g, role: roleIds.grafanaViewer })
)

resource grafanaRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for a in grafanaAccess: if (deployGrafana) {
    name: guid('${namePrefix}-amg', a.principalId, a.role)
    scope: grafana
    properties: {
      principalId: a.principalId
      principalType: 'Group'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', a.role)
    }
  }
]

// ---------------------------------------------------------------------------
// Prometheus rules
// ---------------------------------------------------------------------------

var clusterFilter = 'cluster="${clusterName}"'

// A subset of the recording rules Microsoft recommends; the Grafana Kubernetes
// dashboards that ship with Managed Grafana read these series.
resource nodeRecordingRules 'Microsoft.AlertsManagement/prometheusRuleGroups@2023-03-01' = {
  name: '${namePrefix}-node-recording-rules'
  location: location
  tags: tags
  properties: {
    description: 'Node recording rules.'
    scopes: [monitorWorkspace.id, cluster.id]
    clusterName: clusterName
    enabled: true
    interval: 'PT1M'
    rules: [
      {
        record: 'instance:node_num_cpu:sum'
        expression: 'count without (cpu, mode) (node_cpu_seconds_total{job="node",mode="idle"})'
      }
      {
        record: 'instance:node_cpu_utilisation:rate5m'
        expression: '1 - avg without (cpu) (sum without (mode) (rate(node_cpu_seconds_total{job="node", mode=~"idle|iowait|steal"}[5m])))'
      }
      {
        record: 'instance:node_load1_per_cpu:ratio'
        expression: '(node_load1{job="node"} / instance:node_num_cpu:sum{job="node"})'
      }
      {
        record: 'instance:node_memory_utilisation:ratio'
        expression: '1 - ((node_memory_MemAvailable_bytes{job="node"} or (node_memory_Buffers_bytes{job="node"} + node_memory_Cached_bytes{job="node"} + node_memory_MemFree_bytes{job="node"} + node_memory_Slab_bytes{job="node"})) / node_memory_MemTotal_bytes{job="node"})'
      }
      {
        record: 'instance_device:node_disk_io_time_seconds:rate5m'
        expression: 'rate(node_disk_io_time_seconds_total{job="node", device!=""}[5m])'
      }
      {
        record: 'instance:node_network_receive_bytes_excluding_lo:rate5m'
        expression: 'sum without (device) (rate(node_network_receive_bytes_total{job="node", device!="lo"}[5m]))'
      }
      {
        record: 'instance:node_network_transmit_bytes_excluding_lo:rate5m'
        expression: 'sum without (device) (rate(node_network_transmit_bytes_total{job="node", device!="lo"}[5m]))'
      }
    ]
  }
}

resource kubernetesRecordingRules 'Microsoft.AlertsManagement/prometheusRuleGroups@2023-03-01' = {
  name: '${namePrefix}-kubernetes-recording-rules'
  location: location
  tags: tags
  properties: {
    description: 'Kubernetes recording rules.'
    scopes: [monitorWorkspace.id, cluster.id]
    clusterName: clusterName
    enabled: true
    interval: 'PT1M'
    rules: [
      {
        record: 'node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate'
        expression: 'sum by (cluster, namespace, pod, container) (irate(container_cpu_usage_seconds_total{job="cadvisor", image!=""}[5m])) * on (cluster, namespace, pod) group_left(node) topk by (cluster, namespace, pod) (1, max by(cluster, namespace, pod, node) (kube_pod_info{node!=""}))'
      }
      {
        record: 'node_namespace_pod_container:container_memory_working_set_bytes'
        expression: 'container_memory_working_set_bytes{job="cadvisor", image!=""} * on (namespace, pod) group_left(node) topk by(namespace, pod) (1, max by(namespace, pod, node) (kube_pod_info{node!=""}))'
      }
      {
        record: 'cluster:namespace:pod_memory:active:kube_pod_container_resource_requests'
        expression: 'kube_pod_container_resource_requests{resource="memory",job="kube-state-metrics"} * on (namespace, pod, cluster) group_left() max by (namespace, pod, cluster) ((kube_pod_status_phase{phase=~"Pending|Running"} == 1))'
      }
      {
        record: 'cluster:namespace:pod_cpu:active:kube_pod_container_resource_requests'
        expression: 'kube_pod_container_resource_requests{resource="cpu",job="kube-state-metrics"} * on (namespace, pod, cluster) group_left() max by (namespace, pod, cluster) ((kube_pod_status_phase{phase=~"Pending|Running"} == 1))'
      }
      {
        record: 'namespace_workload_pod:kube_pod_owner:relabel'
        expression: 'max by (cluster, namespace, workload, pod) (label_replace(label_replace(kube_pod_owner{job="kube-state-metrics", owner_kind="ReplicaSet"}, "replicaset", "$1", "owner_name", "(.*)") * on(replicaset, namespace) group_left(owner_name) topk by(replicaset, namespace) (1, max by (replicaset, namespace, owner_name) (kube_replicaset_owner{job="kube-state-metrics"})), "workload", "$1", "owner_name", "(.*)"))'
        labels: { workload_type: 'deployment' }
      }
    ]
  }
}

var alertActions = empty(actionGroupResourceId) ? [] : [{ actionGroupId: actionGroupResourceId }]

resource alertRules 'Microsoft.AlertsManagement/prometheusRuleGroups@2023-03-01' = if (deployAlerts) {
  name: '${namePrefix}-alert-rules'
  location: location
  tags: tags
  properties: {
    description: 'Cluster and workload alerts.'
    scopes: [monitorWorkspace.id, cluster.id]
    clusterName: clusterName
    enabled: true
    interval: 'PT1M'
    rules: [
      {
        alert: 'KubeNodeNotReady'
        expression: 'kube_node_status_condition{job="kube-state-metrics",condition="Ready",status="true",${clusterFilter}} == 0'
        for: 'PT15M'
        severity: 2
        labels: { severity: 'warning' }
        annotations: { description: 'Node {{ $labels.node }} has been NotReady for 15 minutes.' }
        actions: alertActions
        resolveConfiguration: { autoResolved: true, timeToResolve: 'PT10M' }
      }
      {
        alert: 'KubePodCrashLooping'
        expression: 'max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff", job="kube-state-metrics",${clusterFilter}}[5m]) >= 1'
        for: 'PT15M'
        severity: 3
        labels: { severity: 'warning' }
        annotations: {
          description: 'Pod {{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) is crash looping.'
        }
        actions: alertActions
        resolveConfiguration: { autoResolved: true, timeToResolve: 'PT10M' }
      }
      {
        alert: 'KubeContainerOOMKilled'
        expression: 'sum by (cluster, namespace, pod, container) (increase(kube_pod_container_status_restarts_total{${clusterFilter}}[10m]) >= 1) and on (cluster, namespace, pod, container) (kube_pod_container_status_last_terminated_reason{reason="OOMKilled",${clusterFilter}} == 1)'
        for: 'PT5M'
        severity: 3
        labels: { severity: 'warning' }
        annotations: {
          description: 'Container {{ $labels.namespace }}/{{ $labels.pod }}/{{ $labels.container }} was OOM killed.'
        }
        actions: alertActions
        resolveConfiguration: { autoResolved: true, timeToResolve: 'PT10M' }
      }
      {
        alert: 'KubeDeploymentReplicasMismatch'
        expression: '(kube_deployment_spec_replicas{job="kube-state-metrics",${clusterFilter}} > kube_deployment_status_replicas_available{job="kube-state-metrics",${clusterFilter}}) and (changes(kube_deployment_status_replicas_updated{job="kube-state-metrics",${clusterFilter}}[10m]) == 0)'
        for: 'PT15M'
        severity: 3
        labels: { severity: 'warning' }
        annotations: {
          description: 'Deployment {{ $labels.namespace }}/{{ $labels.deployment }} has not matched the expected replicas for 15 minutes.'
        }
        actions: alertActions
        resolveConfiguration: { autoResolved: true, timeToResolve: 'PT10M' }
      }
      {
        alert: 'KubeNodeHighCpu'
        expression: 'instance:node_cpu_utilisation:rate5m{${clusterFilter}} > 0.9'
        for: 'PT15M'
        severity: 3
        labels: { severity: 'warning' }
        annotations: { description: 'Node {{ $labels.instance }} CPU above 90% for 15 minutes.' }
        actions: alertActions
        resolveConfiguration: { autoResolved: true, timeToResolve: 'PT10M' }
      }
      {
        alert: 'KubePersistentVolumeFillingUp'
        expression: 'kubelet_volume_stats_available_bytes{job="kubelet",${clusterFilter}} / kubelet_volume_stats_capacity_bytes{job="kubelet",${clusterFilter}} < 0.1'
        for: 'PT15M'
        severity: 2
        labels: { severity: 'warning' }
        annotations: {
          description: 'Volume {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }} has less than 10% free space.'
        }
        actions: alertActions
        resolveConfiguration: { autoResolved: true, timeToResolve: 'PT10M' }
      }
    ]
  }
}

@description('Resource ID of the Azure Monitor workspace.')
output monitorWorkspaceResourceId string = monitorWorkspace.id

@description('Resource ID of Managed Grafana, empty when not deployed.')
output grafanaResourceId string = deployGrafana ? grafana.id : ''
