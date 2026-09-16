<#
.SYNOPSIS
    Renders the Power Platform deployment settings file from its committed template.

.DESCRIPTION
    Replaces #{TOKEN}# placeholders in powerplatform/config/deploymentSettings.template.json
    with values supplied by the caller (in CI: Bicep outputs plus GitHub repository
    *variables*, never secrets).

    The rendered file contains connection IDs and URLs. It is written to a path that is
    git-ignored and is never committed.

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
        CONNECTION_ID_WEBCONTENTS  = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        CONNECTION_ID_OFFICE365    = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    }
#>
[CmdletBinding()]
param(
    [string] $TemplatePath = (Join-Path $PSScriptRoot '..' 'powerplatform' 'config' 'deploymentSettings.template.json'),

    [Parameter(Mandatory)]
    [string] $OutputPath,

    [hashtable] $Values = @{},

    [switch] $AllowMissingConnections
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

# Connection IDs are the one set of values that cannot be produced by automation: the
# "HTTP with Microsoft Entra ID (preauthorized)" connector uses a delegated-user connection
# that a person must create once. See docs/limitations.md.
$connectionTokens = @($missing | Where-Object { $_ -like 'CONNECTION_ID_*' })
$otherMissing = @($missing | Where-Object { $_ -notlike 'CONNECTION_ID_*' })

if ($otherMissing.Count -gt 0) {
    throw "No value supplied for required token(s): $($otherMissing -join ', ')"
}

if ($connectionTokens.Count -gt 0) {
    if (-not $AllowMissingConnections) {
        throw @"
No value supplied for connection token(s): $($connectionTokens -join ', ')

These are the IDs of connections that already exist in the target Power Platform environment.
List them with:

    pac connection list --environment <environment-url>

then set them as GitHub repository variables (they are identifiers, not credentials):

    gh variable set POWER_PLATFORM_CONNECTION_ID_WEBCONTENTS --body <guid>
    gh variable set POWER_PLATFORM_CONNECTION_ID_OFFICE365   --body <guid>

Re-run with -AllowMissingConnections to import the solution without binding connections; the
flow will import but stay unbound and cannot be turned on.
"@
    }

    Write-Warning "Connection token(s) not supplied: $($connectionTokens -join ', ')."
    Write-Warning 'The solution will import, but its connection references will be unbound and the flow cannot be activated.'

    # Remove unbound connection reference entries rather than writing empty GUIDs, which the
    # importer rejects.
    $settings = $content | ConvertFrom-Json
    $settings.ConnectionReferences = @(
        $settings.ConnectionReferences | Where-Object { -not [string]::IsNullOrWhiteSpace($_.ConnectionId) }
    )
    $content = $settings | ConvertTo-Json -Depth 20
}

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
    $display = if ($key -like 'CONNECTION_ID_*' -and $resolved[$key]) { "$($resolved[$key].Substring(0, [Math]::Min(8, $resolved[$key].Length)))..." } else { $resolved[$key] }
    Write-Host ('  {0,-30} {1}' -f $key, ($display ? $display : '(not supplied)'))
}
