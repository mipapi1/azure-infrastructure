metadata name = 'AVD monitoring'
metadata description = 'AVD Insights data collection rule and alert rules for one host pool: no available hosts, unhealthy hosts, high session count, FSLogix errors, and profile storage latency and capacity.'

@description('Required. Name prefix for the rules.')
param namePrefix string

@description('Optional. Location for all resources.')
param location string = resourceGroup().location

@description('Required. Resource ID of the Log Analytics workspace (destination and alert scope).')
param logAnalyticsWorkspaceResourceId string

@description('Optional. Resource ID of the data collection endpoint for private ingestion.')
param dataCollectionEndpointResourceId string?

@description('Required. Resource ID of the host pool the alerts watch.')
param hostPoolResourceId string

@description('Required. Computer name prefix of the session hosts, used to filter performance data.')
param sessionHostPrefix string

@description('Required. Maximum sessions per host. The high session alert fires at 90%.')
param maxSessionLimit int

@description('Optional. Resource ID of the FSLogix storage account. Storage alerts are skipped when empty.')
param profileStorageAccountResourceId string = ''

@description('Optional. Profile share quota in GiB, for the capacity alert at 80%.')
param profileShareQuotaGiB int = 1024

@description('Optional. Profile storage end-to-end latency threshold in milliseconds.')
param profileStorageLatencyThresholdMs int = 50

@description('Optional. Action group notified by every alert.')
param actionGroupResourceId string = ''

@description('Optional. Severity offset: prod alerts at the given severity, staging can pass higher numbers to keep noise down.')
@minValue(0)
@maxValue(4)
param baseSeverity int = 1

@description('Optional. Tags applied to every resource.')
param tags resourceInput<'Microsoft.Insights/dataCollectionRules@2024-03-11'>.tags?

@description('Optional. Enable AVM usage telemetry.')
param enableTelemetry bool = true

var actions = empty(actionGroupResourceId) ? [] : [actionGroupResourceId]
var hostPoolId = toLower(hostPoolResourceId)

// The AVD Insights workbook finds its rule by the "microsoft-avdi-" name prefix.
module avdInsightsRule 'br/public:avm/res/insights/data-collection-rule:0.11.0' = {
  name: '${uniqueString(deployment().name, location)}-dcr-avdi'
  params: {
    name: 'microsoft-avdi-${namePrefix}'
    location: location
    dataCollectionRuleProperties: {
      kind: 'Windows'
      description: 'Counters and events required by AVD Insights.'
      dataCollectionEndpointResourceId: dataCollectionEndpointResourceId
      dataSources: {
        performanceCounters: [
          {
            name: 'avdi-30s'
            streams: ['Microsoft-Perf']
            samplingFrequencyInSeconds: 30
            counterSpecifiers: [
              '\\LogicalDisk(C:)\\Avg. Disk Queue Length'
              '\\LogicalDisk(C:)\\Current Disk Queue Length'
              '\\Memory\\Available Mbytes'
              '\\Memory\\Page Faults/sec'
              '\\Memory\\Pages/sec'
              '\\Memory\\% Committed Bytes In Use'
              '\\PhysicalDisk(*)\\Avg. Disk Queue Length'
              '\\PhysicalDisk(*)\\Avg. Disk sec/Read'
              '\\PhysicalDisk(*)\\Avg. Disk sec/Transfer'
              '\\PhysicalDisk(*)\\Avg. Disk sec/Write'
              '\\Processor Information(_Total)\\% Processor Time'
              '\\User Input Delay per Process(*)\\Max Input Delay'
              '\\User Input Delay per Session(*)\\Max Input Delay'
              '\\RemoteFX Network(*)\\Current TCP RTT'
              '\\RemoteFX Network(*)\\Current UDP Bandwidth'
            ]
          }
          {
            name: 'avdi-60s'
            streams: ['Microsoft-Perf']
            samplingFrequencyInSeconds: 60
            counterSpecifiers: [
              '\\LogicalDisk(C:)\\% Free Space'
              '\\LogicalDisk(C:)\\Avg. Disk sec/Transfer'
              '\\Terminal Services(*)\\Active Sessions'
              '\\Terminal Services(*)\\Inactive Sessions'
              '\\Terminal Services(*)\\Total Sessions'
            ]
          }
        ]
        windowsEventLogs: [
          {
            name: 'avdi-events'
            streams: ['Microsoft-Event']
            xPathQueries: [
              'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]'
              'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]'
              'System!*'
              'Microsoft-FSLogix-Apps/Operational!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]'
              'Application!*[System[(Level=2 or Level=3)]]'
              'Microsoft-FSLogix-Apps/Admin!*[System[(Level=2 or Level=3 or Level=4 or Level=0)]]'
            ]
          }
        ]
      }
      destinations: {
        logAnalytics: [{ name: 'law', workspaceResourceId: logAnalyticsWorkspaceResourceId }]
      }
      dataFlows: [{ streams: ['Microsoft-Perf', 'Microsoft-Event'], destinations: ['law'] }]
    }
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

var queryAlerts = [
  {
    key: 'no-available-hosts'
    displayName: 'AVD: no session hosts available'
    description: 'No host in the pool reported Available in the last 15 minutes. Users cannot connect.'
    severity: baseSeverity
    query: 'WVDAgentHealthStatus\n| where TimeGenerated > ago(15m)\n| where tolower(_ResourceId) == "${hostPoolId}"\n| summarize arg_max(TimeGenerated, Status) by SessionHostName\n| summarize Available = countif(Status == "Available")'
    column: 'Available'
    operator: 'LessThan'
    threshold: 1
  }
  {
    key: 'unhealthy-hosts'
    displayName: 'AVD: session host unhealthy'
    description: 'One or more hosts report a status other than Available, Shutdown or Upgrading.'
    severity: min(baseSeverity + 1, 4)
    query: 'WVDAgentHealthStatus\n| where TimeGenerated > ago(15m)\n| where tolower(_ResourceId) == "${hostPoolId}"\n| summarize arg_max(TimeGenerated, Status) by SessionHostName\n| where Status !in ("Available", "Shutdown", "Upgrading")\n| summarize Unhealthy = count()'
    column: 'Unhealthy'
    operator: 'GreaterThan'
    threshold: 0
  }
  {
    key: 'high-session-count'
    displayName: 'AVD: host near session limit'
    description: 'A host is at 90% or more of the session limit. Consider more hosts or a higher peak capacity threshold.'
    severity: min(baseSeverity + 2, 4)
    query: 'Perf\n| where TimeGenerated > ago(15m)\n| where ObjectName == "Terminal Services" and CounterName == "Active Sessions"\n| where Computer startswith "${sessionHostPrefix}"\n| summarize Sessions = max(CounterValue) by Computer\n| where Sessions >= ${maxSessionLimit * 9 / 10}\n| summarize Hosts = count()'
    column: 'Hosts'
    operator: 'GreaterThan'
    threshold: 0
  }
  {
    key: 'fslogix-errors'
    displayName: 'AVD: FSLogix profile errors'
    description: 'FSLogix logged errors, usually a profile container that failed to attach.'
    severity: min(baseSeverity + 1, 4)
    query: 'Event\n| where TimeGenerated > ago(15m)\n| where Source == "Microsoft-FSLogix-Apps" and EventLevelName == "Error"\n| where Computer startswith "${sessionHostPrefix}"\n| summarize Errors = count()'
    column: 'Errors'
    operator: 'GreaterThan'
    threshold: 0
  }
]

module queryAlertRules 'br/public:avm/res/insights/scheduled-query-rule:0.6.1' = [
  for a in queryAlerts: {
    name: '${uniqueString(deployment().name, location)}-sqr-${a.key}'
    params: {
      name: '${namePrefix}-${a.key}'
      location: location
      alertDisplayName: a.displayName
      alertDescription: a.description
      severity: a.severity
      scopes: [logAnalyticsWorkspaceResourceId]
      evaluationFrequency: 'PT5M'
      windowSize: 'PT15M'
      autoMitigate: true
      criterias: {
        allOf: [
          {
            query: a.query
            timeAggregation: 'Total'
            metricMeasureColumn: a.column
            operator: a.operator
            threshold: a.threshold
            failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
          }
        ]
      }
      actions: { actionGroupResourceIds: actions }
      tags: tags
      enableTelemetry: enableTelemetry
    }
  }
]

var fileServiceId = '${profileStorageAccountResourceId}/fileServices/default'

module storageLatencyAlert 'br/public:avm/res/insights/metric-alert:0.4.1' = if (!empty(profileStorageAccountResourceId)) {
  name: '${uniqueString(deployment().name, location)}-ma-latency'
  params: {
    name: '${namePrefix}-profile-storage-latency'
    location: 'global'
    alertDescription: 'Average end-to-end latency on the FSLogix share is above ${profileStorageLatencyThresholdMs} ms. Users will see slow sign-in.'
    severity: min(baseSeverity + 1, 4)
    scopes: [fileServiceId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allof: [
        {
          name: 'latency'
          criterionType: 'StaticThresholdCriterion'
          metricNamespace: 'Microsoft.Storage/storageAccounts/fileServices'
          metricName: 'SuccessE2ELatency'
          operator: 'GreaterThan'
          threshold: profileStorageLatencyThresholdMs
          timeAggregation: 'Average'
        }
      ]
    }
    actions: actions
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

module storageCapacityAlert 'br/public:avm/res/insights/metric-alert:0.4.1' = if (!empty(profileStorageAccountResourceId)) {
  name: '${uniqueString(deployment().name, location)}-ma-capacity'
  params: {
    name: '${namePrefix}-profile-storage-capacity'
    location: 'global'
    alertDescription: 'FSLogix share usage is above 80% of its ${profileShareQuotaGiB} GiB quota.'
    severity: min(baseSeverity + 1, 4)
    scopes: [fileServiceId]
    evaluationFrequency: 'PT1H'
    windowSize: 'PT6H'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allof: [
        {
          name: 'capacity'
          criterionType: 'StaticThresholdCriterion'
          metricNamespace: 'Microsoft.Storage/storageAccounts/fileServices'
          metricName: 'FileCapacity'
          operator: 'GreaterThan'
          threshold: profileShareQuotaGiB * 1024 * 1024 * 1024 * 8 / 10
          timeAggregation: 'Average'
        }
      ]
    }
    actions: actions
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

@description('Resource ID of the AVD Insights data collection rule. Associate it with every session host.')
output avdInsightsDataCollectionRuleResourceId string = avdInsightsRule.outputs.resourceId
