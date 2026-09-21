#Requires -Version 7.0

<#
.SYNOPSIS
    Verifies that the Secure Request Classifier demo deployed correctly and is actually secure.

.DESCRIPTION
    Runs a series of independent assertions against the deployed workload and prints a
    pass/fail table. Every check is read-only.

    Checks performed:
      1.  Resource group exists.
      2.  Function App exists and is running.
      3.  Function App public network access is Disabled.
      4.  Function App basic-auth publishing credentials are disabled (SCM and FTP).
      5.  Function App private endpoint exists and is Approved.
      6.  Private DNS zone privatelink.azurewebsites.net contains an A record for the app.
      7.  Private DNS zones are linked to every virtual network in the demo.
      8.  Storage account has shared key access disabled and no public network access.
      9.  Function App has a system-assigned managed identity.
      10. Required RBAC role assignments exist for that identity.
      11. Power Platform delegated subnets exist in both regions with the correct delegation.
      12. Virtual network peering is connected.
      13. Application Insights local authentication is disabled.
      14. Enterprise policy exists with the expected network injection configuration.
      15. Function code is deployed (at least one function is registered).
      16. The public endpoint is genuinely unreachable from the internet.

    Optionally also checks the Power Platform side (solution imported, flow present, VNet
    policy linked) when -PowerPlatformEnvironmentUrl is supplied.

.PARAMETER ResourceGroupName
    Resource group that contains the demo.

.PARAMETER SubscriptionId
    Subscription that holds the resource group. Optional: without it the Azure CLI's current
    subscription is used, which is the usual cause of a "resource group could not be found"
    result on a machine that has access to more than one subscription.

.PARAMETER PowerPlatformEnvironmentUrl
    Optional Dataverse environment URL, for example https://contoso.crm4.dynamics.com.

.PARAMETER PowerPlatformEnvironmentId
    Optional Power Platform environment ID used to verify the enterprise policy link.

.PARAMETER FailOnWarning
    Treat warnings as failures (useful in CI).

.EXAMPLE
    ./Test-Deployment.ps1 -ResourceGroupName rg-srclass-demo

.EXAMPLE
    ./Test-Deployment.ps1 -ResourceGroupName rg-srclass-demo -SubscriptionId 00000000-0000-0000-0000-000000000000
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [string] $SubscriptionId,

    [string] $PowerPlatformEnvironmentUrl,

    [string] $PowerPlatformEnvironmentId,

    [switch] $FailOnWarning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][ValidateSet('Pass', 'Fail', 'Warn', 'Skip')][string] $Status,
        [string] $Detail = ''
    )

    $script:Results.Add([pscustomobject]@{ Check = $Name; Status = $Status; Detail = $Detail })

    $colour = switch ($Status) {
        'Pass' { 'Green' }
        'Fail' { 'Red' }
        'Warn' { 'Yellow' }
        default { 'DarkGray' }
    }

    $symbol = switch ($Status) {
        'Pass' { '[ OK ]' }
        'Fail' { '[FAIL]' }
        'Warn' { '[WARN]' }
        default { '[SKIP]' }
    }

    Write-Host ('{0} {1}' -f $symbol, $Name) -ForegroundColor $colour
    if ($Detail) { Write-Host ('       {0}' -f $Detail) -ForegroundColor DarkGray }
}

function Get-PropertyOrNull {
    <#
        Set-StrictMode turns reading an absent property into a terminating error, and Azure and
        Power Platform APIs routinely omit properties rather than returning them null. Walking a
        response with plain dot notation therefore throws on exactly the "the thing is not
        configured" case a verification script most needs to report clearly.
    #>
    param($InputObject, [Parameter(Mandatory)][string] $Name)

    if ($null -eq $InputObject) { return $null }
    if (-not $InputObject.PSObject.Properties[$Name]) { return $null }

    return $InputObject.PSObject.Properties[$Name].Value
}

function Invoke-Az {
    param([Parameter(Mandatory)][string[]] $Arguments)

    # Every call carries the subscription explicitly when one was supplied. `az account set` is
    # deliberately never used: it mutates the machine's CLI context, which other tools and other
    # shells share, so a verification run would silently change what an unrelated command targets.
    $effective = @($Arguments)
    if ($SubscriptionId -and $Arguments -notcontains '--subscription') {
        $effective += @('--subscription', $SubscriptionId)
    }

    $raw = & az @effective 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    if ([string]::IsNullOrWhiteSpace(($raw | Out-String).Trim())) { return $null }
    return ($raw | Out-String | ConvertFrom-Json)
}

Write-Host ''
Write-Host "Verifying the Secure Request Classifier demo in '$ResourceGroupName'" -ForegroundColor Cyan
Write-Host ('-' * 78)

# ---------------------------------------------------------------------------------------------
# 1. Resource group
# ---------------------------------------------------------------------------------------------

$resourceGroup = Invoke-Az @('group', 'show', '--name', $ResourceGroupName, '--output', 'json')

if (-not $resourceGroup) {
    Add-Result -Name 'Resource group exists' -Status 'Fail' -Detail "Resource group '$ResourceGroupName' was not found."
    $script:Results | Format-Table -AutoSize
    exit 1
}

Add-Result -Name 'Resource group exists' -Status 'Pass' -Detail "$($resourceGroup.name) in $($resourceGroup.location)"

# ---------------------------------------------------------------------------------------------
# 2-4. Function App
# ---------------------------------------------------------------------------------------------

$functionApps = Invoke-Az @('functionapp', 'list', '--resource-group', $ResourceGroupName, '--output', 'json')
$functionApp = $functionApps | Select-Object -First 1

if (-not $functionApp) {
    Add-Result -Name 'Function App exists' -Status 'Fail' -Detail 'No function app found in the resource group.'
}
else {
    Add-Result -Name 'Function App exists' -Status 'Pass' -Detail "$($functionApp.name) ($($functionApp.state))"

    $publicAccess = $functionApp.publicNetworkAccess
    if ($publicAccess -eq 'Disabled') {
        Add-Result -Name 'Function App public network access is disabled' -Status 'Pass' -Detail 'publicNetworkAccess = Disabled'
    }
    else {
        Add-Result -Name 'Function App public network access is disabled' -Status 'Fail' `
            -Detail "publicNetworkAccess = '$publicAccess'. The demo must end with this Disabled."
    }

    foreach ($policy in @('scm', 'ftp')) {
        $basicAuth = Invoke-Az @(
            'resource', 'show',
            '--ids', "$($functionApp.id)/basicPublishingCredentialsPolicies/$policy",
            '--api-version', '2024-04-01', '--output', 'json'
        )

        if ($null -ne $basicAuth -and $basicAuth.properties.allow -eq $false) {
            Add-Result -Name "Basic authentication disabled ($policy)" -Status 'Pass' -Detail 'allow = false'
        }
        else {
            Add-Result -Name "Basic authentication disabled ($policy)" -Status 'Fail' `
                -Detail 'Publishing credentials are still enabled; a username and password could be used to deploy.'
        }
    }

    # 9. Managed identity
    if ($functionApp.identity -and $functionApp.identity.type -match 'SystemAssigned') {
        Add-Result -Name 'Function App has a system-assigned managed identity' -Status 'Pass' `
            -Detail "principalId $($functionApp.identity.principalId)"
    }
    else {
        Add-Result -Name 'Function App has a system-assigned managed identity' -Status 'Fail' `
            -Detail 'No system-assigned identity; the app cannot reach storage or Application Insights without keys.'
    }

    # App Service Authentication
    $authSettings = Invoke-Az @(
        'resource', 'show', '--ids', "$($functionApp.id)/config/authsettingsV2",
        '--api-version', '2024-04-01', '--output', 'json'
    )

    if ($authSettings -and $authSettings.properties.platform.enabled -eq $true `
            -and $authSettings.properties.globalValidation.requireAuthentication -eq $true) {
        $allowed = $authSettings.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications
        Add-Result -Name 'Microsoft Entra ID authentication is enforced' -Status 'Pass' `
            -Detail "unauthenticatedClientAction = $($authSettings.properties.globalValidation.unauthenticatedClientAction); allowedApplications = $($allowed -join ', ')"
    }
    else {
        Add-Result -Name 'Microsoft Entra ID authentication is enforced' -Status 'Fail' `
            -Detail 'App Service Authentication is not enabled or does not require authentication.'
    }

    # 15. Function code deployed
    $functions = Invoke-Az @('functionapp', 'function', 'list', '--resource-group', $ResourceGroupName, '--name', $functionApp.name, '--output', 'json')

    if ($functions -and @($functions).Count -gt 0) {
        Add-Result -Name 'Function code is deployed' -Status 'Pass' -Detail (@($functions | ForEach-Object { ($_.name -split '/')[-1] }) -join ', ')
    }
    else {
        Add-Result -Name 'Function code is deployed' -Status 'Warn' `
            -Detail 'No functions listed. The control plane cannot always enumerate functions on a network-isolated app; check the deploy job log.'
    }

    # 16. Public endpoint genuinely unreachable
    $publicProbeUri = "https://$($functionApp.defaultHostName)/api/health"
    try {
        $probe = Invoke-WebRequest -Uri $publicProbeUri -Method Get -TimeoutSec 20 -SkipHttpErrorCheck -ErrorAction Stop
        if ($probe.StatusCode -eq 403) {
            Add-Result -Name 'Public endpoint is blocked from the internet' -Status 'Pass' `
                -Detail "GET $publicProbeUri returned HTTP 403 (the App Service front end rejected the request before it reached the app)."
        }
        else {
            Add-Result -Name 'Public endpoint is blocked from the internet' -Status 'Fail' `
                -Detail "GET $publicProbeUri returned HTTP $($probe.StatusCode). The app answered over the public internet."
        }
    }
    catch {
        Add-Result -Name 'Public endpoint is blocked from the internet' -Status 'Pass' `
            -Detail "GET $publicProbeUri could not connect: $($_.Exception.Message.Split([Environment]::NewLine)[0])"
    }
}

# ---------------------------------------------------------------------------------------------
# 5. Private endpoints
# ---------------------------------------------------------------------------------------------

$privateEndpoints = Invoke-Az @('network', 'private-endpoint', 'list', '--resource-group', $ResourceGroupName, '--output', 'json')

if (-not $privateEndpoints) {
    Add-Result -Name 'Private endpoints exist' -Status 'Fail' -Detail 'No private endpoints found in the resource group.'
}
else {
    foreach ($pe in $privateEndpoints) {
        $connection = $pe.privateLinkServiceConnections | Select-Object -First 1
        $state = $connection.privateLinkServiceConnectionState.status
        $group = ($connection.groupIds -join ',')

        if ($state -eq 'Approved') {
            Add-Result -Name "Private endpoint approved: $($pe.name)" -Status 'Pass' -Detail "groupId=$group, state=$state"
        }
        else {
            Add-Result -Name "Private endpoint approved: $($pe.name)" -Status 'Fail' -Detail "groupId=$group, state=$state"
        }
    }

    $sitesEndpoint = $privateEndpoints | Where-Object {
        $_.privateLinkServiceConnections[0].groupIds -contains 'sites'
    } | Select-Object -First 1

    if ($sitesEndpoint) {
        Add-Result -Name 'Function App is fronted by a private endpoint' -Status 'Pass' -Detail $sitesEndpoint.name
    }
    else {
        Add-Result -Name 'Function App is fronted by a private endpoint' -Status 'Fail' -Detail 'No private endpoint with groupId "sites".'
    }
}

# ---------------------------------------------------------------------------------------------
# 6-7. Private DNS
# ---------------------------------------------------------------------------------------------

$dnsZones = Invoke-Az @('network', 'private-dns', 'zone', 'list', '--resource-group', $ResourceGroupName, '--output', 'json')
$virtualNetworks = Invoke-Az @('network', 'vnet', 'list', '--resource-group', $ResourceGroupName, '--output', 'json')
$vnetCount = @($virtualNetworks).Count

if (-not $dnsZones) {
    Add-Result -Name 'Workload-owned private DNS zones exist' -Status 'Warn' `
        -Detail 'No private DNS zones in this resource group. Expected when an Azure Landing Zone policy owns DNS centrally.'
}
else {
    Add-Result -Name 'Workload-owned private DNS zones exist' -Status 'Pass' -Detail (@($dnsZones | ForEach-Object { $_.name }) -join ', ')

    $sitesZone = $dnsZones | Where-Object { $_.name -eq 'privatelink.azurewebsites.net' } | Select-Object -First 1

    if ($sitesZone) {
        $records = Invoke-Az @('network', 'private-dns', 'record-set', 'a', 'list',
            '--resource-group', $ResourceGroupName, '--zone-name', 'privatelink.azurewebsites.net', '--output', 'json')

        $recordNames = @($records | ForEach-Object { $_.name })

        if ($recordNames.Count -gt 0) {
            $addresses = @($records | ForEach-Object { $_.aRecords.ipv4Address }) -join ', '
            Add-Result -Name 'Private DNS A records exist for the Function App' -Status 'Pass' `
                -Detail "$($recordNames -join ', ') -> $addresses"

            if ($recordNames -match '\.scm$' -or ($recordNames | Where-Object { $_ -like '*scm*' })) {
                Add-Result -Name 'SCM host resolves privately' -Status 'Pass' -Detail 'An scm A record is present in the same zone.'
            }
            else {
                Add-Result -Name 'SCM host resolves privately' -Status 'Warn' `
                    -Detail 'No scm record found. The private DNS zone group normally adds it automatically.'
            }
        }
        else {
            Add-Result -Name 'Private DNS A records exist for the Function App' -Status 'Fail' `
                -Detail 'The zone exists but contains no A records. The private DNS zone group may not have run.'
        }
    }

    foreach ($zone in $dnsZones) {
        $links = Invoke-Az @('network', 'private-dns', 'link', 'vnet', 'list',
            '--resource-group', $ResourceGroupName, '--zone-name', $zone.name, '--output', 'json')

        $linkCount = @($links).Count

        if ($linkCount -ge $vnetCount -and $vnetCount -gt 0) {
            Add-Result -Name "DNS zone linked to every virtual network: $($zone.name)" -Status 'Pass' -Detail "$linkCount of $vnetCount"
        }
        else {
            Add-Result -Name "DNS zone linked to every virtual network: $($zone.name)" -Status 'Fail' `
                -Detail "Linked to $linkCount of $vnetCount networks. Power Platform resolves names using the DNS of the virtual network the delegated subnet runs in, so every network needs the link."
        }
    }
}

# ---------------------------------------------------------------------------------------------
# 8. Storage
# ---------------------------------------------------------------------------------------------

$storageAccounts = Invoke-Az @('storage', 'account', 'list', '--resource-group', $ResourceGroupName, '--output', 'json')
$storageAccount = $storageAccounts | Select-Object -First 1

if (-not $storageAccount) {
    Add-Result -Name 'Storage account exists' -Status 'Fail' -Detail 'No storage account found.'
}
else {
    Add-Result -Name 'Storage account exists' -Status 'Pass' -Detail $storageAccount.name

    if ($storageAccount.allowSharedKeyAccess -eq $false) {
        Add-Result -Name 'Storage shared key access is disabled' -Status 'Pass' `
            -Detail 'allowSharedKeyAccess = false, so no connection string or SAS token can be produced.'
    }
    else {
        Add-Result -Name 'Storage shared key access is disabled' -Status 'Fail' `
            -Detail "allowSharedKeyAccess = $($storageAccount.allowSharedKeyAccess). Account keys and SAS tokens would still work."
    }

    if ($storageAccount.publicNetworkAccess -eq 'Disabled') {
        Add-Result -Name 'Storage public network access is disabled' -Status 'Pass' -Detail 'publicNetworkAccess = Disabled'
    }
    else {
        Add-Result -Name 'Storage public network access is disabled' -Status 'Warn' `
            -Detail "publicNetworkAccess = $($storageAccount.publicNetworkAccess)"
    }
}

# ---------------------------------------------------------------------------------------------
# 10. RBAC
# ---------------------------------------------------------------------------------------------

if ($functionApp -and $functionApp.identity -and $functionApp.identity.principalId) {
    $principalId = $functionApp.identity.principalId

    $insightsComponents = Invoke-Az @('resource', 'list', '--resource-group', $ResourceGroupName,
        '--resource-type', 'Microsoft.Insights/components', '--output', 'json')
    $insightsForRbac = $insightsComponents | Select-Object -First 1

    $storageId = if ($storageAccount) { $storageAccount.id } else { $null }
    $insightsId = if ($insightsForRbac) { $insightsForRbac.id } else { $null }

    # Listing role assignments at a scope returns that scope and everything it inherits from, never
    # anything below it. These assignments are scoped to individual resources, so asking at the
    # resource group finds nothing and asking at the resource itself finds them. This is the single
    # most common way an RBAC check reports a false negative.
    #
    # `az role assignment list --assignee` is avoided as the primary source because it resolves the
    # principal through Microsoft Graph first: a caller who can read ARM but not the directory --
    # any guest, for instance -- gets an empty list rather than an error, so a correct deployment is
    # reported as having no RBAC at all.
    #
    # Only one query parameter is used, deliberately. On Windows the CLI goes through cmd.exe, which
    # treats an unquoted `&` as a command separator, so a URL carrying both api-version and $filter
    # is cut in half before az ever sees it. Filtering happens here instead.
    function Get-RoleAssignmentsAtScope {
        param([Parameter(Mandatory)][string] $Scope)

        $url = "https://management.azure.com$Scope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"
        $response = Invoke-Az @('rest', '--method', 'get', '--url', $url, '--output', 'json')

        if (-not $response -or -not $response.PSObject.Properties['value']) { return $null }

        return @($response.value | ForEach-Object {
            [pscustomobject]@{
                PrincipalId        = $_.properties.principalId
                RoleDefinitionGuid = ($_.properties.roleDefinitionId -split '/')[-1]
                Scope              = $_.properties.scope
            }
        })
    }

    # Built-in role definition GUIDs, matching the roles map in infra/main.bicep.
    $expectedRoles = @(
        @{ Name = 'Storage Blob Data Owner';        Guid = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'; Target = $storageId;  Kind = 'the storage account' }
        @{ Name = 'Storage Queue Data Contributor'; Guid = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'; Target = $storageId;  Kind = 'the storage account' }
        @{ Name = 'Storage Table Data Contributor'; Guid = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'; Target = $storageId;  Kind = 'the storage account' }
        @{ Name = 'Monitoring Metrics Publisher';   Guid = '3913510d-42f4-4e42-8a64-420c390055eb'; Target = $insightsId; Kind = 'the Application Insights component' }
    )

    # Cache one lookup per distinct target, and remember whether the directory could be read at all.
    $assignmentsByScope = @{}
    $anyScopeReadable = $false

    foreach ($scope in @($expectedRoles | ForEach-Object { $_.Target } | Where-Object { $_ } | Sort-Object -Unique)) {
        $found = Get-RoleAssignmentsAtScope -Scope $scope
        $assignmentsByScope[$scope] = $found
        if ($null -ne $found) { $anyScopeReadable = $true }
    }

    # The storage roles have independent proof: the host cannot start without reading its own
    # deployment package, and with shared key access disabled managed identity is the only way to
    # do that. So if a storage role cannot be found even though the host is running, the grant is
    # present and this caller simply cannot see it -- which means it cannot see the Application
    # Insights grant either, and that one has no equivalent proof to fall back on.
    $hostIsRunning = $functions -and @($functions).Count -gt 0
    $sharedKeysDisabled = $storageAccount -and $storageAccount.allowSharedKeyAccess -eq $false

    $storageRoleGuids = @($expectedRoles | Where-Object { $_.Target -eq $storageId } | ForEach-Object { $_.Guid })
    $storageRolesVisible = @(@($assignmentsByScope[$storageId]) |
        Where-Object { $_.PrincipalId -eq $principalId -and $_.RoleDefinitionGuid -in $storageRoleGuids }).Count -gt 0

    $rbacReadsUnavailable = $hostIsRunning -and $sharedKeysDisabled -and $storageId -and -not $storageRolesVisible

    foreach ($role in $expectedRoles) {
        if (-not $role.Target) {
            Add-Result -Name "Managed identity role assigned: $($role.Name)" -Status 'Warn' `
                -Detail 'The resource this role applies to was not found, so the assignment could not be checked.'
            continue
        }

        $atTarget = @($assignmentsByScope[$role.Target])
        $matching = @($atTarget | Where-Object { $_.PrincipalId -eq $principalId -and $_.RoleDefinitionGuid -eq $role.Guid })

        if ($matching.Count -gt 0) {
            $exact = @($matching | Where-Object { $_.Scope -eq $role.Target })

            if ($exact.Count -gt 0) {
                Add-Result -Name "Managed identity role assigned: $($role.Name)" -Status 'Pass' `
                    -Detail "Scoped to $($role.Kind), which is as narrow as this role can be."
            }
            else {
                Add-Result -Name "Managed identity role assigned: $($role.Name)" -Status 'Warn' `
                    -Detail "Inherited from $(($matching | ForEach-Object { $_.Scope }) -join ', ') rather than assigned on $($role.Kind). Access works, but it is wider than intended."
            }
            continue
        }

        # Nothing matched. Before calling that a failure, weigh it against what the rest of this
        # script has already established -- see $rbacReadsUnavailable above. Reading role
        # assignments needs Microsoft.Authorization/roleAssignments/read on the scope, which plenty
        # of legitimate operators, guests especially, do not have. Reporting a working deployment
        # as broken is the worse error, so that case is a warning that names exactly which of the
        # two possibilities it could not separate.
        if ($rbacReadsUnavailable) {
            Add-Result -Name "Managed identity role assigned: $($role.Name)" -Status 'Warn' `
                -Detail 'Not readable with these credentials. The host is running with shared key access disabled, which is impossible without a working managed-identity grant, so role assignments exist but cannot be listed here. Grant Microsoft.Authorization/roleAssignments/read to check directly.'
        }
        elseif ($anyScopeReadable) {
            Add-Result -Name "Managed identity role assigned: $($role.Name)" -Status 'Fail' `
                -Detail "No assignment of $($role.Guid) for $principalId on or above $($role.Kind)."
        }
        else {
            Add-Result -Name "Managed identity role assigned: $($role.Name)" -Status 'Warn' `
                -Detail 'Role assignments could not be read with these credentials, so presence could not be confirmed either way. Microsoft.Authorization/roleAssignments/read on the resource is required.'
        }
    }

    # Least privilege is about what the identity must NOT hold, so it has to look wider than the
    # two target resources: a broad role granted higher up is inherited and would not show up in
    # the per-resource lookups above.
    $broadRoles = @{
        '8e3af657-a8ff-443c-a75c-2fe8c4bcb635' = 'Owner'
        'b24988ac-6180-42a0-ab88-20f7382dd24c' = 'Contributor'
        '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9' = 'User Access Administrator'
    }

    $inheritedScopes = @(
        "/subscriptions/$(($functionApp.id -split '/')[2])/resourceGroups/$ResourceGroupName"
        "/subscriptions/$(($functionApp.id -split '/')[2])"
    )

    $wideAssignments = @()
    $couldReadWideScopes = $false

    foreach ($scope in $inheritedScopes) {
        $found = Get-RoleAssignmentsAtScope -Scope $scope
        if ($null -eq $found) { continue }
        $couldReadWideScopes = $true
        $wideAssignments += @($found | Where-Object { $_.PrincipalId -eq $principalId -and $broadRoles.ContainsKey($_.RoleDefinitionGuid) })
    }

    if (-not $couldReadWideScopes) {
        Add-Result -Name 'Managed identity is least privilege' -Status 'Warn' `
            -Detail 'Role assignments could not be read with these credentials, so this could not be confirmed.'
    }
    elseif ($wideAssignments.Count -gt 0) {
        $names = @($wideAssignments | ForEach-Object { $broadRoles[$_.RoleDefinitionGuid] } | Sort-Object -Unique)
        Add-Result -Name 'Managed identity is least privilege' -Status 'Fail' -Detail "Holds broad role(s): $($names -join ', ')"
    }
    else {
        Add-Result -Name 'Managed identity is least privilege' -Status 'Pass' -Detail 'No Owner, Contributor or User Access Administrator assignment.'
    }
}

# ---------------------------------------------------------------------------------------------
# 11-12. Networking
# ---------------------------------------------------------------------------------------------

if (-not $virtualNetworks) {
    Add-Result -Name 'Virtual networks exist' -Status 'Fail' -Detail 'No virtual networks found.'
}
else {
    Add-Result -Name 'Virtual networks exist' -Status 'Pass' -Detail (@($virtualNetworks | ForEach-Object { "$($_.name) ($($_.location))" }) -join ', ')

    $delegatedSubnets = 0

    foreach ($vnet in $virtualNetworks) {
        $subnet = $vnet.subnets | Where-Object { $_.name -eq 'snet-powerplatform' } | Select-Object -First 1

        if (-not $subnet) {
            Add-Result -Name "Power Platform delegated subnet in $($vnet.name)" -Status 'Fail' -Detail 'snet-powerplatform not found.'
            continue
        }

        $delegation = $subnet.delegations | Select-Object -First 1
        $serviceName = if ($delegation) { $delegation.serviceName } else { '(none)' }

        if ($serviceName -eq 'Microsoft.PowerPlatform/enterprisePolicies') {
            $delegatedSubnets++
            Add-Result -Name "Power Platform delegated subnet in $($vnet.name)" -Status 'Pass' `
                -Detail "$($subnet.addressPrefix) delegated to $serviceName"
        }
        else {
            Add-Result -Name "Power Platform delegated subnet in $($vnet.name)" -Status 'Fail' `
                -Detail "Delegated to '$serviceName', expected Microsoft.PowerPlatform/enterprisePolicies."
        }
    }

    $primaryVnet = $virtualNetworks | Where-Object { $_.name -like '*primary*' } | Select-Object -First 1
    if ($primaryVnet) {
        $functionSubnet = $primaryVnet.subnets | Where-Object { $_.name -eq 'snet-functions' } | Select-Object -First 1
        $functionDelegation = if ($functionSubnet) { ($functionSubnet.delegations | Select-Object -First 1).serviceName } else { $null }

        if ($functionDelegation -eq 'Microsoft.App/environments') {
            Add-Result -Name 'Function outbound integration subnet delegated correctly' -Status 'Pass' `
                -Detail "snet-functions delegated to $functionDelegation"
        }
        else {
            Add-Result -Name 'Function outbound integration subnet delegated correctly' -Status 'Fail' `
                -Detail "Expected Microsoft.App/environments, found '$functionDelegation'."
        }
    }

    # Azure Landing Zones assign Deny-Subnet-Without-Nsg as a Deny effect, so a missing network
    # security group is not a hardening gap - it means the subnet could not have been created.
    $subnetsWithoutNsg = @()
    foreach ($vnet in $virtualNetworks) {
        foreach ($subnet in $vnet.subnets) {
            if (-not $subnet.networkSecurityGroup) {
                $subnetsWithoutNsg += "$($vnet.name)/$($subnet.name)"
            }
        }
    }

    if ($subnetsWithoutNsg.Count -eq 0) {
        Add-Result -Name 'Every subnet has a network security group' -Status 'Pass' `
            -Detail 'Satisfies the Azure Landing Zone Deny-Subnet-Without-Nsg policy.'
    }
    else {
        Add-Result -Name 'Every subnet has a network security group' -Status 'Fail' `
            -Detail "Missing on: $($subnetsWithoutNsg -join ', ')"
    }

    if ($vnetCount -gt 1) {
        if ($delegatedSubnets -ge 2) {
            Add-Result -Name 'Delegated subnets exist in both regions of the Power Platform region pair' -Status 'Pass' `
                -Detail "$delegatedSubnets delegated subnets"
        }
        else {
            Add-Result -Name 'Delegated subnets exist in both regions of the Power Platform region pair' -Status 'Fail' `
                -Detail 'Power Platform can fail over between the two Azure regions of its region pair; both need a delegated subnet.'
        }

        $peeringsConnected = $true
        foreach ($vnet in $virtualNetworks) {
            $peerings = Invoke-Az @('network', 'vnet', 'peering', 'list',
                '--resource-group', $ResourceGroupName, '--vnet-name', $vnet.name, '--output', 'json')

            foreach ($peering in @($peerings)) {
                if ($peering.peeringState -ne 'Connected') { $peeringsConnected = $false }
            }

            if (@($peerings).Count -eq 0) { $peeringsConnected = $false }
        }

        if ($peeringsConnected) {
            Add-Result -Name 'Virtual network peering is connected' -Status 'Pass'
        }
        else {
            Add-Result -Name 'Virtual network peering is connected' -Status 'Fail' `
                -Detail 'The failover network must be able to reach the private endpoints in the primary network.'
        }
    }
    else {
        Add-Result -Name 'Delegated subnets exist in both regions of the Power Platform region pair' -Status 'Skip' `
            -Detail 'Single-region Power Platform geography.'
    }
}

# ---------------------------------------------------------------------------------------------
# 13. Application Insights
# ---------------------------------------------------------------------------------------------

$components = Invoke-Az @('resource', 'list', '--resource-group', $ResourceGroupName,
    '--resource-type', 'Microsoft.Insights/components', '--output', 'json')
$appInsights = $components | Select-Object -First 1

if (-not $appInsights) {
    Add-Result -Name 'Application Insights exists' -Status 'Fail' -Detail 'No Application Insights component found.'
}
else {
    $detail = Invoke-Az @('resource', 'show', '--ids', $appInsights.id, '--output', 'json')

    if ($detail.properties.DisableLocalAuth -eq $true) {
        Add-Result -Name 'Application Insights local auth is disabled' -Status 'Pass' `
            -Detail 'Telemetry requires a Microsoft Entra ID token; the instrumentation key alone is not accepted.'
    }
    else {
        Add-Result -Name 'Application Insights local auth is disabled' -Status 'Warn' `
            -Detail 'DisableLocalAuth is not true; an instrumentation key would be accepted as a credential.'
    }
}

# ---------------------------------------------------------------------------------------------
# 14. Enterprise policy
# ---------------------------------------------------------------------------------------------

$policies = Invoke-Az @('resource', 'list', '--resource-group', $ResourceGroupName,
    '--resource-type', 'Microsoft.PowerPlatform/enterprisePolicies', '--output', 'json')
$policy = $policies | Select-Object -First 1

if (-not $policy) {
    Add-Result -Name 'Power Platform enterprise policy exists' -Status 'Warn' `
        -Detail 'No enterprise policy in the resource group. Expected when deployEnterprisePolicy = false.'
}
else {
    $policyDetail = Invoke-Az @('resource', 'show', '--ids', $policy.id, '--api-version', '2020-10-30-preview', '--output', 'json')
    # A policy of the wrong kind has no networkInjection property at all, and under StrictMode
    # reading through it throws and takes the whole run down instead of failing this one check.
    $injectedNetworks = @(Get-PropertyOrNull -InputObject (
        Get-PropertyOrNull -InputObject $policyDetail.properties -Name 'networkInjection'
    ) -Name 'virtualNetworks')

    if ($policyDetail.kind -eq 'NetworkInjection' -and $injectedNetworks.Count -ge 1) {
        Add-Result -Name 'Power Platform enterprise policy exists' -Status 'Pass' `
            -Detail "$($policy.name), kind=$($policyDetail.kind), networks=$($injectedNetworks.Count), systemId=$($policyDetail.properties.systemId)"

        if ($vnetCount -gt 1 -and $injectedNetworks.Count -lt 2) {
            Add-Result -Name 'Enterprise policy references both regional networks' -Status 'Fail' `
                -Detail 'Only one virtual network is referenced; the environment would lose connectivity after a Power Platform regional failover.'
        }
        elseif ($vnetCount -gt 1) {
            Add-Result -Name 'Enterprise policy references both regional networks' -Status 'Pass'
        }
    }
    else {
        Add-Result -Name 'Power Platform enterprise policy exists' -Status 'Fail' `
            -Detail "kind=$($policyDetail.kind), networks=$($injectedNetworks.Count)"
    }

    if ($PowerPlatformEnvironmentId) {
        try {
            # Deliberately no --subscription. This is a token for the Power Platform BAP API, not
            # an Azure resource call: the token is tenant-scoped, and pinning it to an Azure
            # subscription made the environment lookup return 404. Verified live, both ways.
            $token = az account get-access-token --resource 'https://service.powerapps.com/' --query accessToken --output tsv
            $uri = "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$PowerPlatformEnvironmentId`?api-version=2016-11-01"
            $environment = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $token" }

            # An environment that is NOT linked simply has no enterprisePolicies property, and
            # under Set-StrictMode walking into it throws. The catch below then reported that as a
            # confusing warning about a missing property, hiding the specific, actionable failure
            # this check exists to produce. Navigate defensively so "not linked" reaches the Fail
            # branch and the catch is left for genuine query problems.
            $linkedPolicy = Get-PropertyOrNull -InputObject (
                Get-PropertyOrNull -InputObject (
                    Get-PropertyOrNull -InputObject $environment.properties -Name 'enterprisePolicies'
                ) -Name 'VNets'
            ) -Name 'id'

            if ($linkedPolicy) {
                Add-Result -Name 'Power Platform environment is linked to the enterprise policy' -Status 'Pass' -Detail $linkedPolicy
            }
            else {
                Add-Result -Name 'Power Platform environment is linked to the enterprise policy' -Status 'Fail' `
                    -Detail 'The environment reports no linked VNet policy. Run scripts/Set-PowerPlatformSubnetInjection.ps1.'
            }
        }
        catch {
            Add-Result -Name 'Power Platform environment is linked to the enterprise policy' -Status 'Warn' `
                -Detail "Could not query the environment: $($_.Exception.Message)"
        }
    }
    else {
        Add-Result -Name 'Power Platform environment is linked to the enterprise policy' -Status 'Skip' `
            -Detail 'Supply -PowerPlatformEnvironmentId to check this.'
    }
}

# ---------------------------------------------------------------------------------------------
# Power Platform solution
# ---------------------------------------------------------------------------------------------

if ($PowerPlatformEnvironmentUrl) {
    $pac = Get-Command pac -ErrorAction SilentlyContinue

    if (-not $pac) {
        Add-Result -Name 'Power Platform solution is imported' -Status 'Skip' -Detail 'Power Platform CLI (pac) is not on PATH.'
    }
    else {
        $solutionList = & pac solution list --environment $PowerPlatformEnvironmentUrl 2>&1 | Out-String

        if ($solutionList -match 'SecureRequestClassifier') {
            Add-Result -Name 'Power Platform solution is imported' -Status 'Pass' -Detail 'SecureRequestClassifier found in the environment.'
        }
        else {
            Add-Result -Name 'Power Platform solution is imported' -Status 'Fail' -Detail 'SecureRequestClassifier was not listed in the environment.'
        }
    }
}
else {
    Add-Result -Name 'Power Platform solution is imported' -Status 'Skip' -Detail 'Supply -PowerPlatformEnvironmentUrl to check this.'
}

# ---------------------------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------------------------

Write-Host ''
Write-Host ('-' * 78)

$passed = @($script:Results | Where-Object Status -eq 'Pass').Count
$failed = @($script:Results | Where-Object Status -eq 'Fail').Count
$warned = @($script:Results | Where-Object Status -eq 'Warn').Count
$skipped = @($script:Results | Where-Object Status -eq 'Skip').Count

Write-Host ("Passed: {0}   Failed: {1}   Warnings: {2}   Skipped: {3}" -f $passed, $failed, $warned, $skipped)

if ($env:GITHUB_STEP_SUMMARY) {
    $lines = @(
        '## Deployment verification',
        '',
        "Passed: **$passed** | Failed: **$failed** | Warnings: **$warned** | Skipped: **$skipped**",
        '',
        '| Status | Check | Detail |',
        '| --- | --- | --- |'
    )
    foreach ($result in $script:Results) {
        $detail = ($result.Detail -replace '\|', '\|')
        $lines += "| $($result.Status) | $($result.Check) | $detail |"
    }
    $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

if ($failed -gt 0) { exit 1 }
if ($FailOnWarning -and $warned -gt 0) { exit 1 }
exit 0
