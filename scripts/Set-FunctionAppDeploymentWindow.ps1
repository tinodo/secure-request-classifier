#Requires -Version 7.0

<#
.SYNOPSIS
    Opens or closes a tightly scoped, temporary deployment window on the Function App.

.DESCRIPTION
    Microsoft documents that when a function app has a private endpoint and public network
    access is disabled, the deployment endpoint is not publicly reachable, and that the
    runner performing the deployment must therefore have network connectivity and DNS
    resolution for the private deployment endpoint:

        https://learn.microsoft.com/en-us/azure/azure-functions/functions-deployment-technologies
        (section "Secured virtual networks")

    A standard GitHub-hosted runner has neither. This script implements the fallback used when
    FUNCTION_DEPLOY_MODE is 'deployment-window':

      Open  - set publicNetworkAccess to Enabled, then immediately restrict both the app and
              its SCM site to a single source IP address (the runner's egress address) with a
              default action of Deny.
      Close - remove the restrictions and set publicNetworkAccess back to Disabled.

    The runtime path is never affected: Power Automate always reaches the app through the
    private endpoint. Only the deployment plane is briefly and narrowly exposed, and the
    close operation is invoked with `if: always()` by the workflow.

    Prefer FUNCTION_DEPLOY_MODE='private-runner' where a network-connected runner is available;
    that path never opens a window at all.

.PARAMETER Action
    Open or Close.

.PARAMETER ResourceGroupName
    Resource group containing the Function App.

.PARAMETER FunctionAppName
    Name of the Function App.

.PARAMETER AllowedIpAddress
    Source IPv4 address permitted during the window. Defaults to this machine's public egress
    address as reported by Azure's own IP echo service.

.EXAMPLE
    ./Set-FunctionAppDeploymentWindow.ps1 -Action Open -ResourceGroupName rg-srclass-demo -FunctionAppName func-srclass-demo-ab12cd

.EXAMPLE
    ./Set-FunctionAppDeploymentWindow.ps1 -Action Close -ResourceGroupName rg-srclass-demo -FunctionAppName func-srclass-demo-ab12cd
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Open', 'Close')]
    [string] $Action,

    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [string] $FunctionAppName,

    [string] $AllowedIpAddress,

    [string] $RuleName = 'github-actions-deployment-window'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PublicEgressAddress {
    foreach ($uri in @('https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com')) {
        try {
            $value = (Invoke-RestMethod -Uri $uri -TimeoutSec 15).ToString().Trim()
            if ($value -match '^\d{1,3}(\.\d{1,3}){3}$') { return $value }
        }
        catch {
            Write-Verbose "Could not resolve egress address from $uri : $($_.Exception.Message)"
        }
    }

    throw 'Unable to determine the runner public egress IP address. Supply -AllowedIpAddress explicitly.'
}

function Set-PublicNetworkAccess {
    param([Parameter(Mandatory)][ValidateSet('Enabled', 'Disabled')][string] $Value)

    az resource update `
        --resource-group $ResourceGroupName `
        --name $FunctionAppName `
        --resource-type 'Microsoft.Web/sites' `
        --set "properties.publicNetworkAccess=$Value" `
        --only-show-errors --output none

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set publicNetworkAccess to $Value on $FunctionAppName."
    }
}

function Remove-RestrictionIfPresent {
    param([switch] $ScmSite)

    $scmArgument = if ($ScmSite) { 'true' } else { 'false' }

    az webapp config access-restriction remove `
        --resource-group $ResourceGroupName `
        --name $FunctionAppName `
        --rule-name $RuleName `
        --scm-site $scmArgument `
        --only-show-errors --output none 2>$null | Out-Null
}

$target = "$FunctionAppName ($ResourceGroupName)"

switch ($Action) {
    'Open' {
        if (-not $AllowedIpAddress) { $AllowedIpAddress = Get-PublicEgressAddress }

        Write-Host "Opening deployment window on $target for $AllowedIpAddress/32 only." -ForegroundColor Yellow

        if (-not $PSCmdlet.ShouldProcess($target, 'Open deployment window')) { return }

        Set-PublicNetworkAccess -Value 'Enabled'

        # Add the allow rule before flipping the default action to Deny so the window is never
        # briefly open to the whole internet.
        foreach ($scm in @($false, $true)) {
            az webapp config access-restriction add `
                --resource-group $ResourceGroupName `
                --name $FunctionAppName `
                --rule-name $RuleName `
                --action Allow `
                --ip-address "$AllowedIpAddress/32" `
                --priority 100 `
                --description 'Temporary GitHub Actions deployment window' `
                --scm-site $scm.ToString().ToLowerInvariant() `
                --only-show-errors --output none
        }

        az resource update `
            --resource-group $ResourceGroupName `
            --name $FunctionAppName `
            --resource-type 'Microsoft.Web/sites' `
            --set 'properties.siteConfig.ipSecurityRestrictionsDefaultAction=Deny' `
                  'properties.siteConfig.scmIpSecurityRestrictionsDefaultAction=Deny' `
                  'properties.siteConfig.scmIpSecurityRestrictionsUseMain=false' `
            --only-show-errors --output none

        Write-Host "Deployment window open. Everything except $AllowedIpAddress/32 is denied." -ForegroundColor Yellow

        if ($env:GITHUB_OUTPUT) {
            "allowed-ip=$AllowedIpAddress" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
        }
    }

    'Close' {
        Write-Host "Closing deployment window on $target." -ForegroundColor Cyan

        if (-not $PSCmdlet.ShouldProcess($target, 'Close deployment window')) { return }

        Remove-RestrictionIfPresent
        Remove-RestrictionIfPresent -ScmSite

        Set-PublicNetworkAccess -Value 'Disabled'

        $state = az resource show `
            --resource-group $ResourceGroupName `
            --name $FunctionAppName `
            --resource-type 'Microsoft.Web/sites' `
            --query 'properties.publicNetworkAccess' --output tsv

        if ($state -ne 'Disabled') {
            throw "Deployment window did not close: publicNetworkAccess is '$state', expected 'Disabled'."
        }

        Write-Host 'Deployment window closed. publicNetworkAccess = Disabled (verified).' -ForegroundColor Green
    }
}
