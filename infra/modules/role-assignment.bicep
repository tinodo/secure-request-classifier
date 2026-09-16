metadata description = '''
Assigns a built-in Azure role to a principal at the scope of this resource group.

Kept as a module so that main.bicep declares every role assignment in one readable list, and
so the demo can state exactly which least-privilege roles it grants and why.
'''

@description('Object (principal) ID that receives the role.')
param principalId string

@description('Built-in role definition GUID.')
param roleDefinitionId string

@description('Principal type. ServicePrincipal covers managed identities and app registrations.')
@allowed(['ServicePrincipal', 'User', 'Group'])
param principalType string = 'ServicePrincipal'

@description('Resource ID of the resource to scope the assignment to. Defaults to the resource group.')
param scopeResourceId string = ''

@description('A stable string that makes the assignment name deterministic and idempotent.')
param assignmentSeed string

var scopeId = empty(scopeResourceId) ? resourceGroup().id : scopeResourceId

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(scopeId, principalId, roleDefinitionId, assignmentSeed)
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
  }
}

@description('Resource ID of the role assignment.')
output roleAssignmentId string = roleAssignment.id
