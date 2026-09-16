# Deployment guide

Complete, ordered instructions. Steps 1–4 happen once; step 5 is repeatable.

---

## 0. What you need before you start

| Requirement | Why |
| --- | --- |
| Azure subscription, with rights to create app registrations and role assignments | The bootstrap script creates two app registrations and two role assignments |
| A Power Platform environment of type Production, Sandbox, Developer or Default | Trial and Dataverse for Teams do not support VNet support |
| Power Platform Administrator or Dynamics 365 Administrator | Required to enable Managed Environments and link the enterprise policy |
| An Azure subscription associated with the Power Platform tenant | A documented prerequisite of VNet support |
| Azure CLI 2.60+, PowerShell 7, Power Platform CLI 2.7+ | Only for the one-time bootstrap |

Confirm your environment's Power Platform geography — everything else derives from it:

```powershell
Install-Module Microsoft.PowerPlatform.EnterprisePolicies -Scope CurrentUser
Get-EnvironmentRegion -EnvironmentId <environment-id>
```

---

## 1. Fork the repository

```bash
gh repo fork <upstream>/secure-request-classifier --clone
cd secure-request-classifier
```

---

## 2. Bootstrap Microsoft Entra ID (once)

```powershell
az login
az account set --subscription <subscription-id>

pwsh ./scripts/Initialize-EntraResources.ps1 `
    -GitHubRepository <owner>/<repo> `
    -SubscriptionId   <subscription-id> `
    -Environments     demo
```

This creates, idempotently:

| Resource | Note |
| --- | --- |
| Deployment app registration | With **three federated identity credentials** (main branch, pull requests, the `demo` environment). No client secret is created. |
| API app registration | Exposes `api://<appId>` and the `user_impersonation` scope, with `requestedAccessTokenVersion: 2` |
| Connector service principal | For Microsoft's `d2ebd3a9-1ada-4480-8b2d-eac162716601` app, created if it does not exist in your tenant |
| Delegated permission grant | `AllPrincipals` consent so users are not prompted when creating the connection |
| Pre-authorized application | The connector added to the API's `preAuthorizedApplications` |
| Azure role assignments | `Contributor` and `Role Based Access Control Administrator` at subscription scope |

Run it with `-WhatIf` first if you want to see exactly what it will do, or `-SkipRoleAssignments` if a different team owns RBAC.

It ends by printing the repository variables to set, including ready-to-paste `gh variable set` commands.

---

## 3. Set repository variables

Everything is a **variable**, not a secret. Settings → Secrets and variables → Actions → *Variables*.

### Required

| Variable | Source |
| --- | --- |
| `AZURE_CLIENT_ID` | printed by the bootstrap script |
| `AZURE_TENANT_ID` | printed by the bootstrap script |
| `AZURE_SUBSCRIPTION_ID` | your subscription |
| `AZURE_API_APP_ID` | printed by the bootstrap script |
| `AZURE_API_APP_ID_URI` | printed by the bootstrap script |

### Required for the Power Platform stages

| Variable | Example |
| --- | --- |
| `POWER_PLATFORM_APP_ID` | same value as `AZURE_CLIENT_ID` |
| `POWER_PLATFORM_TENANT_ID` | same value as `AZURE_TENANT_ID` |
| `POWER_PLATFORM_ENVIRONMENT_URL` | `https://contoso.crm4.dynamics.com` |
| `POWER_PLATFORM_ENVIRONMENT_ID` | `55555555-5555-5555-5555-555555555555` |
| `POWER_PLATFORM_REGION` | `europe` |
| `POWER_PLATFORM_ADMIN_OBJECT_ID` | object id that will link the enterprise policy |

### Optional

| Variable | Default | Purpose |
| --- | --- | --- |
| `AZURE_LOCATION` | `westeurope` | Location for the subscription-scope deployment metadata |
| `RESOURCE_GROUP_NAME` | `rg-srclass-demo` | Override the resource group name |
| `DEPLOY_ENVIRONMENT` | `demo` | GitHub environment used by the deploy jobs |
| `ENVIRONMENT_LABEL` | `Demo` | Shown in the confirmation email |
| `FUNCTION_DEPLOY_MODE` | `deployment-window` | `private-runner` to never enable public access |
| `FUNCTION_DEPLOY_RUNNER_LABEL` | `ubuntu-latest` | Runner label for `private-runner` mode |
| `POWER_PLATFORM_CONNECTION_ID_WEBCONTENTS` | — | Connection ID for the connector (see step 4) |
| `POWER_PLATFORM_CONNECTION_ID_OFFICE365` | — | Connection ID for Office 365 Outlook |
| `RUN_CONNECTIVITY_PROBE` | `false` | Set `true` to run the container-based private probe during verification |
| `CREATE_PRIVATE_DNS_ZONES` | `true` | `false` in an ALZ that owns the zones |
| `CREATE_PRIVATE_DNS_ZONE_GROUPS` | `true` | `false` when an ALZ DeployIfNotExists policy owns DNS integration |

---

## 4. Power Platform prerequisites (once)

```powershell
pac auth create --deviceCode

# Managed Environments is a hard prerequisite of VNet support
pac admin set-governance-config --environment <environment-id> --protection-level Standard

# Let the deployment identity import solutions
pac admin assign-user `
    --environment <environment-id> `
    --user <AZURE_CLIENT_ID> `
    --role "System administrator" `
    --application-user
```

Then, in the Microsoft Entra admin center, assign the deployment app registration the **Power Platform Administrator** role. It needs this to link the enterprise policy.

### Create the connections

The HTTP with Microsoft Entra ID connection must be created by a person once — see [limitations.md](limitations.md#2-the-connector-connection-must-be-created-once-by-a-person). You can do this before or after the first deployment; the Function App base URL is a deployment output, so after is usually easier.

Once both connections exist:

```powershell
pac connection list --environment <environment-url>

gh variable set POWER_PLATFORM_CONNECTION_ID_WEBCONTENTS --body <guid>
gh variable set POWER_PLATFORM_CONNECTION_ID_OFFICE365   --body <guid>
```

Then re-run the Deploy workflow so the solution import binds them.

---

## 5. Deploy

Actions → **Deploy** → *Run workflow*.

```
validate ──┬─ build-function ─┐
           └─ infrastructure ─┼─ deploy-function ─┐
                              ├─ link-enterprise-policy
                              └─ power-platform ──┴─ verify
```

| Job | Does |
| --- | --- |
| `validate` | `dotnet build` + `dotnet test`, Bicep compile, Power Platform solution pack |
| `build-function` | `dotnet publish` and upload as `released-package` |
| `infrastructure` | Registers resource providers, runs `az deployment sub create`, exports outputs |
| `deploy-function` | Deploys the package, then asserts the app ends sealed |
| `link-enterprise-policy` | Links the environment to the network-injection policy |
| `power-platform` | Renders deployment settings and imports the solution over OIDC |
| `verify` | Runs the full assertion suite; optionally the connectivity probe |

Each job writes to the run summary, so the whole deployment is auditable from the Actions UI.

### Choosing the function deployment mode

| Mode | Public access | Needs | Use when |
| --- | --- | --- | --- |
| `private-runner` | **never enabled** | a self-hosted runner in (or peered to) the VNet, or a GitHub-hosted larger runner with Azure private networking | production, and any ALZ with `Deny-Public-Endpoints` |
| `deployment-window` | briefly enabled, restricted to one `/32`, re-sealed with `if: always()` | nothing | a fork, a lab, a demo subscription |

The reasoning and the Microsoft citation are in [limitations.md](limitations.md#4-deploying-code-to-a-private-function-app-needs-a-network-connected-runner).

---

## Azure Landing Zone coexistence

| Symptom | Cause | Fix |
| --- | --- | --- |
| Private endpoint deploys but DNS does not resolve | An ALZ DeployIfNotExists policy owns DNS integration and your zone group pre-empted it | `CREATE_PRIVATE_DNS_ZONE_GROUPS=false` |
| Creating the private DNS zone is denied | `Audit-PeDnsZones` has been switched from Audit to Deny | `CREATE_PRIVATE_DNS_ZONES=false` and link the hub zones to both VNets |
| Deployment window fails with a policy error | `Deny-Public-Endpoints` | `FUNCTION_DEPLOY_MODE=private-runner` |
| Resource creation denied for missing tags | Required-tags policy | Add them to the `tags` parameter in `demo.bicepparam` |
| Subnets lose default outbound access | `Enforce-Subnet-Private` | Attach a NAT gateway to `snet-powerplatform` |

Microsoft's guidance when a DeployIfNotExists policy manages private DNS: *"You can still create private endpoints in your infrastructure as code tooling. But if you use the DeployIfNotExists policy approach in this article, you shouldn't integrate DNS in your code."* ([Private Link and DNS integration at scale](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/private-link-and-dns-integration-at-scale))

---

## Configuration reference

### Bicep parameters (`infra/parameters/demo.bicepparam`)

| Parameter | Default | Notes |
| --- | --- | --- |
| `workloadName` | `srclass` | 3–12 characters; drives every resource name |
| `environmentName` | `demo` | 2–8 characters |
| `resourceGroupName` | `rg-srclass-demo` | |
| `powerPlatformRegion` | `europe` | Power Platform **geography**, not an Azure region |
| `primaryLocation` / `failoverLocation` | derived | Override only if you must |
| `primaryVnetAddressPrefix` | `10.60.0.0/16` | |
| `primaryPowerPlatformSubnetPrefix` | `10.60.0.0/24` | Immutable after delegation |
| `functionSubnetPrefix` | `10.60.1.0/26` | Minimum `/27` |
| `privateEndpointSubnetPrefix` | `10.60.2.0/27` | |
| `failoverVnetAddressPrefix` | `10.61.0.0/16` | |
| `failoverPowerPlatformSubnetPrefix` | `10.61.0.0/24` | Must have the same usable count as the primary |
| `functionAppPublicNetworkAccess` | `Disabled` | Keep it |
| `storagePublicNetworkAccess` | `Disabled` | |
| `createPrivateDnsZones` | `true` | |
| `createPrivateDnsZoneGroups` | `true` | |
| `deployEnterprisePolicy` | `true` | |
| `apiApplicationId` | `''` | Supplied from `AZURE_API_APP_ID` |
| `httpWithEntraIdConnectorAppId` | `d2ebd3a9-…` | Microsoft's connector app |
| `businessDayStartUtcHour` / `businessDayEndUtcHour` | `9` / `17` | SLA calculation window |
| `tags` | cost centre, classification | Merged with the built-in workload tags |

### Function App settings

| Setting | Value | Purpose |
| --- | --- | --- |
| `AzureWebJobsStorage__accountName` | storage name | Identity-based host storage |
| `AzureWebJobsStorage__credential` | `managedidentity` | |
| `APPLICATIONINSIGHTS_AUTHENTICATION_STRING` | `Authorization=AAD` | Managed-identity telemetry |
| `Classifier__BusinessDayStartUtcHour` | `9` | |
| `Classifier__BusinessDayEndUtcHour` | `17` | |
| `Classifier__AllowedClientAppIds` | connector app id | Defence-in-depth allow-list |

### Power Platform environment variables

| Schema name | Set from |
| --- | --- |
| `srcls_FunctionBaseUrl` | `functionAppBaseUrl` Bicep output |
| `srcls_FunctionClassifyPath` | constant `/api/requests/classify` |
| `srcls_FunctionApplicationIdUri` | `AZURE_API_APP_ID_URI` variable |
| `srcls_EnvironmentLabel` | `ENVIRONMENT_LABEL` variable |

### The output-to-input contract

| Bicep output | Consumed by |
| --- | --- |
| `resourceGroupName` | every downstream job, verification, cleanup |
| `functionAppName` | `deploy-function`, deployment window script |
| `functionAppBaseUrl` | `srcls_FunctionBaseUrl` environment variable |
| `enterprisePolicyResourceId` | `link-enterprise-policy` job |
| `enterprisePolicySystemId` | the link REST fallback |
| `primaryLocation` / `failoverLocation` | run summary |
| `functionClassifyUrl` / `functionHealthUrl` | documentation and manual probes |

---

## Redeploying

Re-running the Deploy workflow is safe and idempotent. Bicep converges the infrastructure, the function package is replaced, and the solution import uses `force-overwrite`.

Two operations that are *not* cheap to repeat:

* **Enabling or disabling subnet injection** can cause up to 30 minutes of instability. The link job is a no-op when the environment is already linked.
* **Changing a delegated subnet's range** requires unlinking first, and Microsoft support while it remains delegated.
