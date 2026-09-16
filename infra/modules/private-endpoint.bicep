metadata description = '''
Creates a private endpoint and wires it into a workload-owned private DNS zone.

Used for the Function App (groupId `sites`) and for the storage sub-resources the Functions
host needs (`blob`, `queue`, `table`). A private DNS zone group is used so Azure maintains the
A records automatically - including the extra `scm.` record that the `sites` group requires.

Ref: https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns
'''

@description('Name of the private endpoint.')
param privateEndpointName string

@description('Azure region for the private endpoint.')
param location string

@description('Resource ID of the subnet that hosts the private endpoint. Must not be a delegated subnet.')
param subnetId string

@description('Resource ID of the service being exposed privately.')
param privateLinkServiceId string

@description('Private link sub-resource name, for example sites, blob, queue or table.')
param groupId string

@description('''
Resource ID of the private DNS zone for this sub-resource. Leave empty to skip creating a
private DNS zone group - for example when an Azure Landing Zone DeployIfNotExists policy owns
DNS integration centrally.
''')
param privateDnsZoneId string = ''

@description('Resource tags.')
param tags object = {}

var createDnsZoneGroup = !empty(privateDnsZoneId)

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: privateEndpointName
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${privateEndpointName}-connection'
        properties: {
          privateLinkServiceId: privateLinkServiceId
          groupIds: [groupId]
        }
      }
    ]
  }
}

// A private endpoint supports exactly one private DNS zone group, so this is deliberately
// skipped when a platform policy is expected to create its own.
resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (createDnsZoneGroup) {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: replace(replace(last(split(privateDnsZoneId, '/')), '.', '-'), '_', '-')
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

@description('Resource ID of the private endpoint.')
output privateEndpointId string = privateEndpoint.id

@description('Name of the private endpoint.')
output privateEndpointName string = privateEndpoint.name

@description('Approval state of the private link service connection.')
output connectionState string = privateEndpoint.properties.privateLinkServiceConnections[0].properties.privateLinkServiceConnectionState.status
