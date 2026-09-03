targetScope = 'subscription'

// Grants the Cost Sentinel Function's managed identity built-in Cost Management
// Reader at subscription scope - the scope the daily cost query actually runs at.
//
// Originally this assignment sat in resources.bicep scoped to the resource group,
// on a least-privilege instinct. But the tool's one job is a subscription-wide
// query (POST /subscriptions/{id}/providers/Microsoft.CostManagement/query), and an
// RG-scoped cost role does not authorize that - Cost Management returns
// 401 RBACAccessDenied (not 403). Confirmed live on the 2026-09-02 08:00 UTC
// scheduled run, the one that got past the API's aggressive 429 throttle.
//
// This stays the identity's ONLY role assignment. Cost Management Reader is
// read-only for cost/billing data and grants nothing on any resource in the
// subscription, so the blast radius of the widened scope is a cost report, not
// resource access.
//
// Split into its own module (not inlined in the subscription-scoped main.bicep)
// because a roleAssignment's guid() name must be resolvable at the start of
// deployment: it can be built from a module PARAMETER but not from another
// module's OUTPUT, and the principal id is an output of the resources module.

@description('Object (principal) ID of the Function App system-assigned managed identity.')
param functionAppPrincipalId string

@description('Built-in "Cost Management Reader" role definition ID.')
param costManagementReaderRoleId string

resource costManagementReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, functionAppPrincipalId, costManagementReaderRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', costManagementReaderRoleId)
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}
