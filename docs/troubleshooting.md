# Troubleshooting

Symptom → cause → fix. Ordered roughly by how often each one bites.

---

## The flow fails with 403 Forbidden

### Symptom
`Invoke_classification_API` returns `403`. The connection was created successfully, so it is not a connectivity problem.

### Most likely cause
The delegated permission grant is missing or incomplete. Microsoft's connector documentation is explicit:

> If a scope (permission) has been granted but not all of the required scopes are included, the creation of the connection will succeed but you will encounter a **Forbidden (403)** error at runtime.

### Fix

```powershell
# Confirm the connector service principal exists
az ad sp show --id 7ab7862c-4c57-491e-8a45-d52a7e023983 --query id -o tsv

# Confirm the grant exists against your API
$connector = az ad sp show --id 7ab7862c-4c57-491e-8a45-d52a7e023983 --query id -o tsv
$api = az ad sp show --id <AZURE_API_APP_ID> --query id -o tsv
az rest --method get --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$connector' and resourceId eq '$api'"
```

If it is missing, re-run `./scripts/Initialize-EntraResources.ps1`. It is idempotent.

### Second possible cause
The token's application is not in the Easy Auth allow-list.

```powershell
az resource show --ids "<function-app-id>/config/authsettingsV2" --api-version 2024-04-01 `
  --query "properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications"
```

It must contain `7ab7862c-4c57-491e-8a45-d52a7e023983`.

### Timing note
> Removing or adding preauthorizations can take up to 1 hour to reflect for connections existing prior to the update. However, new connections should reflect the updated authorizations instantly.

If you changed the grant after creating the connection, **delete and recreate the connection** rather than waiting.

---

## The flow fails with 401 Unauthorized

### Cause A — audience mismatch
The token's `aud` claim is not in `allowedAudiences`.

```powershell
az resource show --ids "<function-app-id>/config/authsettingsV2" --api-version 2024-04-01 `
  --query "properties.identityProviders.azureActiveDirectory.validation.allowedAudiences"
```

Should contain both `api://<appId>` and `<appId>`. The connection's *Microsoft Entra ID Resource URI (Application ID URI)* parameter must match one of them exactly.

### Cause B — legacy issuer
If the identity provider was ever configured through the portal's express setup, the issuer may be the legacy `https://sts.windows.net/<tenant>/` endpoint while the connector presents a v2.0 token.

```powershell
az resource show --ids "<function-app-id>/config/authsettingsV2" --api-version 2024-04-01 `
  --query "properties.identityProviders.azureActiveDirectory.registration.openIdIssuer"
# expected: https://login.microsoftonline.com/<tenant-id>/v2.0
```

Redeploy the Bicep to correct it.

---

## The host name resolves to a public IP address from the delegated subnet

### Symptom
The flow times out, or reaches something other than your Function App.

### Cause
The private DNS zone is not linked to the virtual network that the connector container happened to start in. Microsoft's own troubleshooting article uses exactly this failure as its worked example.

### Fix

```powershell
az network private-dns link vnet list `
  -g rg-srclass-demo -z privatelink.azurewebsites.net --query "[].{name:name,vnet:virtualNetwork.id}" -o table
```

There must be one link per virtual network. If the failover network is missing, redeploy the Bicep — `private-dns-zone.bicep` links every network in `linkedVirtualNetworkIds`.

Confirm it from Power Platform's own point of view:

```powershell
Test-DnsResolution -EnvironmentId <env-id> -HostName <app>.azurewebsites.net -Region westeurope
Test-DnsResolution -EnvironmentId <env-id> -HostName <app>.azurewebsites.net -Region northeurope
```

Both must return the private address.

---

## The flow worked, then stopped working days later

### Cause
The Power Platform environment failed over to the other Azure region of its region pair, and something in the failover path is incomplete — usually the DNS zone link or the VNet peering.

### Fix

```powershell
Get-EnvironmentRegion -EnvironmentId <env-id>     # which region is it in now?

az network vnet peering list -g rg-srclass-demo --vnet-name vnet-srclass-demo-failover `
  --query "[].{name:name,state:peeringState}" -o table   # must be Connected

Test-NetworkConnectivity -EnvironmentId <env-id> -Destination <app>.azurewebsites.net -Port 443 -Region <failover-region>
```

This is the failure mode that makes the two-network requirement non-negotiable.

---

## The function deploy step times out

### Symptom
`Azure/functions-action` fails with a connection timeout or `ECONNRESET`.

### Cause
The runner cannot reach the deployment endpoint. Expected when `publicNetworkAccess` is `Disabled` and the runner has no network path — Microsoft documents this directly.

### Fix
Check which mode ran:

```
Mode: deployment-window
```
in the job summary.

* **`deployment-window`** — the window step may have failed, or an Azure Policy such as ALZ `Deny-Public-Endpoints` blocked enabling public access. Check the *Open deployment window* step's log.
* **`private-runner`** — the runner is not actually on a connected network. Verify from the runner:

  ```bash
  nslookup <app>.scm.azurewebsites.net    # must return a private address
  curl -v https://<app>.scm.azurewebsites.net
  ```

If policy blocks the window, `private-runner` is the only option.

---

## The function app is left with public access enabled

### Symptom
Verification fails with `publicNetworkAccess = 'Enabled'`.

### Cause
The deploy job was cancelled between opening and closing the window. The close step uses `if: always()`, which covers failure but not a forced cancellation.

### Fix

```powershell
pwsh ./scripts/Set-FunctionAppDeploymentWindow.ps1 `
    -Action Close -ResourceGroupName rg-srclass-demo -FunctionAppName <app> -Confirm:$false
```

The script verifies the final state and throws if it is not `Disabled`.

---

## `Enable-SubnetInjection` cannot read the policy

### Symptom
`The specified policy is not a Subnet Injection policy`, or an authorisation error reading the enterprise policy.

### Cause A — no Reader on the policy
Microsoft requires the linking administrator to hold **Reader** on the enterprise policy resource.

```powershell
az role assignment create --assignee-object-id <oid> --assignee-principal-type ServicePrincipal `
    --role Reader --scope <enterprise-policy-resource-id>
```

Better: set `POWER_PLATFORM_ADMIN_OBJECT_ID` and redeploy, so Bicep grants it.

### Cause B — not a Power Platform Administrator
The identity needs the Power Platform Administrator directory role.

```powershell
Test-AccountPermissions
```

### Cause C — the policy has no `systemId` yet
It is still provisioning. Wait a minute and retry.

```powershell
az resource show --ids <policy-id> --api-version 2020-10-30-preview --query properties.systemId -o tsv
```

---

## Solution import fails on connection references

### Symptom
`The connection reference ... could not be resolved`, or the flow imports but cannot be turned on.

### Cause
The deployment settings file had no `ConnectionId` for one or both connection references. The workflow passes `-AllowMissingConnections`, so the import succeeds but leaves them unbound.

### Fix

```powershell
pac connection list --environment <environment-url>
gh secret set POWER_PLATFORM_CONNECTION_ID_WEBCONTENTS --body <guid>
gh secret set POWER_PLATFORM_CONNECTION_ID_OFFICE365   --body <guid>
```

Then re-run the Deploy workflow. See [limitations.md](limitations.md#2-the-connector-connection-must-be-created-once-by-a-person).

---

## `pac solution pack` prints "root components are not defined in customizations"

### This is benign.

SolutionPackager does not index connection references or environment variable definitions when it
matches root components, so it reports them as missing even when they are correctly declared. A
solution folder produced by `pac solution unpack` — the canonical layout — prints the same
warning. Verify the package instead:

```powershell
./scripts/Build-Solution.ps1
./scripts/Test-SolutionPackage.ps1
```

You should see exactly four entries — `solution.xml`, `customizations.xml`, `[Content_Types].xml`
and `Workflows/<flow>.json` — and nothing else.

---

## The solution import fails with "An unexpected error occurred"

### `pac solution import` reports every asynchronous failure with that one sentence.

The real reason is recorded in Dataverse, and the Deploy workflow prints it automatically from
`scripts/Get-SolutionImportFailure.ps1`. Two causes have bitten this repository.

#### `XmlNode.AppendChild ... the specified node is the wrong type`

```
System.InvalidOperationException: The specified node cannot be inserted as the valid child of this
node, because the specified node is the wrong type.
   at System.Xml.XmlNode.AppendChild(XmlNode newChild)
   at Microsoft.Crm.Tools.ImportExportPublish.SourceControlHandler.ImportEntityFromFile(...)
```

A component folder — for example `environmentvariabledefinitions/<schemaname>/` — was copied into
the zip verbatim instead of being folded into `customizations.xml`. `pac solution pack` does that
silently and still exits 0; Dataverse then reads the loose files with its source-control handler
and crashes.

Keep those components inline in `powerplatform/solution/src/Other/Customizations.xml`, which is
what `pac solution unpack` produces for this solution.

#### `Cannot add a Root Component ... because it is not in the target system`

```
Cannot add a Root Component srcls_5Fsharedwebcontents_5Fclassifier of type 372 because it is not
in the target system.
   at Microsoft.Crm.Tools.ImportExportPublish.ImportRootComponentsHandler.GetSolutionRootsCollection(...)
```

A connection reference or an environment variable definition was listed in `<RootComponents>`.
They must not be — `customizations.xml` alone carries them.

Component type **372 is "Connector"**, meaning a *custom connector*, not a connection reference.
The `componenttype` choice has no value for a connection reference at all, which is why the
exporter writes `type="connectionreference"` as a string in `MissingDependencies` rather than a
number. Microsoft's own [CoE Audit Logs solution](https://github.com/microsoft/coe-starter-kit/blob/main/CenterofExcellenceAuditLogs/SolutionPackage/src/Other/Solution.xml)
declares five connection references in `Customizations.xml` and has exactly two root components,
both type 29.

The `_5F` spelling seen in real solutions, such as `cat_5Fcustomazuredevops`, is part of a custom
connector's actual stored name, where `_` is hex-escaped as `5F`. It is not a serialisation escape
and it does not apply to connection references.

Both invariants are enforced by `scripts/Test-SolutionPackage.ps1`, which runs in CI and in the
Deploy workflow ahead of the import.

---

## The canvas app is missing from the solution

### Expected on a clean clone.
`pac canvas pack` cannot build an `.msapp` from YAML that has not been through Power Apps Studio. `Build-Solution.ps1` reports this and continues.

The flow still deploys. Run it from Power Automate — the PowerApps (V2) trigger renders an input form — and the whole private-network path is exercised.

To add the app permanently, follow [limitations.md](limitations.md#1-the-canvas-app-msapp-cannot-be-built-from-source-in-ci).

---

## GitHub OIDC token exchange fails

### Symptom
`AADSTS70021: No matching federated identity record found`.

### Cause A — subject mismatch
Read the actual subject from the failed run and compare:

```powershell
az ad app federated-credential list --id <AZURE_CLIENT_ID> --query "[].{name:name,subject:subject}" -o table
```

Common mismatches: the workflow runs on a branch other than `main`; the job specifies a GitHub `environment` that has no matching credential; the trigger is a pull request but only a branch credential exists.

### Cause B — immutable subject claims
GitHub issues subjects containing immutable numeric IDs, for example
`repo:octo-org@123456/octo-repo@456789:ref:refs/heads/main`, rather than the name-based
`repo:octo-org/octo-repo:ref:refs/heads/main`. This is on by default and cannot currently be
turned off: a `PUT` to `/repos/{owner}/{repo}/actions/oidc/customization/sub` setting
`use_immutable_subject` to `false` is accepted and then ignored.

`scripts/Initialize-EntraResources.ps1` handles this automatically — it reads the prefix GitHub
will actually issue and builds the federated credentials from it:

```powershell
gh api repos/<owner>/<repo>/actions/oidc/customization/sub
```

If the bootstrap ran without the GitHub CLI available, it falls back to the name-based form and
warns. Re-run it with `gh` installed and authenticated, and it will correct the existing
credentials in place. Note that **recreating a repository with the same name changes its numeric
ID**, which invalidates existing credentials — re-run the bootstrap after doing so.

### Cause C — missing permission
The workflow (or job) must declare:

```yaml
permissions:
  id-token: write
  contents: read
```

---

## `pac` authentication fails in CI

### Symptom
`Too many authentication parameters specified`, or an interactive prompt.

### Cause
Federation is selected **implicitly** by supplying `app-id` and `tenant-id` and omitting `client-secret`. Supplying a secret as well is ambiguous.

### Fix
Remove any `client-secret` input. Ensure `id-token: write` is granted. Ensure `microsoft/powerplatform-actions/actions-install@v1` runs before any other Power Platform action.

---

## Storage or telemetry errors in the Function logs

### Symptom
`AuthorizationPermissionMismatch`, or telemetry never appears.

### Cause A — RBAC has not propagated
Role assignments can take several minutes. Restart the app and retry.

### Cause B — assignments missing

```powershell
$principal = az functionapp show -g rg-srclass-demo -n <app> --query identity.principalId -o tsv
az role assignment list --assignee $principal --all -o table
```

Expect Storage Blob Data Owner, Storage Queue Data Contributor, Storage Table Data Contributor and Monitoring Metrics Publisher.

### Cause C — the app cannot reach storage privately

```powershell
az network private-endpoint list -g rg-srclass-demo `
  --query "[].{name:name,group:privateLinkServiceConnections[0].groupIds[0]}" -o table
```

Expect `blob`, `queue` and `table`. Also confirm the Function App has `virtualNetworkSubnetId` set to `snet-functions`.

---

## Diagnostics from Power Platform's own point of view

These run *inside* the delegated subnet and are the most direct evidence available. They need the Power Platform Administrator role.

```powershell
Install-Module Microsoft.PowerPlatform.EnterprisePolicies -Scope CurrentUser

Test-AccountPermissions
Get-EnvironmentRegion        -EnvironmentId <env-id>
Get-EnvironmentUsage         -EnvironmentId <env-id>
Test-DnsResolution           -EnvironmentId <env-id> -HostName <app>.azurewebsites.net -Region <region>
Test-NetworkConnectivity     -EnvironmentId <env-id> -Destination <app>.azurewebsites.net -Port 443 -Region <region>
Test-TLSHandshake            -EnvironmentId <env-id> -Destination <app>.azurewebsites.net -Port 443 -Region <region>
```

Run the region-scoped ones against **both** regions of your region pair.

Note: `Test-NetworkConnectivity` only proves a TCP connection can be established — it says nothing about application-level success.

---

## Everything looks right but nothing works

Work down this list:

1. Is the environment actually a **Managed Environment**?
   `pac admin list --environment <id>`
2. Is it actually **linked** to the enterprise policy?
   `pwsh ./scripts/Test-Deployment.ps1 -ResourceGroupName rg-srclass-demo -PowerPlatformEnvironmentId <id>`
3. Was linking done **less than 30 minutes ago**? Microsoft documents up to 30 minutes of instability after enabling subnet delegation.
4. Is the environment type supported? Trial and Dataverse for Teams are not.
5. Is the flow using the **HTTP with Microsoft Entra ID (preauthorized)** connector and the **Invoke an HTTP request** action? The plain HTTP action is not VNet-routed, and `Get web resource` is unsupported under VNet.
