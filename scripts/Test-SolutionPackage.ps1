<#
.SYNOPSIS
    Fails if the packed Power Platform solution is not a clean SolutionPackager package.

.DESCRIPTION
    There are two different on-disk solution formats, and `pac solution pack` will happily mix
    them:

      * SolutionPackager format - components live inline in Other/Customizations.xml.
      * Git integration format  - components live in per-component folders, for example
                                  environmentvariabledefinitions/<schemaname>/.

    A Git-integration folder dropped into a SolutionPackager source tree is NOT folded into
    customizations.xml. It is copied into the zip verbatim, `pac solution pack` returns exit code
    0, and the failure only appears later, inside Dataverse, as the entirely unhelpful

        An unexpected error occurred.

    whose real text is

        System.InvalidOperationException: The specified node cannot be inserted as the valid
        child of this node, because the specified node is the wrong type.
           at System.Xml.XmlNode.AppendChild(XmlNode newChild)
           at Microsoft.Crm.Tools.ImportExportPublish.SourceControlHandler.ImportEntityFromFile(...)

    This script asserts, on the packed zip, that:
      1. the zip contains only entries a SolutionPackager package is allowed to contain;
      2. no root component declared in solution.xml is missing from customizations.xml.

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

# Top-level folders a SolutionPackager zip is allowed to contain. Anything else is either a
# Git-integration component folder or a stray file, and both break the import.
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
                "'$($segments[0])/' is a Git-integration component folder, not a SolutionPackager " +
                "folder. Move its contents inline into powerplatform/solution/src/Other/Customizations.xml " +
                "and delete the folder. Offending entry: $entry")
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
        # Component type -> the element that must carry it in customizations.xml, and the
        # attribute that holds its schema name.
        $componentTypes = @{
            '372' = @{ Path = 'connectionreferences/connectionreference'; Attribute = 'connectionreferencelogicalname'; Label = 'connection reference' }
            '380' = @{ Path = 'environmentvariabledefinitions/environmentvariabledefinition'; Attribute = 'schemaname'; Label = 'environment variable definition' }
        }

        $rootComponents = $solutionXml.SelectNodes('//RootComponent')

        foreach ($component in $rootComponents) {
            $type = $component.GetAttribute('type')
            if (-not $componentTypes.ContainsKey($type)) { continue }

            $schemaName = $component.GetAttribute('schemaName')
            if ([string]::IsNullOrWhiteSpace($schemaName)) { continue }

            # Dataverse stores '_' as '_5F' in RootComponent schema names.
            $logicalName = $schemaName -replace '_5F', '_'

            $definition = $componentTypes[$type]
            $matched = $customizationsXml.SelectNodes("/ImportExportXml/$($definition.Path)") |
                Where-Object { $_.GetAttribute($definition.Attribute) -eq $logicalName }

            if (-not $matched) {
                $failures.Add(
                    "root component type $type ($($definition.Label)) '$schemaName' is declared in " +
                    "solution.xml but has no <$(Split-Path -Leaf ($definition.Path -replace '/', '\'))> " +
                    "entry in customizations.xml")
            }
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
