metadata description = '''
Creates one virtual network for the Secure Request Classifier demo.

Two of these are deployed: a primary network (which hosts the Function App's outbound
integration subnet and the private endpoints) and a failover network (which only needs the
Power Platform delegated subnet). Power Platform requires a delegated subnet in *both* Azure
regions of the Power Platform region pair, because a Power Platform environment can fail over
between them.

Ref: https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-overview
'''

@description('Name of the virtual network.')
param virtualNetworkName string

@description('Azure region for this virtual network.')
param location string

@description('Address space for the virtual network, for example 10.20.0.0/16.')
param addressPrefix string

@description('Address prefix for the subnet delegated to Power Platform.')
param powerPlatformSubnetPrefix string

@description('''
Address prefix for the Function App outbound VNet-integration subnet.
Leave empty on the failover network, which does not host the Function App.
''')
param functionSubnetPrefix string = ''

@description('''
Address prefix for the private endpoint subnet.
Leave empty on the failover network.
''')
param privateEndpointSubnetPrefix string = ''

@description('Resource tags.')
param tags object = {}

// Subnet names must not contain underscores (Azure Functions VNet integration requirement).
var powerPlatformSubnetName = 'snet-powerplatform'
var functionSubnetName = 'snet-functions'
var privateEndpointSubnetName = 'snet-private-endpoints'

var deployFunctionSubnet = !empty(functionSubnetPrefix)
var deployPrivateEndpointSubnet = !empty(privateEndpointSubnetPrefix)

// Azure Landing Zones commonly assign `Deny-Subnet-Without-Nsg`, which refuses to create a
// subnet that has no network security group. Every subnet below therefore gets one.
module powerPlatformNsg 'network-security-group.bicep' = {
  name: '${virtualNetworkName}-nsg-powerplatform'
  params: {
    networkSecurityGroupName: 'nsg-${virtualNetworkName}-powerplatform'
    location: location
    subnetRole: 'powerPlatform'
    virtualNetworkAddressPrefix: addressPrefix
    tags: tags
  }
}

module functionNsg 'network-security-group.bicep' = if (deployFunctionSubnet) {
  name: '${virtualNetworkName}-nsg-functions'
  params: {
    networkSecurityGroupName: 'nsg-${virtualNetworkName}-functions'
    location: location
    subnetRole: 'functions'
    virtualNetworkAddressPrefix: addressPrefix
    tags: tags
  }
}

module privateEndpointNsg 'network-security-group.bicep' = if (deployPrivateEndpointSubnet) {
  name: '${virtualNetworkName}-nsg-private-endpoints'
  params: {
    networkSecurityGroupName: 'nsg-${virtualNetworkName}-private-endpoints'
    location: location
    subnetRole: 'privateEndpoints'
    virtualNetworkAddressPrefix: addressPrefix
    tags: tags
  }
}

// The delegated subnet is dedicated to Power Platform: no other resource, and no other
// delegation, may share it. The delegation name and serviceName are the same string.
var powerPlatformSubnet = {
  name: powerPlatformSubnetName
  properties: {
    addressPrefix: powerPlatformSubnetPrefix
    networkSecurityGroup: {
      id: powerPlatformNsg.outputs.networkSecurityGroupId
    }
    delegations: [
      {
        name: 'Microsoft.PowerPlatform/enterprisePolicies'
        properties: {
          serviceName: 'Microsoft.PowerPlatform/enterprisePolicies'
        }
      }
    ]
    // Power Platform containers must be able to reach the private endpoints in the peered
    // network. The network security group documents that flow explicitly and leaves Azure's
    // default outbound rules in place beneath it.
    privateEndpointNetworkPolicies: 'Enabled'
    privateLinkServiceNetworkPolicies: 'Enabled'
  }
}

// Flex Consumption outbound integration requires delegation to Microsoft.App/environments.
// This is a *different* delegation from the Power Platform one above, which is why the two
// workloads cannot share a subnet.
var functionSubnet = {
  name: functionSubnetName
  properties: {
    addressPrefix: functionSubnetPrefix
    networkSecurityGroup: deployFunctionSubnet ? {
      id: functionNsg!.outputs.networkSecurityGroupId
    } : null
    delegations: [
      {
        name: 'Microsoft.App/environments'
        properties: {
          serviceName: 'Microsoft.App/environments'
        }
      }
    ]
    privateEndpointNetworkPolicies: 'Enabled'
    privateLinkServiceNetworkPolicies: 'Enabled'
  }
}

// Private endpoints cannot live in a delegated subnet, so they get their own.
var privateEndpointSubnet = {
  name: privateEndpointSubnetName
  properties: {
    addressPrefix: privateEndpointSubnetPrefix
    networkSecurityGroup: deployPrivateEndpointSubnet ? {
      id: privateEndpointNsg!.outputs.networkSecurityGroupId
    } : null
    privateEndpointNetworkPolicies: 'Disabled'
    privateLinkServiceNetworkPolicies: 'Disabled'
  }
}

var subnets = concat(
  [powerPlatformSubnet],
  deployFunctionSubnet ? [functionSubnet] : [],
  deployPrivateEndpointSubnet ? [privateEndpointSubnet] : []
)

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: virtualNetworkName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [addressPrefix]
    }
    subnets: subnets
  }
}

@description('Resource ID of the virtual network.')
output virtualNetworkId string = virtualNetwork.id

@description('Name of the virtual network.')
output virtualNetworkName string = virtualNetwork.name

@description('Name of the subnet delegated to Microsoft.PowerPlatform/enterprisePolicies.')
output powerPlatformSubnetName string = powerPlatformSubnetName

@description('Resource ID of the Power Platform delegated subnet.')
output powerPlatformSubnetId string = resourceId(
  'Microsoft.Network/virtualNetworks/subnets',
  virtualNetworkName,
  powerPlatformSubnetName
)

@description('Resource ID of the Function App outbound integration subnet, or empty.')
output functionSubnetId string = deployFunctionSubnet
  ? resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, functionSubnetName)
  : ''

@description('Resource ID of the private endpoint subnet, or empty.')
output privateEndpointSubnetId string = deployPrivateEndpointSubnet
  ? resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, privateEndpointSubnetName)
  : ''
