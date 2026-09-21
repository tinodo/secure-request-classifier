<#
.SYNOPSIS
    Renders the Power Platform deployment settings file from its committed template.

.DESCRIPTION
    Replaces #{TOKEN}# placeholders in powerplatform/config/deploymentSettings.template.json
    with values supplied by the caller (in CI: Bicep outputs plus GitHub repository secrets and
    variables).

    The rendered file contains only environment variable values. It deliberately carries NO
    ConnectionReferences: both connectors use delegated-user OAuth, so a person creates the
    connections once in the flow designer and binds them there, and the pipeline leaves those
    bindings alone on every later import.

.PARAMETER TemplatePath
    Path to the template. Defaults to the repository's committed template.

.PARAMETER OutputPath
    Where to write the rendered settings file.

.PARAMETER Values
    Hashtable of token name to value. Tokens not supplied are looked up in environment
    variables of the same name.

.EXAMPLE
    ./New-DeploymentSettings.ps1 -OutputPath ./out/deploymentSettings.json -Values @{
        FUNCTION_BASE_URL          = 'https://func-srclass-demo-ab12cd.azurewebsites.net'
        FUNCTION_APPLICATION_ID_URI = 'api://00000000-0000-0000-0000-000000000000'
        ENVIRONMENT_LABEL          = 'Demo'
    }
#>
[CmdletBinding()]
param(
    [string] $TemplatePath = (Join-Path $PSScriptRoot '..' 'powerplatform' 'config' 'deploymentSettings.template.json'),

    [Parameter(Mandatory)]
    [string] $OutputPath,

    [hashtable] $Values = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $TemplatePath)) {
    throw "Deployment settings template not found at '$TemplatePath'."
}

$content = Get-Content -Path $TemplatePath -Raw

$tokens = [regex]::Matches($content, '#\{(?<name>[A-Z0-9_]+)\}#') |
    ForEach-Object { $_.Groups['name'].Value } |
    Select-Object -Unique

$missing = [System.Collections.Generic.List[string]]::new()
$resolved = [ordered]@{}

foreach ($token in $tokens) {
    $value = $null

    if ($Values.ContainsKey($token)) {
        $value = [string] $Values[$token]
    }
    else {
        $value = [Environment]::GetEnvironmentVariable($token)
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        $missing.Add($token)
        $value = ''
    }

    $resolved[$token] = $value
    $content = $content.Replace("#{$token}#", $value)
}

if ($missing.Count -gt 0) {
    throw "No value supplied for required token(s): $($missing -join ', ')"
}

# There is deliberately no connection handling here. Both connectors use delegated-user OAuth:
# a person creates the connections once in the flow designer and binds them there. The pipeline
# must not rebind them, because the import runs as the deployment service principal, which has no
# permission on a connection owned by a user - the bind fails with ConnectionAuthorizationFailed
# and destroys the binding on the way. See docs/limitations.md.

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory -and -not (Test-Path $outputDirectory)) {
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
}

# Strip the "//" documentation block so the importer sees a clean settings file.
$final = $content | ConvertFrom-Json
if ($final.PSObject.Properties.Name -contains '//') { $final.PSObject.Properties.Remove('//') }
if ($final.PSObject.Properties.Name -contains '$schema') { $final.PSObject.Properties.Remove('$schema') }

$final | ConvertTo-Json -Depth 20 | Set-Content -Path $OutputPath -Encoding utf8

Write-Host "Wrote deployment settings to $OutputPath" -ForegroundColor Green
Write-Host ''
Write-Host 'Resolved tokens:'
foreach ($key in $resolved.Keys) {
    $display = $resolved[$key]
    Write-Host ('  {0,-30} {1}' -f $key, ($display ? $display : '(not supplied)'))
}
