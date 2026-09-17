<#
.SYNOPSIS
    Removes everything the Secure Request Classifier deployment created.

.DESCRIPTION
    The deployment creates two things: a single, isolated Azure resource group, and a Power
    Platform environment. This script removes both, in the order that works:

      1. Unlink the environment from the enterprise policy. This must happen before the virtual
         networks are deleted, and before the environment is deleted, or the subnet delegation
         can be left held and the resource group refuses to go.
      2. Delete the Power Platform environment, including its Dataverse database and the
         imported solution.
      3. Delete the Azure resource group, and wait for it.

    What it deliberately does NOT remove:

      * The "HTTP with Microsoft Entra ID" connector service principal and its delegated
        permission grant. That service principal is a shared, tenant-wide Microsoft first-party
        application that other solutions in the tenant may depend on. It is not ours to delete.

    Deleting the app registrations removes the identity the pipelines
    authenticate with, so Initialize-EntraResources.ps1 has to be re-run, and the repository
    secrets re-set, before deploying again.

    Two guards stop this being pointed at the wrong thing: the resource group must carry the
    demo's own workload tag, and the environment's display name must match the one supplied.

.PARAMETER ResourceGroupName
    Resource group to delete.

.PARAMETER PowerPlatformEnvironmentId
    Optional. When supplied, the environment is unlinked from the enterprise policy, and deleted
    unless -KeepPowerPlatformEnvironment is passed.

.PARAMETER PowerPlatformEnvironmentUrl
    Optional. Only used when the environment is being kept, to uninstall the solution from it.

.PARAMETER PowerPlatformEnvironmentName
    Expected display name of the environment. Deletion is refused unless it matches.

.PARAMETER KeepPowerPlatformEnvironment
    Unlink and uninstall the solution, but leave the environment itself in place.

.PARAMETER KeepEntraApplications
    Keep the app registrations created by Initialize-EntraResources.ps1. By default they are
    deleted, because the deployment created them.

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

    [string] $PowerPlatformEnvironmentName,

    [switch] $KeepPowerPlatformEnvironment,

    [string] $SolutionUniqueName = 'SecureRequestClassifier',

    [switch] $KeepEntraApplications,

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

if ($PowerPlatformEnvironmentUrl -and $KeepPowerPlatformEnvironment) {
    # Only worth doing when the environment survives. If it is being deleted, the solution goes
    # with it and uninstalling first just adds minutes.
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

if ($PowerPlatformEnvironmentId -and -not $KeepPowerPlatformEnvironment) {
    Write-Step 'Deleting the Power Platform environment'

    $removeEnvironment = Join-Path $PSScriptRoot 'Remove-PowerPlatformEnvironment.ps1'

    $environmentParameters = @{
        EnvironmentId = $PowerPlatformEnvironmentId
        Confirm       = $false
    }

    if ($PowerPlatformEnvironmentName) {
        $environmentParameters.ExpectedDisplayName = $PowerPlatformEnvironmentName
    }
    else {
        # No name to check against, so the guard cannot run. Say so rather than silently
        # bypassing it.
        Write-Warning 'No -PowerPlatformEnvironmentName supplied, so the display-name guard is being skipped.'
        $environmentParameters.SkipNameCheck = $true
    }

    # The environment must be gone before the resource group, otherwise the delegated subnet can
    # still be held and the virtual network delete fails.
    & $removeEnvironment @environmentParameters
}

# ---------------------------------------------------------------------------------------------

if ($resourceGroup) {
    Write-Step "Deleting resource group '$ResourceGroupName'"

    if ($Force -or $PSCmdlet.ShouldProcess($ResourceGroupName, 'Delete resource group and all resources in it')) {
        # Deliberately NOT --no-wait. This script reporting success has to mean the resource
        # group is actually gone, otherwise a redeploy races a half-deleted one.
        az group delete --name $ResourceGroupName --yes --only-show-errors

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete resource group '$ResourceGroupName'."
        }

        Write-Host "    '$ResourceGroupName' is deleted." -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------------------------

if (-not $KeepEntraApplications) {
    Write-Step 'Deleting Microsoft Entra ID app registrations'
    Write-Host '    This removes the identity the pipelines sign in with. Re-run' -ForegroundColor Yellow
    Write-Host '    Initialize-EntraResources.ps1 and reset the repository secrets' -ForegroundColor Yellow
    Write-Host '    before deploying again.' -ForegroundColor Yellow

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
