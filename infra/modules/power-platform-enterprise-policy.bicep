metadata description = '''
The Power Platform enterprise policy that carries the network-injection (subnet delegation)
configuration, plus the Reader grant that a Power Platform administrator needs in order to
see and link the policy.

Creating this resource does NOT link it to a Power Platform environment. Linking is a
Power Platform control-plane operation performed by
`Microsoft.PowerPlatform.EnterprisePolicies\\Enable-SubnetInjection` (or the equivalent BAP
REST call) - see scripts/Set-PowerPlatformSubnetInjection.ps1 and docs/networking-model.md.

Ref: https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-setup-configure
'''

@description('Name of the enterprise policy resource.')
param enterprisePolicyName string

@description('''
Power Platform *geography* name, NOT an Azure region. For example: europe, unitedstates, uk,
australia, canada, india, japan, asia, brazil, france, germany, korea, norway, singapore,
southafrica, sweden, switzerland, uae, italy, usgov.
''')
param powerPlatformRegion string

@description('Resource ID of the primary virtual network.')
param primaryVirtualNetworkId string

@description('Name of the delegated subnet in the primary virtual network.')
param primarySubnetName string

@description('Resource ID of the failover virtual network. Empty for single-region geographies.')
param failoverVirtualNetworkId string = ''

@description('Name of the delegated subnet in the failover virtual network.')
param failoverSubnetName string = ''

@description('''
Object IDs of Power Platform administrators who must be able to link this policy to an
environment. Microsoft requires the Reader role on the enterprise policy resource for this.
''')
param readerPrincipalIds string[] = []

@description('Resource tags.')
param tags object = {}

var readerRoleDefinitionId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

var primaryNetwork = {
  id: primaryVirtualNetworkId
  subnet: {
    name: primarySubnetName
  }
}

var failoverNetwork = {
  id: failoverVirtualNetworkId
  subnet: {
    name: failoverSubnetName
  }
}

var hasFailoverNetwork = !empty(failoverVirtualNetworkId) && !empty(failoverSubnetName)

resource enterprisePolicy 'Microsoft.PowerPlatform/enterprisePolicies@2020-10-30-preview' = {
  name: enterprisePolicyName
  location: powerPlatformRegion
  kind: 'NetworkInjection'
  tags: tags
  properties: {
    networkInjection: {
      virtualNetworks: hasFailoverNetwork ? [primaryNetwork, failoverNetwork] : [primaryNetwork]
    }
  }
}

// Microsoft: "the admin ... is required to grant the Reader role to the Power Platform admin.
// Once the Reader role is granted, the Power Platform administrator is able to view the
// enterprise policies on the Power Platform admin center."
resource readerAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in readerPrincipalIds: {
    name: guid(enterprisePolicy.id, principalId, readerRoleDefinitionId)
    scope: enterprisePolicy
    properties: {
      principalId: principalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleDefinitionId)
    }
  }
]

@description('Resource ID (ARM ID) of the enterprise policy. Needed by Enable-SubnetInjection.')
output enterprisePolicyId string = enterprisePolicy.id

@description('Name of the enterprise policy.')
output enterprisePolicyName string = enterprisePolicy.name

@description('''
Power Platform systemId of the policy. This - not the ARM ID - is what the Power Platform
control plane expects in the link request body.
''')
output enterprisePolicySystemId string = enterprisePolicy.properties.systemId
