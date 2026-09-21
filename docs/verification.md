# Verification

What is checked automatically, and how to check each thing by hand.

---

## Automated

### Full assertion suite

```powershell
pwsh ./scripts/Test-Deployment.ps1 `
    -ResourceGroupName           rg-srclass-demo `
    -PowerPlatformEnvironmentId  <environment-id> `
    -PowerPlatformEnvironmentUrl https://contoso.crm4.dynamics.com
```

Read-only. Prints a pass/fail line per check, writes a table to `$GITHUB_STEP_SUMMARY` in CI, and exits non-zero on any failure. Add `-FailOnWarning` to treat warnings as failures.

| # | Check | Requirement it protects |
| --- | --- | --- |
| 1 | Resource group exists | Deployment succeeded |
| 2 | Function App exists and is running | |
| 3 | `publicNetworkAccess` is `Disabled` | **Public access is disabled** |
| 4 | SCM basic auth disabled | No publishing password |
| 5 | FTP basic auth disabled | No publishing password |
| 6 | System-assigned managed identity present | Managed identities are configured |
| 7 | Easy Auth enabled and requires authentication | Microsoft Entra ID authentication |
| 8 | Function code deployed | Function application is deployed |
| 9 | Public endpoint unreachable from the internet | **Public access is disabled** (behavioural, not just declarative) |
| 10–13 | Every private endpoint is `Approved` | **Private endpoint exists and is approved** |
| 14 | A `sites` private endpoint fronts the Function App | |
| 15 | Workload-owned private DNS zones exist | **Expected DNS configuration exists** |
| 16 | A records exist for the app | |
| 17 | An `scm` record exists | |
| 18–21 | Each zone linked to *every* virtual network | Survives a Power Platform regional failover |
| 22 | Storage account exists | |
| 23 | `allowSharedKeyAccess` is `false` | No storage keys, no SAS |
| 24 | Storage `publicNetworkAccess` is `Disabled` | |
| 25–28 | The four expected data-plane roles are assigned | **Required RBAC assignments exist** |
| 29 | The Function identity holds no broad role | Least privilege |
| 30 | Virtual networks exist | |
| 31–32 | `snet-powerplatform` delegated correctly in each network | **Power Platform VNet configuration** |
| 33 | `snet-functions` delegated to `Microsoft.App/environments` | |
| 34 | Delegated subnets exist in both regions | Failover correctness |
| 35 | Peering state is `Connected` | |
| 36 | Application Insights local auth disabled | No instrumentation key as a credential |
| 37 | Enterprise policy exists with `kind: NetworkInjection` | |
| 38 | Policy references both regional networks | |
| 39 | Environment is linked to the policy | **Power Platform VNet configuration** |
| 40 | Power Platform solution imported | **Solution is imported** |

### Live connectivity probe

```powershell
pwsh ./scripts/Invoke-PrivateConnectivityProbe.ps1 -ResourceGroupName rg-srclass-demo
```

Two probes with opposite expected outcomes:

* **From the public internet** → must fail to connect or be rejected before reaching the app.
* **From inside the virtual network** → a container instance placed in the demo's own network resolves the host name (printing the private address it got) and calls `/api/health` successfully.

The container is created and deleted by the script, inside the demo resource group. Use `-KeepProbe` to leave it running while troubleshooting.

This is the most convincing single artefact in the whole demo: the same URL, two network positions, two different outcomes.

### CI security invariants

`.github/workflows/ci.yml` → `security-invariants` fails the build on:

* any `${{ secrets.* }}` reference other than `GITHUB_TOKEN`;
* `allowSharedKeyAccess: true` anywhere in `infra/`;
* a `clientSecretSettingName:` assignment;
* `demo.bicepparam` no longer shipping `publicNetworkAccess = 'Disabled'`;
* `storage.bicep` no longer setting `allowSharedKeyAccess: false`;
* a credential-shaped literal in any source file;
* an `AuthorizationLevel` other than `Anonymous`.

### Unit tests

```bash
dotnet test
```

98 tests across seven fixtures:

| Fixture | Covers |
| --- | --- |
| `RequestClassifierPriorityTests` | All 12 category × impact combinations, team assignment, status, reason text, correlation echo |
| `BusinessHoursTests` | Same-day, next-day, weekend-skipping, out-of-hours arrival, configurable window, UTC normalisation |
| `NormalizationTests` | Case-insensitive matching, unknown-category fallback with note, whitespace collapsing |
| `RequestValidatorTests` | Every field, boundary lengths, email shapes, closed enumerations, multi-error aggregation |
| `CallerIdentityReaderTests` | Easy Auth principal parsing, v1 and v2 claim shapes, malformed headers degrading to anonymous |
| `ClassifyRequestFunctionTests` | HTTP status codes, `application/problem+json` shape, correlation handling, the caller allow-list |
| `HealthFunctionTests` | Authenticated and unauthenticated probes, reported runtime and version |

The "no Function keys" claim is not left to a unit test. The `security-invariants` job in CI greps
the source for `AuthorizationLevel.Function`, `.Admin` and `.System` and fails the build if any
appears, so the guarantee is checked against the whole tree rather than against whichever triggers
somebody remembered to write a test for.

### The Functions host must actually start

```bash
pwsh ./scripts/Test-FunctionHostStartup.ps1
```

Building and unit-testing prove the code compiles and behaves. They do not prove the Functions
host can start the isolated worker, which is a separate process that loads the published assemblies
alongside the host's own. When those disagree the worker aborts, the host indexes nothing, and every
route answers 404 — while the build, the tests and the deployment all stay green.

This starts the real host against the published output and asserts that every function declared in
the source is registered. It discovers the expected names from the `[Function]` attributes, so a new
function is covered without anyone remembering to add it, and it ignores the host's built-in
`WarmUp` function, which is present even when the worker is dead and would otherwise read as
success. It runs in CI on every pull request.

### Documentation links must resolve

```bash
pwsh ./scripts/Test-DocumentationLinks.ps1
```

Checks every relative link and anchor across the markdown files. A reworded heading breaks links to
its anchor without breaking anything visible: the link still renders and still navigates, it just
lands at the top of the page. External links are not fetched, so this works offline.

---

## Manual checks

### Public access is disabled

```bash
az functionapp show -g rg-srclass-demo -n <app> --query publicNetworkAccess -o tsv
# Disabled

curl -i --max-time 20 https://<app>.azurewebsites.net/api/health
# connection failure, or 403 before reaching the app
```

### Private endpoint

```bash
az network private-endpoint list -g rg-srclass-demo \
  --query "[].{name:name, group:privateLinkServiceConnections[0].groupIds[0], state:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status}" \
  -o table
```

All four should read `Approved`. There is no separate `scm` sub-resource — the `sites` endpoint covers both hosts.

### DNS

```bash
az network private-dns record-set a list -g rg-srclass-demo -z privatelink.azurewebsites.net -o table
az network private-dns link vnet list -g rg-srclass-demo -z privatelink.azurewebsites.net --query "[].name" -o tsv
```

Expect two A records (app and `scm`) and one link per virtual network.

### Subnet delegation

```bash
for vnet in vnet-srclass-demo-primary vnet-srclass-demo-failover; do
  echo "$vnet:"
  az network vnet subnet show -g rg-srclass-demo --vnet-name "$vnet" -n snet-powerplatform \
    --query "delegations[].serviceName" -o tsv
done
# Microsoft.PowerPlatform/enterprisePolicies   (twice)

az network vnet subnet show -g rg-srclass-demo --vnet-name vnet-srclass-demo-primary -n snet-functions \
  --query "delegations[].serviceName" -o tsv
# Microsoft.App/environments
```

### Managed identity and RBAC

```bash
principal=$(az functionapp show -g rg-srclass-demo -n <app> --query identity.principalId -o tsv)
az role assignment list --assignee "$principal" --all \
  --query "[].{role:roleDefinitionName, scope:scope}" -o table
```

Expect exactly four data-plane roles and nothing broader.

### No keys anywhere

```bash
az storage account show -g rg-srclass-demo -n <storage> --query allowSharedKeyAccess -o tsv
# false

az resource show --ids "<function-app-id>/basicPublishingCredentialsPolicies/scm" \
  --api-version 2024-04-01 --query properties.allow -o tsv
# false

az resource show --ids "<app-insights-id>" --query properties.DisableLocalAuth -o tsv
# true
```

### Enterprise policy and its link

```bash
az resource list -g rg-srclass-demo --resource-type Microsoft.PowerPlatform/enterprisePolicies -o table

policy=$(az resource list -g rg-srclass-demo --resource-type Microsoft.PowerPlatform/enterprisePolicies --query "[0].id" -o tsv)
az resource show --ids "$policy" --api-version 2020-10-30-preview \
  --query "{kind:kind, systemId:properties.systemId, networks:properties.networkInjection.virtualNetworks[].id}"
```

Then from Power Platform's side:

```bash
token=$(az account get-access-token --resource https://service.powerapps.com/ --query accessToken -o tsv)
curl -s -H "Authorization: Bearer $token" \
  "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/<env-id>?api-version=2016-11-01" \
  | jq '.properties.enterprisePolicies'
```

### From inside the delegated subnet

The most direct evidence available. Needs the Power Platform Administrator role.

```powershell
Install-Module Microsoft.PowerPlatform.EnterprisePolicies -Scope CurrentUser

Test-AccountPermissions
Get-EnvironmentRegion    -EnvironmentId <env-id>
Get-EnvironmentUsage     -EnvironmentId <env-id>

foreach ($region in 'westeurope', 'northeurope') {
    Test-DnsResolution       -EnvironmentId <env-id> -HostName '<app>.azurewebsites.net' -Region $region
    Test-NetworkConnectivity -EnvironmentId <env-id> -Destination '<app>.azurewebsites.net' -Port 443 -Region $region
    Test-TLSHandshake        -EnvironmentId <env-id> -Destination '<app>.azurewebsites.net' -Port 443 -Region $region
}
```

Run these against **both** regions. `Test-DnsResolution` returning a public address in either region is the classic missing-DNS-link failure.

Note: `Test-NetworkConnectivity` proves only that a TCP connection can be established.

### The Power Platform solution

```bash
pac solution list --environment https://contoso.crm4.dynamics.com
```

Expect `SecureRequestClassifier`. Then in Power Automate, confirm **Classify and Notify** exists, both connection references resolve, and the run history shows successful runs.

---

## What a healthy end-to-end run looks like

1. `Test-Deployment.ps1` → `Failed: 0`.
2. `Invoke-PrivateConnectivityProbe.ps1` → public blocked, private reachable, host resolves to `10.x.x.x`.
3. Submitting the form in the app returns a request ID within a few seconds.
4. The flow run shows all six actions succeeded.
5. The confirmation email arrives.
6. Application Insights shows the request, with the correlation ID matching the flow run.

```kusto
traces
| where timestamp > ago(1h)
| where customDimensions.CorrelationId == "<correlation-id>"
| project timestamp, message, customDimensions.CallerAppId, customDimensions.CallerObjectId
| order by timestamp asc
```

`CallerAppId` should be `7ab7862c-4c57-491e-8a45-d52a7e023983` — the connector — and `CallerObjectId` the object ID of the human who submitted the form.
