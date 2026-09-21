#Requires -Version 7.0

<#
.SYNOPSIS
    Checks every flow action's parameter names against the connector's own operation schema.

.DESCRIPTION
    A Power Automate OpenApiConnection action addresses the properties of a body parameter with
    slash notation: "<bodyParameter>/<property>". For the Office 365 Outlook SendEmailV2
    operation, whose body parameter is "emailMessage", that is "emailMessage/To".

    Get it wrong and nothing complains. The solution imports, the flow saves, and the designer
    renders the action with every field EMPTY and the required ones flagged as missing, because
    the supplied names bound to nothing. That is exactly what happened to the HTTP action here:
    it passed method / url / headers / body flat, when InvokeHttp takes a single body parameter
    named "request", so the correct names are request/method, request/url and so on.

    This script reads the live connector definition from the environment - not a checked-in copy,
    which could itself drift - and asserts that every parameter the flow supplies is one the
    operation actually accepts.

    Requires a Power Platform token, so it runs against a real environment rather than in
    offline CI.

.PARAMETER EnvironmentId
    Environment whose connector definitions to read.

.PARAMETER FlowPath
    The flow definition JSON. Defaults to the solution's only flow.

.EXAMPLE
    ./Test-FlowConnectorParameters.ps1 -EnvironmentId 1111...
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $EnvironmentId,

    [string] $FlowPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Validate every OpenApiConnection action's parameter names against the live connector swagger.
# A flat parameter name that is actually a property of a body parameter binds to nothing: the
# designer renders the action with every field empty and marks the required ones missing.

$envId = $EnvironmentId
$token = az account get-access-token --resource 'https://service.powerapps.com/' --query accessToken -o tsv 2>$null
if (-not $token) { throw 'no Power Platform token' }

$headers = @{ Authorization = "Bearer $token" }
$swaggerCache = @{}

function Get-Swagger {
    param([string] $ApiName)

    if ($swaggerCache.ContainsKey($ApiName)) { return $swaggerCache[$ApiName] }

    $uri = "https://api.powerapps.com/providers/Microsoft.PowerApps/apis/$ApiName" +
           "?api-version=2016-11-01&`$filter=environment eq '$envId'"
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 60
    $swaggerCache[$ApiName] = $response.properties.swagger
    return $swaggerCache[$ApiName]
}

$flowFile = if ($FlowPath) {
    Get-Item -LiteralPath $FlowPath
}
else {
    Get-ChildItem (Join-Path $PSScriptRoot '..' 'powerplatform' 'solution' 'src' 'Workflows') -Filter '*.json' |
        Select-Object -First 1
}

$flow = Get-Content $flowFile.FullName -Raw | ConvertFrom-Json

$failed = $false

foreach ($action in $flow.properties.definition.actions.PSObject.Properties) {
    $inputs = $action.Value.inputs
    if ($action.Value.type -ne 'OpenApiConnection') { continue }

    $apiName = ($inputs.host.apiId -split '/')[-1]
    $operationId = $inputs.host.operationId

    $swagger = Get-Swagger -ApiName $apiName

    $operation = $null
    foreach ($path in $swagger.paths.PSObject.Properties) {
        foreach ($method in $path.Value.PSObject.Properties) {
            if ($method.Value.operationId -eq $operationId) { $operation = $method.Value }
        }
    }

    if (-not $operation) {
        Write-Host "[FAIL] $($action.Name): operation '$operationId' not found in $apiName"
        $failed = $true
        continue
    }

    # Names the connector accepts: every non-path parameter, plus <bodyParam>/<property> for
    # each property of a body parameter.
    $accepted = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($param in $operation.parameters) {
        if ($param.in -eq 'path') { continue }

        if ($param.in -ne 'body') { [void] $accepted.Add($param.name); continue }

        [void] $accepted.Add($param.name)

        $schema = $param.schema
        if ($schema.'$ref') {
            $definitionName = ($schema.'$ref' -split '/')[-1]
            $schema = $swagger.definitions.$definitionName
        }

        foreach ($property in $schema.properties.PSObject.Properties) {
            [void] $accepted.Add("$($param.name)/$($property.Name)")
        }
    }

    foreach ($supplied in $inputs.parameters.PSObject.Properties) {
        if ($accepted.Contains($supplied.Name)) {
            Write-Host "[ OK ] $($action.Name): '$($supplied.Name)'"
        }
        else {
            Write-Host "[FAIL] $($action.Name): '$($supplied.Name)' is not a parameter of $operationId"
            Write-Host "       accepted: $(($accepted | Sort-Object) -join ', ')"
            $failed = $true
        }
    }
}

if ($failed) { exit 1 }
Write-Host ''
Write-Host 'every action parameter matches its connector operation'
