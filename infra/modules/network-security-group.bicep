metadata description = '''
Network security group for one subnet in the demo.

Azure Landing Zones commonly assign the `Deny-Subnet-Without-Nsg` policy, which refuses to
create any subnet that has no network security group attached. Attaching one is therefore a
hard requirement in a governed subscription, not an optional hardening step.

The rules here are deliberately explicit rather than restrictive. Azure's default rules already
permit intra-virtual-network traffic and outbound internet access, and Power Platform states
that containers in a delegated subnet need outbound connectivity. Adding a blanket deny would
break the demo in a way that is tedious to diagnose. These rules document the flows the demo
actually uses and leave the platform defaults in place beneath them.

Ref: https://learn.microsoft.com/en-us/power-platform/admin/virtual-network-support-whitepaper
     (network security groups on the delegated subnet are a supported, customer-owned control)
'''

@description('Name of the network security group.')
param networkSecurityGroupName string

@description('Azure region.')
param location string

@description('''
Workload role of the subnet this group protects. Determines which documented flows are made
explicit: powerPlatform, functions or privateEndpoints.
''')
@allowed(['powerPlatform', 'functions', 'privateEndpoints'])
param subnetRole string

@description('Address prefix of the virtual network, used to scope the private endpoint rules.')
param virtualNetworkAddressPrefix string

@description('Resource tags.')
param tags object = {}

// Traffic the Power Platform connector containers generate: HTTPS to the private endpoints
// (reached across the peering) and HTTPS to Power Platform's own control plane.
var powerPlatformRules = [
  {
    name: 'Allow-Https-To-PrivateEndpoints'
    properties: {
      description: 'Connector containers call the Function App private endpoint over HTTPS.'
      protocol: 'Tcp'
      sourcePortRange: '*'
      destinationPortRange: '443'
      sourceAddressPrefix: 'VirtualNetwork'
      destinationAddressPrefix: 'VirtualNetwork'
      access: 'Allow'
      priority: 100
      direction: 'Outbound'
    }
  }
  {
    name: 'Allow-Https-To-AzureCloud'
    properties: {
      description: 'Power Platform containers require outbound access to the service control plane.'
      protocol: 'Tcp'
      sourcePortRange: '*'
      destinationPortRange: '443'
      sourceAddressPrefix: 'VirtualNetwork'
      destinationAddressPrefix: 'AzureCloud'
      access: 'Allow'
      priority: 110
      direction: 'Outbound'
    }
  }
]

// The Function App's outbound virtual network integration: storage over private endpoints,
// plus Azure Monitor ingestion.
var functionRules = [
  {
    name: 'Allow-Https-To-PrivateEndpoints'
    properties: {
      description: 'Functions host reaches blob, queue and table storage over private endpoints.'
      protocol: 'Tcp'
      sourcePortRange: '*'
      destinationPortRange: '443'
      sourceAddressPrefix: 'VirtualNetwork'
      destinationAddressPrefix: 'VirtualNetwork'
      access: 'Allow'
      priority: 100
      direction: 'Outbound'
    }
  }
  {
    name: 'Allow-Https-To-AzureCloud'
    properties: {
      description: 'Telemetry to Azure Monitor and platform calls made by the Functions host.'
      protocol: 'Tcp'
      sourcePortRange: '*'
      destinationPortRange: '443'
      sourceAddressPrefix: 'VirtualNetwork'
      destinationAddressPrefix: 'AzureCloud'
      access: 'Allow'
      priority: 110
      direction: 'Outbound'
    }
  }
]

// Private endpoints only ever receive HTTPS, and only from inside the network.
var privateEndpointRules = [
  {
    name: 'Allow-Https-From-VirtualNetwork'
    properties: {
      description: 'Private endpoints accept HTTPS from the delegated and integration subnets.'
      protocol: 'Tcp'
      sourcePortRange: '*'
      destinationPortRange: '443'
      sourceAddressPrefix: virtualNetworkAddressPrefix
      destinationAddressPrefix: 'VirtualNetwork'
      access: 'Allow'
      priority: 100
      direction: 'Inbound'
    }
  }
]

var rulesByRole = {
  powerPlatform: powerPlatformRules
  functions: functionRules
  privateEndpoints: privateEndpointRules
}

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: networkSecurityGroupName
  location: location
  tags: tags
  properties: {
    securityRules: rulesByRole[subnetRole]
  }
}

@description('Resource ID of the network security group.')
output networkSecurityGroupId string = networkSecurityGroup.id

@description('Name of the network security group.')
output networkSecurityGroupName string = networkSecurityGroup.name
