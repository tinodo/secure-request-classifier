metadata description = '''
Log Analytics workspace and workspace-based Application Insights for the demo.

Local (instrumentation key / API key) authentication is disabled on both resources, so the
only way to publish telemetry is with a Microsoft Entra ID token from a managed identity.
That is what lets the Function App report telemetry without any secret in configuration.

Ref: https://learn.microsoft.com/en-us/azure/azure-monitor/app/azure-ad-authentication
'''

@description('Name of the Log Analytics workspace.')
param logAnalyticsWorkspaceName string

@description('Name of the Application Insights component.')
param applicationInsightsName string

@description('Azure region.')
param location string

@description('Retention in days for the workspace.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

@description('Daily ingestion cap in GB. -1 means no cap. A small cap keeps demo cost predictable.')
param dailyQuotaGb int = 1

@description('Resource tags.')
param tags object = {}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaGb
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    features: {
      // Require Microsoft Entra ID authentication for data ingestion.
      disableLocalAuth: true
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: applicationInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
    IngestionMode: 'LogAnalytics'
    // No instrumentation key or connection-string secret is usable on its own: the Function
    // App must present a managed-identity token (APPLICATIONINSIGHTS_AUTHENTICATION_STRING).
    DisableLocalAuth: true
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

@description('Resource ID of the Log Analytics workspace.')
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id

@description('Customer ID (workspace ID) of the Log Analytics workspace.')
output logAnalyticsCustomerId string = logAnalyticsWorkspace.properties.customerId

@description('Resource ID of the Application Insights component.')
output applicationInsightsId string = applicationInsights.id

@description('Application Insights connection string. Contains no secret: local auth is disabled.')
output applicationInsightsConnectionString string = applicationInsights.properties.ConnectionString

@description('Name of the Application Insights component.')
output applicationInsightsName string = applicationInsights.name
