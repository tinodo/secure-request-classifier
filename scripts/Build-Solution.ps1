<#
.SYNOPSIS
    Packs the Power Platform solution.

.DESCRIPTION
    Produces powerplatform/out/SecureRequestClassifier.zip from the source under
    powerplatform/solution/src.

    The solution contains the Classify and Notify cloud flow, its two connection references,
    and the environment variables the flow reads. There is no canvas app: the flow's PowerApps
    (V2) trigger renders the input form, and `pac canvas pack` is deprecated and cannot build an
    .msapp from YAML that has not been opened in Power Apps Studio, so no app binary can be
    produced by a pipeline from a clean clone. See docs/limitations.md.

.PARAMETER SourcePath
    Unpacked solution source to pack.

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

    [string] $OutputPath = (Join-Path $PSScriptRoot '..' 'powerplatform' 'out' 'SecureRequestClassifier.zip'),

    [ValidateSet('Unmanaged', 'Managed', 'Both')]
    [string] $SolutionType = 'Unmanaged'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string] $Message) Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }

function Resolve-PacCommand {
    <#
        The microsoft/powerplatform-actions install action exports the CLI location as
        POWERPLATFORMTOOLS_PACPATH but does not reliably add it to PATH for later `run:` steps,
        so calling `pac` bare fails with "The term 'pac' is not recognized". Resolve it
        explicitly: PATH first, then the action's own hint, which may name either the executable
        or the directory containing it.
    #>
    $onPath = Get-Command 'pac' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($onPath) { return $onPath.Source }

    $hint = $env:POWERPLATFORMTOOLS_PACPATH
    if (-not [string]::IsNullOrWhiteSpace($hint)) {
        if (Test-Path -LiteralPath $hint -PathType Leaf) {
            return (Resolve-Path -LiteralPath $hint).Path
        }

        if (Test-Path -LiteralPath $hint -PathType Container) {
            $candidate = Get-ChildItem -LiteralPath $hint -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq 'pac' -or $_.Name -eq 'pac.exe' } |
                Select-Object -First 1
            if ($candidate) { return $candidate.FullName }
        }
    }

    return $null
}

$pac = Resolve-PacCommand
if (-not $pac) {
    throw @'
The Power Platform CLI (pac) was not found.

In GitHub Actions, add this before calling the script:
    - uses: microsoft/powerplatform-actions/actions-install@v1

Locally, install it with:
    dotnet tool install --global Microsoft.PowerApps.CLI.Tool
'@
}

Write-Step 'Locating the Power Platform CLI'
Write-Host "    using pac at $pac"

$SourcePath = (Resolve-Path $SourcePath).Path

Write-Step 'Packing the solution'

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path $outputDirectory)) { New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null }

& $pac solution pack --zipfile $OutputPath --folder $SourcePath --packagetype $SolutionType --errorlevel Warning

if ($LASTEXITCODE -ne 0) {
    throw "pac solution pack failed with exit code $LASTEXITCODE."
}

$zip = Get-Item $OutputPath
Write-Host ''
Write-Host "    packed $($zip.FullName) ($([math]::Round($zip.Length / 1KB, 1)) KB)" -ForegroundColor Green

if ($env:GITHUB_OUTPUT) {
    "solution-path=$($zip.FullName)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}
