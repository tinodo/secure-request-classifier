#Requires -Version 7.0

<#
.SYNOPSIS
    Resolves a Power Platform environment by display name to its ID and Dataverse URL.

.DESCRIPTION
    Every deployment stage that touches the Power Platform environment needs its ID or its
    Dataverse URL. Those two values are NOT passed between jobs, deliberately.

    A GitHub Actions job output whose value contains a registered secret is redacted to an empty
    string on the runner and never reaches the consuming job. The environment ID and URL are
    tenant-specific, so they are registered as masked values, which makes them ineligible to
    travel as job outputs. Passing them that way silently yields an empty string, and the
    consuming step then fails with a confusing error such as EnvironmentNotFound.

    So each job resolves the environment for itself, from the display name, which is ordinary
    non-sensitive configuration. Step outputs stay on the runner and are not redacted, so the
    resolved values are usable within the job that produced them.

.PARAMETER DisplayName
    Display name of the environment, for example srclass-demo.

.PARAMETER Required
    Fail when no environment matches. Without it, the script reports no match and emits empty
    outputs so the caller can decide what to do.

.EXAMPLE
    ./Resolve-PowerPlatformEnvironment.ps1 -DisplayName srclass-demo -Required

.NOTES
    Requires an existing Azure CLI sign-in (azure/login in CI) whose identity can read the
    Business Application Platform admin APIs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $DisplayName,

    [switch] $Required
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bapEndpoint = 'https://api.bap.microsoft.com/'
$bapApiVersion = '2021-04-01'
$tokenResource = 'https://service.powerapps.com/'

function Protect-LogValue {
    param([string] $Value)

    if ($env:GITHUB_ACTIONS -eq 'true' -and -not [string]::IsNullOrWhiteSpace($Value)) {
        Write-Host "::add-mask::$Value"
    }

    return $Value
}

function Write-StepOutput {
    param(
        [Parameter(Mandatory)][string] $Name,
        [string] $Value
    )

    if ($env:GITHUB_OUTPUT) {
        "$Name=$Value" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    }
}

$token = az account get-access-token --resource $tokenResource --query accessToken --output tsv 2>$null

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
    throw "Could not acquire a token for $tokenResource. Sign in with 'az login' (or azure/login in CI) first."
}

$uri = "${bapEndpoint}providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=$bapApiVersion"

$response = Invoke-WebRequest -Uri $uri -Method GET -SkipHttpErrorCheck -Headers @{
    Authorization  = "Bearer $($token.Trim())"
    'Content-Type' = 'application/json'
}

if ($response.StatusCode -ne 200) {
    throw "GET $uri failed with HTTP $($response.StatusCode): $($response.Content)"
}

$environments = $response.Content | ConvertFrom-Json
$candidates = @($environments.value | Where-Object { $_.properties.displayName -eq $DisplayName })

if ($candidates.Count -gt 1) {
    throw "More than one Power Platform environment is named '$DisplayName'. Resolve the ambiguity before re-running."
}

$environment = $candidates | Select-Object -First 1

if (-not $environment) {
    Write-StepOutput -Name 'environment-id' -Value ''
    Write-StepOutput -Name 'environment-url' -Value ''
    Write-StepOutput -Name 'vnet-policy-linked' -Value 'false'
    Write-StepOutput -Name 'found' -Value 'false'

    if ($Required) {
        throw "No Power Platform environment named '$DisplayName' was found in this tenant."
    }

    Write-Host "    no environment named '$DisplayName' found"
    return
}

$environmentId = Protect-LogValue $environment.name

$instanceUrl = ''
if ($environment.properties.PSObject.Properties.Name -contains 'linkedEnvironmentMetadata') {
    $instanceUrl = Protect-LogValue $environment.properties.linkedEnvironmentMetadata.instanceUrl
}

# Whether a NetworkInjection enterprise policy is currently linked to this environment.
#
# This matters because Power Platform refuses ANY write to a linked enterprise policy, failing
# the whole deployment with EnterprisePolicyUpdateNotAllowed. The link state is NOT visible on
# the Azure side: the ARM resource exposes only its VNet configuration and systemId. It is only
# observable here, on the environment.
$vnetPolicyLinked = 'false'

$detailUri = "${bapEndpoint}providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$($environment.name)" +
             "?api-version=$bapApiVersion&`$expand=properties.enterprisePolicies"

$detailResponse = Invoke-WebRequest -Uri $detailUri -Method GET -SkipHttpErrorCheck -Headers @{
    Authorization  = "Bearer $($token.Trim())"
    'Content-Type' = 'application/json'
}

if ($detailResponse.StatusCode -eq 200) {
    $detail = $detailResponse.Content | ConvertFrom-Json
    $policies = $detail.properties.PSObject.Properties.Name -contains 'enterprisePolicies' ? $detail.properties.enterprisePolicies : $null

    if ($policies -and ($policies.PSObject.Properties.Name -contains 'vNets') -and $policies.vNets.linkStatus -eq 'Linked') {
        $vnetPolicyLinked = 'true'
    }
}
else {
    Write-Warning "Could not read the enterprise policy link state (HTTP $($detailResponse.StatusCode)); assuming not linked."
}

Write-StepOutput -Name 'environment-id' -Value $environmentId
Write-StepOutput -Name 'environment-url' -Value $instanceUrl
Write-StepOutput -Name 'vnet-policy-linked' -Value $vnetPolicyLinked
Write-StepOutput -Name 'found' -Value 'true'

Write-Host "    resolved '$DisplayName'" -ForegroundColor Green
Write-Host "    environment id:  $environmentId"
Write-Host "    instance url:    $instanceUrl"
Write-Host "    vnet policy:     $($vnetPolicyLinked -eq 'true' ? 'Linked' : 'not linked')"

return [pscustomobject] @{
    environmentId    = $environmentId
    instanceUrl      = $instanceUrl
    vnetPolicyLinked = ($vnetPolicyLinked -eq 'true')
}
