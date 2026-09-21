#Requires -Version 7.0

<#
.SYNOPSIS
    Fails if the packed Power Platform solution is not a clean SolutionPackager package.

.DESCRIPTION
    Two things have made the Dataverse import fail in ways `pac solution pack` reports as success.

    1. Component folders that were not folded into customizations.xml.

       `pac solution pack` copies a component folder it does not understand - for example
       environmentvariabledefinitions/<schemaname>/ - into the zip verbatim, and exits 0.
       Dataverse then reaches it through its source-control handler and dies with

           An unexpected error occurred.

       whose real text is

           System.InvalidOperationException: The specified node cannot be inserted as the valid
           child of this node, because the specified node is the wrong type.
              at System.Xml.XmlNode.AppendChild(XmlNode newChild)
              at Microsoft.Crm.Tools.ImportExportPublish.SourceControlHandler.ImportEntityFromFile(...)

       This repository therefore keeps every such component inline in Other/Customizations.xml,
       which is what `pac solution unpack` produces for it, and the zip must contain no loose
       component folders at all.

    2. Connection references and environment variable definitions listed as root components.

       Type 372 is "Connector" - a custom connector - and the componenttype choice has no value
       for a connection reference at all. Declaring one as a root component fails the import with

           Cannot add a Root Component <name> of type 372 because it is not in the target system.

    This script asserts both invariants on the packed zip.

.PARAMETER SolutionPath
    The packed solution zip to inspect.

.EXAMPLE
    ./Test-SolutionPackage.ps1
#>
[CmdletBinding()]
param(
    [string] $SolutionPath = (Join-Path $PSScriptRoot '..' 'powerplatform' 'out' 'SecureRequestClassifier.zip')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SolutionPath)) {
    throw "Solution package not found at $SolutionPath. Run scripts/Build-Solution.ps1 first."
}

$SolutionPath = (Resolve-Path -LiteralPath $SolutionPath).Path

Add-Type -AssemblyName System.IO.Compression.FileSystem

$failures = [System.Collections.Generic.List[string]]::new()

# Top-level folders the packed zip is allowed to contain. These carry binary or free-form
# payloads that cannot be expressed inline in customizations.xml. Anything else is a component
# folder `pac solution pack` failed to fold in, and it will break the import.
$allowedFolders = @('Workflows', 'CanvasApps', 'WebResources', 'AppModules', 'Reports', 'Formulas', 'pluginassemblies')
$allowedRootFiles = @('solution.xml', 'customizations.xml', '[Content_Types].xml', 'content_types.xml')

$archive = [System.IO.Compression.ZipFile]::OpenRead($SolutionPath)
try {
    $entries = @($archive.Entries | ForEach-Object { $_.FullName })

    Write-Host ''
    Write-Host "==> Inspecting $(Split-Path -Leaf $SolutionPath)" -ForegroundColor Cyan
    $entries | Sort-Object | ForEach-Object { Write-Host "    $_" }

    foreach ($entry in $entries) {
        $segments = $entry -split '/'

        if ($segments.Count -eq 1) {
            if ($allowedRootFiles -notcontains $segments[0]) {
                $failures.Add("unexpected file at the root of the package: $entry")
            }
            continue
        }

        if ($allowedFolders -notcontains $segments[0]) {
            $failures.Add(
                "'$($segments[0])/' was copied into the package verbatim instead of being folded " +
                'into customizations.xml. Move its contents inline into ' +
                'powerplatform/solution/src/Other/Customizations.xml and delete the folder. ' +
                "Offending entry: $entry")
        }
    }

    function Get-EntryXml {
        param([Parameter(Mandatory)][string] $Name)

        $entry = $archive.GetEntry($Name)
        if (-not $entry) { return $null }

        $reader = [System.IO.StreamReader]::new($entry.Open())
        try { return [xml] $reader.ReadToEnd() } finally { $reader.Dispose() }
    }

    $solutionXml = Get-EntryXml -Name 'solution.xml'
    $customizationsXml = Get-EntryXml -Name 'customizations.xml'

    if (-not $solutionXml) { $failures.Add('the package has no solution.xml') }
    if (-not $customizationsXml) { $failures.Add('the package has no customizations.xml') }

    if ($solutionXml -and $customizationsXml) {
        # Connection references and environment variable definitions must NOT be root components.
        #
        # Type 372 is "Connector" - a custom connector. The componenttype choice has no value for
        # a connection reference at all. Listing one as a root component fails the import with
        #   Cannot add a Root Component <name> of type 372 because it is not in the target system.
        # Environment variable definitions (380) behave the same way. Microsoft's own solutions
        # declare both only in customizations.xml; see the note in Other/Solution.xml.
        $forbiddenRootComponents = @{
            '372' = 'a connection reference (type 372 is a custom connector)'
            '380' = 'an environment variable definition'
        }

        foreach ($component in $solutionXml.SelectNodes('//RootComponent')) {
            $type = $component.GetAttribute('type')
            if (-not $forbiddenRootComponents.ContainsKey($type)) { continue }

            $name = $component.GetAttribute('schemaName')
            if ([string]::IsNullOrWhiteSpace($name)) { $name = $component.GetAttribute('id') }

            $failures.Add(
                "solution.xml declares '$name' as a root component of type $type. " +
                "$($forbiddenRootComponents[$type]) belongs in customizations.xml only - remove " +
                'the RootComponent line.')
        }

        # Everything the flow connects through has to be declared in customizations.xml, because
        # that is now the only place carrying it.
        $connectionReferences = @($customizationsXml.SelectNodes(
                '/ImportExportXml/connectionreferences/connectionreference'))

        if ($connectionReferences.Count -eq 0) {
            $failures.Add('customizations.xml declares no connection references')
        }

        $definitions = @($customizationsXml.SelectNodes(
                '/ImportExportXml/environmentvariabledefinitions/environmentvariabledefinition'))

        if ($definitions.Count -eq 0) {
            $failures.Add('customizations.xml declares no environment variable definitions')
        }
    }
}
finally {
    $archive.Dispose()
}

Write-Host ''

if ($failures.Count -gt 0) {
    Write-Host '==> FAILED' -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    Write-Host ''
    exit 1
}

Write-Host '==> The package is a clean SolutionPackager package.' -ForegroundColor Green
Write-Host ''
