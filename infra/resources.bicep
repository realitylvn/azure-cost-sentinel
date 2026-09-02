@description('Azure region for all resources.')
param location string

@description('azd environment name (e.g. cost-sentinel-dev) - drives resource naming per azure-naming-conventions.md, and seeds the short token used only where global uniqueness is required.')
param environmentName string

param tags object

@description('Percentage delta above the trailing 7-day average spend that counts as an anomaly.')
param anomalyThresholdPct int

@description('Days to suppress repeat alerts while an anomaly is ongoing.')
param alertCooldownDays int

@description('Monthly Azure Budget amount, in USD.')
param budgetAmountUsd int

@description('Email address that receives the Budget alert and anomaly notifications.')
param notificationEmail string

@description('First-of-month start date for the budget, in yyyy-MM-dd form.')
param budgetStartDate string = utcNow('yyyy-MM-01')

@description('Built-in "Cost Management Reader" role definition ID (verified via az role definition list).')
var costManagementReaderRoleId = '72fafb9e-0641-4937-9268-a91bfd8191a3'

// Only storage accounts and Function Apps need azd's uniqueness token appended -
// both have globally-unique naming requirements the rest of these resources don't.
// See azure-naming-conventions.md.
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var shortToken = substring(resourceToken, 0, 6)
var stateContainerName = 'state'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  // Storage account names: lowercase alphanumeric only, no hyphens, <=24 chars.
  name: 'st${toLower(replace(environmentName, '-', ''))}${shortToken}'
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }

  resource blobServices 'blobServices' = {
    name: 'default'

    resource stateContainer 'containers' = {
      name: stateContainerName
      properties: {
        publicAccess: 'None'
      }
    }
  }
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${environmentName}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    workspaceCapping: {
      dailyQuotaGb: json('1')
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${environmentName}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    RetentionInDays: 30
  }
}

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'plan-${environmentName}'
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  // Web App hostnames are globally unique, so this gets the short token too.
  name: 'func-${environmentName}-${shortToken}'
  location: location
  tags: union(tags, { 'azd-service-name': 'function' })
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'Python|3.11'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'ANOMALY_THRESHOLD_PCT'
          value: string(anomalyThresholdPct)
        }
        {
          name: 'ALERT_COOLDOWN_DAYS'
          value: string(alertCooldownDays)
        }
        {
          name: 'STATE_STORAGE_ACCOUNT_NAME'
          value: storage.name
        }
        {
          name: 'STATE_CONTAINER_NAME'
          value: stateContainerName
        }
      ]
    }
  }
}

resource costManagementReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, functionApp.id, costManagementReaderRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', costManagementReaderRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${environmentName}'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'costsentnl'
    enabled: true
    emailReceivers: [
      {
        name: 'primary'
        emailAddress: notificationEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// The Function's managed identity only ever holds Cost Management Reader - it has no
// permission to trigger an Action Group directly. Instead, the Function logs a plain
// -English "AnomalyDetected: ..." trace to Application Insights (needs only the
// connection string, no RBAC), and this Log Alert watches for that trace and fires
// the Action Group. Keeps the identity's privilege exactly as scoped in the spec.
resource anomalyAlertRule 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = {
  name: 'alert-anomaly-${environmentName}'
  location: location
  tags: tags
  properties: {
    displayName: 'Azure Cost Sentinel - anomaly detected'
    description: 'Fires when the Function logs an AnomalyDetected trace to Application Insights.'
    severity: 3
    enabled: true
    evaluationFrequency: 'PT1H'
    windowSize: 'PT1H'
    scopes: [
      logAnalytics.id
    ]
    criteria: {
      allOf: [
        {
          query: 'traces | where message startswith "AnomalyDetected"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

// Microsoft.Consumption/budgets has no tags property in its ARM schema at all -
// confirmed via a failed `tags:` build attempt, not assumed. Naming is the only way
// this resource can carry the convention.
resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: 'budget-${environmentName}'
  properties: {
    category: 'Cost'
    amount: budgetAmountUsd
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: budgetStartDate
      endDate: dateTimeAdd(budgetStartDate, 'P5Y')
    }
    notifications: {
      actualGreaterThan80Percent: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: [
          notificationEmail
        ]
      }
    }
  }
}

output functionAppName string = functionApp.name
output storageAccountName string = storage.name
