metadata description = '''
The Azure Function App: a Flex Consumption plan running the .NET 10 isolated worker.

Security posture expressed here:
  * `publicNetworkAccess` defaults to Disabled - the app is reachable only through its
    private endpoint. Note this also disables the SCM/Kudu deployment endpoint; see
    docs/deployment.md for how code is deployed.
  * Outbound traffic is integrated into the virtual network so the app can reach the private
    endpoints of its storage account.
  * Identity-based connections only: no `AzureWebJobsStorage` connection string, no
    instrumentation key, no Function keys used for application authentication.
  * App Service Authentication (Easy Auth) validates Microsoft Entra ID tokens in front of the
    worker, so the HTTP triggers can safely use AuthorizationLevel.Anonymous.

Ref: https://learn.microsoft.com/en-us/azure/azure-functions/functions-infrastructure-as-code?pivots=flex-consumption-plan
'''

@description('Name of the Function App.')
param functionAppName string

@description('Name of the Flex Consumption plan.')
param hostingPlanName string

@description('Azure region.')
param location string

@description('Name of the storage account used for host storage and deployment packages.')
param storageAccountName string

@description('Blob container URL that holds the deployment package.')
param deploymentContainerUrl string

@description('Application Insights connection string.')
param applicationInsightsConnectionString string

@description('Resource ID of the subnet used for outbound virtual network integration.')
param functionSubnetId string

@description('Public network access for the Function App.')
@allowed(['Enabled', 'Disabled'])
param publicNetworkAccess string = 'Disabled'

@description('Maximum number of Flex Consumption instances.')
@minValue(1)
@maxValue(1000)
param maximumInstanceCount int = 40

@description('Instance memory in MB.')
@allowed([512, 2048, 4096])
param instanceMemoryMB int = 2048

@description('''
Application (client) ID of the Microsoft Entra ID app registration that represents this API.
Required, with no default: an empty value used to silently skip the authsettingsV2 resource
below and deploy the API unauthenticated. See the same parameter in main.bicep.
''')
@minLength(36)
param apiApplicationId string

@description('Tenant ID used to build the OpenID Connect issuer for token validation.')
param tenantId string = tenant().tenantId

@description('''
Application (client) IDs allowed to call this API. Evaluated by App Service Authentication
against the token's azp/appid claim. Normally the Microsoft Entra ID application behind the
"HTTP with Microsoft Entra ID (preauthorized)" connector.
''')
param allowedClientApplicationIds string[] = []

@description('''
Paths excluded from authentication. /api/health stays open so a probe from inside the virtual
network can prove network reachability independently of authentication.
''')
param authExcludedPaths string[] = ['/api/health']

@description('Business-day start hour (UTC) used by the classifier.')
param businessDayStartUtcHour int = 9

@description('Business-day end hour (UTC) used by the classifier.')
param businessDayEndUtcHour int = 17

@description('Resource tags.')
param tags object = {}

resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageAccountName
}

resource hostingPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: hostingPlanName
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    // Flex Consumption is Linux only.
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: hostingPlan.id
    httpsOnly: true
    publicNetworkAccess: publicNetworkAccess
    virtualNetworkSubnetId: functionSubnetId
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      http20Enabled: true
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: deploymentContainerUrl
          authentication: {
            // No connection string: the platform uses the app's own managed identity.
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: maximumInstanceCount
        instanceMemoryMB: instanceMemoryMB
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10.0'
      }
    }
  }
}

// Basic-auth publishing credentials are the classic way a "no secrets" claim quietly breaks.
// Disabling both removes the FTP and SCM username/password surface entirely.
resource disableScmBasicAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: functionApp
  name: 'scm'
  properties: {
    allow: false
  }
}

resource disableFtpBasicAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: functionApp
  name: 'ftp'
  properties: {
    allow: false
  }
}

resource appSettings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: functionApp
  name: 'appsettings'
  properties: {
    // Identity-based host storage. Note AzureWebJobsStorage__accountName is a special syntax
    // that only applies to AzureWebJobsStorage.
    AzureWebJobsStorage__accountName: storageAccount.name
    AzureWebJobsStorage__blobServiceUri: storageAccount.properties.primaryEndpoints.blob
    AzureWebJobsStorage__queueServiceUri: storageAccount.properties.primaryEndpoints.queue
    AzureWebJobsStorage__tableServiceUri: storageAccount.properties.primaryEndpoints.table
    AzureWebJobsStorage__credential: 'managedidentity'

    APPLICATIONINSIGHTS_CONNECTION_STRING: applicationInsightsConnectionString
    // Local auth is disabled on the Application Insights component, so telemetry is only
    // accepted when presented with a Microsoft Entra ID token from the managed identity.
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD'

    Classifier__BusinessDayStartUtcHour: string(businessDayStartUtcHour)
    Classifier__BusinessDayEndUtcHour: string(businessDayEndUtcHour)
    Classifier__ServiceName: 'Secure Request Classifier'
    Classifier__AllowedClientAppIds: join(allowedClientApplicationIds, ',')
  }
}

// App Service Authentication configured as a pure token validator: there is no
// clientSecretSettingName, because no sign-in flow is ever initiated by the API itself.
//
// Deliberately NOT conditional. This used to be `if (configureAuthentication)`, where
// configureAuthentication was `!empty(apiApplicationId)` and apiApplicationId defaulted to ''.
// One unset secret therefore deployed a Function App with authentication switched off entirely,
// leaving network isolation as the only control. Authentication is now unconditional, so the
// worst an empty value can do is fail the deployment.
resource authSettings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: functionApp
  name: 'authsettingsV2'
  properties: {
    platform: {
      enabled: true
      runtimeVersion: '~1'
    }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
      excludedPaths: authExcludedPaths
    }
    httpSettings: {
      requireHttps: true
      routes: {
        apiPrefix: '/.auth'
      }
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: apiApplicationId
          openIdIssuer: '${environment().authentication.loginEndpoint}${tenantId}/v2.0'
        }
        validation: {
          // A v2.0 token for scope api://<appId>/.default carries aud = api://<appId>;
          // some configurations issue aud = <appId>. Accept both to avoid a confusing 401.
          allowedAudiences: [
            'api://${apiApplicationId}'
            apiApplicationId
          ]
          defaultAuthorizationPolicy: {
            allowedApplications: allowedClientApplicationIds
          }
        }
      }
    }
    login: {
      // A machine-to-machine API has no session to store.
      tokenStore: {
        enabled: false
      }
    }
  }
  dependsOn: [
    appSettings
  ]
}

@description('Resource ID of the Function App.')
output functionAppId string = functionApp.id

@description('Name of the Function App.')
output functionAppName string = functionApp.name

@description('Default host name of the Function App.')
output functionAppHostName string = functionApp.properties.defaultHostName

@description('Base URL of the Function App.')
output functionAppBaseUrl string = 'https://${functionApp.properties.defaultHostName}'

@description('Principal ID of the Function App system-assigned managed identity.')
output principalId string = functionApp.identity.principalId

@description('Resource ID of the Flex Consumption plan.')
output hostingPlanId string = hostingPlan.id
