// Demo defaults for the Secure Request Classifier.
//
// Every value here is safe to commit: they are identifiers and network ranges, never secrets.
// Override any of them with a `-p name=value` argument or by copying this file.
//
// Usage:
//   az deployment sub create --location westeurope \
//       --template-file infra/main.bicep --parameters infra/parameters/demo.bicepparam

using '../main.bicep'

param workloadName = 'srclass'
param environmentName = 'demo'

// Power Platform geography of the target environment. The Azure region pair is derived from
// this automatically; override primaryLocation / failoverLocation only if you must.
param powerPlatformRegion = 'europe'

// Network layout. The Power Platform delegated subnets are /24 because Microsoft's sizing
// guidance allocates 25-30 IP addresses per production environment plus 5 reserved.
param primaryVnetAddressPrefix = '10.60.0.0/16'
param primaryPowerPlatformSubnetPrefix = '10.60.0.0/24'
param functionSubnetPrefix = '10.60.1.0/26'
param privateEndpointSubnetPrefix = '10.60.2.0/27'
param failoverVnetAddressPrefix = '10.61.0.0/16'
param failoverPowerPlatformSubnetPrefix = '10.61.0.0/24'

// Secure by default. The deployment workflow flips the Function App to Enabled only inside a
// tightly scoped, IP-restricted deployment window when FUNCTION_DEPLOY_MODE=deployment-window,
// and always re-seals it afterwards.
param functionAppPublicNetworkAccess = 'Disabled'
param storagePublicNetworkAccess = 'Disabled'

// Set to false in an Azure Landing Zone where the
// "Configure Azure PaaS services to use private DNS zones" DeployIfNotExists policy
// owns private DNS integration centrally.
param createPrivateDnsZones = true
param createPrivateDnsZoneGroups = true

param deployEnterprisePolicy = true

// Required, and intentionally sourced from the environment rather than committed. The deployment
// workflow passes --parameters apiApplicationId=<AZURE_API_APP_ID secret>, which overrides this;
// the env-var read is what lets a local `az deployment sub create` and `az bicep build-params`
// work. There is deliberately no committed default: an empty value used to switch App Service
// Authentication off entirely.
param apiApplicationId = readEnvironmentVariable('AZURE_API_APP_ID', '00000000-0000-0000-0000-000000000000')

param businessDayStartUtcHour = 9
param businessDayEndUtcHour = 17

param tags = {
  costCenter: 'demo'
  dataClassification: 'none'
}
