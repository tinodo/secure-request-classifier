#Requires -Version 7.0

<#
.SYNOPSIS
    Creates (idempotently) a dedicated Power Platform environment for this demo, enables
    Managed Environments on it, and adds the deployment identity as a Dataverse application
    user.

.DESCRIPTION
    A Power Platform environment is *not* an Azure Resource Manager resource, so Bicep cannot
    create it. It lives on the Business Application Platform (BAP) control plane. That is a
    genuine limitation, not a shortcut: see docs/limitations.md.

    What is avoidable is doing it by hand. Every environment-scoped prerequisite this demo
    needs is therefore expressed here, in a committed, idempotent, re-runnable script:

      1. Create the environment with a Dataverse database (skipped when it already exists).
      2. Enable Managed Environments - a hard prerequisite of VNet support.
         https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-setup-configure
      3. Add the deployment app registration as a Dataverse application user holding the
         System Administrator security role, so the Deploy workflow can import the solution.

    The script NEVER modifies an environment it did not create unless you pass -AdoptExisting.
    Re-running it against an environment it already created is a no-op.

    No secret is involved anywhere: every token comes from the caller's existing Azure CLI
    sign-in.

.PARAMETER DisplayName
    Display name of the environment. Also the idempotency key.

.PARAMETER DomainName
    Dataverse domain name, producing https://<DomainName>.crm<n>.dynamics.com.
    Defaults to DisplayName lowercased.

.PARAMETER Location
    Power Platform geography (not an Azure region), e.g. europe, unitedstates.

.PARAMETER CurrencyCode
    ISO currency code for the Dataverse organisation. Immutable after creation.

.PARAMETER LanguageCode
    Dataverse base language LCID. 1033 is English (United States). Immutable after creation.

.PARAMETER EnvironmentSku
    Sandbox, Production, Developer or Trial. Trial does not support VNet support.

.PARAMETER DeploymentAppId
    Application (client) ID of the deployment app registration, added as a Dataverse
    application user. This is the AZURE_CLIENT_ID printed by Initialize-EntraResources.ps1.

.PARAMETER SecurityGroupId
    Entra security group restricting environment access. Omit for no restriction.

.PARAMETER SkipManagedEnvironment
    Do not enable Managed Environments. VNet support will not work without it.

.PARAMETER SkipApplicationUser
    Do not create the Dataverse application user.

.PARAMETER AdoptExisting
    Allow the script to configure an environment that already exists. Without this switch an
    existing environment with the same display name is reported and left completely alone.

.EXAMPLE
    ./New-PowerPlatformEnvironment.ps1 `
        -DisplayName srclass-demo `
        -Location europe `
        -DeploymentAppId 00000000-0000-0000-0000-000000000000

.NOTES
    The calling identity needs the Power Platform Administrator or Global Administrator role.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 ._-]{1,62}$')]
    [string] $DisplayName,

    [ValidatePattern('^[a-z0-9][a-z0-9-]{1,62}$')]
    [string] $DomainName,

    [string] $Location = 'europe',

    [ValidatePattern('^[A-Z]{3}$')]
    [string] $CurrencyCode = 'EUR',

    [int] $LanguageCode = 1033,

    [ValidateSet('Sandbox', 'Production', 'Developer', 'Trial')]
    [string] $EnvironmentSku = 'Sandbox',

    [string] $DeploymentAppId,

    [string] $SecurityGroupId,

    [string] $Description = 'Created by scripts/New-PowerPlatformEnvironment.ps1 for the Secure Request Classifier demo.',

    [switch] $SkipManagedEnvironment,

    [switch] $SkipApplicationUser,

    [switch] $AdoptExisting,

    [int] $TimeoutSeconds = 1800
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BapEndpoint = 'https://api.bap.microsoft.com/'
$script:BapApiVersion = '2021-04-01'
$script:TokenResource = 'https://service.powerapps.com/'
$script:SystemAdministratorRoleName = 'System Administrator'

function Write-Step { param([string] $Message) Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }

# Registers a value as a masked secret with the GitHub Actions runner, so it is redacted from
# the run log and the step summary. GitHub only masks output produced AFTER the workflow command
# is emitted, so every sensitive value is passed through here before it is ever printed.
# Outside Actions this is a no-op, which keeps local runs readable.
function Protect-LogValue {
    param([string] $Value)

    if ($env:GITHUB_ACTIONS -eq 'true' -and -not [string]::IsNullOrWhiteSpace($Value)) {
        Write-Host "::add-mask::$Value"
    }

    return $Value
}

function Get-AccessTokenFor {
    param([Parameter(Mandatory)][string] $Resource)

    $token = az account get-access-token --resource $Resource --query accessToken --output tsv 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw "Could not acquire a token for $Resource. Sign in with 'az login' (or azure/login in CI) first."
    }

    return $token.Trim()
}

function Invoke-Bap {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string] $Method,
        [Parameter(Mandatory)][string] $Uri,
        [object] $Body,
        [int[]] $SuccessStatusCodes = @(200, 201, 202, 204)
    )

    $headers = @{
        Authorization  = "Bearer $(Get-AccessTokenFor -Resource $script:TokenResource)"
        'Content-Type' = 'application/json'
    }

    $arguments = @{
        Uri                = $Uri
        Method             = $Method
        Headers            = $headers
        SkipHttpErrorCheck = $true
    }

    if ($null -ne $Body) {
        $arguments['Body'] = ($Body | ConvertTo-Json -Depth 20)
    }

    $response = Invoke-WebRequest @arguments

    if ($response.StatusCode -notin $SuccessStatusCodes) {
        throw "$Method $Uri failed with HTTP $($response.StatusCode): $($response.Content)"
    }

    return $response
}

function ConvertFrom-ResponseContent {
    param([Parameter(Mandatory)] $Response)

    if ([string]::IsNullOrWhiteSpace($Response.Content)) { return $null }

    return ($Response.Content | ConvertFrom-Json)
}

function Get-EnvironmentByDisplayName {
    param([Parameter(Mandatory)][string] $Name)

    $uri = "$($script:BapEndpoint)providers/Microsoft.BusinessAppPlatform/scopes/admin/environments" +
           "?api-version=$($script:BapApiVersion)"

    $environments = ConvertFrom-ResponseContent -Response (Invoke-Bap -Method GET -Uri $uri)

    $matches = @($environments.value | Where-Object { $_.properties.displayName -eq $Name })

    if ($matches.Count -gt 1) {
        throw "More than one Power Platform environment is named '$Name'. Resolve the ambiguity before re-running."
    }

    return $matches | Select-Object -First 1
}

function Get-EnvironmentById {
    param([Parameter(Mandatory)][string] $EnvironmentId)

    $uri = "$($script:BapEndpoint)providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$EnvironmentId" +
           "?api-version=$($script:BapApiVersion)"

    return ConvertFrom-ResponseContent -Response (Invoke-Bap -Method GET -Uri $uri)
}

function Wait-LifecycleOperation {
    param([Parameter(Mandatory)][string] $OperationUri)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $operation = ConvertFrom-ResponseContent -Response (Invoke-Bap -Method GET -Uri $OperationUri)

        $state = if ($operation -and $operation.PSObject.Properties.Name -contains 'state') { $operation.state.id } else { $null }
        Write-Host "    state: $state"

        switch ($state) {
            'Succeeded' { return $operation }
            'Failed' {
                $message = if ($operation.PSObject.Properties.Name -contains 'error') { $operation.error.message } else { 'no detail returned' }
                throw "Environment lifecycle operation failed: $message"
            }
        }

        Start-Sleep -Seconds 15
    }

    throw "Timed out after $TimeoutSeconds seconds waiting for the environment lifecycle operation."
}

function New-Environment {
    $effectiveDomain = if ($DomainName) { $DomainName } else { $DisplayName.ToLowerInvariant() -replace '[^a-z0-9-]', '-' }

    $linkedMetadata = [ordered]@{
        baseLanguage = $LanguageCode
        currency     = @{ code = $CurrencyCode }
        domainName   = $effectiveDomain
    }

    if ($SecurityGroupId) { $linkedMetadata['securityGroupId'] = $SecurityGroupId }

    $body = [ordered]@{
        location   = $Location
        properties = [ordered]@{
            displayName               = $DisplayName
            description               = $Description
            environmentSku            = $EnvironmentSku
            databaseType              = 'CommonDataService'
            linkedEnvironmentMetadata = $linkedMetadata
        }
    }

    $uri = "$($script:BapEndpoint)providers/Microsoft.BusinessAppPlatform/environments" +
           "?api-version=$($script:BapApiVersion)"

    Write-Host "    creating environment '$DisplayName' ($EnvironmentSku, $Location, domain '$effectiveDomain')"

    $response = Invoke-Bap -Method POST -Uri $uri -Body $body

    if ($response.StatusCode -eq 202) {
        $operationUri = @($response.Headers['Location'])[0]

        if (-not $operationUri) {
            throw 'The environment create request was accepted but returned no Location header to poll.'
        }

        Write-Host "    accepted; polling $operationUri"
        $operation = Wait-LifecycleOperation -OperationUri $operationUri

        $environmentPath = $operation.links.environment.path
        $environmentId = ($environmentPath -split '/')[-1]
    }
    else {
        $created = ConvertFrom-ResponseContent -Response $response
        $environmentId = $created.name
    }

    Write-Host "    environment id: $(Protect-LogValue $environmentId)" -ForegroundColor Green

    return $environmentId
}

function Wait-DataverseReady {
    param([Parameter(Mandatory)][string] $EnvironmentId)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $environment = Get-EnvironmentById -EnvironmentId $EnvironmentId

        $provisioning = $environment.properties.provisioningState
        $instanceUrl = $null

        if ($environment.properties.PSObject.Properties.Name -contains 'linkedEnvironmentMetadata') {
            $instanceUrl = $environment.properties.linkedEnvironmentMetadata.instanceUrl
        }

        Write-Host "    provisioningState: $provisioning; instanceUrl: $(Protect-LogValue $instanceUrl)"

        if ($provisioning -eq 'Succeeded' -and $instanceUrl) { return $environment }

        if ($provisioning -eq 'Failed') {
            throw "Environment $EnvironmentId reached provisioningState 'Failed'."
        }

        Start-Sleep -Seconds 15
    }

    throw "Timed out after $TimeoutSeconds seconds waiting for the Dataverse database to become available."
}

function Enable-ManagedEnvironment {
    param([Parameter(Mandatory)][string] $EnvironmentId)

    # Note the route has NO /scopes/admin/ segment, unlike every read path in this script.
    # This matches Set-AdminPowerAppEnvironmentGovernanceConfiguration in Microsoft's
    # Microsoft.PowerApps.Administration.PowerShell module. Using the admin-scoped path
    # returns HTTP 404, which reads like a missing environment but is a missing route.
    $uri = "$($script:BapEndpoint)providers/Microsoft.BusinessAppPlatform/environments/$EnvironmentId" +
           "/governanceConfiguration?api-version=$($script:BapApiVersion)"

    $body = [ordered]@{
        protectionLevel = 'Standard'
    }

    Invoke-Bap -Method POST -Uri $uri -Body $body | Out-Null
}

function Get-ManagedEnvironmentLevel {
    param([Parameter(Mandatory)][string] $EnvironmentId)

    $environment = Get-EnvironmentById -EnvironmentId $EnvironmentId

    if ($environment.properties.PSObject.Properties.Name -notcontains 'governanceConfiguration') { return 'Basic' }

    return $environment.properties.governanceConfiguration.protectionLevel
}

function Invoke-Dataverse {
    param(
        [Parameter(Mandatory)][string] $InstanceUrl,
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string] $Method,
        [Parameter(Mandatory)][string] $Path,
        [object] $Body,
        [int[]] $SuccessStatusCodes = @(200, 201, 204)
    )

    $baseUri = $InstanceUrl.TrimEnd('/')

    $headers = @{
        Authorization      = "Bearer $(Get-AccessTokenFor -Resource $baseUri)"
        'Content-Type'     = 'application/json'
        Accept             = 'application/json'
        'OData-MaxVersion' = '4.0'
        'OData-Version'    = '4.0'
    }

    $arguments = @{
        Uri                = "$baseUri/api/data/v9.2/$Path"
        Method             = $Method
        Headers            = $headers
        SkipHttpErrorCheck = $true
    }

    if ($null -ne $Body) {
        $arguments['Body'] = ($Body | ConvertTo-Json -Depth 20)
    }

    $response = Invoke-WebRequest @arguments

    if ($response.StatusCode -notin $SuccessStatusCodes) {
        throw "Dataverse $Method $Path failed with HTTP $($response.StatusCode): $($response.Content)"
    }

    if ([string]::IsNullOrWhiteSpace($response.Content)) { return $null }

    return ($response.Content | ConvertFrom-Json)
}

function Get-FirstPropertyValue {
    <#
        Reads a named property off the first element of an OData `value` array, returning $null
        when the array is empty or the property is absent.

        Under Set-StrictMode, `@($response.value)[0].someId` on an empty result throws
        PropertyNotFoundException rather than yielding $null, so the friendly `if (-not $x) { throw
        "Could not find ..." }` guard on the next line never runs and the caller sees a property
        error instead of the reason.
    #>
    param($Response, [Parameter(Mandatory)][string] $Name)

    if ($null -eq $Response) { return $null }
    if (-not $Response.PSObject.Properties['value']) { return $null }

    $first = @($Response.value) | Select-Object -First 1
    if ($null -eq $first) { return $null }
    if (-not $first.PSObject.Properties[$Name]) { return $null }

    return $first.PSObject.Properties[$Name].Value
}

function Set-DataverseApplicationUser {
    param(
        [Parameter(Mandatory)][string] $InstanceUrl,
        [Parameter(Mandatory)][string] $ApplicationId
    )

    $existing = Invoke-Dataverse -InstanceUrl $InstanceUrl -Method GET `
        -Path "systemusers?`$select=systemuserid,applicationid&`$filter=applicationid eq $ApplicationId"

    $systemUserId = $null

    if ($existing -and @($existing.value).Count -gt 0) {
        $systemUserId = Get-FirstPropertyValue -Response $existing -Name 'systemuserid'
        Write-Host "    application user already exists ($systemUserId)"
    }
    else {
        $businessUnits = Invoke-Dataverse -InstanceUrl $InstanceUrl -Method GET `
            -Path "businessunits?`$select=businessunitid&`$filter=parentbusinessunitid eq null"

        $rootBusinessUnitId = Get-FirstPropertyValue -Response $businessUnits -Name 'businessunitid'

        if (-not $rootBusinessUnitId) { throw 'Could not resolve the root business unit.' }

        $created = Invoke-Dataverse -InstanceUrl $InstanceUrl -Method POST -Path 'systemusers' -Body ([ordered]@{
                applicationid            = $ApplicationId
                'businessunitid@odata.bind' = "/businessunits($rootBusinessUnitId)"
            })

        $systemUserId = if ($created) { $created.systemuserid } else { $null }

        if (-not $systemUserId) {
            $lookup = Invoke-Dataverse -InstanceUrl $InstanceUrl -Method GET `
                -Path "systemusers?`$select=systemuserid&`$filter=applicationid eq $ApplicationId"
            $systemUserId = Get-FirstPropertyValue -Response $lookup -Name 'systemuserid'
        }

        Write-Host "    created application user $systemUserId" -ForegroundColor Green
    }

    $escapedRole = $script:SystemAdministratorRoleName.Replace("'", "''")

    $roles = Invoke-Dataverse -InstanceUrl $InstanceUrl -Method GET `
        -Path "roles?`$select=roleid,name&`$filter=name eq '$escapedRole'"

    $roleId = Get-FirstPropertyValue -Response $roles -Name 'roleid'

    if (-not $roleId) { throw "Could not find the '$($script:SystemAdministratorRoleName)' security role." }

    $assigned = Invoke-Dataverse -InstanceUrl $InstanceUrl -Method GET `
        -Path "systemusers($systemUserId)/systemuserroles_association?`$select=roleid"

    if (@($assigned.value | Where-Object { $_.roleid -eq $roleId }).Count -gt 0) {
        Write-Host "    security role '$($script:SystemAdministratorRoleName)' already assigned"
    }
    else {
        Invoke-Dataverse -InstanceUrl $InstanceUrl -Method POST `
            -Path "systemusers($systemUserId)/systemuserroles_association/`$ref" `
            -Body @{ '@odata.id' = "$($InstanceUrl.TrimEnd('/'))/api/data/v9.2/roles($roleId)" } | Out-Null

        Write-Host "    assigned security role '$($script:SystemAdministratorRoleName)'" -ForegroundColor Green
    }

    return $systemUserId
}

# ---------------------------------------------------------------------------------------------

Write-Step 'Checking Azure CLI sign-in'

$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) { throw "Not signed in. Run 'az login' first." }

Write-Host "    tenant $(Protect-LogValue $account.tenantId)"
Write-Host "    signed in as $(Protect-LogValue $account.user.name)"

# ---------------------------------------------------------------------------------------------

Write-Step "Resolving the Power Platform environment '$DisplayName'"

$environment = Get-EnvironmentByDisplayName -Name $DisplayName
$environmentId = $null

if ($environment) {
    $environmentId = $environment.name
    Write-Host "    environment already exists: $(Protect-LogValue $environmentId)"

    if (-not $AdoptExisting) {
        Write-Host ''
        Write-Warning "An environment named '$DisplayName' already exists and -AdoptExisting was not supplied."
        Write-Warning 'Nothing has been changed. Re-run with -AdoptExisting to configure it, or choose a different -DisplayName.'
        return [pscustomobject] @{
            environmentId = $environmentId
            instanceUrl   = $environment.properties.linkedEnvironmentMetadata.instanceUrl
            changed       = $false
        }
    }
}
else {
    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'Create Power Platform environment')) { return }

    $environmentId = New-Environment
}

# ---------------------------------------------------------------------------------------------

Write-Step 'Waiting for the Dataverse database'

$environment = Wait-DataverseReady -EnvironmentId $environmentId
$instanceUrl = $environment.properties.linkedEnvironmentMetadata.instanceUrl

Write-Host "    instanceUrl: $(Protect-LogValue $instanceUrl)" -ForegroundColor Green

# ---------------------------------------------------------------------------------------------

if (-not $SkipManagedEnvironment) {
    Write-Step 'Enabling Managed Environments (required by VNet support)'

    $level = Get-ManagedEnvironmentLevel -EnvironmentId $environmentId

    if ($level -eq 'Standard') {
        Write-Host '    already Standard'
    }
    elseif ($PSCmdlet.ShouldProcess($environmentId, 'Enable Managed Environments')) {
        Enable-ManagedEnvironment -EnvironmentId $environmentId
        Start-Sleep -Seconds 10
        Write-Host "    protectionLevel: $(Get-ManagedEnvironmentLevel -EnvironmentId $environmentId)" -ForegroundColor Green
    }
}
else {
    Write-Step 'Skipping Managed Environments (-SkipManagedEnvironment). VNet support will not work.'
}

# ---------------------------------------------------------------------------------------------

$applicationUserId = $null

if (-not $SkipApplicationUser) {
    if (-not $DeploymentAppId) {
        Write-Warning 'No -DeploymentAppId supplied; skipping the Dataverse application user.'
    }
    elseif ($PSCmdlet.ShouldProcess($instanceUrl, "Add application user $DeploymentAppId")) {
        Write-Step 'Adding the deployment identity as a Dataverse application user'
        $applicationUserId = Set-DataverseApplicationUser -InstanceUrl $instanceUrl -ApplicationId $DeploymentAppId
    }
}
else {
    Write-Step 'Skipping the Dataverse application user (-SkipApplicationUser)'
}

# ---------------------------------------------------------------------------------------------

Write-Step 'Done. The environment is ready'

# These are printed for reference only. Nothing needs to be stored: every deployment stage
# resolves the environment by display name at run time with
# scripts/Resolve-PowerPlatformEnvironment.ps1. They are deliberately never passed between
# GitHub Actions jobs, because GitHub redacts a job output whose value contains a masked value.
Write-Host ''
Write-Host ('  {0,-32} {1}' -f 'Environment ID', $environmentId) -ForegroundColor Green
Write-Host ('  {0,-32} {1}' -f 'Dataverse URL', $instanceUrl) -ForegroundColor Green
Write-Host ('  {0,-32} {1}' -f 'Region', $Location) -ForegroundColor Green

Write-Host ''
Write-Host '  Nothing to copy into GitHub. Set POWER_PLATFORM_REGION as a repository variable if' -ForegroundColor DarkGray
Write-Host '  you used a non-default geography.' -ForegroundColor DarkGray

return [pscustomobject] ([ordered]@{
        environmentId     = $environmentId
        instanceUrl       = $instanceUrl
        displayName       = $DisplayName
        location          = $Location
        environmentSku    = $EnvironmentSku
        managedEnvironment = (Get-ManagedEnvironmentLevel -EnvironmentId $environmentId)
        applicationUserId = $applicationUserId
        changed           = $true
    })
