@description('Azure region for all resources.')
param location string

@description('azd environment name (e.g. cost-sentinel-dev) - drives resource naming per azure-naming-conventions.md, and seeds the short token used only where global uniqueness is required.')
param environmentName string

param tags object

@description('Percentage delta above the trailing 7-day average spend that counts as an anomaly.')
param anomalyThresholdPct int

@description('Days to suppress repeat alerts while an anomaly is ongoing.')
param alertCooldownDays int

@description('Minimum trailing-average daily spend (USD) before the percentage check runs. Below this, a percentage delta is noise. String so it can carry a sub-dollar value.')
param minimumBaselineUsd string

@description('Monthly Azure Budget amount, in USD.')
param budgetAmountUsd int

@description('Email address that receives the Budget alert and anomaly notifications.')
param notificationEmail string

@description('First-of-month start date for the budget, in yyyy-MM-dd form.')
param budgetStartDate string = utcNow('yyyy-MM-01')

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
          // Required for Python on Linux Consumption: without this, a zip deploy
          // never runs Oryx to pip install requirements.txt, so the worker can't
          // import the function and reports zero triggers - looks "deployed" but
          // is silently non-functional. Hit this exact failure on the first deploy.
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          // The subscription this Function watches spend for. The identity only
          // holds Cost Management Reader on this one subscription, so there's
          // nothing to discover at runtime - passing it as config lets the code
          // drop the azure-mgmt-resource SDK dependency entirely.
          name: 'AZURE_SUBSCRIPTION_ID'
          value: subscription().subscriptionId
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
          name: 'MINIMUM_BASELINE_USD'
          value: minimumBaselineUsd
        }
        {
          // The dedupe-state blob is accessed with this account-key connection
          // string, NOT the Function's managed identity - the identity holds only
          // Cost Management Reader (subscription scope, for the cost query) and has
          // no data-plane role here, and adding one just to write a timestamp would
          // widen it. Same account and key as AzureWebJobsStorage above.
          name: 'STATE_STORAGE_CONNECTION_STRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'STATE_CONTAINER_NAME'
          value: stateContainerName
        }
      ]
    }
  }
}

// The Cost Management Reader role assignment lives in main.bicep, at SUBSCRIPTION
// scope. It was originally scoped here to the resource group on a least-privilege
// instinct, but the tool's whole job is a subscription-wide cost query
// (POST /subscriptions/{id}/providers/Microsoft.CostManagement/query), and an
// RG-scoped cost role does not authorize that call - it returns 401 RBACAccessDenied.
// Confirmed on the 2026-09-02 08:00 UTC scheduled run, the one that got past the
// Cost Management API's aggressive 429 throttle. See REVIEW.md, "Cost-query scope".
// functionAppPrincipalId is surfaced as an output for main.bicep to consume.

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
    // Scoped to the App Insights resource itself, not the underlying Log Analytics
    // workspace: only the App Insights scope exposes the classic "traces" table
    // alias with camelCase columns. Scoping to the raw workspace would require
    // querying "AppTraces" with PascalCase columns instead.
    scopes: [
      appInsights.id
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
output functionAppPrincipalId string = functionApp.identity.principalId
