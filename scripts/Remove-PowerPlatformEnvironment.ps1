<#
.SYNOPSIS
    Deletes a Power Platform environment created by New-PowerPlatformEnvironment.ps1.

.DESCRIPTION
    The counterpart to New-PowerPlatformEnvironment.ps1. The deploy pipeline creates the
    environment, so the destroy pipeline has to be able to delete it, otherwise "destroy" leaves
    the largest thing the deployment made still standing.

    Deletion goes through the same Business Application Platform admin API the provisioning
    script uses:

        POST   .../scopes/admin/environments/{id}/validateDelete   preflight, advisory
        DELETE .../scopes/admin/environments/{id}                  202 + a lifecycle operation

    Safety: the environment's display name must match -ExpectedDisplayName. The provisioning
    script runs with -AdoptExisting, so the environment this deletes is not guaranteed to be one
    the pipeline created; refusing to delete anything whose name does not match the configured
    name is what keeps it from eating an unrelated environment.

.PARAMETER EnvironmentId
    The environment to delete.

.PARAMETER ExpectedDisplayName
    Required unless -SkipNameCheck. The deletion is refused unless the environment's display name
    matches this exactly.

.PARAMETER SkipNameCheck
    Bypass the display-name guard. Use only when you are certain.

.PARAMETER TimeoutSeconds
    How long to wait for the delete lifecycle operation.

.EXAMPLE
    ./Remove-PowerPlatformEnvironment.ps1 -EnvironmentId 1111... -ExpectedDisplayName srclass-demo -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string] $EnvironmentId,

    [string] $ExpectedDisplayName,

    [switch] $SkipNameCheck,

    [int] $TimeoutSeconds = 1800
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BapEndpoint = 'https://api.bap.microsoft.com/'
$script:BapApiVersion = '2021-04-01'
$script:TokenResource = 'https://service.powerapps.com/'

function Write-Step { param([string] $Message) Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }

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
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'DELETE')][string] $Method,
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

    if ($null -ne $Body) { $arguments['Body'] = ($Body | ConvertTo-Json -Depth 20) }

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

function Get-Environment {
    param([Parameter(Mandatory)][string] $Id)

    $uri = "$($script:BapEndpoint)providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$Id" +
           "?api-version=$($script:BapApiVersion)"

    $response = Invoke-WebRequest -Uri $uri -Method GET -SkipHttpErrorCheck -Headers @{
        Authorization = "Bearer $(Get-AccessTokenFor -Resource $script:TokenResource)"
    }

    if ($response.StatusCode -eq 404) { return $null }

    if ($response.StatusCode -ne 200) {
        throw "GET $uri failed with HTTP $($response.StatusCode): $($response.Content)"
    }

    return ConvertFrom-ResponseContent -Response $response
}

function Wait-LifecycleOperation {
    param([Parameter(Mandatory)][string] $OperationUri)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $response = Invoke-WebRequest -Uri $OperationUri -Method GET -SkipHttpErrorCheck -Headers @{
            Authorization = "Bearer $(Get-AccessTokenFor -Resource $script:TokenResource)"
        }

        # Once the environment is gone the operation resource can disappear with it.
        if ($response.StatusCode -in @(404, 403)) {
            Write-Host '    operation resource no longer readable; treating the delete as complete'
            return
        }

        $operation = ConvertFrom-ResponseContent -Response $response

        $state = $null
        if ($operation -and $operation.PSObject.Properties.Name -contains 'state') {
            $state = $operation.state.id
        }

        Write-Host "    state: $state"

        switch ($state) {
            'Succeeded' { return }
            'Failed' {
                $message = 'no detail returned'
                if ($operation.PSObject.Properties.Name -contains 'error') { $message = $operation.error.message }
                throw "Environment delete failed: $message"
            }
        }

        Start-Sleep -Seconds 15
    }

    throw "Timed out after $TimeoutSeconds seconds waiting for the environment to delete."
}

# ---------------------------------------------------------------------------------------------

Write-Step "Inspecting Power Platform environment '$EnvironmentId'"

$environment = Get-Environment -Id $EnvironmentId

if (-not $environment) {
    Write-Warning "Environment '$EnvironmentId' does not exist. Nothing to delete."
    return
}

$displayName = $environment.properties.displayName
Write-Host "    display name : $displayName"
Write-Host "    type         : $($environment.properties.environmentSku)"

if (-not $SkipNameCheck) {
    if ([string]::IsNullOrWhiteSpace($ExpectedDisplayName)) {
        throw 'Pass -ExpectedDisplayName (or -SkipNameCheck). Refusing to delete an environment without confirming which one it is.'
    }

    if ($displayName -ne $ExpectedDisplayName) {
        throw @"
Refusing to delete environment '$EnvironmentId'.

Its display name is '$displayName', but '$ExpectedDisplayName' was expected. The provisioning
script adopts an existing environment when one already carries the configured name, so this
environment may not be one the pipeline created.

Re-run with -SkipNameCheck only if you are certain.
"@
    }
}

# ---------------------------------------------------------------------------------------------

Write-Step 'Checking whether the environment can be deleted'

# Advisory only. Some tenants and environment types do not expose this route, and a 404 here says
# nothing about whether the delete itself will succeed.
try {
    $validateUri = "$($script:BapEndpoint)providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$EnvironmentId" +
                   "/validateDelete?api-version=$($script:BapApiVersion)"

    $validation = ConvertFrom-ResponseContent -Response (Invoke-Bap -Method POST -Uri $validateUri)

    if ($validation -and $validation.PSObject.Properties.Name -contains 'canInitiateDelete') {
        Write-Host "    canInitiateDelete: $($validation.canInitiateDelete)"

        if (-not $validation.canInitiateDelete) {
            $reasons = 'no detail returned'
            if ($validation.PSObject.Properties.Name -contains 'errors' -and $validation.errors) {
                $reasons = ($validation.errors | ForEach-Object { $_.message }) -join '; '
            }
            Write-Warning "The service says the environment cannot be deleted yet: $reasons"
        }
    }
}
catch {
    Write-Warning "validateDelete was not usable ($($_.Exception.Message)). Continuing to the delete itself."
}

# ---------------------------------------------------------------------------------------------

if (-not $PSCmdlet.ShouldProcess("$displayName ($EnvironmentId)", 'Delete Power Platform environment and all data in it')) {
    return
}

Write-Step "Deleting environment '$displayName'"
Write-Host '    This permanently destroys the Dataverse database and everything in it.' -ForegroundColor Yellow

$deleteUri = "$($script:BapEndpoint)providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$EnvironmentId" +
             "?api-version=$($script:BapApiVersion)"

$response = Invoke-Bap -Method DELETE -Uri $deleteUri

$operationUri = $null
foreach ($header in @('Location', 'Operation-Location')) {
    if ($response.Headers.Keys -contains $header) {
        $operationUri = @($response.Headers[$header])[0]
        break
    }
}

if ($response.StatusCode -eq 202 -and $operationUri) {
    Write-Host '    delete accepted; waiting for it to finish'
    Wait-LifecycleOperation -OperationUri $operationUri
}
elseif ($response.StatusCode -eq 202) {
    Write-Warning 'Delete accepted but no operation URI was returned; polling the environment instead.'

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Environment -Id $EnvironmentId)) { break }
        Start-Sleep -Seconds 15
    }
}

# ---------------------------------------------------------------------------------------------

Write-Step 'Confirming the environment is gone'

$remaining = Get-Environment -Id $EnvironmentId

if ($remaining) {
    throw "Environment '$displayName' ($EnvironmentId) still exists after the delete completed."
}

Write-Host "    '$displayName' is deleted." -ForegroundColor Green
