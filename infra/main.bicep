targetScope = 'subscription'

metadata description = '''
Secure Request Classifier - complete, isolated demo workload.

Deploys everything the demo needs into a single resource group so that cleanup is a single,
safe `az group delete`. Nothing here reuses hub networking, shared private DNS zones, existing
route tables or any other pre-existing resource.

Runtime path proven by this template:
  Power App -> Power Automate -> Power Platform delegated subnet -> VNet peering ->
  private endpoint -> Azure Function (public network access disabled)

Ref: https://learn.microsoft.com/en-us/power-platform/architecture/reference-architectures/secure-access-azure-resources
'''

// ---------------------------------------------------------------------------------------------
// Naming and placement
// ---------------------------------------------------------------------------------------------

@description('Short name for the workload. Used to build every resource name.')
@minLength(3)
@maxLength(12)
param workloadName string = 'srclass'

@description('Environment moniker, for example demo, dev or test.')
@minLength(2)
@maxLength(8)
param environmentName string = 'demo'

@description('Name of the resource group that will contain the entire demo.')
param resourceGroupName string = 'rg-${workloadName}-${environmentName}'

@description('''
Power Platform *geography* of the target Power Platform environment. This is not an Azure
region. Run `Get-EnvironmentRegion` (Microsoft.PowerPlatform.EnterprisePolicies) or check the
Power Platform admin center if you are unsure.
''')
@allowed([
  'unitedstates'
  'europe'
  'uk'
  'asia'
  'australia'
  'japan'
  'india'
  'canada'
  'southamerica'
  'france'
  'germany'
  'switzerland'
  'unitedarabemirates'
  'southafrica'
  'korea'
  'norway'
  'singapore'
  'sweden'
  'italy'
])
param powerPlatformRegion string = 'europe'

@description('''
Primary Azure region. Leave empty to use the first region of the documented Azure region pair
for `powerPlatformRegion`.
''')
param primaryLocation string = ''

@description('''
Failover Azure region. Leave empty to use the second region of the documented Azure region
pair. Power Platform requires a delegated subnet in BOTH regions of a paired geography.
''')
param failoverLocation string = ''

// ---------------------------------------------------------------------------------------------
// Networking
// ---------------------------------------------------------------------------------------------

@description('Address space of the primary virtual network.')
param primaryVnetAddressPrefix string = '10.60.0.0/16'

@description('Address prefix of the Power Platform delegated subnet in the primary network.')
param primaryPowerPlatformSubnetPrefix string = '10.60.0.0/24'

@description('Address prefix of the Function App outbound integration subnet. Minimum /27.')
param functionSubnetPrefix string = '10.60.1.0/26'

@description('Address prefix of the private endpoint subnet.')
param privateEndpointSubnetPrefix string = '10.60.2.0/27'

@description('Address space of the failover virtual network.')
param failoverVnetAddressPrefix string = '10.61.0.0/16'

@description('Address prefix of the Power Platform delegated subnet in the failover network.')
param failoverPowerPlatformSubnetPrefix string = '10.61.0.0/24'

@description('''
Create private DNS zone groups on the private endpoints.

Set to false when the subscription is governed by an Azure Landing Zone DeployIfNotExists
policy that manages DNS integration centrally ("Configure Azure PaaS services to use private
DNS zones"). Microsoft's guidance is that you should not integrate DNS in your own code when
that policy is in force.

Ref: https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/private-link-and-dns-integration-at-scale
''')
param createPrivateDnsZoneGroups bool = true

@description('Create the workload-owned private DNS zones. Set to false to reuse zones an ALZ policy manages.')
param createPrivateDnsZones bool = true

// ---------------------------------------------------------------------------------------------
// Function App
// ---------------------------------------------------------------------------------------------

@description('''
Public network access for the Function App. The demo is designed to run with this Disabled.
It is exposed as a parameter only so the deployment workflow can prove the transition.
''')
@allowed(['Enabled', 'Disabled'])
param functionAppPublicNetworkAccess string = 'Disabled'

@description('Public network access for the storage account.')
@allowed(['Enabled', 'Disabled'])
param storagePublicNetworkAccess string = 'Disabled'

@description('''
Application (client) ID of the Microsoft Entra ID app registration that represents the
Function App API. Created by scripts/Initialize-EntraResources.ps1.

Required, and deliberately has no empty default. It used to default to '', which switched off
the whole authsettingsV2 resource: omit one secret and the classify endpoint deployed reachable
by any caller, with only network isolation left. The bootstrap always creates this app
registration before the first deployment, so there is no case where an empty value is correct.
''')
@minLength(36)
param apiApplicationId string

@description('''
Application (client) ID of the Microsoft Entra ID application used by the "HTTP with Microsoft
Entra ID (preauthorized)" connector. Microsoft publishes this value in
microsoft/PowerApps-Samples/powershell/connectors/HTTPWithMicrosoftEntraId/ManagePermissionGrant.ps1
as `$HttpWithAADAppAppId`.
''')
param httpWithEntraIdConnectorAppId string = 'd2ebd3a9-1ada-4480-8b2d-eac162716601'

@description('Additional application (client) IDs permitted to call the Function App.')
param additionalAllowedClientAppIds string[] = []

@description('Business-day start hour, UTC, used to compute the response target.')
@minValue(0)
@maxValue(23)
param businessDayStartUtcHour int = 9

@description('Business-day end hour, UTC, used to compute the response target.')
@minValue(1)
@maxValue(24)
param businessDayEndUtcHour int = 17

// ---------------------------------------------------------------------------------------------
// Power Platform enterprise policy
// ---------------------------------------------------------------------------------------------

@description('Create the Power Platform network-injection enterprise policy.')
param deployEnterprisePolicy bool = true

@description('''
Set to true when the enterprise policy already exists AND is linked to an environment. Power
Platform refuses any write to a linked policy with EnterprisePolicyUpdateNotAllowed, so a second
deployment would fail even when nothing about the policy changed. The deploy workflow detects
this and sets the flag, which skips the policy write while leaving everything else idempotent.
To genuinely change the policy, unlink the environment first.
''')
param enterprisePolicyIsLinked bool = false

@description('''
Object IDs of the Power Platform administrators (users or service principals) that must be
able to link the enterprise policy to an environment. Microsoft requires Reader on the policy
resource for this.
''')
param enterprisePolicyReaderPrincipalIds string[] = []

// ---------------------------------------------------------------------------------------------
// Misc
// ---------------------------------------------------------------------------------------------

@description('Tags applied to every resource. Landing zones frequently require specific tags.')
param tags object = {}

// =============================================================================================
// Region pair resolution
// =============================================================================================

// Documented mapping of Power Platform geography -> Azure region pair.
// Ref: https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-overview
var regionPairs = {
  unitedstates: ['eastus', 'westus']
  europe: ['westeurope', 'northeurope']
  uk: ['uksouth', 'ukwest']
  asia: ['eastasia', 'southeastasia']
  australia: ['australiasoutheast', 'australiaeast']
  japan: ['japaneast', 'japanwest']
  india: ['centralindia', 'southindia']
  canada: ['canadacentral', 'canadaeast']
  southamerica: ['brazilsouth', '']
  france: ['francecentral', 'francesouth']
  germany: ['germanynorth', 'germanywestcentral']
  switzerland: ['switzerlandnorth', 'switzerlandwest']
  unitedarabemirates: ['uaenorth', '']
  southafrica: ['southafricanorth', 'southafricawest']
  korea: ['koreasouth', 'koreacentral']
  norway: ['norwaywest', 'norwayeast']
  singapore: ['southeastasia', '']
  sweden: ['swedencentral', '']
  italy: ['italynorth', '']
}

// The enterprise policy `location` uses Power Platform geography names, which differ from the
// Power Platform environment `location` for a handful of geographies.
var enterprisePolicyLocationAliases = {
  uk: 'uk'
  unitedarabemirates: 'uae'
  southamerica: 'brazil'
}

var resolvedPrimaryLocation = empty(primaryLocation) ? regionPairs[powerPlatformRegion][0] : primaryLocation
var resolvedFailoverLocation = empty(failoverLocation) ? regionPairs[powerPlatformRegion][1] : failoverLocation
var deployFailoverNetwork = !empty(resolvedFailoverLocation)

var enterprisePolicyLocation = enterprisePolicyLocationAliases[?powerPlatformRegion] ?? powerPlatformRegion

// =============================================================================================
// Names
// =============================================================================================

var uniqueSuffix = substring(uniqueString(subscription().subscriptionId, resourceGroupName), 0, 6)
var baseName = '${workloadName}-${environmentName}'

var names = {
  primaryVnet: 'vnet-${baseName}-primary'
  failoverVnet: 'vnet-${baseName}-failover'
  storageAccount: toLower('st${replace(workloadName, '-', '')}${environmentName}${uniqueSuffix}')
  logAnalytics: 'log-${baseName}'
  applicationInsights: 'appi-${baseName}'
  hostingPlan: 'plan-${baseName}'
  functionApp: 'func-${baseName}-${uniqueSuffix}'
  enterprisePolicy: 'ep-${baseName}-netinjection'
  functionPrivateEndpoint: 'pe-func-${baseName}'
  blobPrivateEndpoint: 'pe-blob-${baseName}'
  queuePrivateEndpoint: 'pe-queue-${baseName}'
  tablePrivateEndpoint: 'pe-table-${baseName}'
}

// Order matters: the private endpoints below select their zone from this list. Do NOT iterate an
// object with items() to build that list — items() sorts by key ALPHABETICALLY, not in
// declaration order, which silently attaches each private endpoint to the wrong zone.
var dnsZoneKeys = [
  'sites'
  'blob'
  'queue'
  'table'
]

var dnsZoneNames = {
  sites: 'privatelink.azurewebsites.net'
  blob: 'privatelink.blob.${environment().suffixes.storage}'
  queue: 'privatelink.queue.${environment().suffixes.storage}'
  table: 'privatelink.table.${environment().suffixes.storage}'
}

// Built-in role definition GUIDs.
var roles = {
  storageBlobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  storageQueueDataContributor: '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  storageTableDataContributor: '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
  monitoringMetricsPublisher: '3913510d-42f4-4e42-8a64-420c390055eb'
}

var allAllowedClientAppIds = union([httpWithEntraIdConnectorAppId], additionalAllowedClientAppIds)

var defaultTags = {
  workload: 'secure-request-classifier'
  environment: environmentName
  managedBy: 'bicep'
  demo: 'power-platform-private-azure'
}

var allTags = union(defaultTags, tags)

// =============================================================================================
// Resource group
// =============================================================================================

resource resourceGroupResource 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: resourceGroupName
  location: resolvedPrimaryLocation
  tags: allTags
}

// =============================================================================================
// Networking
// =============================================================================================

module primaryNetwork 'modules/virtual-network.bicep' = {
  scope: resourceGroupResource
  name: 'primary-network'
  params: {
    virtualNetworkName: names.primaryVnet
    location: resolvedPrimaryLocation
    addressPrefix: primaryVnetAddressPrefix
    powerPlatformSubnetPrefix: primaryPowerPlatformSubnetPrefix
    functionSubnetPrefix: functionSubnetPrefix
    privateEndpointSubnetPrefix: privateEndpointSubnetPrefix
    tags: allTags
  }
}

module failoverNetwork 'modules/virtual-network.bicep' = if (deployFailoverNetwork) {
  scope: resourceGroupResource
  name: 'failover-network'
  params: {
    virtualNetworkName: names.failoverVnet
    location: resolvedFailoverLocation
    addressPrefix: failoverVnetAddressPrefix
    powerPlatformSubnetPrefix: failoverPowerPlatformSubnetPrefix
    tags: allTags
  }
}

module networkPeering 'modules/virtual-network-peering.bicep' = if (deployFailoverNetwork) {
  scope: resourceGroupResource
  name: 'network-peering'
  params: {
    primaryVirtualNetworkName: names.primaryVnet
    failoverVirtualNetworkName: names.failoverVnet
  }
  dependsOn: [
    primaryNetwork
    failoverNetwork
  ]
}

var linkedVirtualNetworkIds = deployFailoverNetwork
  ? [primaryNetwork.outputs.virtualNetworkId, failoverNetwork!.outputs.virtualNetworkId]
  : [primaryNetwork.outputs.virtualNetworkId]

module privateDnsZones 'modules/private-dns-zone.bicep' = [
  for zoneKey in dnsZoneKeys: if (createPrivateDnsZones) {
    scope: resourceGroupResource
    name: 'dns-${zoneKey}'
    params: {
      zoneName: dnsZoneNames[zoneKey]
      virtualNetworkIds: linkedVirtualNetworkIds
      tags: allTags
    }
  }
]

// =============================================================================================
// Monitoring
// =============================================================================================

module monitoring 'modules/monitoring.bicep' = {
  scope: resourceGroupResource
  name: 'monitoring'
  params: {
    logAnalyticsWorkspaceName: names.logAnalytics
    applicationInsightsName: names.applicationInsights
    location: resolvedPrimaryLocation
    tags: allTags
  }
}

// =============================================================================================
// Storage
// =============================================================================================

module storage 'modules/storage.bicep' = {
  scope: resourceGroupResource
  name: 'storage'
  params: {
    storageAccountName: names.storageAccount
    location: resolvedPrimaryLocation
    publicNetworkAccess: storagePublicNetworkAccess
    tags: allTags
  }
}

// =============================================================================================
// Function App
// =============================================================================================

module functionApp 'modules/function-app.bicep' = {
  scope: resourceGroupResource
  name: 'function-app'
  params: {
    functionAppName: names.functionApp
    hostingPlanName: names.hostingPlan
    location: resolvedPrimaryLocation
    storageAccountName: storage.outputs.storageAccountName
    deploymentContainerUrl: storage.outputs.deploymentContainerUrl
    applicationInsightsConnectionString: monitoring.outputs.applicationInsightsConnectionString
    functionSubnetId: primaryNetwork.outputs.functionSubnetId
    publicNetworkAccess: functionAppPublicNetworkAccess
    apiApplicationId: apiApplicationId
    allowedClientApplicationIds: allAllowedClientAppIds
    businessDayStartUtcHour: businessDayStartUtcHour
    businessDayEndUtcHour: businessDayEndUtcHour
    tags: allTags
  }
}

// =============================================================================================
// Least-privilege RBAC for the Function App managed identity
// =============================================================================================

module storageBlobRole 'modules/role-assignment.bicep' = {
  scope: resourceGroupResource
  name: 'rbac-storage-blob'
  params: {
    principalId: functionApp.outputs.principalId
    roleDefinitionId: roles.storageBlobDataOwner
    scopeResourceId: storage.outputs.storageAccountId
    assignmentSeed: 'function-host-blob'
  }
}

module storageQueueRole 'modules/role-assignment.bicep' = {
  scope: resourceGroupResource
  name: 'rbac-storage-queue'
  params: {
    principalId: functionApp.outputs.principalId
    roleDefinitionId: roles.storageQueueDataContributor
    scopeResourceId: storage.outputs.storageAccountId
    assignmentSeed: 'function-host-queue'
  }
}

module storageTableRole 'modules/role-assignment.bicep' = {
  scope: resourceGroupResource
  name: 'rbac-storage-table'
  params: {
    principalId: functionApp.outputs.principalId
    roleDefinitionId: roles.storageTableDataContributor
    scopeResourceId: storage.outputs.storageAccountId
    assignmentSeed: 'function-host-table'
  }
}

module metricsPublisherRole 'modules/role-assignment.bicep' = {
  scope: resourceGroupResource
  name: 'rbac-appinsights'
  params: {
    principalId: functionApp.outputs.principalId
    roleDefinitionId: roles.monitoringMetricsPublisher
    scopeResourceId: monitoring.outputs.applicationInsightsId
    assignmentSeed: 'function-telemetry'
  }
}

// =============================================================================================
// Private endpoints
// =============================================================================================

module functionPrivateEndpoint 'modules/private-endpoint.bicep' = {
  scope: resourceGroupResource
  name: 'pe-function'
  params: {
    privateEndpointName: names.functionPrivateEndpoint
    location: resolvedPrimaryLocation
    subnetId: primaryNetwork.outputs.privateEndpointSubnetId
    privateLinkServiceId: functionApp.outputs.functionAppId
    groupId: 'sites'
    // A single `sites` private endpoint covers both the app and its scm host.
    privateDnsZoneId: createPrivateDnsZoneGroups && createPrivateDnsZones ? privateDnsZones[indexOf(dnsZoneKeys, 'sites')]!.outputs.privateDnsZoneId : ''
    tags: allTags
  }
}

// The zone is resolved by NAME, never by a hard-coded index, so the mapping cannot drift.
var storagePrivateEndpoints = [
  { name: names.blobPrivateEndpoint, groupId: 'blob' }
  { name: names.queuePrivateEndpoint, groupId: 'queue' }
  { name: names.tablePrivateEndpoint, groupId: 'table' }
]

module storagePrivateEndpointModules 'modules/private-endpoint.bicep' = [
  for pe in storagePrivateEndpoints: {
    scope: resourceGroupResource
    name: 'pe-${pe.groupId}'
    params: {
      privateEndpointName: pe.name
      location: resolvedPrimaryLocation
      subnetId: primaryNetwork.outputs.privateEndpointSubnetId
      privateLinkServiceId: storage.outputs.storageAccountId
      groupId: pe.groupId
      privateDnsZoneId: createPrivateDnsZoneGroups && createPrivateDnsZones
        ? privateDnsZones[indexOf(dnsZoneKeys, pe.groupId)]!.outputs.privateDnsZoneId
        : ''
      tags: allTags
    }
  }
]

// =============================================================================================
// Power Platform enterprise policy
// =============================================================================================

// True only when this deployment actually writes the policy. A policy that is already linked to
// an environment cannot be written at all, so the module is skipped in that case.
var enterprisePolicyWasWritten = deployEnterprisePolicy && !enterprisePolicyIsLinked

module enterprisePolicy 'modules/power-platform-enterprise-policy.bicep' = if (enterprisePolicyWasWritten) {
  scope: resourceGroupResource
  name: 'enterprise-policy'
  params: {
    enterprisePolicyName: names.enterprisePolicy
    powerPlatformRegion: enterprisePolicyLocation
    primaryVirtualNetworkId: primaryNetwork.outputs.virtualNetworkId
    primarySubnetName: primaryNetwork.outputs.powerPlatformSubnetName
    failoverVirtualNetworkId: deployFailoverNetwork ? failoverNetwork!.outputs.virtualNetworkId : ''
    failoverSubnetName: deployFailoverNetwork ? failoverNetwork!.outputs.powerPlatformSubnetName : ''
    readerPrincipalIds: enterprisePolicyReaderPrincipalIds
    tags: allTags
  }
}

// =============================================================================================
// Outputs - these are the contract consumed by the workflows, scripts and Power Platform
// =============================================================================================

@description('Name of the resource group containing the entire demo.')
output resourceGroupName string = resourceGroupResource.name

@description('Primary Azure region actually used.')
output primaryLocation string = resolvedPrimaryLocation

@description('Failover Azure region actually used, or empty for single-region geographies.')
output failoverLocation string = resolvedFailoverLocation

@description('Name of the Function App.')
output functionAppName string = functionApp.outputs.functionAppName

@description('Resource ID of the Function App.')
output functionAppResourceId string = functionApp.outputs.functionAppId

@description('Base URL of the Function App, resolvable only from inside the virtual network.')
output functionAppBaseUrl string = functionApp.outputs.functionAppBaseUrl

@description('Classification endpoint the Power Automate flow calls.')
output functionClassifyUrl string = '${functionApp.outputs.functionAppBaseUrl}/api/requests/classify'

@description('Health endpoint used to prove private network reachability.')
output functionHealthUrl string = '${functionApp.outputs.functionAppBaseUrl}/api/health'

@description('Principal ID of the Function App managed identity.')
output functionAppPrincipalId string = functionApp.outputs.principalId

@description('Whether App Service Authentication was configured.')
output functionAppAuthenticationConfigured bool = functionApp.outputs.authenticationConfigured

@description('Name of the storage account.')
output storageAccountName string = storage.outputs.storageAccountName

@description('URL of the deployment package container.')
output deploymentContainerUrl string = storage.outputs.deploymentContainerUrl

@description('Name of the Application Insights component.')
output applicationInsightsName string = monitoring.outputs.applicationInsightsName

@description('Resource ID of the primary virtual network.')
output primaryVirtualNetworkId string = primaryNetwork.outputs.virtualNetworkId

@description('Resource ID of the failover virtual network, or empty.')
output failoverVirtualNetworkId string = deployFailoverNetwork ? failoverNetwork!.outputs.virtualNetworkId : ''

@description('Name of the Power Platform delegated subnet.')
output powerPlatformSubnetName string = primaryNetwork.outputs.powerPlatformSubnetName

@description('ARM resource ID of the Power Platform enterprise policy, or empty.')
output enterprisePolicyResourceId string = deployEnterprisePolicy
  ? (enterprisePolicyWasWritten
      ? enterprisePolicy!.outputs.enterprisePolicyId
      : resourceId(
          subscription().subscriptionId,
          resourceGroupResource.name,
          'Microsoft.PowerPlatform/enterprisePolicies',
          names.enterprisePolicy
        ))
  : ''

@description('Name of the Power Platform enterprise policy, or empty. Emitted separately from the full resource ID because GitHub Actions drops a job output that contains a secret, and the resource ID embeds the subscription ID. Derived from the naming convention rather than the module, so it is still correct on a re-run where the policy write was skipped because the policy is already linked.')
output enterprisePolicyName string = deployEnterprisePolicy ? names.enterprisePolicy : ''

@description('Power Platform systemId of the enterprise policy. Empty when the policy write was skipped because the policy is already linked to an environment.')
output enterprisePolicySystemId string = enterprisePolicyWasWritten ? enterprisePolicy!.outputs.enterprisePolicySystemId : ''

@description('Power Platform geography name used for the enterprise policy location.')
output enterprisePolicyLocation string = enterprisePolicyLocation

@description('Application ID of the HTTP with Microsoft Entra ID connector that is allow-listed.')
output httpWithEntraIdConnectorAppId string = httpWithEntraIdConnectorAppId

@description('Name of the private endpoint in front of the Function App.')
output functionPrivateEndpointName string = functionPrivateEndpoint.outputs.privateEndpointName
