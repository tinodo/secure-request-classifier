metadata description = '''
Storage account for the Azure Functions host and for the Flex Consumption deployment package.

Hardened for the demo's "no keys, no SAS" requirement:
  * `allowSharedKeyAccess: false`  - the account keys are not usable at all, so neither the
    Functions host nor any pipeline can fall back to a connection string or build a SAS.
  * `publicNetworkAccess: Disabled` with private endpoints for blob, queue and table.
  * `defaultToOAuthAuthentication: true` - Microsoft Entra ID is the only authentication path.

The Functions host reaches this account over the private endpoints via the Function App's
outbound virtual network integration, authenticating with its managed identity.

Ref: https://learn.microsoft.com/en-us/azure/azure-functions/manage-connections?pivots=functions-auth-identity
'''

@description('Name of the storage account.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Azure region.')
param location string

@description('Name of the blob container that holds the Flex Consumption deployment package.')
param deploymentContainerName string = 'function-releases'

@description('Public network access for the storage account.')
@allowed(['Enabled', 'Disabled'])
param publicNetworkAccess string = 'Disabled'

@description('Resource tags.')
param tags object = {}

resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    // Disabling shared-key access is what makes "no storage account keys, no SAS tokens"
    // an enforced property of the deployment rather than a convention.
    allowSharedKeyAccess: false
    allowBlobPublicAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: publicNetworkAccess
    dnsEndpointType: 'Standard'
    allowCrossTenantReplication: false
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: publicNetworkAccess == 'Disabled' ? 'Deny' : 'Allow'
      virtualNetworkRules: []
      ipRules: []
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

// The Flex Consumption plan requires this container to exist before the site is created.
resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobService
  name: deploymentContainerName
  properties: {
    publicAccess: 'None'
  }
}

@description('Resource ID of the storage account.')
output storageAccountId string = storageAccount.id

@description('Name of the storage account.')
output storageAccountName string = storageAccount.name

@description('Primary blob endpoint, for example https://account.blob.core.windows.net/.')
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob

@description('Primary queue endpoint.')
output queueEndpoint string = storageAccount.properties.primaryEndpoints.queue

@description('Primary table endpoint.')
output tableEndpoint string = storageAccount.properties.primaryEndpoints.table

@description('Name of the deployment package container.')
output deploymentContainerName string = deploymentContainer.name

@description('Full URL of the deployment package container.')
output deploymentContainerUrl string = '${storageAccount.properties.primaryEndpoints.blob}${deploymentContainerName}'
