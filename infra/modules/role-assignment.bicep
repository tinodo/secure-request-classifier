metadata description = '''
Assigns a built-in Azure role to a principal, scoped to a single resource.

Kept as a module so that main.bicep declares every role assignment in one readable list, and
so the demo can state exactly which least-privilege roles it grants and why.

The target is named rather than passed as a resource ID. A role assignment is an extension
resource, so it has to be attached to the resource it applies to with `scope:`, and `scope:`
takes a resource reference, not a string. Accepting a resource ID and only feeding it to
`guid()` is what this module used to do, and every assignment silently landed on the resource
group instead -- broader than intended, while the template still read as least privilege.
'''

@description('Object (principal) ID that receives the role.')
param principalId string

@description('Built-in role definition GUID.')
param roleDefinitionId string

@description('Principal type. ServicePrincipal covers managed identities and app registrations.')
@allowed(['ServicePrincipal', 'User', 'Group'])
param principalType string = 'ServicePrincipal'

@description('Which kind of resource the assignment is scoped to.')
@allowed(['storageAccount', 'applicationInsights'])
param targetKind string

@description('Name of the resource, in this resource group, that the assignment is scoped to.')
param targetName string

@description('A stable string that makes the assignment name deterministic and idempotent.')
param assignmentSeed string

resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' existing = if (targetKind == 'storageAccount') {
  name: targetName
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' existing = if (targetKind == 'applicationInsights') {
  name: targetName
}

// One resource per target type, because scope: has to name a concrete resource. The role
// assignment name stays keyed on the target so the two branches cannot collide, and so the
// name is stable across redeployments.

resource storageAccountRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (targetKind == 'storageAccount') {
  scope: storageAccount
  name: guid(resourceGroup().id, targetName, principalId, roleDefinitionId, assignmentSeed)
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
  }
}

resource applicationInsightsRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (targetKind == 'applicationInsights') {
  scope: applicationInsights
  name: guid(resourceGroup().id, targetName, principalId, roleDefinitionId, assignmentSeed)
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
  }
}
