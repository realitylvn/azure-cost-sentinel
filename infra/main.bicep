targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the azd environment; used to generate a short unique resource token and as the resource group name suffix.')
param environmentName string

@minLength(1)
@description('Azure region for all resources.')
param location string

@description('Percentage delta above the trailing 7-day average spend that counts as an anomaly.')
param anomalyThresholdPct int = 20

@description('Days to suppress repeat alerts while an anomaly is ongoing.')
param alertCooldownDays int = 3

@description('Minimum trailing-average daily spend (USD) before the percentage check runs. Default $1/day; lower it to detect anomalies on a low-spend subscription.')
param minimumBaselineUsd string = '1.0'

@description('Monthly Azure Budget amount, in USD. No default on purpose - this is a personal spending decision, set it via azd env set.')
param budgetAmountUsd int

@description('Email address that receives the Budget alert and anomaly notifications.')
param notificationEmail string

@description('Portfolio project slug, used only for the "project" tag value - see azure-naming-conventions.md.')
param projectSlug string = 'cost-sentinel'

@description('Environment tag value - see azure-naming-conventions.md. Distinct from the azd environment name.')
param environmentTag string = 'dev'

var tags = {
  'azd-env-name': environmentName
  portfolio: 'azure-devops-portfolio'
  project: projectSlug
  environment: environmentTag
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    location: location
    environmentName: environmentName
    tags: tags
    anomalyThresholdPct: anomalyThresholdPct
    alertCooldownDays: alertCooldownDays
    minimumBaselineUsd: minimumBaselineUsd
    budgetAmountUsd: budgetAmountUsd
    notificationEmail: notificationEmail
  }
}

output AZURE_RESOURCE_GROUP string = rg.name
output FUNCTION_APP_NAME string = resources.outputs.functionAppName
output STORAGE_ACCOUNT_NAME string = resources.outputs.storageAccountName
