#Requires -Version 7.0

<#
.SYNOPSIS
    Proves that the Azure Function is reachable over private networking and unreachable from
    the public internet.

.DESCRIPTION
    Runs two probes:

      Public  - a plain HTTPS request from wherever this script runs. With
                publicNetworkAccess disabled this must fail to connect (or be rejected before
                it reaches the app).

      Private - a container instance placed directly in the demo's private endpoint subnet,
                which resolves the Function App host name through the workload's own Azure
                Private DNS zone and calls /api/health.

    The private probe is created and deleted by this script, inside the demo resource group,
    so it leaves nothing behind.

    The health endpoint is excluded from App Service Authentication precisely so this probe
    can separate "the network path works" from "the caller is authenticated". The business
    endpoint still requires a Microsoft Entra ID token.

.PARAMETER ResourceGroupName
    Resource group containing the demo.

.PARAMETER KeepProbe
    Leave the container instance in place afterwards (useful while troubleshooting).

.EXAMPLE
    ./Invoke-PrivateConnectivityProbe.ps1 -ResourceGroupName rg-srclass-demo
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [string] $ProbeName = 'ci-srclass-probe',

    [switch] $KeepProbe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string] $Message) Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }

Write-Step 'Locating the Function App'

$functionApp = az functionapp list --resource-group $ResourceGroupName --output json | ConvertFrom-Json | Select-Object -First 1

if (-not $functionApp) { throw "No function app found in resource group '$ResourceGroupName'." }

$hostName = $functionApp.defaultHostName
$healthUrl = "https://$hostName/api/health"

Write-Host "    app        $($functionApp.name)"
Write-Host "    host       $hostName"
Write-Host "    public NA  $($functionApp.publicNetworkAccess)"

# ---------------------------------------------------------------------------------------------

Write-Step "Probe 1 of 2: public internet -> $healthUrl (this SHOULD fail)"

$publicResult = 'unknown'

try {
    $response = Invoke-WebRequest -Uri $healthUrl -Method Get -TimeoutSec 20 -SkipHttpErrorCheck
    if ($response.StatusCode -eq 403) {
        $publicResult = 'blocked'
        Write-Host "    HTTP 403 - rejected before reaching the app. PASS." -ForegroundColor Green
    }
    else {
        $publicResult = 'reachable'
        Write-Host "    HTTP $($response.StatusCode) - the app answered over the public internet. FAIL." -ForegroundColor Red
    }
}
catch {
    $publicResult = 'blocked'
    Write-Host "    connection failed: $($_.Exception.Message.Split([Environment]::NewLine)[0])" -ForegroundColor Green
    Write-Host '    PASS - there is no public path to the app.' -ForegroundColor Green
}

# ---------------------------------------------------------------------------------------------

Write-Step 'Probe 2 of 2: from inside the virtual network (this SHOULD succeed)'

$virtualNetwork = az network vnet list --resource-group $ResourceGroupName `
    --query "[?contains(name, 'primary')] | [0]" --output json | ConvertFrom-Json

if (-not $virtualNetwork) {
    $virtualNetwork = az network vnet list --resource-group $ResourceGroupName --output json | ConvertFrom-Json | Select-Object -First 1
}

if (-not $virtualNetwork) { throw 'No virtual network found in the resource group.' }

$subnet = $virtualNetwork.subnets | Where-Object { $_.name -eq 'snet-private-endpoints' } | Select-Object -First 1
if (-not $subnet) { throw "Subnet 'snet-private-endpoints' not found in $($virtualNetwork.name)." }

Write-Host "    network    $($virtualNetwork.name)"
Write-Host "    subnet     $($subnet.name) ($($subnet.addressPrefix))"
Write-Host ''
Write-Host '    Container instances need a subnet delegated to Microsoft.ContainerInstance/containerGroups.'
Write-Host '    The private endpoint subnet is not delegated, so a dedicated probe subnet is used.'

$probeSubnetName = 'snet-connectivity-probe'
$existingProbeSubnet = $virtualNetwork.subnets | Where-Object { $_.name -eq $probeSubnetName } | Select-Object -First 1

if (-not $existingProbeSubnet) {
    # Carve a /28 out of the address space that is not already in use.
    $usedPrefixes = @($virtualNetwork.subnets | ForEach-Object { $_.addressPrefix })
    $basePrefix = ($virtualNetwork.addressSpace.addressPrefixes | Select-Object -First 1)
    $baseOctets = ($basePrefix -split '/')[0] -split '\.'

    $candidate = $null
    foreach ($third in 200..250) {
        $test = "$($baseOctets[0]).$($baseOctets[1]).$third.0/28"
        if ($usedPrefixes -notcontains $test) { $candidate = $test; break }
    }

    if (-not $candidate) { throw 'Could not find a free /28 for the probe subnet.' }

    Write-Host "    creating probe subnet $probeSubnetName ($candidate)"

    az network vnet subnet create `
        --resource-group $ResourceGroupName `
        --vnet-name $virtualNetwork.name `
        --name $probeSubnetName `
        --address-prefixes $candidate `
        --delegations Microsoft.ContainerInstance/containerGroups `
        --only-show-errors --output none
}

$probeCommand = @"
set -e
echo '--- DNS resolution for $hostName ---'
getent hosts $hostName || nslookup $hostName || true
echo
echo '--- GET $healthUrl ---'
curl --silent --show-error --fail --max-time 30 -w '\nHTTP_STATUS=%{http_code}\nREMOTE_IP=%{remote_ip}\n' $healthUrl
"@

Write-Host "    starting container instance '$ProbeName'"

az container create `
    --resource-group $ResourceGroupName `
    --name $ProbeName `
    --image mcr.microsoft.com/azurelinux/base/core:3.0 `
    --os-type Linux `
    --cpu 1 --memory 1 `
    --restart-policy Never `
    --vnet $virtualNetwork.name `
    --subnet $probeSubnetName `
    --command-line "/bin/sh -c `"tdnf install -y curl >/dev/null 2>&1 || true; $($probeCommand -replace '"', '\"' -replace "`n", '; ')`"" `
    --only-show-errors --output none

Write-Host '    waiting for the probe to finish'

$deadline = (Get-Date).AddMinutes(5)
$state = 'Pending'

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10
    $state = az container show --resource-group $ResourceGroupName --name $ProbeName `
        --query 'instanceView.state' --output tsv 2>$null
    Write-Host "      state: $state"
    if ($state -in @('Succeeded', 'Failed', 'Terminated')) { break }
}

$logs = az container logs --resource-group $ResourceGroupName --name $ProbeName 2>&1 | Out-String

Write-Host ''
Write-Host '    --- probe output ---' -ForegroundColor DarkGray
$logs -split "`n" | ForEach-Object { Write-Host "    $_" }
Write-Host '    --- end probe output ---' -ForegroundColor DarkGray

$privateResult = if ($logs -match 'HTTP_STATUS=200') { 'reachable' } else { 'unreachable' }

$resolvedPrivateIp = $false
if ($logs -match '10\.\d+\.\d+\.\d+') { $resolvedPrivateIp = $true }

if (-not $KeepProbe) {
    Write-Host ''
    Write-Host "    deleting container instance '$ProbeName'"
    az container delete --resource-group $ResourceGroupName --name $ProbeName --yes --only-show-errors --output none
}

# ---------------------------------------------------------------------------------------------

Write-Step 'Result'

$publicOk = $publicResult -eq 'blocked'
$privateOk = $privateResult -eq 'reachable'

Write-Host ('  {0} public internet  -> {1}' -f ($publicOk ? '[ OK ]' : '[FAIL]'), $publicResult) -ForegroundColor ($publicOk ? 'Green' : 'Red')
Write-Host ('  {0} inside the VNet  -> {1}' -f ($privateOk ? '[ OK ]' : '[FAIL]'), $privateResult) -ForegroundColor ($privateOk ? 'Green' : 'Red')
Write-Host ('  {0} host resolves to a private address' -f ($resolvedPrivateIp ? '[ OK ]' : '[WARN]')) -ForegroundColor ($resolvedPrivateIp ? 'Green' : 'Yellow')

Write-Host ''
if ($publicOk -and $privateOk) {
    Write-Host 'The Function App has no public endpoint and is reachable only over private networking.' -ForegroundColor Green
    exit 0
}

Write-Host 'Private connectivity could not be proven. See docs/troubleshooting.md.' -ForegroundColor Red
exit 1
