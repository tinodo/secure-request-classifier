<#
.SYNOPSIS
    Removes everything the Secure Request Classifier demo created, and nothing else.

.DESCRIPTION
    The demo is deliberately built as a single, isolated resource group with no dependency on
    hub networking, shared private DNS zones or any pre-existing resource. Cleanup is
    therefore scoped to exactly that resource group, plus the optional Power Platform and
    Microsoft Entra ID artefacts.

    The script refuses to delete a resource group that does not carry the demo's own tag,
    which prevents it from being pointed at something else by accident.

    Order matters: the Power Platform environment must be unlinked from the enterprise policy
    before the policy or its virtual networks are deleted, otherwise the environment is left
    referencing a policy that no longer exists.

.PARAMETER ResourceGroupName
    Resource group to delete.

.PARAMETER PowerPlatformEnvironmentId
    Optional. When supplied, the environment is unlinked from the enterprise policy first.

.PARAMETER PowerPlatformEnvironmentUrl
    Optional. When supplied, the solution is uninstalled from the environment.

.PARAMETER RemoveEntraApplications
    Also delete the app registrations created by Initialize-EntraResources.ps1.

.PARAMETER Force
    Do not prompt for confirmation.

.EXAMPLE
    ./Remove-Demo.ps1 -ResourceGroupName rg-srclass-demo -PowerPlatformEnvironmentId 1111... -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [string] $PowerPlatformEnvironmentId,

    [string] $PowerPlatformEnvironmentUrl,

    [string] $SolutionUniqueName = 'SecureRequestClassifier',

    [switch] $RemoveEntraApplications,

    [string] $DeploymentAppDisplayName = 'Secure Request Classifier - GitHub deployment',

    [string] $ApiAppDisplayName = 'Secure Request Classifier - Function API',

    [switch] $Force,

    [switch] $SkipTagCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string] $Message) Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }

Write-Step "Inspecting resource group '$ResourceGroupName'"

$resourceGroup = az group show --name $ResourceGroupName --output json 2>$null | ConvertFrom-Json

if (-not $resourceGroup) {
    Write-Warning "Resource group '$ResourceGroupName' does not exist. Nothing to delete in Azure."
}
else {
    $tagValue = $null
    if ($resourceGroup.tags -and $resourceGroup.tags.PSObject.Properties.Name -contains 'workload') {
        $tagValue = $resourceGroup.tags.workload
    }

    if (-not $SkipTagCheck -and $tagValue -ne 'secure-request-classifier') {
        throw @"
Refusing to delete '$ResourceGroupName'.

It does not carry the tag workload=secure-request-classifier, so this script cannot confirm it
belongs to the demo. Inspect it first:

    az group show --name $ResourceGroupName --query tags

Re-run with -SkipTagCheck only if you are certain.
"@
    }

    $resources = az resource list --resource-group $ResourceGroupName --query "[].{name:name,type:type}" --output json | ConvertFrom-Json
    Write-Host "    $(@($resources).Count) resource(s) will be deleted:"
    foreach ($resource in @($resources)) {
        Write-Host ('      {0,-52} {1}' -f $resource.name, $resource.type)
    }
}

# ---------------------------------------------------------------------------------------------

if ($PowerPlatformEnvironmentUrl) {
    Write-Step "Uninstalling the '$SolutionUniqueName' solution"

    if ($PSCmdlet.ShouldProcess($PowerPlatformEnvironmentUrl, "Delete solution $SolutionUniqueName")) {
        & pac solution delete --environment $PowerPlatformEnvironmentUrl --solution-name $SolutionUniqueName 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'Solution delete failed or the solution was already absent. Continuing.'
        }
    }
}

if ($PowerPlatformEnvironmentId) {
    Write-Step 'Unlinking the Power Platform environment from the enterprise policy'
    Write-Host '    This must happen before the virtual networks are deleted.' -ForegroundColor Yellow

    $policyId = $null
    if ($resourceGroup) {
        $policyId = az resource list --resource-group $ResourceGroupName `
            --resource-type 'Microsoft.PowerPlatform/enterprisePolicies' `
            --query '[0].id' --output tsv 2>$null
    }

    if ($PSCmdlet.ShouldProcess($PowerPlatformEnvironmentId, 'Unlink network injection enterprise policy')) {
        $unlinkScript = Join-Path $PSScriptRoot 'Set-PowerPlatformSubnetInjection.ps1'

        try {
            & $unlinkScript -EnvironmentId $PowerPlatformEnvironmentId `
                -EnterprisePolicyResourceId ($policyId ? $policyId : '/subscriptions/unknown') `
                -Action Unlink -Confirm:$false
        }
        catch {
            Write-Warning "Unlink failed: $($_.Exception.Message)"
            Write-Warning 'Unlink manually before deleting the resource group:'
            Write-Warning "    Disable-SubnetInjection -EnvironmentId $PowerPlatformEnvironmentId"
        }

        Write-Host '    Waiting 60 seconds for the unlink to settle before deleting networks.' -ForegroundColor Yellow
        Start-Sleep -Seconds 60
    }
}

# ---------------------------------------------------------------------------------------------

if ($resourceGroup) {
    Write-Step "Deleting resource group '$ResourceGroupName'"

    if ($Force -or $PSCmdlet.ShouldProcess($ResourceGroupName, 'Delete resource group and all resources in it')) {
        az group delete --name $ResourceGroupName --yes --no-wait --only-show-errors

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to start deletion of resource group '$ResourceGroupName'."
        }

        Write-Host '    Deletion started. Track it with:' -ForegroundColor Green
        Write-Host "      az group wait --deleted --name $ResourceGroupName"
    }
}

# ---------------------------------------------------------------------------------------------

if ($RemoveEntraApplications) {
    Write-Step 'Deleting Microsoft Entra ID app registrations'

    foreach ($displayName in @($DeploymentAppDisplayName, $ApiAppDisplayName)) {
        $appId = az ad app list --display-name $displayName --query '[0].appId' --output tsv 2>$null

        if (-not $appId) {
            Write-Host "    no app registration named '$displayName'"
            continue
        }

        if ($PSCmdlet.ShouldProcess($displayName, 'Delete app registration')) {
            az ad app delete --id $appId --only-show-errors
            Write-Host "    deleted '$displayName' ($appId)" -ForegroundColor Green
        }
    }

    Write-Host ''
    Write-Host '    The "HTTP with Microsoft Entra ID" connector service principal and its' -ForegroundColor Yellow
    Write-Host '    delegated permission grant are intentionally left alone: that service' -ForegroundColor Yellow
    Write-Host '    principal is a shared, tenant-wide Microsoft first-party application and' -ForegroundColor Yellow
    Write-Host '    other solutions may depend on it.' -ForegroundColor Yellow
}

Write-Step 'Cleanup complete'
Write-Host 'Nothing outside the demo resource group was modified.' -ForegroundColor Green
