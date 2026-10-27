# AVD monitoring

AVD Insights data collection rule (`microsoft-avdi-<prefix>`, the name prefix the workbook looks for) and alert rules for one host pool:

| Alert | Source | Default severity |
|---|---|---|
| No session hosts available | `WVDAgentHealthStatus` | base |
| Session host unhealthy | `WVDAgentHealthStatus` | base + 1 |
| Host near session limit (90%) | Perf, Terminal Services | base + 2 |
| FSLogix errors | Event log | base + 1 |
| Profile storage latency | File service metric | base + 1 |
| Profile share above 80% of quota | File service metric | base + 1 |

Optional, in a second rule `<prefix>-dcr-security` (associate it with the hosts too):

- `complianceEvidence`: JSON lines from `C:\ProgramData\STIG\evidence\compliance-*.json` to the custom table `AvdComplianceEvidence_CL` (created in the workspace's resource group with the workspace table AVM), and a shared workbook (`workbooks/compliance.workbook.json`). Needs a data collection endpoint.
- `securityEvents`: AppLocker and Defender Antivirus warnings and errors, and Defender configuration changes (5007), to `Event`.

## Parameters

<!-- BEGIN_PARAMS -->
| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `namePrefix` | string | yes |  | Name prefix for the rules. |
| `location` | string | no | computed | Location for all resources. |
| `logAnalyticsWorkspaceResourceId` | string | yes |  | Resource ID of the Log Analytics workspace (destination and alert scope). |
| `dataCollectionEndpointResourceId` | string | no |  | Resource ID of the data collection endpoint for private ingestion. |
| `hostPoolResourceId` | string | yes |  | Resource ID of the host pool the alerts watch. |
| `sessionHostPrefix` | string | yes |  | Computer name prefix of the session hosts, used to filter performance data. |
| `maxSessionLimit` | int | yes |  | Maximum sessions per host. The high session alert fires at 90%. |
| `profileStorageAccountResourceId` | string | no | `""` | Resource ID of the FSLogix storage account. Storage alerts are skipped when empty. |
| `profileShareQuotaGiB` | int | no | `1024` | Profile share quota in GiB, for the capacity alert at 80%. |
| `profileStorageLatencyThresholdMs` | int | no | `50` | Profile storage end-to-end latency threshold in milliseconds. |
| `actionGroupResourceId` | string | no | `""` | Action group notified by every alert. |
| `baseSeverity` | int | no | `1` | Severity offset: prod alerts at the given severity, staging can pass higher numbers to keep noise down. |
| `complianceEvidence` | bool | no | `false` | Collect the daily compliance evidence the session hosts write (custom table AvdComplianceEvidence_CL) and deploy a compliance workbook. Needs dataCollectionEndpointResourceId. |
| `securityEvents` | bool | no | `false` | Forward AppLocker and Microsoft Defender Antivirus events (warnings and errors, plus Defender configuration changes) to the Event table. |
| `tags` | object | no |  | Tags applied to every resource. |
| `enableTelemetry` | bool | no | `true` | Enable AVM usage telemetry. |

| Output | Type | Description |
|---|---|---|
| `avdInsightsDataCollectionRuleResourceId` | string | Resource ID of the AVD Insights data collection rule. Associate it with every session host. |
| `securityDataCollectionRuleResourceId` | string | Resource ID of the compliance evidence and security events rule, empty when neither is enabled. Associate it with every session host. |
| `complianceWorkbookResourceId` | string | Resource ID of the compliance workbook, empty when complianceEvidence is false. |
<!-- END_PARAMS -->
