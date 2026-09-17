#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Checks that the moving parts of the repository agree with each other.

.DESCRIPTION
    The demo spans five artefact types that must stay in sync: Bicep outputs, GitHub Actions
    workflow references, Power Platform environment variables and connection references, the
    Function App's configuration keys, and the HTTP routes.

    A rename in one place that is not mirrored in the others produces a deployment that
    succeeds and a demo that silently fails. This script catches that class of drift, and runs
    in CI on every pull request.

.EXAMPLE
    pwsh ./scripts/Test-RepositoryConsistency.ps1
#>
[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Failures = 0

function Assert-True {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][bool] $Condition,
        [string] $Detail = ''
    )

    if ($Condition) {
        Write-Host "[ OK ] $Name" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "       $Detail" -ForegroundColor DarkGray }
        $script:Failures++
    }
}

function Get-FileText {
    param([Parameter(Mandatory)][string] $RelativePath)
    $path = Join-Path $RepositoryRoot $RelativePath
    if (-not (Test-Path $path)) { throw "Expected file not found: $RelativePath" }
    return (Get-Content -Path $path -Raw)
}

Write-Host ''
Write-Host 'Repository consistency' -ForegroundColor Cyan
Write-Host ('-' * 70)

# ---------------------------------------------------------------------------------------------
# 1. Bicep outputs referenced by the deploy workflow must exist
# ---------------------------------------------------------------------------------------------

$mainBicep = Get-FileText 'infra/main.bicep'
$deployWorkflow = Get-FileText '.github/workflows/deploy.yml'

$declaredOutputs = [regex]::Matches($mainBicep, '(?m)^output\s+(?<name>\w+)\s') |
    ForEach-Object { $_.Groups['name'].Value }

$referencedOutputs = [regex]::Matches($deployWorkflow, 'steps\.deploy\.outputs\.(?<name>\w+)') |
    ForEach-Object { $_.Groups['name'].Value } | Select-Object -Unique

foreach ($output in $referencedOutputs) {
    Assert-True -Name "deploy.yml references an existing Bicep output: $output" `
        -Condition ($declaredOutputs -contains $output) `
        -Detail "main.bicep declares: $($declaredOutputs -join ', ')"
}

# ---------------------------------------------------------------------------------------------
# 2. Environment variable definitions, deployment settings and the flow must agree
# ---------------------------------------------------------------------------------------------

# The definitions live inline in Customizations.xml. They must NOT be split into
# environmentvariabledefinitions/<schemaname>/ folders: that is the Power Platform Git
# integration layout, and SolutionPackager copies it into the zip verbatim instead of folding it
# into customizations.xml, which makes the Dataverse import fail. See Test-SolutionPackage.ps1.
$gitFormatFolder = Join-Path $RepositoryRoot 'powerplatform/solution/src/environmentvariabledefinitions'
Assert-True -Name 'Environment variable definitions are not in Git-integration format' `
    -Condition (-not (Test-Path $gitFormatFolder)) `
    -Detail "Move $gitFormatFolder inline into Other/Customizations.xml and delete it."

$customizationsXml = [xml](Get-FileText 'powerplatform/solution/src/Other/Customizations.xml')

$definitionNodes = @($customizationsXml.SelectNodes(
        '/ImportExportXml/environmentvariabledefinitions/environmentvariabledefinition'))

Assert-True -Name 'Customizations.xml declares environment variable definitions' `
    -Condition ($definitionNodes.Count -gt 0)

$definitionNames = $definitionNodes | ForEach-Object { $_.GetAttribute('schemaname') }

$solutionXml = Get-FileText 'powerplatform/solution/src/Other/Solution.xml'
$settingsTemplate = Get-FileText 'powerplatform/config/deploymentSettings.template.json'
$settings = $settingsTemplate | ConvertFrom-Json

$settingsSchemaNames = $settings.EnvironmentVariables | ForEach-Object { $_.SchemaName }

foreach ($name in $definitionNames) {
    Assert-True -Name "Environment variable is registered in Solution.xml: $name" `
        -Condition ($solutionXml -match [regex]::Escape("schemaName=`"$name`""))

    Assert-True -Name "Environment variable has a deployment setting: $name" `
        -Condition ($settingsSchemaNames -contains $name)
}

foreach ($name in $settingsSchemaNames) {
    Assert-True -Name "Deployment setting has a matching definition: $name" `
        -Condition ($definitionNames -contains $name)
}

# Every connection reference declared in Solution.xml must also be defined inline. Dataverse
# stores '_' as '_5F' in RootComponent schema names.
$connectionReferenceNames = @($customizationsXml.SelectNodes(
        '/ImportExportXml/connectionreferences/connectionreference')) |
    ForEach-Object { $_.GetAttribute('connectionreferencelogicalname') }

$declaredConnectionReferences = [regex]::Matches(
    $solutionXml, '<RootComponent\s+type="372"\s+schemaName="(?<name>[^"]+)"') |
    ForEach-Object { $_.Groups['name'].Value -replace '_5F', '_' }

foreach ($name in $declaredConnectionReferences) {
    Assert-True -Name "Connection reference is defined in Customizations.xml: $name" `
        -Condition ($connectionReferenceNames -contains $name) `
        -Detail "Customizations.xml defines: $($connectionReferenceNames -join ', ')"
}

# ---------------------------------------------------------------------------------------------
# 3. The flow's environment variable parameters must be defined
# ---------------------------------------------------------------------------------------------

$flowFile = Get-ChildItem -Path (Join-Path $RepositoryRoot 'powerplatform/solution/src/Workflows') -Filter '*.json' |
    Select-Object -First 1

Assert-True -Name 'A cloud flow definition exists' -Condition ($null -ne $flowFile)

if ($flowFile) {
    $flowText = Get-Content $flowFile.FullName -Raw
    $flow = $flowText | ConvertFrom-Json

    $flowParameters = $flow.properties.definition.parameters.PSObject.Properties.Name |
        Where-Object { $_ -notin @('$connections', '$authentication') }

    foreach ($parameter in $flowParameters) {
        # Parameter names take the form "schemaName (displayName)".
        $schemaName = ($parameter -split ' ')[0]

        Assert-True -Name "Flow parameter maps to a defined environment variable: $schemaName" `
            -Condition ($definitionNames -contains $schemaName)
    }

    # Every parameter declared must actually be referenced, and vice versa.
    foreach ($parameter in $flowParameters) {
        Assert-True -Name "Flow parameter is used in the definition: $parameter" `
            -Condition ($flowText -match [regex]::Escape("parameters('$parameter')"))
    }

    # 4. Connection references
    $customizations = Get-FileText 'powerplatform/solution/src/Other/Customizations.xml'
    $customizationsXml = [xml] $customizations

    $declaredReferences = $customizationsXml.ImportExportXml.connectionreferences.connectionreference |
        ForEach-Object { $_.connectionreferencelogicalname }

    $flowReferences = $flow.properties.connectionReferences.PSObject.Properties |
        ForEach-Object { $_.Value.connection.connectionReferenceLogicalName }

    foreach ($reference in $flowReferences) {
        Assert-True -Name "Flow connection reference is declared in Customizations.xml: $reference" `
            -Condition ($declaredReferences -contains $reference)

        # Solution.xml stores the schema name with underscores escaped as _5F.
        $escaped = $reference -replace '_', '_5F'
        Assert-True -Name "Connection reference is a root component: $reference" `
            -Condition ($solutionXml -match [regex]::Escape($escaped))
    }

    $settingsReferences = $settings.ConnectionReferences | ForEach-Object { $_.LogicalName }
    foreach ($reference in $declaredReferences) {
        Assert-True -Name "Connection reference has a deployment setting: $reference" `
            -Condition ($settingsReferences -contains $reference)
    }

    # 5. The flow must use the VNet-supported connector and action
    Assert-True -Name 'Flow uses the HTTP with Microsoft Entra ID (preauthorized) connector' `
        -Condition ($flowText -match 'shared_webcontents') `
        -Detail 'Only this connector is on the Power Platform VNet supported-services list.'

    Assert-True -Name 'Flow uses the InvokeHttp action, not GetFileContent' `
        -Condition (($flowText -match '"operationId": "InvokeHttp"') -and ($flowText -notmatch 'GetFileContent')) `
        -Detail 'Get web resource is unsupported under VNet support.'
}

# ---------------------------------------------------------------------------------------------
# 6. HTTP routes must agree between the Function code, Bicep and the deployment settings
# ---------------------------------------------------------------------------------------------

$classifyFunction = Get-FileText 'src/function/SecureRequestClassifier.Functions/Endpoints/ClassifyRequestFunction.cs'
$healthFunction = Get-FileText 'src/function/SecureRequestClassifier.Functions/Endpoints/HealthFunction.cs'
$functionAppBicep = Get-FileText 'infra/modules/function-app.bicep'
$hostJson = Get-FileText 'src/function/SecureRequestClassifier.Functions/host.json' | ConvertFrom-Json

$routePrefix = $hostJson.extensions.http.routePrefix

Assert-True -Name 'Classify route matches the deployment settings path' `
    -Condition ($classifyFunction -match 'Route = "requests/classify"') `
    -Detail 'Expected Route = "requests/classify" in ClassifyRequestFunction.'

$classifyPath = ($settings.EnvironmentVariables | Where-Object SchemaName -eq 'srcls_FunctionClassifyPath').Value
Assert-True -Name "Deployment settings classify path is /$routePrefix/requests/classify" `
    -Condition ($classifyPath -eq "/$routePrefix/requests/classify") `
    -Detail "Found '$classifyPath'."

Assert-True -Name 'main.bicep publishes the same classify URL' `
    -Condition ($mainBicep -match [regex]::Escape("/$routePrefix/requests/classify"))

Assert-True -Name 'Health route matches the Easy Auth exclusion' `
    -Condition (($healthFunction -match 'Route = "health"') -and ($functionAppBicep -match [regex]::Escape("/$routePrefix/health")))

# ---------------------------------------------------------------------------------------------
# 7. Function App settings must match the options class
# ---------------------------------------------------------------------------------------------

$optionsClass = Get-FileText 'src/function/SecureRequestClassifier.Functions/Configuration/ClassifierOptions.cs'

$sectionMatch = [regex]::Match($optionsClass, 'SectionName\s*=\s*"(?<name>\w+)"')
$sectionName = $sectionMatch.Groups['name'].Value

Assert-True -Name 'Options section name resolved' -Condition (-not [string]::IsNullOrWhiteSpace($sectionName))

$optionProperties = [regex]::Matches($optionsClass, '(?m)^\s*public\s+\w+(?:\[\])?\s+(?<name>\w+)\s*\{\s*get;\s*set;') |
    ForEach-Object { $_.Groups['name'].Value }

$settingsInBicep = [regex]::Matches($functionAppBicep, "(?m)^\s*${sectionName}__(?<name>\w+)\s*:") |
    ForEach-Object { $_.Groups['name'].Value }

foreach ($setting in $settingsInBicep) {
    Assert-True -Name "App setting ${sectionName}__$setting binds to a real option" `
        -Condition ($optionProperties -contains $setting) `
        -Detail "ClassifierOptions exposes: $($optionProperties -join ', ')"
}

# ---------------------------------------------------------------------------------------------
# 8. Subnet names must match between Bicep, verification and the probe
# ---------------------------------------------------------------------------------------------

$networkBicep = Get-FileText 'infra/modules/virtual-network.bicep'
$testScript = Get-FileText 'scripts/Test-Deployment.ps1'
$probeScript = Get-FileText 'scripts/Invoke-PrivateConnectivityProbe.ps1'

foreach ($subnet in @('snet-powerplatform', 'snet-functions', 'snet-private-endpoints')) {
    Assert-True -Name "Subnet name defined in Bicep: $subnet" -Condition ($networkBicep -match $subnet)
}

# Azure Landing Zones deny subnets without a network security group, so every subnet variant in
# the network module must attach one.
Assert-True -Name 'Every subnet variant attaches a network security group' `
    -Condition (([regex]::Matches($networkBicep, 'networkSecurityGroup:')).Count -ge 3) `
    -Detail 'Required by the ALZ Deny-Subnet-Without-Nsg policy.'

Assert-True -Name 'A network security group module exists' `
    -Condition (Test-Path (Join-Path $RepositoryRoot 'infra/modules/network-security-group.bicep'))

Assert-True -Name 'Test-Deployment asserts every subnet has a network security group' `
    -Condition ($testScript -match 'network security group')

Assert-True -Name 'Test-Deployment checks the Power Platform delegated subnet by name' `
    -Condition ($testScript -match 'snet-powerplatform')

Assert-True -Name 'Connectivity probe targets the private endpoint subnet by name' `
    -Condition ($probeScript -match 'snet-private-endpoints')

# ---------------------------------------------------------------------------------------------
# 9. Delegation service names must be the documented ones
# ---------------------------------------------------------------------------------------------

Assert-True -Name 'Power Platform delegation service name is correct' `
    -Condition ($networkBicep -match [regex]::Escape('Microsoft.PowerPlatform/enterprisePolicies'))

Assert-True -Name 'Flex Consumption delegation service name is correct' `
    -Condition ($networkBicep -match [regex]::Escape('Microsoft.App/environments'))

# ---------------------------------------------------------------------------------------------
# 10. The cleanup tag guard must match the tag Bicep applies
# ---------------------------------------------------------------------------------------------

$removeScript = Get-FileText 'scripts/Remove-Demo.ps1'

$tagMatch = [regex]::Match($mainBicep, "workload:\s*'(?<value>[^']+)'")
$workloadTag = $tagMatch.Groups['value'].Value

Assert-True -Name 'main.bicep applies a workload tag' -Condition (-not [string]::IsNullOrWhiteSpace($workloadTag))
Assert-True -Name "Remove-Demo guards on the same tag value ($workloadTag)" `
    -Condition ($removeScript -match [regex]::Escape($workloadTag))

# ---------------------------------------------------------------------------------------------
# 11. The connector application ID must be identical everywhere it appears
# ---------------------------------------------------------------------------------------------

$connectorAppId = 'd2ebd3a9-1ada-4480-8b2d-eac162716601'

foreach ($file in @('infra/main.bicep', 'scripts/Initialize-EntraResources.ps1', 'docs/identity-model.md')) {
    Assert-True -Name "Connector application ID present in $file" `
        -Condition ((Get-FileText $file) -match $connectorAppId)
}

# ---------------------------------------------------------------------------------------------
# 12. Private endpoints must select their DNS zone by name, never by a positional index
# ---------------------------------------------------------------------------------------------

# Regression guard. The private DNS zone modules were once built with `items(dnsZoneNames)`,
# and items() sorts by key ALPHABETICALLY rather than in declaration order. Combined with
# hard-coded zoneIndex values that assumed declaration order, every private endpoint was
# attached to the wrong zone: blob got the queue zone, the function app got the blob zone. The
# deployment still succeeded, so nothing failed until name resolution was attempted at runtime.

Assert-True -Name 'main.bicep does not build the DNS zone list with items()' `
    -Condition ($mainBicep -notmatch 'items\(\s*dnsZoneNames\s*\)')

Assert-True -Name 'Private endpoints resolve their DNS zone by name via indexOf' `
    -Condition ($mainBicep -match 'indexOf\(\s*dnsZoneKeys\s*,')

Assert-True -Name 'No private endpoint carries a hard-coded zoneIndex' `
    -Condition ($mainBicep -notmatch 'zoneIndex')

# ---------------------------------------------------------------------------------------------
# 13. The environment ID and URL must not cross a job boundary as job outputs
# ---------------------------------------------------------------------------------------------

# Regression guard. Both values are masked, and GitHub redacts any job output whose value
# contains a registered secret, so passing them between jobs silently yields an empty string.
# Each job resolves the environment for itself instead.

Assert-True -Name 'deploy.yml does not publish the environment id as a job output' `
    -Condition ($deployWorkflow -notmatch '(?m)^\s*environment-id:\s*\$\{\{\s*steps\.')

Assert-True -Name 'deploy.yml resolves the environment with the shared script' `
    -Condition ($deployWorkflow -match 'Resolve-PowerPlatformEnvironment\.ps1')

Assert-True -Name 'Resolve-PowerPlatformEnvironment.ps1 exists' `
    -Condition (Test-Path (Join-Path $RepositoryRoot 'scripts/Resolve-PowerPlatformEnvironment.ps1'))

# ---------------------------------------------------------------------------------------------

Write-Host ('-' * 70)

if ($script:Failures -eq 0) {
    Write-Host 'All consistency checks passed.' -ForegroundColor Green
    exit 0
}

Write-Host "$($script:Failures) consistency check(s) failed." -ForegroundColor Red
exit 1
