# Deployment guide

Complete, ordered instructions. Steps 1–5 happen once; step 6 is repeatable.

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
| Deployment app registration | With **three federated identity credentials** (main branch, pull requests, the `demo` environment). No client secret is created. || API app registration | Exposes `api://<appId>` and the `user_impersonation` scope, with `requestedAccessTokenVersion: 2` |
| Connector service principal | For Microsoft's `7ab7862c-4c57-491e-8a45-d52a7e023983` app, created if it does not exist in your tenant |
| Delegated permission grant | `AllPrincipals` consent so users are not prompted when creating the connection |
| Pre-authorized application | The connector added to the API's `preAuthorizedApplications` |
| Azure role assignments | `Contributor` and `Role Based Access Control Administrator` at subscription scope |
| Power Platform Administrator | The directory role the deployment identity needs to link the enterprise policy. Skip with `-SkipPowerPlatformAdminRole` |
| Power Platform management application | Registers the deployment app via the BAP `adminApplications` API. **The directory role alone is not enough** — without this registration a service principal calling the Power Platform admin APIs is rejected with HTTP 403 "does not have permission to access the path". Equivalent to `New-PowerAppManagementApp` |

Run it with `-WhatIf` first if you want to see exactly what it will do, or `-SkipRoleAssignments` if a different team owns RBAC.

It ends by printing the repository secrets to set, including ready-to-paste `gh secret set` commands.

---

## 3. Create the Power Platform environment (once)

A Power Platform environment is not an ARM resource, so Bicep cannot create it — it lives on
the Business Application Platform control plane. It is still scripted, not clicked:

```powershell
pwsh ./scripts/New-PowerPlatformEnvironment.ps1 `
    -DisplayName     srclass-demo `
    -Location        europe `
    -DeploymentAppId <AZURE_CLIENT_ID printed by step 2>
```

This creates, idempotently:

| Step | Note |
| --- | --- |
| The environment | Sandbox SKU with a Dataverse database. Override with `-EnvironmentSku`, `-CurrencyCode`, `-LanguageCode`, `-DomainName`, `-SecurityGroupId` |
| Managed Environments | `protectionLevel = Standard`. A hard prerequisite of VNet support |
| Dataverse application user | The deployment identity, holding the **System Administrator** security role, so the workflow can import the solution |

**It will not touch an environment it did not create.** If an environment with the same display
name already exists the script reports it and changes nothing; pass `-AdoptExisting` to
deliberately configure a pre-existing environment.

Trial environments and Dataverse for Teams do not support VNet support — use Sandbox,
Production or Developer.

It ends by printing the environment ID and Dataverse URL for reference. You do not need to store
them anywhere: every deployment stage resolves the environment by display name at run time.

---

## 4. Set repository secrets and variables

None of the values below is a credential — they are identifiers, and none grants access on its
own. The tenant-specific ones are nevertheless stored as **secrets**, for one practical reason:
**GitHub masks secrets in run logs and step summaries, and does not mask variables.** This
repository is public, so anything held in a variable is printed in the clear the first time a
deployment succeeds. Only genuinely non-sensitive configuration stays a variable.

The CI `security-invariants` job enforces this split: it allow-lists exactly these identifier
secrets and fails the build on any other `secrets.*` reference, or on any name that looks like
credential material.

### Required secrets

Settings → Secrets and variables → Actions → *Secrets*.

| Secret | Source |
| --- | --- |
| `AZURE_CLIENT_ID` | printed by the bootstrap script |
| `AZURE_TENANT_ID` | printed by the bootstrap script |
| `AZURE_SUBSCRIPTION_ID` | your subscription |
| `AZURE_API_APP_ID` | printed by the bootstrap script |
| `AZURE_API_APP_ID_URI` | printed by the bootstrap script |

### Required secrets for the Power Platform stages

| Secret | Example |
| --- | --- |
| `POWER_PLATFORM_APP_ID` | same value as `AZURE_CLIENT_ID` |
| `POWER_PLATFORM_TENANT_ID` | same value as `AZURE_TENANT_ID` |
| `POWER_PLATFORM_ADMIN_OBJECT_ID` | object id that will link the enterprise policy |

### Optional secrets

| Secret | Purpose |
| --- | --- |
| `POWER_PLATFORM_SECURITY_GROUP_ID` | Restrict environment access to a security group |

There are no connection ID secrets. The pipeline never binds connection references — see
[limitations.md](limitations.md#2-connections-are-created-and-bound-by-a-person-once-per-environment).

You never supply the environment ID or Dataverse URL. Each stage that needs them resolves the
environment by display name with `scripts/Resolve-PowerPlatformEnvironment.ps1`. They are
deliberately not handed between jobs: both are masked, and GitHub redacts any job output whose
value contains a registered secret, so a job output would silently arrive empty and the
consuming step would fail with a confusing error such as `EnvironmentNotFound`.

### Optional variables

Settings → Secrets and variables → Actions → *Variables*. These are not tenant-specific and are
safe to expose in a public run log.

| Variable | Default | Purpose |
| --- | --- | --- |
| `POWER_PLATFORM_REGION` | `europe` | Power Platform geography |
| `POWER_PLATFORM_ENVIRONMENT_NAME` | `srclass-demo` | Display name of the provisioned environment |
| `POWER_PLATFORM_ENVIRONMENT_SKU` | `Sandbox` | Environment SKU |
| `AZURE_LOCATION` | `westeurope` | Location for the subscription-scope deployment metadata |
| `RESOURCE_GROUP_NAME` | `rg-srclass-demo` | Override the resource group name |
| `DEPLOY_ENVIRONMENT` | `demo` | GitHub environment used by the deploy jobs |
| `ENVIRONMENT_LABEL` | `Demo` | Shown in the confirmation email |
| `FUNCTION_DEPLOY_MODE` | `deployment-window` | `private-runner` to never enable public access |
| `FUNCTION_DEPLOY_RUNNER_LABEL` | `ubuntu-latest` | Runner label for `private-runner` mode. **Do not point this at a self-hosted runner while the repository is public** |
| `RUN_CONNECTIVITY_PROBE` | `false` | Set `true` to run the container-based private probe during verification |
| `CREATE_PRIVATE_DNS_ZONES` | `true` | `false` in an ALZ that owns the zones |
| `CREATE_PRIVATE_DNS_ZONE_GROUPS` | `true` | `false` when an ALZ DeployIfNotExists policy owns DNS integration |

---

## 5. Power Platform prerequisites (once)

Managed Environments and the Dataverse application user are handled by
`New-PowerPlatformEnvironment.ps1` in step 3. Nothing below needs doing by hand for a new
environment — this section is only for an environment created outside that script.

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

### Create the connections and turn the flow on

Both connections are created by a person, once per environment. See
[limitations.md](limitations.md#2-connections-are-created-and-bound-by-a-person-once-per-environment)
for why this cannot be automated. Do it after the first deployment: the Function App base URL is a
deployment output.

> **This is not only a first-run step.** Every deployment that imports the solution replaces the
> flow, and the replacement arrives with its connections unbound and the flow switched off. Plan
> to spend a minute in Power Automate after any deployment that changes the Power Platform
> solution. The connections themselves survive — you reselect them, you do not recreate them.
> [What a redeployment resets](#what-a-redeployment-resets) covers this in full.

#### Where to find the two values

**You do not need to go to Azure.** The deployment writes both values into the solution's own
environment variables, in the same environment you are about to work in:

| Environment variable | Display name | Use it for |
| --- | --- | --- |
| `srcls_FunctionBaseUrl` | Function base URL | *Base Resource URL* |
| `srcls_FunctionApplicationIdUri` | Function Application ID URI | *Microsoft Entra ID Resource URI (Application ID URI)* |

Read them in [make.powerapps.com](https://make.powerapps.com) → **Solutions** → **Secure Request
Classifier** → **Environment variables**, or from the CLI:

```powershell
pac env select --environment <environment-url>
pac env list-settings          # or open the solution in the maker portal
```

The **Deploy** workflow's run summary also prints the Function base URL and restates these steps.
The Application ID URI is not printed there: it is a repository secret, so GitHub masks it in run
logs. Take it from the environment variable above.

Other places the same values exist, if you prefer:

| Value | Also found in |
| --- | --- |
| Function base URL | Azure portal → the Function App → **Overview** → *Default domain*; or `az functionapp show --name <app> --resource-group <rg> --query defaultHostName` |
| Application ID URI | Entra admin centre → **App registrations** → *Secure Request Classifier - Function API* → **Expose an API**; or `az ad app list --display-name "Secure Request Classifier - Function API" --query "[0].identifierUris[0]" -o tsv` |

#### The steps

1. Open the **Classify and Notify** flow in Power Automate and select **Edit**.
2. On the **Invoke classification API** action, create a new connection:
   * Connector: **HTTP with Microsoft Entra ID (preauthorized)** — not the v2 connector
   * *Microsoft Entra ID Resource URI (Application ID URI)*: the `srcls_FunctionApplicationIdUri` value, for example `api://44444444-4444-4444-4444-444444444444`
   * *Base Resource URL*: the `srcls_FunctionBaseUrl` value, for example `https://func-srclass-demo-ab12cd.azurewebsites.net`
   * Sign in
3. On the **Send confirmation email** action, create an **Office 365 Outlook** connection.
4. **Save** the flow, then **turn it on**. Both are needed: saving does not enable a flow that
   the import left switched off.

On a redeployment the connections already exist, so steps 2 and 3 are a pick from a list rather
than a sign-in.

> **Create the connections in the flow designer, not ahead of time in Connections.** Adding a
> connection from the designer binds it to the connection reference the solution already ships.
> Creating one first under **Data** → **Connections** and then selecting it can leave you with a
> second, duplicate connection reference for the same connector, which is confusing to unpick
> later.

The first call after a fresh network link can still fail while Power Platform settles — see
[What a redeployment resets](#what-a-redeployment-resets).

---

## 6. Deploy

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
| `RequestDisallowedByPolicy: Subnets ... have a Network Security Group` | `Deny-Subnet-Without-Nsg` is assigned at the `landingzones` management group | Already handled — every subnet ships with an NSG. If you removed them, put them back |
| Private endpoint deploys but DNS does not resolve | An ALZ DeployIfNotExists policy owns DNS integration and your zone group pre-empted it | `CREATE_PRIVATE_DNS_ZONE_GROUPS=false` |
| Creating the private DNS zone is denied | `Audit-PeDnsZones` has been switched from Audit to Deny | `CREATE_PRIVATE_DNS_ZONES=false` and link the hub zones to both VNets |
| Deployment window fails with a policy error | `Deny-Public-Endpoints` | `FUNCTION_DEPLOY_MODE=private-runner` |
| Resource creation denied for missing tags | Required-tags policy | Add them to the `tags` parameter in `demo.bicepparam` |
| Subnets lose default outbound access | `Enforce-Subnet-Private` | Attach a NAT gateway to `snet-powerplatform` |

**Always dry-run before deploying into a governed subscription.** Policy failures surface in
seconds and name the exact policy definition:

```bash
az deployment sub validate \
  --location westeurope \
  --template-file infra/main.bicep \
  --parameters infra/parameters/demo.bicepparam
```

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
| `srcls_FunctionApplicationIdUri` | `AZURE_API_APP_ID_URI` secret |
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

### What a redeployment resets

Importing the solution replaces the flow. The replacement is the flow as it exists in source
control, which has no connections selected and is not switched on, so **after any deployment that
imports the solution you have to go back into Power Automate**, reselect both connections, save,
and turn the flow on. A flow left in that state does not fail loudly — it simply never runs.

What does *not* happen is equally worth knowing:

| | Survives a redeployment? |
| --- | --- |
| The two connections themselves | **Yes.** They belong to the person who made them, and the pipeline has no permission to touch them. You reselect them, you do not recreate them |
| The binding from the flow to those connections | No — reselect it |
| The flow being switched on | No — turn it back on |
| Environment variable values | Yes. They are set from deployment outputs on every import |
| The Power Platform environment and its Dataverse database | Yes |
| The enterprise policy link | Yes. The link job is a no-op when the environment is already linked |

The pipeline deliberately does not bind the connection references, because doing so as the
deployment service principal fails with `ConnectionAuthorizationFailed` and destroys a binding
that was already working. That is covered in
[limitations.md](limitations.md#why-the-pipeline-does-not-bind-them-either).

### The first run after a network change can be slow, then fail once

Enabling or changing subnet injection can leave Power Platform unsettled for up to 30 minutes.
During that window the flow may sit in the connector for a long time and then return a `404` from
`*.azure-apihub.net` — which looks like a broken function but is the connector failing to route.
Wait, then run it again before investigating anything else. The same symptom with its other causes
is in [troubleshooting.md](troubleshooting.md).

### Two operations that are not cheap to repeat

* **Enabling or disabling subnet injection** can cause up to 30 minutes of instability. The link job is a no-op when the environment is already linked.
* **Changing a delegated subnet's range** requires unlinking first, and Microsoft support while it remains delegated.
