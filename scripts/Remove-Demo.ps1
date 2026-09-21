#Requires -Version 7.0

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

    What it does NOT remove, and why. Both are stated here because an earlier version of this
    script claimed to remove "everything the demo created, and nothing else" while quietly
    leaving things behind, which is how the Power Platform environment went unremoved for so
    long. The boundary is now explicit rather than implied:

      * The two Microsoft Entra ID app registrations. These are created by the BOOTSTRAP
        (Initialize-EntraResources.ps1), not by a deployment. The deployment one is the identity
        the pipelines sign in with, so deleting it means re-running the bootstrap and re-setting
        every repository secret before the next deploy. Deploy runs happily against the same
        pair any number of times, so keeping them costs nothing and destroys nothing.
        Pass -RemoveEntraApplications when you do want them gone.

      * The "HTTP with Microsoft Entra ID" connector service principal and its delegated
        permission grant. That is a shared, tenant-wide Microsoft first-party application other
        solutions in the tenant may depend on. It is never removed, at all, by design.

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

.PARAMETER RemoveEntraApplications
    Also delete the bootstrap's app registrations. Off by default: it removes the identity the
    pipelines sign in with, so Initialize-EntraResources.ps1 has to be re-run and the repository
    secrets re-set before deploying again.

.PARAMETER Force
    Delete without prompting. It suppresses the confirmation, it does not override -WhatIf:
    `-Force -WhatIf` previews and deletes nothing.

.PARAMETER SkipTagCheck
    Delete the resource group even if it is not tagged workload=secure-request-classifier.

    That tag is the guard that stops this script being aimed at the wrong resource group, so
    skipping it removes the only thing standing between a mistyped name and somebody else's
    estate. Use it only when you know the group was created by this demo and the tag was lost,
    and read the name back to yourself before pressing enter.

.PARAMETER SubscriptionId
    Subscription holding the resource group. Optional, but worth supplying: without it the Azure
    CLI's current subscription is used, and a destructive script should not depend on ambient
    machine state.

.PARAMETER SolutionUniqueName
    Unique name of the solution to delete from the environment. Defaults to the one this
    repository ships.

.PARAMETER DeploymentAppDisplayName
    Display name of the deployment app registration, used only with -RemoveEntraApplications.

.PARAMETER ApiAppDisplayName
    Display name of the API app registration, used only with -RemoveEntraApplications.
.EXAMPLE
    ./Remove-Demo.ps1 -ResourceGroupName rg-srclass-demo -PowerPlatformEnvironmentId 1111... -WhatIf

.PARAMETER SubscriptionId
    Subscription holding the resource group. Optional, but worth supplying: without it the Azure
    CLI's current subscription is used, and a destructive script should not depend on ambient
    machine state.

.PARAMETER SolutionUniqueName
    Unique name of the solution to delete from the environment. Defaults to the one this
    repository ships.

.PARAMETER DeploymentAppDisplayName
    Display name of the deployment app registration, used only with -RemoveEntraApplications.

.PARAMETER ApiAppDisplayName
    Display name of the API app registration, used only with -RemoveEntraApplications.
.EXAMPLE
    ./Remove-Demo.ps1 -ResourceGroupName rg-srclass-demo -PowerPlatformEnvironmentName srclass-demo -Force
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [string] $SubscriptionId,

    [string] $PowerPlatformEnvironmentId,

    [string] $PowerPlatformEnvironmentUrl,

    [string] $PowerPlatformEnvironmentName,

    [switch] $KeepPowerPlatformEnvironment,

    [string] $SolutionUniqueName = 'SecureRequestClassifier',

    [switch] $RemoveEntraApplications,

    [string] $DeploymentAppDisplayName = 'Secure Request Classifier - GitHub deployment',

    [string] $ApiAppDisplayName = 'Secure Request Classifier - Function API',

    [switch] $Force,

    [switch] $SkipTagCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Carried on every az call below. `az account set` is deliberately never used: it mutates the
# machine's CLI context, which other tools and other shells share, so running this script would
# silently change what an unrelated command targets.
$azContext = if ($SubscriptionId) { @('--subscription', $SubscriptionId) } else { @() }

# -Force means "do not ask me", not "ignore -WhatIf". Writing the gates as
# `$Force -or $PSCmdlet.ShouldProcess(...)` short-circuits, so ShouldProcess is never reached and
# -WhatIf never takes effect: `-Force -WhatIf`, the natural way to ask for a forced dry run, would
# delete the resource group and everything in it for real.
#
# Lowering $ConfirmPreference instead keeps ShouldProcess on every path, so -WhatIf always previews
# and -Confirm can still be requested explicitly. It also makes -Force apply uniformly, rather than
# only to the resource group delete while the solution, the policy unlink and the app registrations
# kept prompting.
if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) {
    $ConfirmPreference = 'None'
}

function Write-Step { param([string] $Message) Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }

Write-Step "Inspecting resource group '$ResourceGroupName'"

# An absent resource group is an expected outcome here, not an error: Destroy has to be safe to
# re-run against an estate that is already clean. Two separate things make that hard.
#
#   * PowerShell 7.4 turns on $PSNativeCommandUseErrorActionPreference by default, so a native
#     command exiting non-zero THROWS while $ErrorActionPreference is 'Stop'. The probe below
#     would abort the whole script.
#   * PowerShell adopts a native command's exit code as its own, so even without the throw a
#     stale non-zero code leaks out and the run reports failure after doing everything right.
#
# Hence the try/catch, the explicit exit-code test, and the reset.
$resourceGroup = $null

try {
    $resourceGroupJson = az group show --name $ResourceGroupName --output json @azContext 2>$null

    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($resourceGroupJson)) {
        $resourceGroup = $resourceGroupJson | ConvertFrom-Json
    }
}
catch {
    # Absent, or unreadable. Either way there is nothing to delete, and the tag guard below
    # cannot be satisfied, so treat it as absent.
    $resourceGroup = $null
}

$global:LASTEXITCODE = 0

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

    az group show --name $ResourceGroupName --query tags @azContext

Re-run with -SkipTagCheck only if you are certain.
"@
    }

    $resources = az resource list --resource-group $ResourceGroupName --query "[].{name:name,type:type}" --output json @azContext | ConvertFrom-Json
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
            --query '[0].id' --output tsv @azContext 2>$null
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

    if ($PSCmdlet.ShouldProcess($ResourceGroupName, 'Delete resource group and all resources in it')) {
        # Deliberately NOT --no-wait. This script reporting success has to mean the resource
        # group is actually gone, otherwise a redeploy races a half-deleted one.
        az group delete --name $ResourceGroupName --yes --only-show-errors @azContext

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete resource group '$ResourceGroupName'."
        }

        Write-Host "    '$ResourceGroupName' is deleted." -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------------------------

if ($RemoveEntraApplications) {
    Write-Step 'Deleting Microsoft Entra ID app registrations'
    Write-Host '    This removes the identity the pipelines sign in with. Re-run' -ForegroundColor Yellow
    Write-Host '    Initialize-EntraResources.ps1 and reset the repository secrets' -ForegroundColor Yellow
    Write-Host '    before deploying again.' -ForegroundColor Yellow

    foreach ($displayName in @($DeploymentAppDisplayName, $ApiAppDisplayName)) {
        $appId = az ad app list --display-name $displayName --query '[0].appId' --output tsv @azContext 2>$null

        if (-not $appId) {
            Write-Host "    no app registration named '$displayName'"
            continue
        }

        if ($PSCmdlet.ShouldProcess($displayName, 'Delete app registration')) {
            az ad app delete --id $appId --only-show-errors @azContext
            Write-Host "    deleted '$displayName' ($appId)" -ForegroundColor Green
        }
    }
}

# ---------------------------------------------------------------------------------------------
# Say plainly what survived. An earlier version of this script claimed to remove "everything the
# demo created, and nothing else" while silently leaving the environment behind, so the boundary
# is now printed on every run rather than described in a comment nobody reads.

Write-Step 'Cleanup complete'

# Report what actually happened, not what the arguments asked for. Claiming to have removed a
# resource group that was never there, or announcing deletions during a -WhatIf preview, is the
# kind of summary that teaches a reader to stop believing the summary.
$previewOnly = $WhatIfPreference

if ($previewOnly) {
    Write-Host 'Nothing was changed (-WhatIf). This run would remove:' -ForegroundColor Cyan
}
else {
    Write-Host 'Removed:' -ForegroundColor Green
}

if ($resourceGroup) {
    Write-Host "    resource group '$ResourceGroupName' and everything in it"
}
else {
    Write-Host "    nothing in Azure: resource group '$ResourceGroupName' did not exist"
}

if ($PowerPlatformEnvironmentId -and -not $KeepPowerPlatformEnvironment) {
    Write-Host '    the Power Platform environment, its Dataverse database and the solution'
}

Write-Host ''
Write-Host 'Left in place:' -ForegroundColor Yellow

if ($KeepPowerPlatformEnvironment) {
    Write-Host '    the Power Platform environment (-KeepPowerPlatformEnvironment)'
}

if (-not $RemoveEntraApplications) {
    Write-Host '    the two bootstrap app registrations. They are created by'
    Write-Host '    Initialize-EntraResources.ps1, not by a deployment, and the deployment one is'
    Write-Host '    the identity these pipelines sign in with. Deploy can run again as-is.'
    Write-Host '    Pass -RemoveEntraApplications to delete them, then re-run the bootstrap and'
    Write-Host '    reset the repository secrets before the next deploy.'
}

Write-Host '    the "HTTP with Microsoft Entra ID" connector service principal and its delegated'
Write-Host '    permission grant. Never removed, by design: it is a shared, tenant-wide Microsoft'
Write-Host '    first-party application other solutions in the tenant may depend on.'

Write-Host ''
Write-Host 'Nothing else was modified.' -ForegroundColor Green

# Reaching here means cleanup succeeded; every real failure above throws. Without this, a stale
# non-zero $LASTEXITCODE from an expected az probe failure (an absent resource group, an absent
# app registration) becomes this script's exit code, and a clean run reports as a failed one.
# Re-running Destroy against an already-empty estate is exactly that case.
exit 0
