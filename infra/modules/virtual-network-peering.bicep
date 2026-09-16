metadata description = '''
Peers the primary and failover virtual networks in both directions.

Power Platform containers can run in either region of the Power Platform region pair. Peering
lets a container in the failover network reach the private endpoints that live in the primary
network, so the demo keeps working after a Power Platform regional failover.

Ref: https://learn.microsoft.com/en-us/power-platform/architecture/reference-architectures/secure-access-azure-resources
'''

@description('Name of the primary virtual network (must exist in this resource group).')
param primaryVirtualNetworkName string

@description('Name of the failover virtual network (must exist in this resource group).')
param failoverVirtualNetworkName string

resource primaryVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: primaryVirtualNetworkName
}

resource failoverVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: failoverVirtualNetworkName
}

resource primaryToFailover 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: primaryVirtualNetwork
  name: 'peer-to-${failoverVirtualNetworkName}'
  properties: {
    remoteVirtualNetwork: {
      id: failoverVirtualNetwork.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource failoverToPrimary 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: failoverVirtualNetwork
  name: 'peer-to-${primaryVirtualNetworkName}'
  properties: {
    remoteVirtualNetwork: {
      id: primaryVirtualNetwork.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
  dependsOn: [
    primaryToFailover
  ]
}

@description('Peering state of the primary-to-failover peering.')
output primaryPeeringState string = primaryToFailover.properties.peeringState

@description('Peering state of the failover-to-primary peering.')
output failoverPeeringState string = failoverToPrimary.properties.peeringState
