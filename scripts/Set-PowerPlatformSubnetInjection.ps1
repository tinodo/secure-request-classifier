<#
.SYNOPSIS
    Links (or unlinks) a Power Platform environment to the network-injection enterprise policy.

.DESCRIPTION
    Creating the enterprise policy is an Azure Resource Manager operation and is handled by
    Bicep. *Linking* it to a Power Platform environment is a Power Platform control-plane
    operation that ARM cannot express.

    Microsoft's supported tooling for this is the `Microsoft.PowerPlatform.EnterprisePolicies`
    PowerShell module (`Enable-SubnetInjection` / `Disable-SubnetInjection`):
        https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-setup-configure

    This script prefers that module. When the module is unavailable it falls back to the same
    REST call the module makes, against the Power Platform Business Application Platform
    endpoint, using a token obtained with the caller's existing Azure CLI sign-in. The
    fallback is included so the operation stays automatable on a clean CI runner; it is
    documented as an undocumented-but-Microsoft-published surface in docs/limitations.md.

    Either way there is no secret: the caller is a workload-identity-federated service
    principal or an interactively signed-in administrator.

.PARAMETER EnvironmentId
    Power Platform environment ID (a GUID).

.PARAMETER EnterprisePolicyResourceId
    Full ARM resource ID of the Microsoft.PowerPlatform/enterprisePolicies resource.

.PARAMETER Action
    Link or Unlink.

.PARAMETER ForceRestApi
    Skip the PowerShell module and use the REST fallback.

.EXAMPLE
    ./Set-PowerPlatformSubnetInjection.ps1 `
        -EnvironmentId 11111111-1111-1111-1111-111111111111 `
        -EnterprisePolicyResourceId /subscriptions/.../providers/Microsoft.PowerPlatform/enterprisePolicies/ep-srclass-demo-netinjection

.NOTES
    The calling identity needs:
      * the Power Platform Administrator role in Microsoft Entra ID, and
      * the Reader role on the enterprise policy resource (granted by the Bicep deployment
        via the enterprisePolicyReaderPrincipalIds parameter).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $EnvironmentId,

    [Parameter(Mandatory)]
    [string] $EnterprisePolicyResourceId,

    [ValidateSet('Link', 'Unlink')]
    [string] $Action = 'Link',

    [switch] $ForceRestApi,

    [int] $TimeoutSeconds = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BapEndpoint = 'https://api.bap.microsoft.com/'
$script:BapApiVersion = '2019-10-01'
$script:TokenResource = 'https://service.powerapps.com/'

function Write-Step { param([string] $Message) Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }

function Get-PowerPlatformAccessToken {
    $token = az account get-access-token --resource $script:TokenResource --query accessToken --output tsv 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw "Could not acquire a token for $script:TokenResource. Sign in with 'az login' (or azure/login in CI) first."
    }

    return $token
}

function Get-EnterprisePolicySystemId {
    param([Parameter(Mandatory)][string] $ResourceId)

    $policy = az rest --method get `
        --url "https://management.azure.com$ResourceId`?api-version=2020-10-30-preview" `
        --output json 2>$null | ConvertFrom-Json

    if (-not $policy) {
        throw "Could not read the enterprise policy at $ResourceId. Check the resource exists and that you have at least Reader on it."
    }

    if ($policy.kind -ne 'NetworkInjection') {
        throw "Enterprise policy '$($policy.name)' has kind '$($policy.kind)'. Expected 'NetworkInjection'."
    }

    $systemId = $policy.properties.systemId

    if ([string]::IsNullOrWhiteSpace($systemId)) {
        throw "Enterprise policy '$($policy.name)' has no systemId yet. It may still be provisioning; retry shortly."
    }

    return $systemId
}

function Invoke-EnterprisePolicyLinkRest {
    param(
        [Parameter(Mandatory)][string] $SystemId,
        [Parameter(Mandatory)][ValidateSet('link', 'unlink')][string] $Operation
    )

    $token = Get-PowerPlatformAccessToken

    $uri = "$($script:BapEndpoint)providers/Microsoft.BusinessAppPlatform/environments/$EnvironmentId" +
           "/enterprisePolicies/NetworkInjection/$Operation`?api-version=$($script:BapApiVersion)"

    $headers = @{
        Authorization  = "Bearer $token"
        'Content-Type' = 'application/json'
    }

    $body = @{ SystemId = $SystemId } | ConvertTo-Json -Compress

    Write-Host "    POST $uri"

    $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $body -SkipHttpErrorCheck

    if ($response.StatusCode -notin @(200, 201, 202)) {
        throw "Enterprise policy $Operation failed with HTTP $($response.StatusCode): $($response.Content)"
    }

    $operationLocation = $response.Headers['operation-location']
    if (-not $operationLocation) {
        Write-Host "    completed synchronously (HTTP $($response.StatusCode))" -ForegroundColor Green
        return
    }

    $operationUri = @($operationLocation)[0]
    Write-Host "    accepted; polling $operationUri"

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15

        $pollToken = Get-PowerPlatformAccessToken
        $poll = Invoke-RestMethod -Uri $operationUri -Method Get -Headers @{ Authorization = "Bearer $pollToken" }

        $state = if ($poll.PSObject.Properties.Name -contains 'state') { $poll.state.id } else { $null }
        Write-Host "    state: $state"

        switch ($state) {
            'Succeeded' {
                Write-Host "    enterprise policy $Operation succeeded" -ForegroundColor Green
                return
            }
            'Failed' {
                $message = if ($poll.PSObject.Properties.Name -contains 'error') { $poll.error.message } else { 'no detail returned' }
                throw "Enterprise policy $Operation failed: $message"
            }
        }
    }

    throw "Timed out after $TimeoutSeconds seconds waiting for the enterprise policy $Operation to complete."
}

function Invoke-EnterprisePolicyLinkModule {
    param([Parameter(Mandatory)][ValidateSet('Link', 'Unlink')][string] $Operation)

    $module = Get-Module -ListAvailable -Name 'Microsoft.PowerPlatform.EnterprisePolicies' |
        Sort-Object Version -Descending | Select-Object -First 1

    if (-not $module) { return $false }

    Import-Module $module.Name -ErrorAction Stop
    Write-Host "    using Microsoft.PowerPlatform.EnterprisePolicies $($module.Version)"

    if ($Operation -eq 'Link') {
        Enable-SubnetInjection -EnvironmentId $EnvironmentId -PolicyArmId $EnterprisePolicyResourceId -ErrorAction Stop | Out-Null
    }
    else {
        Disable-SubnetInjection -EnvironmentId $EnvironmentId -ErrorAction Stop | Out-Null
    }

    return $true
}

# ---------------------------------------------------------------------------------------------

Write-Step "$Action environment $EnvironmentId and enterprise policy"

if (-not $PSCmdlet.ShouldProcess($EnvironmentId, "$Action network injection enterprise policy")) { return }

$usedModule = $false

if (-not $ForceRestApi) {
    try {
        $usedModule = Invoke-EnterprisePolicyLinkModule -Operation $Action
    }
    catch {
        Write-Warning "Microsoft.PowerPlatform.EnterprisePolicies failed: $($_.Exception.Message)"
        Write-Warning 'Falling back to the Power Platform REST API.'
        $usedModule = $false
    }
}

if (-not $usedModule) {
    Write-Host '    Microsoft.PowerPlatform.EnterprisePolicies not used; calling the Power Platform API directly.'

    $systemId = Get-EnterprisePolicySystemId -ResourceId $EnterprisePolicyResourceId
    Write-Host "    enterprise policy systemId: $systemId"

    Invoke-EnterprisePolicyLinkRest -SystemId $systemId -Operation $Action.ToLowerInvariant()
}

Write-Step 'Verifying the environment reports the linked policy'

$token = Get-PowerPlatformAccessToken
$environmentUri = "$($script:BapEndpoint)providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$EnvironmentId`?api-version=2016-11-01"
$environment = Invoke-RestMethod -Uri $environmentUri -Method Get -Headers @{ Authorization = "Bearer $token" }

$linked = $null

# After a successful unlink the 'enterprisePolicies' property is not merely empty, it is absent
# from the response entirely. Under Set-StrictMode, walking into it then throws, which turned a
# SUCCESSFUL unlink into "Unlink failed: The property 'enterprisePolicies' cannot be found on
# this object" and told the operator to go and unlink by hand.
#
# PSObject.Properties['name'] returns $null for a missing property instead of throwing, and
# unlike .Properties.Name it is also safe on an object with no properties at all.
function Get-PropertyOrNull {
    param($InputObject, [string] $Name)

    if ($null -eq $InputObject) { return $null }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }

    return $property.Value
}

$policies = Get-PropertyOrNull -InputObject $environment.properties -Name 'enterprisePolicies'
$vnets = Get-PropertyOrNull -InputObject $policies -Name 'VNets'
$linked = Get-PropertyOrNull -InputObject $vnets -Name 'id'

if ($Action -eq 'Link') {
    if ($linked) {
        Write-Host "    environment is linked to: $linked" -ForegroundColor Green
    }
    else {
        Write-Warning 'The environment does not yet report a linked VNet policy. Linking can take a few minutes to surface; re-run the verification script shortly.'
    }
}
else {
    if ($linked) {
        Write-Warning "The environment still reports a linked policy: $linked"
    }
    else {
        Write-Host '    environment reports no linked VNet policy' -ForegroundColor Green
    }
}

Write-Host ''
Write-Host 'Note: enabling or disabling subnet delegation can cause up to 30 minutes of instability' -ForegroundColor Yellow
Write-Host 'while connections initialise for the delegated subnet.' -ForegroundColor Yellow
