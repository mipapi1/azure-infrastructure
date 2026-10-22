# AKS monitoring

Managed Prometheus, Container Insights and Managed Grafana for one AKS cluster, all over private link:

- Azure Monitor workspace with public access disabled and a private endpoint.
- Data collection rules for Prometheus metrics (`MSProm-*`) and Container Insights with ContainerLogV2 (`MSCI-*`), using a data collection endpoint in the private link scope, and their associations with the cluster.
- Managed Grafana with public access disabled by default, a private endpoint and a managed private endpoint to the workspace (approve it on the workspace after the first deployment), Monitoring Data Reader on the workspace, and Grafana Admin and Viewer group assignments.
- Prometheus recording rules for the built-in Kubernetes dashboards and alert rules for node readiness, crash loops, OOM kills, replica mismatches, node CPU and volume space.

See D-019 in `docs/DECISIONS.md`.

## Parameters

<!-- BEGIN_PARAMS -->
| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `namePrefix` | string | yes |  | Name prefix for the resources. |
| `location` | string | no | computed | Location for all resources. |
| `clusterName` | string | yes |  | Name of the AKS cluster, in this resource group. |
| `logAnalyticsWorkspaceResourceId` | string | yes |  | Resource ID of the central Log Analytics workspace (Container Insights destination). |
| `dataCollectionEndpointResourceId` | string | yes |  | Resource ID of a data collection endpoint in the same region, linked to the Azure Monitor private link scope. |
| `privateEndpointSubnetResourceId` | string | yes |  | Subnet for the private endpoints. |
| `prometheusPrivateDnsZoneResourceId` | string | yes |  | Resource ID of the privatelink.<region>.prometheus.monitor.azure.com zone. |
| `deployGrafana` | bool | no | `true` | Deploy Managed Grafana. |
| `grafanaPrivateDnsZoneResourceId` | string | no | `""` | Resource ID of the privatelink.grafana.azure.com zone. Required with Grafana. |
| `grafanaPublicNetworkAccess` | `Disabled` \| `Enabled` | no | `"Disabled"` | Public network access for Grafana. |
| `grafanaZoneRedundancy` | bool | no | `false` | Zone redundant Grafana. |
| `grafanaAdminGroupObjectIds` | string[] | no | `[]` | Entra group object IDs with Grafana Admin. |
| `grafanaViewerGroupObjectIds` | string[] | no | `[]` | Entra group object IDs with Grafana Viewer. |
| `deployAlerts` | bool | no | `true` | Deploy the Prometheus alert rules. |
| `actionGroupResourceId` | string | no | `""` | Action group notified by the Prometheus alerts. |
| `lock` | lockType | no |  | Lock applied to the workspace and Grafana. |
| `tags` | object | no |  | Tags applied to every resource. |
| `enableTelemetry` | bool | no | `true` | Enable AVM usage telemetry. |

| Output | Type | Description |
|---|---|---|
| `monitorWorkspaceResourceId` | string | Resource ID of the Azure Monitor workspace. |
| `grafanaResourceId` | string | Resource ID of Managed Grafana, empty when not deployed. |
<!-- END_PARAMS -->
