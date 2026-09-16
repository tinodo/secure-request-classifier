metadata description = '''
Creates one workload-owned Azure Private DNS zone and links it to every virtual network in the
demo.

The demo deliberately creates its own zones instead of reusing hub/platform zones, because it
must be deployable as a fully isolated workload. Linking the zone to BOTH virtual networks is
mandatory: the Power Platform delegated subnet resolves names using the DNS configured on the
virtual network it runs in, so a zone linked only to the primary network would resolve to a
public IP address after a Power Platform regional failover.

Ref: https://learn.microsoft.com/en-us/troubleshoot/power-platform/administration/virtual-network
'''

@description('Private DNS zone name, for example privatelink.azurewebsites.net.')
param zoneName string

@description('Resource IDs of the virtual networks to link the zone to.')
param virtualNetworkIds string[]

@description('Resource tags.')
param tags object = {}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: zoneName
  // Private DNS zones are global resources.
  location: 'global'
  tags: tags
}

resource virtualNetworkLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (virtualNetworkId, index) in virtualNetworkIds: {
    parent: privateDnsZone
    name: 'link-${last(split(virtualNetworkId, '/'))}'
    location: 'global'
    tags: tags
    properties: {
      virtualNetwork: {
        id: virtualNetworkId
      }
      // The demo never needs Azure to auto-register VM records in these zones.
      registrationEnabled: false
    }
  }
]

@description('Resource ID of the private DNS zone.')
output privateDnsZoneId string = privateDnsZone.id

@description('Name of the private DNS zone.')
output privateDnsZoneName string = privateDnsZone.name
