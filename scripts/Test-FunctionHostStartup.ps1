#Requires -Version 7.0

<#
.SYNOPSIS
    Starts the real Azure Functions host against the published output and asserts that every
    function in the source is actually indexed.

.DESCRIPTION
    Building and unit-testing the function project proves the code compiles and that its methods
    behave. It does not prove the Functions host can start the isolated worker, and that is a
    genuinely different question: the worker is a separate process that loads the published
    assemblies together with the host's own dependencies.

    When those dependencies disagree the worker aborts before it registers anything. The host
    reports "0 functions found", keeps its own built-in warm-up endpoint, and answers 404 on every
    real route. Deployment still succeeds, because nothing about publishing a broken worker fails.

    That is not hypothetical. This repository shipped exactly that failure: a transitive upgrade to
    Microsoft.ApplicationInsights 3.x removed the ITelemetryInitializer type that
    Microsoft.Azure.Functions.Worker.ApplicationInsights binds against, so the worker died with

        System.TypeLoadException: Could not load type
        'Microsoft.ApplicationInsights.Extensibility.ITelemetryInitializer'

    and every call to /api/requests/classify returned 404. Build was green. Tests were green.
    Deployment was green. The demo was broken.

    This script closes that gap by doing the only thing that actually detects it: starting the host
    and reading back the list of functions it managed to index.

    The expected function names are discovered from the source, so a newly added function is
    covered automatically and cannot silently fail to register.

.PARAMETER ProjectPath
    The function project to publish and start. Defaults to the repository's function project.

.PARAMETER TimeoutSeconds
    How long to wait for the host to finish indexing. Cold starts on hosted runners are slow.

.EXAMPLE
    ./scripts/Test-FunctionHostStartup.ps1
#>

[CmdletBinding()]
param(
    [string] $ProjectPath,
    [int]    $TimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not $ProjectPath) {
    $ProjectPath = Join-Path $repoRoot 'src/function/SecureRequestClassifier.Functions/SecureRequestClassifier.Functions.csproj'
}

if (-not (Test-Path $ProjectPath)) {
    throw "Function project not found: $ProjectPath"
}

$projectDir = Split-Path -Parent $ProjectPath

# ---------------------------------------------------------------------------------------------
# Work out which functions the source declares, so the assertion follows the code.
# ---------------------------------------------------------------------------------------------

$expected = Get-ChildItem -Path $projectDir -Filter '*.cs' -Recurse |
    Select-String -Pattern '\[Function\(\s*"([^"]+)"\s*\)\]' -AllMatches |
    ForEach-Object { $_.Matches } |
    ForEach-Object { $_.Groups[1].Value } |
    Sort-Object -Unique

if (-not $expected -or $expected.Count -eq 0) {
    throw "Found no [Function(...)] declarations under $projectDir. Either the project moved or the detection is wrong; refusing to pass a test that cannot fail."
}

Write-Host "Functions declared in source: $($expected -join ', ')"

# ---------------------------------------------------------------------------------------------
# Publish.
# ---------------------------------------------------------------------------------------------

$publishDir = Join-Path ([IO.Path]::GetTempPath()) "func-startup-$([Guid]::NewGuid().ToString('N'))"

Write-Host "Publishing to $publishDir"
dotnet publish $ProjectPath --configuration Release --output $publishDir --nologo --verbosity quiet
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE."
}

# ---------------------------------------------------------------------------------------------
# Make sure the Functions host is available.
# ---------------------------------------------------------------------------------------------

if (-not (Get-Command func -ErrorAction SilentlyContinue)) {
    Write-Host 'Azure Functions Core Tools not present; installing.'
    npm install --global azure-functions-core-tools@4 --unsafe-perm true
    if ($LASTEXITCODE -ne 0) {
        throw "Could not install Azure Functions Core Tools (npm exited $LASTEXITCODE)."
    }
}

# ---------------------------------------------------------------------------------------------
# Start the host and read back what it indexed.
# ---------------------------------------------------------------------------------------------

# The worker only needs to start and register; it never serves a request here, so there is no
# storage account and no telemetry endpoint to point it at.
$env:AzureWebJobsStorage = ''
$env:APPLICATIONINSIGHTS_CONNECTION_STRING = ''
$env:FUNCTIONS_WORKER_RUNTIME = 'dotnet-isolated'

$stdout = Join-Path $publishDir 'host.out.log'
$stderr = Join-Path $publishDir 'host.err.log'

$process = Start-Process -FilePath 'func' `
    -ArgumentList 'start', '--no-build', '--port', '7099' `
    -WorkingDirectory $publishDir `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr `
    -PassThru

$indexed = @()
$failure = $null
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)

try {
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3

        $log = @(
            (Get-Content $stdout -ErrorAction SilentlyContinue)
            (Get-Content $stderr -ErrorAction SilentlyContinue)
        ) -join "`n"

        if (-not $log) {
            if ($process.HasExited) {
                $failure = "The host exited with code $($process.ExitCode) before producing any output."
                break
            }
            continue
        }

        # The worker failing is reported by the host rather than thrown, so look for it explicitly.
        foreach ($symptom in @(
            'Failed to start language worker process',
            'Exceeded language worker restart retry count',
            'Unhandled exception',
            'TypeLoadException',
            'FileNotFoundException',
            'MissingMethodException')) {

            if ($log -match [regex]::Escape($symptom)) {
                $detail = ($log -split "`n" |
                    Where-Object { $_ -match 'Exception|Failed to start language worker|Exceeded language worker' } |
                    Select-Object -First 5) -join "`n    "
                $failure = "The isolated worker did not start.`n    $detail"
                break
            }
        }

        if ($failure) { break }

        if ($log -match '0 functions found') {
            $failure = 'The host started but indexed no functions at all.'
            break
        }

        $indexed = [regex]::Matches($log, "Host\.Functions\.([A-Za-z0-9_]+)") |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique

        # WarmUp is the host's own built-in function and is present even when the worker is dead,
        # so it must never be mistaken for a sign of success.
        $indexed = @($indexed | Where-Object { $_ -ne 'WarmUp' })

        if ($indexed.Count -ge $expected.Count) { break }

        if ($process.HasExited) {
            $failure = "The host exited with code $($process.ExitCode) before indexing finished."
            break
        }
    }
}
finally {
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------------------------
# Report.
# ---------------------------------------------------------------------------------------------

if ($failure) {
    Write-Host ''
    Write-Host '--- host output ---'
    Get-Content $stdout -ErrorAction SilentlyContinue | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
    Get-Content $stderr -ErrorAction SilentlyContinue | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
    Write-Host ''
    throw "The Functions host could not serve this build. $failure"
}

$missing = @($expected | Where-Object { $_ -notin $indexed })

if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host '--- host output ---'
    Get-Content $stdout -ErrorAction SilentlyContinue | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
    Write-Host ''
    throw "The host started but did not index: $($missing -join ', '). Indexed: $(if ($indexed) { $indexed -join ', ' } else { '(none)' })."
}

Write-Host ''
Write-Host "The Functions host indexed every declared function: $($indexed -join ', ')"

Remove-Item $publishDir -Recurse -Force -ErrorAction SilentlyContinue
