#Requires -Version 7.0

<#
.SYNOPSIS
    Reports why the most recent Power Platform solution import failed.

.DESCRIPTION
    `pac solution import` surfaces asynchronous failures as "An unexpected error occurred",
    which is not actionable. The real reason is recorded in Dataverse, on the async operation
    and in the import job's result XML.

    This script reads both and prints them. It is intended to run as a failure handler in the
    deployment workflow, where the signed-in identity is the deployment service principal, which
    holds the Dataverse System Administrator role.

    Note that a guest user usually CANNOT read this from a workstation: tenants commonly enable
    the "restrict guest access" setting, and Dataverse then answers 403 with error 0x80095fcd.
    Running inside the pipeline as the service principal avoids that.

.PARAMETER EnvironmentUrl
    Dataverse environment URL, for example https://contoso.crm4.dynamics.com.

.PARAMETER Top
    How many recent failures to report. Defaults to 1.

.EXAMPLE
    ./Get-SolutionImportFailure.ps1 -EnvironmentUrl https://contoso.crm4.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $EnvironmentUrl,

    [int] $Top = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$baseUrl = $EnvironmentUrl.TrimEnd('/')

$token = az account get-access-token --resource $baseUrl --query accessToken --output tsv 2>$null

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
    Write-Warning "Could not acquire a Dataverse token for $baseUrl; cannot explain the failure."
    return
}

$headers = @{
    Authorization    = "Bearer $($token.Trim())"
    Accept           = 'application/json'
    'OData-Version'  = '4.0'
}

function Invoke-Dataverse {
    param([Parameter(Mandatory)][string] $Path)

    $response = Invoke-WebRequest -Uri "$baseUrl/api/data/v9.2/$Path" -Headers $headers -Method GET -SkipHttpErrorCheck

    if ($response.StatusCode -ne 200) {
        Write-Warning "GET $Path returned HTTP $($response.StatusCode): $($response.Content)"
        return $null
    }

    return $response.Content | ConvertFrom-Json
}

Write-Host ''
Write-Host '==> Most recent failed solution import' -ForegroundColor Cyan

# operationtype 54 is ImportSolution; statuscode 31 is Failed.
$asyncPath = 'asyncoperations?$select=name,statuscode,message,friendlymessage,createdon' +
             '&$filter=operationtype eq 54 and statuscode eq 31' +
             "&`$orderby=createdon desc&`$top=$Top"

$async = Invoke-Dataverse -Path $asyncPath

if ($async -and $async.value.Count -gt 0) {
    foreach ($operation in $async.value) {
        Write-Host ''
        Write-Host "    created: $($operation.createdon)"
        if ($operation.friendlymessage) {
            Write-Host "    reason : $($operation.friendlymessage)" -ForegroundColor Yellow
        }
        if ($operation.message) {
            Write-Host '    detail :' -ForegroundColor Yellow
            $operation.message -split "`n" | Select-Object -First 40 | ForEach-Object { Write-Host "      $_" }
        }
    }
}
else {
    Write-Host '    no failed ImportSolution async operation found'
}

Write-Host ''
Write-Host '==> Most recent import job result' -ForegroundColor Cyan

$importPath = 'importjobs?$select=solutionname,progress,startedon,completedon,data' +
              "&`$orderby=startedon desc&`$top=$Top"

$jobs = Invoke-Dataverse -Path $importPath

if (-not $jobs -or $jobs.value.Count -eq 0) {
    Write-Host '    no import job found'
    return
}

foreach ($job in $jobs.value) {
    Write-Host ''
    Write-Host "    solution : $($job.solutionname)"
    Write-Host "    progress : $($job.progress)"
    Write-Host "    started  : $($job.startedon)"
    Write-Host "    completed: $($job.completedon)"

    if ([string]::IsNullOrWhiteSpace($job.data)) {
        Write-Host '    no result XML recorded'
        continue
    }

    try {
        $xml = [xml] $job.data
    }
    catch {
        Write-Host '    result XML could not be parsed; raw head follows'
        Write-Host "      $($job.data.Substring(0, [Math]::Min(1500, $job.data.Length)))"
        continue
    }

    # Every node that recorded a non-zero errorcode carries the real reason.
    $failures = $xml.SelectNodes('//*[@errorcode and @errorcode!="0" and @errorcode!="0x0"]')

    if ($failures.Count -eq 0) {
        Write-Host '    result XML records no explicit error code'
        continue
    }

    Write-Host '    failures:' -ForegroundColor Yellow

    foreach ($node in $failures) {
        $name = $node.GetAttribute('LocalizedName')
        if (-not $name) { $name = $node.GetAttribute('name') }

        $text = $node.GetAttribute('errortext')
        if (-not $text) { $text = $node.InnerText }

        Write-Host "      [$($node.LocalName)] $name" -ForegroundColor Yellow
        if ($text) {
            Write-Host "        error $($node.GetAttribute('errorcode')): $($text.Trim())"
        }
    }
}
