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
# environmentvariabledefinitions/<schemaname>/ folders: this version of `pac solution pack` does
# not fold that layout into customizations.xml, it copies it into the zip verbatim, and the
# Dataverse import then fails. See Test-SolutionPackage.ps1.
$looseFolder = Join-Path $RepositoryRoot 'powerplatform/solution/src/environmentvariabledefinitions'
Assert-True -Name 'Environment variable definitions are not in a separate folder' `
    -Condition (-not (Test-Path $looseFolder)) `
    -Detail "Move $looseFolder inline into Other/Customizations.xml and delete it."

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
    Assert-True -Name "Environment variable has a deployment setting: $name" `
        -Condition ($settingsSchemaNames -contains $name)
}

foreach ($name in $settingsSchemaNames) {
    Assert-True -Name "Deployment setting has a matching definition: $name" `
        -Condition ($definitionNames -contains $name)
}

# Connection references and environment variable definitions must not be root components.
# Type 372 is a custom connector, not a connection reference, and Dataverse rejects both with
# "Cannot add a Root Component ... because it is not in the target system".
$solutionDocument = [xml] $solutionXml
foreach ($type in @('372', '380')) {
    $offenders = @($solutionDocument.SelectNodes('//RootComponent') |
            Where-Object { $_.GetAttribute('type') -eq $type })

    Assert-True -Name "Solution.xml declares no root component of type $type" `
        -Condition ($offenders.Count -eq 0) `
        -Detail 'Connection references and environment variable definitions belong in Customizations.xml only.'
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

        # Customizations.xml is the only place that may carry it; see the type-372 note above.
        Assert-True -Name "Connection reference is not a root component: $reference" `
            -Condition ($solutionXml -notmatch [regex]::Escape($reference))
    }

    # The deployment settings file must NOT carry connection references. Binding them makes the
    # import run as the deployment service principal against a connection owned by a person,
    # which fails with ConnectionAuthorizationFailed and destroys the existing binding.
    Assert-True -Name 'Deployment settings do not bind connection references' `
        -Condition (-not ($settings.PSObject.Properties.Name -contains 'ConnectionReferences')) `
        -Detail 'Connections are created and bound by a person; the pipeline must leave them alone.'

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
# Connector action parameters must use slash notation for body properties
#
# An OpenApiConnection action addresses a body parameter's properties as
# "<bodyParameter>/<property>" - emailMessage/To, request/method. Supplying them flat binds
# nothing: the solution imports, the flow saves, and the designer shows every field empty with
# the required ones missing. scripts/Test-FlowConnectorParameters.ps1 checks this properly
# against the live connector schema; this is the offline approximation CI can run.
# ---------------------------------------------------------------------------------------------

$knownFlatParameters = @{
    'InvokeHttp'  = @('method', 'url', 'headers', 'body')
    'SendEmailV2' = @('To', 'Subject', 'Body', 'Importance', 'Cc', 'Bcc')
}

foreach ($action in $flow.properties.definition.actions.PSObject.Properties) {
    if ($action.Value.type -ne 'OpenApiConnection') { continue }

    $operationId = $action.Value.inputs.host.operationId
    if (-not $knownFlatParameters.ContainsKey($operationId)) { continue }

    foreach ($supplied in $action.Value.inputs.parameters.PSObject.Properties) {
        $isBare = $knownFlatParameters[$operationId] -contains $supplied.Name

        Assert-True -Name "$($action.Name): '$($supplied.Name)' is qualified with its body parameter" `
            -Condition (-not $isBare) `
            -Detail "Use '<bodyParameter>/$($supplied.Name)'. A bare name binds to nothing and the action renders empty."
    }
}


# There are two similarly named connectors, backed by DIFFERENT OAuth client applications:
#
#   shared_webcontents    "HTTP with Microsoft Entra ID (preauthorized)"  client 7ab7862c...
#                         Microsoft's first-party "App Service" app. VNet supported.
#   shared_webcontentsv2  "HTTP With Microsoft Entra ID"                  client d2ebd3a9...
#                         NOT on the VNet supported-services list.
#
# The repository originally preauthorized, granted and allow-listed d2ebd3a9 while the solution
# used shared_webcontents. Creating the connection then failed with "Create and authorize OAuth
# connection failed", because the connector authenticates as 7ab7862c, which had no consent and
# no service principal. Assert the pairing so the two cannot drift apart again.

$connectorClientIds = @{
    'shared_webcontents'   = '7ab7862c-4c57-491e-8a45-d52a7e023983'
    'shared_webcontentsv2' = 'd2ebd3a9-1ada-4480-8b2d-eac162716601'
}

$customizationsText = Get-FileText 'powerplatform/solution/src/Other/Customizations.xml'

$usesV2 = $customizationsText -match 'apis/shared_webcontentsv2'
$usesV1 = $customizationsText -match 'apis/shared_webcontents(?!v2)'

Assert-True -Name 'The solution uses the VNet-supported HTTP connector (shared_webcontents)' `
    -Condition ($usesV1 -and -not $usesV2) `
    -Detail 'shared_webcontentsv2 is not on the Power Platform VNet supported-services list.'

$connectorAppId = $connectorClientIds['shared_webcontents']

foreach ($file in @('infra/main.bicep', 'scripts/Initialize-EntraResources.ps1', 'docs/identity-model.md')) {
    Assert-True -Name "Connector application ID present in $file" `
        -Condition ((Get-FileText $file) -match $connectorAppId)

    # Match an ASSIGNMENT of the v2 client ID, not a mention of it. The files deliberately name
    # the wrong value in a comment so the trap stays documented.
    Assert-True -Name "$file does not assign the v2 connector's client ID" `
        -Condition ((Get-FileText $file) -notmatch ("=\s*'" + [regex]::Escape($connectorClientIds['shared_webcontentsv2']) + "'")) `
        -Detail 'That app backs shared_webcontentsv2, which this solution does not use.'
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
# Whatever Deploy creates, Destroy must remove
#
# This asymmetry is exactly how the destroy pipeline silently stopped doing what it claimed:
# environment provisioning was added to deploy.yml and destroy.yml was never taught to undo it,
# so "Removes everything the demo created" quietly became false. Assert the pairing instead of
# trusting a comment.
# ---------------------------------------------------------------------------------------------

$destroyWorkflow = Get-FileText '.github/workflows/destroy.yml'
$removeDemo = Get-FileText 'scripts/Remove-Demo.ps1'

# Everything reachable from the destroy workflow, one level of indirection deep.
$destroyReach = $destroyWorkflow + "`n" + $removeDemo

$creators = [regex]::Matches($deployWorkflow, 'scripts/(?<name>New-[A-Za-z0-9]+)\.ps1') |
    ForEach-Object { $_.Groups['name'].Value } | Select-Object -Unique

# Scripts that create nothing outside the runner's own workspace, so there is nothing to undo.
# Keep this list short and justified; anything that touches Azure, Dataverse or Entra belongs in
# the paired check below, not here.
$localOnlyCreators = @{
    'New-DeploymentSettings' = 'renders powerplatform/out/deploymentSettings.json inside the runner workspace'
}

Assert-True -Name 'Deploy calls at least one provisioning script' -Condition ($creators.Count -gt 0)

foreach ($creator in $creators) {
    if ($localOnlyCreators.ContainsKey($creator)) {
        Write-Host "[ -- ] $creator.ps1 needs no counterpart: $($localOnlyCreators[$creator])"
        continue
    }

    $remover = $creator -replace '^New-', 'Remove-'

    Assert-True -Name "Destroy can undo $creator.ps1 (needs $remover.ps1)" `
        -Condition (Test-Path (Join-Path $RepositoryRoot "scripts/$remover.ps1")) `
        -Detail "Deploy creates something with $creator.ps1, so Destroy needs $remover.ps1."

    Assert-True -Name "Destroy actually calls $remover.ps1" `
        -Condition ($destroyReach -match [regex]::Escape("$remover.ps1")) `
        -Detail 'The script exists but nothing in the destroy path invokes it.'
}

# "Destroyed" has to mean destroyed, not "deletion requested". A --no-wait resource group delete
# lets the workflow go green while Azure is still working, and a redeploy then races it.
Assert-True -Name 'Remove-Demo.ps1 waits for the resource group delete' `
    -Condition ($removeDemo -notmatch 'az group delete[^\r\n]*--no-wait') `
    -Detail 'Drop --no-wait so the run finishing means the resource group is gone.'

Assert-True -Name 'Destroy deletes the Power Platform environment by default' `
    -Condition ($destroyWorkflow -match '(?s)keep-power-platform-environment:.*?default:\s*false') `
    -Detail 'Deploy creates the environment, so Destroy must remove it unless explicitly told not to.'

Assert-True -Name 'Environment deletion is guarded by the expected display name' `
    -Condition ($removeDemo -match 'PowerPlatformEnvironmentName') `
    -Detail 'Provisioning adopts an existing environment, so deletion must confirm which one it is.'

# The Entra app registrations are created by the BOOTSTRAP, not by a deployment, and the
# deployment one is the identity the pipelines sign in with, so Destroy keeps them by default.
# That is a defensible choice; claiming to remove "everything" while doing it is not. Assert the
# opt-out exists and that no script in the destroy path makes the false totality claim that hid
# the missing environment delete for so long.
Assert-True -Name 'Destroy can delete the Entra app registrations on request' `
    -Condition (($destroyWorkflow -match 'remove-entra-applications') -and ($removeDemo -match '\$RemoveEntraApplications')) `
    -Detail 'Keeping them by default is fine; having no way to remove them is not.'

foreach ($file in @('.github/workflows/destroy.yml', 'scripts/Remove-Demo.ps1')) {
    $text = Get-FileText $file

    Assert-True -Name "$file does not claim to remove everything" `
        -Condition ($text -notmatch '(?i)removes everything the demo created, and nothing else') `
        -Detail 'It keeps the bootstrap app registrations and the connector service principal. Say so.'
}

Assert-True -Name 'Remove-Demo.ps1 prints what it left behind' `
    -Condition ($removeDemo -match "(?m)^\s*Write-Host 'Left in place:'") `
    -Detail 'The survivors must be visible on every run, not buried in a comment.'

# Destroy has to be safe to re-run against an estate that is already clean. Probing for an absent
# resource group leaves a non-zero $LASTEXITCODE that PowerShell adopts as the script's own exit
# code, so a run that did everything right reports failure. It did exactly that once.
Assert-True -Name 'Remove-Demo.ps1 ends with an explicit exit 0' `
    -Condition ($removeDemo -match '(?m)^exit 0\s*$') `
    -Detail 'Otherwise a stale native exit code from an expected probe failure fails the job.'

Assert-True -Name 'Remove-Demo.ps1 tolerates an absent resource group' `
    -Condition (($removeDemo -match '\$global:LASTEXITCODE = 0') -and ($removeDemo -match '(?s)try\s*\{[^}]*az group show')) `
    -Detail 'PowerShell 7.4 throws on a failing native command under ErrorActionPreference Stop.'

# ---------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------------
# Docs must classify each setting the same way the workflows read it
#
# docs/limitations.md once told the reader to "store it as a repository variable" directly above
# a code block running `gh secret set`, while deploy.yml read it from `secrets.`. Three sources,
# two answers. Check the mechanical half: anything the docs tell you to set must be read from the
# matching context.
# ---------------------------------------------------------------------------------------------

$workflowText = ($deployWorkflow + "`n" + $destroyWorkflow + "`n" + (Get-FileText '.github/workflows/ci.yml'))

$docFiles = Get-ChildItem -Path (Join-Path $RepositoryRoot 'docs') -Filter '*.md' -File |
    ForEach-Object { "docs/$($_.Name)" }
$docFiles += 'README.md'

foreach ($docFile in $docFiles) {
    $docText = Get-FileText $docFile

    foreach ($match in [regex]::Matches($docText, 'gh (?<kind>secret|variable) set (?<name>[A-Z0-9_]+)')) {
        $name = $match.Groups['name'].Value
        $kind = $match.Groups['kind'].Value

        # Only meaningful for settings a workflow actually consumes.
        $readAsSecret = $workflowText -match "secrets\.$name\b"
        $readAsVariable = $workflowText -match "vars\.$name\b"

        if (-not ($readAsSecret -or $readAsVariable)) { continue }

        $expected = if ($readAsSecret) { 'secret' } else { 'variable' }

        Assert-True -Name "$docFile sets $name as a $expected, matching the workflows" `
            -Condition ($kind -eq $expected) `
            -Detail "The docs say 'gh $kind set', but the workflows read it from '$(if ($readAsSecret) { 'secrets' } else { 'vars' }).$name'."
    }
}

# ---------------------------------------------------------------------------------------------
# Community health files. A public repository is expected to carry these, and SECURITY.md in
# particular has to exist before anyone can report a vulnerability responsibly.
# ---------------------------------------------------------------------------------------------

foreach ($file in @('LICENSE', 'SECURITY.md', 'SUPPORT.md', 'CONTRIBUTING.md', 'CODE_OF_CONDUCT.md')) {
    Assert-True -Name "$file exists" `
        -Condition (Test-Path (Join-Path $RepositoryRoot $file))
}

# ---------------------------------------------------------------------------------------------
# The README documents the scripts folder as a tree. It drifts silently as scripts are added,
# which is how it came to omit several of them. Assert every script is listed.
# ---------------------------------------------------------------------------------------------

$readme = Get-FileText 'README.md'

$scriptFiles = Get-ChildItem -Path (Join-Path $RepositoryRoot 'scripts') -Filter '*.ps1' -File |
    ForEach-Object { $_.Name }

foreach ($script in $scriptFiles) {
    Assert-True -Name "README lists scripts/$script" `
        -Condition ($readme -match [regex]::Escape($script)) `
        -Detail 'Add it to the repository layout tree in README.md.'
}

# ---------------------------------------------------------------------------------------------
# The Application Insights packages must stay on the same major version
# ---------------------------------------------------------------------------------------------

# Microsoft.Azure.Functions.Worker.ApplicationInsights binds against Microsoft.ApplicationInsights
# 2.x. On 3.x the ITelemetryInitializer type it needs is gone, so the isolated worker aborts the
# moment the host starts it, no functions are indexed, and every route returns 404 -- while the
# build, the tests and the deployment all still report success. Test-FunctionHostStartup.ps1 is
# what actually proves the host works; this is the cheap version that explains the constraint at
# the point somebody would otherwise "helpfully" bump the version.

$functionProject = Get-FileText 'src/function/SecureRequestClassifier.Functions/SecureRequestClassifier.Functions.csproj'

if ($functionProject -match 'Microsoft\.ApplicationInsights\.WorkerService"\s+Version="([^"]+)"') {
    $insightsVersion = $Matches[1]
    Assert-True -Name 'Microsoft.ApplicationInsights.WorkerService stays on 2.x' `
        -Condition ($insightsVersion -like '2.*') `
        -Detail "Found $insightsVersion. Version 3.x removes Microsoft.ApplicationInsights.Extensibility.ITelemetryInitializer, which Microsoft.Azure.Functions.Worker.ApplicationInsights requires; the worker then crashes at startup and the app serves 404 on every route."
}
else {
    Assert-True -Name 'Microsoft.ApplicationInsights.WorkerService stays on 2.x' `
        -Condition $false `
        -Detail 'The package reference was not found in the function project.'
}

# ---------------------------------------------------------------------------------------------
# Starting the Functions host must be part of CI
# ---------------------------------------------------------------------------------------------

$ciWorkflow = Get-FileText '.github/workflows/ci.yml'

Assert-True -Name 'CI starts the Functions host and checks indexing' `
    -Condition ($ciWorkflow -match 'Test-FunctionHostStartup\.ps1') `
    -Detail 'Without it, a worker that cannot start ships as a green build that answers 404.'

Assert-True -Name 'CI checks that documentation links resolve' `
    -Condition ($ciWorkflow -match 'Test-DocumentationLinks\.ps1') `
    -Detail 'A reworded heading breaks every link to its anchor without breaking anything visible.'

# A push to a branch that already has a pull request is the same commit arriving twice, and each
# trigger publishes its own check run under the same required-context name. Cancelling one does not
# help: branch protection sees the cancelled conclusion for a required context and blocks the merge
# even though the surviving run passed. Triggering only on pull_request yields exactly one check
# run per context, which is what main's protection actually gates on.

$ciTriggerBlock = ''
if ($ciWorkflow -match '(?ms)^on:\s*\r?\n(.*?)^\S') {
    $ciTriggerBlock = $Matches[1]
}

Assert-True -Name 'CI trigger block was located' `
    -Condition ([bool]$ciTriggerBlock) `
    -Detail 'Could not find the on: block in .github/workflows/ci.yml.'

if ($ciTriggerBlock) {
    Assert-True -Name 'CI does not also trigger on push' `
        -Condition ($ciTriggerBlock -notmatch '(?m)^\s+push:') `
        -Detail 'A push and its pull request would each publish a check run for the same required context, and a cancelled one blocks the merge.'
}

# ---------------------------------------------------------------------------------------------
# Role assignments must be scoped to the resource they are about
# ---------------------------------------------------------------------------------------------

# A role assignment is an extension resource. Without `scope:` it attaches to whatever the
# deployment scope happens to be -- here the resource group -- so a grant written to cover one
# storage account silently covers everything in the group. The template still reads as least
# privilege, which is what makes it worth asserting rather than trusting.

$roleAssignmentModule = Get-FileText 'infra/modules/role-assignment.bicep'

$roleAssignmentDeclarations = [regex]::Matches(
    $roleAssignmentModule,
    "(?s)resource\s+\w+\s+'Microsoft\.Authorization/roleAssignments@[^']+'\s*=[^{]*\{(.*?)\r?\n\}")

Assert-True -Name 'role-assignment.bicep declares at least one role assignment' `
    -Condition ($roleAssignmentDeclarations.Count -gt 0) `
    -Detail 'The scope assertion below would otherwise pass by finding nothing.'

foreach ($declaration in $roleAssignmentDeclarations) {
    Assert-True -Name 'Every role assignment sets an explicit scope' `
        -Condition ($declaration.Groups[1].Value -match '(?m)^\s*scope:\s*\S') `
        -Detail 'Without scope: the assignment lands on the resource group, which is wider than intended.'
}

Assert-True -Name 'main.bicep does not pass the removed scopeResourceId parameter' `
    -Condition ($mainBicep -notmatch 'scopeResourceId') `
    -Detail 'That parameter was only ever used inside guid(), so it never scoped anything.'

# ---------------------------------------------------------------------------------------------

Write-Host ('-' * 70)

if ($script:Failures -eq 0) {
    Write-Host 'All consistency checks passed.' -ForegroundColor Green
    exit 0
}

Write-Host "$($script:Failures) consistency check(s) failed." -ForegroundColor Red
exit 1
