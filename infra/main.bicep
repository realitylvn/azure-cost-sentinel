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

@description('Built-in "Cost Management Reader" role definition ID (verified via az role definition list --name "Cost Management Reader").')
var costManagementReaderRoleId = '72fafb9e-0641-4937-9268-a91bfd8191a3'

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

// Cost Management Reader for the Function's managed identity, at SUBSCRIPTION scope.
// The tool queries subscription-wide spend
// (POST /subscriptions/{id}/providers/Microsoft.CostManagement/query); an RG-scoped
// cost role does not authorize that call and Cost Management returns 401
// RBACAccessDenied (not 403). This is still the identity's only role assignment and
// it is read-only for cost data - it grants no access to any resource in the
// subscription. Its own module because a roleAssignment's guid() name must be
// computable at deployment start - it can take a module PARAMETER (principal id
// passed in below) but not another module's OUTPUT. Creating a subscription-scoped
// assignment requires the deployer to hold Owner or User Access Administrator on the
// subscription. See REVIEW.md, "Cost-query scope: RG-scoped role returned 401".
module subscriptionRbac 'subscription-rbac.bicep' = {
  name: 'subscription-rbac'
  params: {
    functionAppPrincipalId: resources.outputs.functionAppPrincipalId
    costManagementReaderRoleId: costManagementReaderRoleId
  }
}

output AZURE_RESOURCE_GROUP string = rg.name
output FUNCTION_APP_NAME string = resources.outputs.functionAppName
output STORAGE_ACCOUNT_NAME string = resources.outputs.storageAccountName
