// ===========================================================================
//  File replication monitoring - Azure-native stack
//  Deploys: Log Analytics workspace, DCR (Windows Event Log collection via AMA),
//           AMA extension + DCR association on the mover VM, an email Action Group,
//           and the scheduled-query + metric alert rules.
//
//  Deploy (resource-group scope):
//    az deployment group create -g <rg> -f deploy-monitoring.bicep \
//       -p vmName=<vm> storageAccountName=<acct> alertEmail=support@customer.com
// ===========================================================================

@description('Azure region for the workspace and DCR.')
param location string = resourceGroup().location

@description('Name of the existing mover VM (its OS hostname must match for the heartbeat alert).')
param vmName string

@description('Name of the existing Azure Files storage account.')
param storageAccountName string

@description('Destination address for alert email (customer support team).')
param alertEmail string

@description('Replication schedule interval, in hours. Drives the dead-man and overrun thresholds.')
param intervalHours int = 4

@description('Dead-man window in hours: alert if no completion event arrives within this span. Default = interval + 1h grace.')
param deadmanWindowHours int = 5

@description('Overrun threshold in seconds: warn if a run takes longer than this (default 80% of interval).')
param overrunThresholdSec int = (intervalHours * 3600) * 80 / 100

param workspaceName string = 'law-filerepl'
param eventSourceName string = 'FileRepl'
param retentionDays int = 30

// --- existing resources ----------------------------------------------------
resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: vmName
}
resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

// --- log analytics ----------------------------------------------------------
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionDays
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

// --- data collection rule: scrape only our event source --------------------
resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: 'dcr-filerepl'
  location: location
  properties: {
    dataSources: {
      windowsEventLogs: [
        {
          name: 'fileReplEvents'
          streams: [ 'Microsoft-Event' ]
          xPathQueries: [
            'Application!*[System[Provider[@Name=\'${eventSourceName}\']]]'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        { name: 'la', workspaceResourceId: workspace.id }
      ]
    }
    dataFlows: [
      { streams: [ 'Microsoft-Event' ], destinations: [ 'la' ] }
    ]
  }
}

// --- Azure Monitor Agent on the mover VM + DCR association ------------------
resource ama 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: vm
  name: 'AzureMonitorWindowsAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

resource dcra 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: 'filerepl-dcra'
  scope: vm
  properties: { dataCollectionRuleId: dcr.id }
  dependsOn: [ ama ]
}

// --- action group: email the customer support team -------------------------
resource ag 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-filerepl'
  location: 'global'
  properties: {
    groupShortName: 'FileRepl'
    enabled: true
    emailReceivers: [
      { name: 'support', emailAddress: alertEmail, useCommonAlertSchema: true }
    ]
  }
}

// --- KQL for the scheduled-query alerts ------------------------------------
// Dead-man and "all good" both rely on: summarize over the window always returns
// exactly one row, so a count of 0 yields a row we can alert on.
var qFailure  = 'Event | where EventLog == "Application" and Source == "${eventSourceName}" and EventID == 1001'
var qDeadman  = 'Event | where EventLog == "Application" and Source == "${eventSourceName}" and EventID in (1000,1001) | summarize n = count() | where n == 0'
var qCanary   = 'Event | where EventLog == "Application" and Source == "${eventSourceName}" and EventID == 1002'
var qOverrun  = 'Event | where EventLog == "Application" and Source == "${eventSourceName}" and EventID == 1000 | extend J = parse_json(extract(@"(\\{.*\\})", 1, RenderedDescription)) | extend DurationSec = toint(J.DurationSec) | where DurationSec > ${overrunThresholdSec}'
var qHeartbeat = 'Heartbeat | where Computer == "${vmName}" | summarize n = count() | where n == 0'

var rules = [
  { name: 'alrt-filerepl-failed',    sev: 2, freq: 'PT30M', window: 'PT${intervalHours}H',        query: qFailure,   desc: 'A replication run reported failure (robocopy exit >= 8 or script crash).' }
  { name: 'alrt-filerepl-deadman',   sev: 1, freq: 'PT1H',  window: 'PT${deadmanWindowHours}H',    query: qDeadman,   desc: 'No replication completion event in the expected window - the VM, task, or script may be down.' }
  { name: 'alrt-filerepl-canary',    sev: 1, freq: 'PT30M', window: 'PT${intervalHours}H',         query: qCanary,    desc: 'Abnormal number of files purged from the target (/MIR deletion canary) - possible ransomware or source loss.' }
  { name: 'alrt-filerepl-overrun',   sev: 3, freq: 'PT1H',  window: 'PT${intervalHours}H',         query: qOverrun,   desc: 'A replication run is taking longer than 80% of the schedule interval and may overlap the next cycle.' }
  { name: 'alrt-filerepl-vmdown',    sev: 1, freq: 'PT5M',  window: 'PT15M',                       query: qHeartbeat, desc: 'No Azure Monitor Agent heartbeat from the mover VM.' }
]

resource scheduledAlerts 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = [for r in rules: {
  name: r.name
  location: location
  properties: {
    displayName: r.name
    description: r.desc
    severity: r.sev
    enabled: true
    scopes: [ workspace.id ]
    evaluationFrequency: r.freq
    windowSize: r.window
    criteria: {
      allOf: [
        {
          query: r.query
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    autoMitigate: true
    actions: { actionGroups: [ ag.id ] }
  }
}]

// --- metric alert: storage account availability ----------------------------
resource availabilityAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alrt-filerepl-storage-availability'
  location: 'global'
  properties: {
    description: 'Azure Files storage account availability dropped below 99%.'
    severity: 2
    enabled: true
    scopes: [ storage.id ]
    evaluationFrequency: 'PT15M'
    windowSize: 'PT1H'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'Availability'
          metricNamespace: 'Microsoft.Storage/storageAccounts'
          metricName: 'Availability'
          operator: 'LessThan'
          threshold: 99
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [ { actionGroupId: ag.id } ]
  }
}

output workspaceId string = workspace.id
output actionGroupId string = ag.id
