<#
.SYNOPSIS
    Packs the Power Platform solution, including the canvas app when a .msapp is available.

.DESCRIPTION
    Produces powerplatform/out/SecureRequestClassifier.zip from the source under
    powerplatform/solution/src.

    The canvas app is handled specially. Microsoft's supported source-control mechanism for
    canvas apps is Power Platform Git integration, which stores the app as .pa.yaml. The
    `pac canvas pack` command that would turn that YAML back into a binary .msapp is
    deprecated and refuses to run on sources that have not first been validated by opening the
    app in Power Apps Studio:

        "Canvas apps packed using yaml SourceCode must be validated first by opening the app
         for edit within the Power Apps studio."  -- pac canvas pack, https://aka.ms/paccanvas
        "The pack and unpack commands are deprecated. To source control your canvas app, use
         the Power Platform Git Integration."
         -- https://learn.microsoft.com/en-us/power-platform/developer/cli/reference/canvas

    So this script does the following:
      * If powerplatform/solution/src/CanvasApps contains a .msapp, it is packed as-is.
      * Otherwise, if -CanvasSourcePath contains Studio-validated sources, `pac canvas pack`
        is attempted.
      * Otherwise the solution is packed WITHOUT the canvas app, and the script explains the
        single manual step that produces it. The flow, connection references and environment
        variables - that is, the whole private-networking demo - still deploy and run.

.PARAMETER OutputPath
    Path of the solution zip to produce.

.PARAMETER SolutionType
    Unmanaged, Managed or Both.

.EXAMPLE
    ./Build-Solution.ps1
#>
[CmdletBinding()]
param(
    [string] $SourcePath = (Join-Path $PSScriptRoot '..' 'powerplatform' 'solution' 'src'),

    [string] $CanvasSourcePath = (Join-Path $PSScriptRoot '..' 'powerplatform' 'canvas-app' 'src'),

    [string] $OutputPath = (Join-Path $PSScriptRoot '..' 'powerplatform' 'out' 'SecureRequestClassifier.zip'),

    [ValidateSet('Unmanaged', 'Managed', 'Both')]
    [string] $SolutionType = 'Unmanaged',

    [string] $CanvasAppSchemaName = 'srcls_securerequestclassifier'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string] $Message) Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }

$SourcePath = (Resolve-Path $SourcePath).Path
$canvasAppsDirectory = Join-Path $SourcePath 'CanvasApps'

Write-Step 'Checking for a canvas app binary'

$existingMsapp = $null
if (Test-Path $canvasAppsDirectory) {
    $existingMsapp = Get-ChildItem -Path $canvasAppsDirectory -Filter '*.msapp' -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
}

if ($existingMsapp) {
    Write-Host "    found $($existingMsapp.Name); it will be included in the solution." -ForegroundColor Green
}
else {
    $hasCanvasSources = (Test-Path $CanvasSourcePath) -and
        @(Get-ChildItem -Path $CanvasSourcePath -Filter '*.pa.yaml' -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0

    if ($hasCanvasSources) {
        Write-Host '    no .msapp present; attempting pac canvas pack from the YAML sources.'

        New-Item -ItemType Directory -Force -Path $canvasAppsDirectory | Out-Null
        $targetMsapp = Join-Path $canvasAppsDirectory "$($CanvasAppSchemaName)_DocumentUri.msapp"

        $packOutput = & pac canvas pack --sources $CanvasSourcePath --msapp $targetMsapp --layout SourceCode --overwrite 2>&1 | Out-String

        if ($LASTEXITCODE -eq 0 -and (Test-Path $targetMsapp)) {
            Write-Host '    canvas app packed successfully.' -ForegroundColor Green
        }
        else {
            Write-Host ''
            Write-Warning 'pac canvas pack could not build the .msapp from source. This is expected on a clean clone.'
            Write-Host ''
            Write-Host '    Reason reported by the CLI:' -ForegroundColor Yellow
            $packOutput -split "`n" | Select-Object -First 4 | ForEach-Object { Write-Host "      $_" -ForegroundColor Yellow }
            Write-Host ''
            Write-Host '    One-time action that fixes this permanently (see docs/limitations.md):' -ForegroundColor Yellow
            Write-Host '      1. make.powerapps.com > Apps > New app > Start with a blank canvas.'
            Write-Host "      2. Build the form described in $CanvasSourcePath/RequestScreen.pa.yaml,"
            Write-Host '         add the ClassifyandNotify flow, and save the app into the'
            Write-Host '         SecureRequestClassifier solution.'
            Write-Host '      3. Export the unmanaged solution and run:'
            Write-Host "           pac solution unpack --zipfile <export>.zip --folder $SourcePath --packagetype Unmanaged"
            Write-Host '         Commit the resulting CanvasApps/*.msapp and *.meta.xml.'
            Write-Host ''
            Write-Host '    Continuing without the canvas app. The cloud flow still deploys and can be run'
            Write-Host '    directly from Power Automate, which exercises the entire private network path.'

            Remove-Item -Path $targetMsapp -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        Write-Host "    no canvas sources found at $CanvasSourcePath; packing without a canvas app."
    }
}

Write-Step 'Packing the solution'

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path $outputDirectory)) { New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null }

& pac solution pack --zipfile $OutputPath --folder $SourcePath --packagetype $SolutionType --errorlevel Warning

if ($LASTEXITCODE -ne 0) {
    throw "pac solution pack failed with exit code $LASTEXITCODE."
}

$zip = Get-Item $OutputPath
Write-Host ''
Write-Host "    packed $($zip.FullName) ($([math]::Round($zip.Length / 1KB, 1)) KB)" -ForegroundColor Green

if ($env:GITHUB_OUTPUT) {
    "solution-path=$($zip.FullName)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "has-canvas-app=$([bool](Get-ChildItem -Path $canvasAppsDirectory -Filter '*.msapp' -File -ErrorAction SilentlyContinue))" |
        Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}
