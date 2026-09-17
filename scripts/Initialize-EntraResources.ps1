<#
.SYNOPSIS
    Creates the Microsoft Entra ID resources the demo needs, using no secrets at any point.

.DESCRIPTION
    This is the one-time bootstrap. It creates:

      1. A deployment app registration with a GitHub **federated identity credential**
         (workload identity federation). No client secret is ever created, so there is nothing
         to store in GitHub.
      2. An API app registration that represents the Azure Function, exposing an
         Application ID URI and a delegated scope.
      3. The service principal for the "HTTP with Microsoft Entra ID (preauthorized)"
         connector, plus the delegated permission grant that lets the connector obtain a token
         for the API on behalf of a signed-in user.
      4. Least-privilege Azure role assignments for the deployment identity.

    Everything it prints is an identifier, not a credential. Store the values as GitHub
    repository *variables*.

.PARAMETER GitHubRepository
    owner/repo, for example contoso/secure-request-classifier.

.PARAMETER SubscriptionId
    Azure subscription that will host the demo.

.PARAMETER Environments
    GitHub environment names to federate. A federated credential is also created for the
    default branch and for pull requests.

.PARAMETER SkipRoleAssignments
    Create the identities but do not attempt Azure role assignments. Use when a separate
    person or process owns RBAC.

.EXAMPLE
    ./Initialize-EntraResources.ps1 -GitHubRepository contoso/secure-request-classifier `
        -SubscriptionId 00000000-0000-0000-0000-000000000000

.NOTES
    Requires: Azure CLI, signed in as a user who can create app registrations and role
    assignments. Microsoft Graph permissions needed: Application.ReadWrite.All and
    DelegatedPermissionGrant.ReadWrite.All (Application Administrator or Cloud Application
    Administrator is sufficient).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string] $GitHubRepository,

    [Parameter(Mandatory)]
    [string] $SubscriptionId,

    [string] $DeploymentAppDisplayName = 'Secure Request Classifier - GitHub deployment',

    [string] $ApiAppDisplayName = 'Secure Request Classifier - Function API',

    [string[]] $Environments = @('demo'),

    [string] $DefaultBranch = 'main',

    [string] $ApiScopeName = 'user_impersonation',

    [switch] $SkipRoleAssignments,

    [switch] $SkipPowerPlatformAdminRole
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Microsoft publishes this application ID in
# microsoft/PowerApps-Samples/powershell/connectors/HTTPWithMicrosoftEntraId/ManagePermissionGrant.ps1
# as $HttpWithAADAppAppId. It is the app behind the "HTTP with Microsoft Entra ID
# (preauthorized)" connector.
$script:HttpWithEntraIdConnectorAppId = 'd2ebd3a9-1ada-4480-8b2d-eac162716601'

$script:GraphBase = 'https://graph.microsoft.com/v1.0'

# Built-in role definition GUIDs.
$script:Roles = @{
    Contributor                          = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
    RoleBasedAccessControlAdministrator  = 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'
}

# Microsoft Entra ID directory role template for Power Platform Administrator. The deployment
# identity needs it to link the network-injection enterprise policy to the environment.
# https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference
$script:PowerPlatformAdministratorRoleTemplateId = '11648597-926c-4cf3-9c36-bcebb0ba8dcc'

function Write-Step {
    param([string] $Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Invoke-Graph {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string] $Method,
        [Parameter(Mandatory)][string] $Uri,
        [object] $Body
    )

    $arguments = @('rest', '--method', $Method.ToLowerInvariant(), '--uri', $Uri)
    $bodyFile = $null

    if ($null -ne $Body) {
        # Pass the payload via a file rather than inline. Inline JSON is mangled by the shell's
        # argument parsing on Windows, which Microsoft Graph rejects with
        # "Unable to read JSON request payload".
        $bodyFile = [System.IO.Path]::GetTempFileName()
        $json = $Body | ConvertTo-Json -Depth 20

        # Azure CLI reads @file as UTF-8 and chokes on a byte order mark.
        [System.IO.File]::WriteAllText($bodyFile, $json, (New-Object System.Text.UTF8Encoding($false)))

        $arguments += @('--headers', 'Content-Type=application/json', '--body', "@$bodyFile")
    }

    try {
        $raw = & az @arguments 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "Microsoft Graph $Method $Uri failed: $raw"
        }
    }
    finally {
        if ($bodyFile -and (Test-Path $bodyFile)) {
            Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
        }
    }

    if ([string]::IsNullOrWhiteSpace(($raw | Out-String).Trim())) { return $null }

    return ($raw | Out-String | ConvertFrom-Json)
}

function Get-ApplicationByDisplayName {
    param([Parameter(Mandatory)][string] $DisplayName)

    $escaped = $DisplayName.Replace("'", "''")
    $result = Invoke-Graph -Method GET -Uri "$script:GraphBase/applications?`$filter=displayName eq '$escaped'"

    if ($result.value.Count -gt 1) {
        throw "More than one app registration is named '$DisplayName'. Resolve the ambiguity before re-running."
    }

    return $result.value | Select-Object -First 1
}

function New-OrGetApplication {
    param(
        [Parameter(Mandatory)][string] $DisplayName,
        [hashtable] $ExtraProperties = @{}
    )

    $existing = Get-ApplicationByDisplayName -DisplayName $DisplayName
    if ($existing) {
        Write-Host "    app registration already exists: $DisplayName ($($existing.appId))"
        return $existing
    }

    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'Create app registration')) { return $null }

    $body = @{
        displayName    = $DisplayName
        signInAudience = 'AzureADMyOrg'
    }
    foreach ($key in $ExtraProperties.Keys) { $body[$key] = $ExtraProperties[$key] }

    $created = Invoke-Graph -Method POST -Uri "$script:GraphBase/applications" -Body $body
    Write-Host "    created app registration: $DisplayName ($($created.appId))" -ForegroundColor Green

    # Graph is eventually consistent; give the object a moment to replicate.
    Start-Sleep -Seconds 10
    return $created
}

function New-OrGetServicePrincipal {
    param([Parameter(Mandatory)][string] $AppId)

    $result = Invoke-Graph -Method GET -Uri "$script:GraphBase/servicePrincipals?`$filter=appId eq '$AppId'"
    $existing = $result.value | Select-Object -First 1

    if ($existing) {
        Write-Host "    service principal already exists for $AppId ($($existing.id))"
        return $existing
    }

    if (-not $PSCmdlet.ShouldProcess($AppId, 'Create service principal')) { return $null }

    $created = Invoke-Graph -Method POST -Uri "$script:GraphBase/servicePrincipals" -Body @{ appId = $AppId }
    Write-Host "    created service principal for $AppId ($($created.id))" -ForegroundColor Green
    Start-Sleep -Seconds 5
    return $created
}

function Set-FederatedCredential {
    param(
        [Parameter(Mandatory)][string] $ApplicationObjectId,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Subject,
        [Parameter(Mandatory)][string] $Description
    )

    $existing = Invoke-Graph -Method GET `
        -Uri "$script:GraphBase/applications/$ApplicationObjectId/federatedIdentityCredentials"

    $match = $existing.value | Where-Object { $_.name -eq $Name } | Select-Object -First 1

    if ($match) {
        if ($match.subject -eq $Subject) {
            Write-Host "    federated credential '$Name' already correct"
            return
        }

        Write-Host "    federated credential '$Name' has subject '$($match.subject)', updating to '$Subject'"
        Invoke-Graph -Method PATCH `
            -Uri "$script:GraphBase/applications/$ApplicationObjectId/federatedIdentityCredentials/$($match.id)" `
            -Body @{ subject = $Subject } | Out-Null
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Name, 'Create federated identity credential')) { return }

    Invoke-Graph -Method POST `
        -Uri "$script:GraphBase/applications/$ApplicationObjectId/federatedIdentityCredentials" `
        -Body @{
            name        = $Name
            issuer      = 'https://token.actions.githubusercontent.com'
            subject     = $Subject
            description = $Description
            audiences   = @('api://AzureADTokenExchange')
        } | Out-Null

    Write-Host "    created federated credential '$Name' -> $Subject" -ForegroundColor Green
}

function Get-GitHubSubjectPrefix {
    param([Parameter(Mandatory)][string] $Repository)

    <#
        GitHub now issues OIDC subject claims that embed immutable numeric IDs:

            repo:owner@44774639/repo@1374170102:environment:demo

        rather than the name-based form:

            repo:owner/repo:environment:demo

        This is enabled by default on repositories and cannot currently be turned off (a PUT
        setting use_immutable_subject to false is accepted and ignored). A federated identity
        credential built from the repository NAME therefore never matches, and azure/login
        fails with AADSTS700213 "No matching federated identity record found".

        So rather than assuming a format, ask GitHub which prefix it will actually issue.
    #>
    $default = "repo:$Repository"

    $gh = Get-Command 'gh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $gh) {
        Write-Warning "GitHub CLI (gh) not found, so the OIDC subject prefix cannot be read."
        Write-Warning "Assuming '$default'. If azure/login later fails with AADSTS700213, install"
        Write-Warning "the GitHub CLI, run 'gh auth login' and re-run this script."
        return $default
    }

    try {
        $raw = & $gh.Source api "repos/$Repository/actions/oidc/customization/sub" 2>$null

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
            Write-Warning "Could not read the OIDC subject configuration for $Repository; assuming '$default'."
            return $default
        }

        $config = $raw | ConvertFrom-Json

        if (($config.PSObject.Properties.Name -contains 'sub_claim_prefix') -and
            -not [string]::IsNullOrWhiteSpace($config.sub_claim_prefix)) {

            if ($config.sub_claim_prefix -ne $default) {
                Write-Host '    this repository uses immutable OIDC subject claims' -ForegroundColor Yellow
                Write-Host "    subject prefix: $($config.sub_claim_prefix)"
            }

            return $config.sub_claim_prefix
        }
    }
    catch {
        Write-Warning "Could not read the OIDC subject configuration: $($_.Exception.Message)"
    }

    return $default
}

function Ensure-ApiScope {
    param(
        [Parameter(Mandatory)][object] $Application,
        [Parameter(Mandatory)][string] $ScopeName
    )

    $api = $Application.api
    $existingScope = $null
    if ($api -and $api.oauth2PermissionScopes) {
        $existingScope = $api.oauth2PermissionScopes | Where-Object { $_.value -eq $ScopeName } | Select-Object -First 1
    }

    if ($existingScope) {
        Write-Host "    scope '$ScopeName' already exposed ($($existingScope.id))"
        return $existingScope.id
    }

    $scopeId = [guid]::NewGuid().ToString()

    $scope = @{
        id                      = $scopeId
        value                   = $ScopeName
        type                    = 'User'
        isEnabled               = $true
        adminConsentDisplayName = 'Classify requests on behalf of the signed-in user'
        adminConsentDescription = 'Allows the calling application to submit classification requests to the Secure Request Classifier API on behalf of the signed-in user.'
        userConsentDisplayName  = 'Classify requests on your behalf'
        userConsentDescription  = 'Allows the app to submit classification requests on your behalf.'
    }

    $identifierUri = "api://$($Application.appId)"

    if (-not $PSCmdlet.ShouldProcess($Application.displayName, "Expose scope $ScopeName")) { return $scopeId }

    Invoke-Graph -Method PATCH -Uri "$script:GraphBase/applications/$($Application.id)" -Body @{
        identifierUris = @($identifierUri)
        api            = @{
            oauth2PermissionScopes    = @($scope)
            requestedAccessTokenVersion = 2
        }
    } | Out-Null

    Write-Host "    exposed scope '$ScopeName' and Application ID URI $identifierUri" -ForegroundColor Green
    Start-Sleep -Seconds 5
    return $scopeId
}

function Set-PreAuthorizedApplication {
    param(
        [Parameter(Mandatory)][string] $ApiApplicationObjectId,
        [Parameter(Mandatory)][string] $ClientAppId,
        [Parameter(Mandatory)][string] $ScopeId
    )

    if (-not $PSCmdlet.ShouldProcess($ClientAppId, 'Pre-authorize application')) { return }

    Invoke-Graph -Method PATCH -Uri "$script:GraphBase/applications/$ApiApplicationObjectId" -Body @{
        api = @{
            preAuthorizedApplications = @(
                @{
                    appId                  = $ClientAppId
                    delegatedPermissionIds = @($ScopeId)
                }
            )
        }
    } | Out-Null

    Write-Host "    pre-authorized $ClientAppId for scope $ScopeId" -ForegroundColor Green
}

function Set-DelegatedPermissionGrant {
    param(
        [Parameter(Mandatory)][string] $ClientServicePrincipalId,
        [Parameter(Mandatory)][string] $ResourceServicePrincipalId,
        [Parameter(Mandatory)][string] $Scope
    )

    $filter = "clientId eq '$ClientServicePrincipalId' and resourceId eq '$ResourceServicePrincipalId'"
    $existing = Invoke-Graph -Method GET -Uri "$script:GraphBase/oauth2PermissionGrants?`$filter=$filter"
    $grant = $existing.value | Select-Object -First 1

    if ($grant) {
        $scopes = ($grant.scope -split ' ') | Where-Object { $_ }
        if ($scopes -contains $Scope) {
            Write-Host "    delegated grant already includes '$Scope'"
            return
        }

        $merged = (($scopes + $Scope) | Select-Object -Unique) -join ' '
        Invoke-Graph -Method PATCH -Uri "$script:GraphBase/oauth2PermissionGrants/$($grant.id)" `
            -Body @{ scope = $merged } | Out-Null
        Write-Host "    extended delegated grant to '$merged'" -ForegroundColor Green
        return
    }

    if (-not $PSCmdlet.ShouldProcess($ResourceServicePrincipalId, "Grant delegated scope $Scope")) { return }

    Invoke-Graph -Method POST -Uri "$script:GraphBase/oauth2PermissionGrants" -Body @{
        clientId    = $ClientServicePrincipalId
        consentType = 'AllPrincipals'
        resourceId  = $ResourceServicePrincipalId
        scope       = $Scope
    } | Out-Null

    Write-Host "    created delegated grant '$Scope' for all principals" -ForegroundColor Green
}

function Set-AzureRoleAssignment {
    param(
        [Parameter(Mandatory)][string] $PrincipalObjectId,
        [Parameter(Mandatory)][string] $RoleDefinitionId,
        [Parameter(Mandatory)][string] $Scope,
        [string] $RoleLabel
    )

    $existing = az role assignment list --assignee $PrincipalObjectId --scope $Scope `
        --role $RoleDefinitionId --query "[0].id" --output tsv 2>$null

    if ($existing) {
        Write-Host "    role '$RoleLabel' already assigned"
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Scope, "Assign role $RoleLabel")) { return }

    az role assignment create `
        --assignee-object-id $PrincipalObjectId `
        --assignee-principal-type ServicePrincipal `
        --role $RoleDefinitionId `
        --scope $Scope `
        --only-show-errors --output none

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to assign role '$RoleLabel' at $Scope."
    }

    Write-Host "    assigned role '$RoleLabel'" -ForegroundColor Green
}

function Set-DirectoryRoleMember {
    param(
        [Parameter(Mandatory)][string] $RoleTemplateId,
        [Parameter(Mandatory)][string] $PrincipalObjectId,
        [Parameter(Mandatory)][string] $RoleLabel
    )

    # A directory role only exists once it has been activated from its template in the tenant.
    $roles = Invoke-Graph -Method GET -Uri "$script:GraphBase/directoryRoles?`$filter=roleTemplateId eq '$RoleTemplateId'"
    $role = $roles.value | Select-Object -First 1

    if (-not $role) {
        if (-not $PSCmdlet.ShouldProcess($RoleLabel, 'Activate directory role')) { return }

        $role = Invoke-Graph -Method POST -Uri "$script:GraphBase/directoryRoles" -Body @{ roleTemplateId = $RoleTemplateId }
        Write-Host "    activated directory role '$RoleLabel'"
    }

    $members = Invoke-Graph -Method GET -Uri "$script:GraphBase/directoryRoles/$($role.id)/members?`$select=id"

    if ($members.value.id -contains $PrincipalObjectId) {
        Write-Host "    directory role '$RoleLabel' already assigned"
        return
    }

    if (-not $PSCmdlet.ShouldProcess($PrincipalObjectId, "Assign directory role $RoleLabel")) { return }

    Invoke-Graph -Method POST -Uri "$script:GraphBase/directoryRoles/$($role.id)/members/`$ref" -Body @{
        '@odata.id' = "$script:GraphBase/directoryObjects/$PrincipalObjectId"
    } | Out-Null

    Write-Host "    assigned directory role '$RoleLabel'" -ForegroundColor Green
}

# ---------------------------------------------------------------------------------------------

Write-Step 'Checking Azure CLI sign-in'

$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) {
    throw "Not signed in. Run 'az login' first."
}

az account set --subscription $SubscriptionId
$tenantId = (az account show --query tenantId --output tsv)
Write-Host "    tenant       $tenantId"
Write-Host "    subscription $SubscriptionId"

# ---------------------------------------------------------------------------------------------

Write-Step "Creating the deployment app registration (workload identity federation, no secret)"

$deploymentApp = New-OrGetApplication -DisplayName $DeploymentAppDisplayName
$deploymentSp = New-OrGetServicePrincipal -AppId $deploymentApp.appId

$subjectPrefix = Get-GitHubSubjectPrefix -Repository $GitHubRepository

$subjects = [ordered]@{
    "github-branch-$DefaultBranch" = @{
        Subject     = "${subjectPrefix}:ref:refs/heads/$DefaultBranch"
        Description = "GitHub Actions on the $DefaultBranch branch of $GitHubRepository"
    }
    'github-pull-request'          = @{
        Subject     = "${subjectPrefix}:pull_request"
        Description = "GitHub Actions for pull requests in $GitHubRepository (validation only)"
    }
}

foreach ($environmentName in $Environments) {
    $subjects["github-environment-$environmentName"] = @{
        Subject     = "${subjectPrefix}:environment:$environmentName"
        Description = "GitHub Actions in the '$environmentName' environment of $GitHubRepository"
    }
}

foreach ($name in $subjects.Keys) {
    Set-FederatedCredential -ApplicationObjectId $deploymentApp.id `
        -Name $name `
        -Subject $subjects[$name].Subject `
        -Description $subjects[$name].Description
}

# ---------------------------------------------------------------------------------------------

Write-Step 'Creating the Function API app registration'

$apiApp = New-OrGetApplication -DisplayName $ApiAppDisplayName
$apiApp = Invoke-Graph -Method GET -Uri "$script:GraphBase/applications/$($apiApp.id)"
$apiSp = New-OrGetServicePrincipal -AppId $apiApp.appId

$scopeId = Ensure-ApiScope -Application $apiApp -ScopeName $ApiScopeName

# ---------------------------------------------------------------------------------------------

Write-Step 'Authorizing the "HTTP with Microsoft Entra ID (preauthorized)" connector'

$connectorSp = New-OrGetServicePrincipal -AppId $script:HttpWithEntraIdConnectorAppId

Set-PreAuthorizedApplication -ApiApplicationObjectId $apiApp.id `
    -ClientAppId $script:HttpWithEntraIdConnectorAppId -ScopeId $scopeId

Set-DelegatedPermissionGrant -ClientServicePrincipalId $connectorSp.id `
    -ResourceServicePrincipalId $apiSp.id -Scope $ApiScopeName

Write-Host '    note: changing preauthorizations can take up to one hour to affect connections' -ForegroundColor Yellow
Write-Host '          that already existed. New connections pick the change up immediately.' -ForegroundColor Yellow

# ---------------------------------------------------------------------------------------------

if (-not $SkipRoleAssignments) {
    Write-Step 'Assigning least-privilege Azure roles to the deployment identity'

    $subscriptionScope = "/subscriptions/$SubscriptionId"

    # Contributor lets the workflow create the resource group and every resource inside it.
    Set-AzureRoleAssignment -PrincipalObjectId $deploymentSp.id `
        -RoleDefinitionId $script:Roles.Contributor -Scope $subscriptionScope -RoleLabel 'Contributor'

    # Contributor explicitly cannot write role assignments. Role Based Access Control
    # Administrator is the narrowest built-in role that can, and is strictly less privileged
    # than both Owner and User Access Administrator.
    Set-AzureRoleAssignment -PrincipalObjectId $deploymentSp.id `
        -RoleDefinitionId $script:Roles.RoleBasedAccessControlAdministrator -Scope $subscriptionScope `
        -RoleLabel 'Role Based Access Control Administrator'
}
else {
    Write-Step 'Skipping Azure role assignments (-SkipRoleAssignments)'
}

# ---------------------------------------------------------------------------------------------

if (-not $SkipPowerPlatformAdminRole) {
    Write-Step 'Granting the deployment identity the Power Platform Administrator role'

    Set-DirectoryRoleMember -RoleTemplateId $script:PowerPlatformAdministratorRoleTemplateId `
        -PrincipalObjectId $deploymentSp.id -RoleLabel 'Power Platform Administrator'

    # The directory role alone is NOT sufficient. A service principal calling the Business
    # Application Platform admin APIs (/providers/Microsoft.BusinessAppPlatform/scopes/admin/...)
    # is rejected with HTTP 403 "does not have permission to access the path" unless the
    # application is also registered as a Power Platform management application. This is the
    # REST equivalent of New-PowerAppManagementApp.
    # https://learn.microsoft.com/en-us/power-platform/admin/powershell-create-service-principal
    Write-Step 'Registering the deployment app as a Power Platform management application'

    if ($PSCmdlet.ShouldProcess($deploymentApp.appId, 'Register as a Power Platform management application')) {
        try {
            $bapToken = az account get-access-token --resource 'https://service.powerapps.com/' --query accessToken --output tsv 2>$null

            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($bapToken)) {
                throw 'could not acquire a token for https://service.powerapps.com/'
            }

            Invoke-RestMethod -Method PUT `
                -Uri "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/adminApplications/$($deploymentApp.appId)?api-version=2020-10-01" `
                -Headers @{ Authorization = "Bearer $($bapToken.Trim())" } `
                -ContentType 'application/json' | Out-Null

            Write-Host '    registered as a management application' -ForegroundColor Green
        }
        catch {
            Write-Warning "Could not register the management application: $($_.Exception.Message)"
            Write-Warning 'Without this, the deployment identity gets HTTP 403 from the Power Platform admin APIs.'
            Write-Warning 'A Power Platform or Global Administrator can register it with:'
            Write-Warning "    New-PowerAppManagementApp -ApplicationId $($deploymentApp.appId)"
        }
    }
}
else {
    Write-Step 'Skipping the Power Platform Administrator role (-SkipPowerPlatformAdminRole)'
}

# ---------------------------------------------------------------------------------------------

Write-Step 'Done. Configure these as GitHub repository SECRETS (Settings > Secrets and variables > Actions > Secrets)'

# These are tenant-specific identifiers. None of them is a credential, but they are configured as
# SECRETS rather than variables because GitHub masks secrets in run logs and step summaries and
# does NOT mask variables — and this repository is intended to be public.
$secrets = [ordered]@{
    AZURE_CLIENT_ID          = $deploymentApp.appId
    AZURE_TENANT_ID          = $tenantId
    AZURE_SUBSCRIPTION_ID    = $SubscriptionId
    AZURE_API_APP_ID         = $apiApp.appId
    AZURE_API_APP_ID_URI     = "api://$($apiApp.appId)"
    POWER_PLATFORM_APP_ID    = $deploymentApp.appId
    POWER_PLATFORM_TENANT_ID = $tenantId
}

Write-Host ''
foreach ($key in $secrets.Keys) {
    Write-Host ('  {0,-26} {1}' -f $key, $secrets[$key]) -ForegroundColor Green
}

Write-Host ''
Write-Host '  Set them in one command with the GitHub CLI:' -ForegroundColor Cyan
Write-Host ''
foreach ($key in $secrets.Keys) {
    Write-Host "    gh secret set $key --repo $GitHubRepository --body `"$($secrets[$key])`""
}

Write-Host ''
Write-Host '  No client secret was created. Nothing produced by this script is a credential.' -ForegroundColor Yellow
Write-Host ''
Write-Host '  Next: create the Power Platform environment (see docs/deployment.md):' -ForegroundColor Cyan
Write-Host "    ./scripts/New-PowerPlatformEnvironment.ps1 -DisplayName <name> -Location <geography> -DeploymentAppId $($deploymentApp.appId)"
Write-Host ''
Write-Host '  That script creates the environment, enables Managed Environments and adds this'
Write-Host '  identity as a Dataverse application user. Nothing else is done by hand.'

$summary = [ordered]@{
    tenantId                  = $tenantId
    subscriptionId            = $SubscriptionId
    deploymentAppId           = $deploymentApp.appId
    deploymentAppObjectId     = $deploymentApp.id
    deploymentPrincipalId     = $deploymentSp.id
    apiAppId                  = $apiApp.appId
    apiApplicationIdUri       = "api://$($apiApp.appId)"
    apiScopeName              = $ApiScopeName
    apiScopeId                = $scopeId
    connectorAppId            = $script:HttpWithEntraIdConnectorAppId
    connectorPrincipalId      = $connectorSp.id
}

return [pscustomobject] $summary
