# Limitations

This document lists everything in the demo that **cannot** currently be automated end to end with supported Microsoft tooling, why, the authoritative source for that conclusion, and the smallest manual action that works around it.

Nothing here is papered over with a secret, and nothing here blocks the security demonstration itself.

---

## 1. The canvas app `.msapp` cannot be built from source in CI

### What cannot be automated

Producing the binary `.msapp` for the Power App from the committed Power Fx YAML source, inside a GitHub Actions job, with no prior human interaction.

### Why

Two independent blocks.

**`pac canvas pack` is deprecated.** From the [Power Platform CLI canvas command reference](https://learn.microsoft.com/en-us/power-platform/developer/cli/reference/canvas):

> - The `pack` and `unpack` commands are deprecated.
> - To source control your canvas app, use the Power Platform Git Integration.
> - The `create` command is generally available.

**The `SourceCode` packer refuses un-validated sources.** Running it against hand-authored YAML produces, verbatim:

```
Canvas apps packed using yaml SourceCode must be validated first by opening the app for edit
within the Power Apps studio. For more information see https://aka.ms/paccanvas
```

This is a deliberate gate in `bolt.module.canvas.SourceCodeCanvasPacker.ValidateSources`, not a transient bug. The app must round-trip through Power Apps Studio at least once.

Microsoft's own supported source-control path for canvas apps is [Power Platform Git integration](https://learn.microsoft.com/en-us/power-platform/alm/git-integration/canvas-apps-git-integration), which produces `.pa.yaml` from Dataverse — it does not build an `.msapp` from arbitrary YAML.

### What this repository does instead

* The app's Power Fx source is committed at `powerplatform/canvas-app/src/RequestScreen.pa.yaml`. It is fully readable, reviewable and diffable — the requirement that the app be source controlled is met.
* `scripts/Build-Solution.ps1` attempts `pac canvas pack` on every build. If it succeeds (because a validated `.msapp` or validated sources are present), the app is included.
* If it fails, the script prints the exact one-time action and **packs the solution without the canvas app**. The cloud flow, connection references and environment variables all still deploy.
* The cloud flow uses a **PowerApps (V2) trigger**, which renders a typed input form when the flow is run directly from Power Automate. The presenter therefore has a working input form and the complete private-network path from the first deployment, with or without the canvas app.

### Smallest manual action

Once, per repository — not per deployment:

1. Deploy the solution (the flow imports).
2. In [make.powerapps.com](https://make.powerapps.com), create a blank canvas app inside the `SecureRequestClassifier` solution and build the form described in `RequestScreen.pa.yaml` (six inputs, a submit button, a result card). Add the `ClassifyandNotify` flow to it.
3. Save and publish.
4. Export the unmanaged solution and unpack it over the repository source:

   ```powershell
   pac solution export --environment <url> --name SecureRequestClassifier --path ./export.zip --managed false
   pac solution unpack --zipfile ./export.zip --folder ./powerplatform/solution/src --packagetype Unmanaged
   ```

5. Commit the resulting `CanvasApps/*.msapp` and `CanvasApps/*.meta.xml`. Every subsequent deployment includes the app automatically.

Microsoft's own CoE Starter Kit commits the `.msapp` binary to source control for exactly this reason.

---

## 2. The connector connection must be created once by a person

### What cannot be automated

Creating the **HTTP with Microsoft Entra ID (preauthorized)** connection that the flow uses, without a human sign-in.

### Why

The connector's Microsoft Entra ID authentication type is a **delegated user** connection. From the [connector reference](https://learn.microsoft.com/en-us/connectors/webcontents/):

> This preauthorization empowers the connector to interact with these services using delegated access **on behalf of the user**.

The connection parameters for auth type `EntraAuth` are *Microsoft Entra ID Resource URI (Application ID URI)* and *Base Resource URL*. There is no service-principal option: the only app-identity variant is `CertOauth`, which requires a client certificate **and its password** — that is, a secret, which this demo refuses to introduce.

### Why the alternative connectors do not help

| Connector | VNet supported? | Notes |
| --- | --- | --- |
| **HTTP with Microsoft Entra ID (preauthorized)** (`shared_webcontents`) | **Yes** | The only VNet-routed HTTP-style connector |
| HTTP With Microsoft Entra ID v2 (`shared_webcontentsv2`) | No | Not on the supported-services list |
| HTTP (built-in action) | No | Not on the supported-services list |
| Custom connector | Yes | Supported, but the connection has the same delegated-auth characteristics |

The supported-services table in the [VNet support overview](https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-overview) is the definitive list, and the plain HTTP action is absent from it.

Additionally, under VNet support the connector's **Get web resource** action is unsupported, so the flow uses `InvokeHttp` ("Invoke an HTTP request") exclusively.

### Smallest manual action

Once per Power Platform environment:

1. In Power Automate → **Connections** → **New connection** → *HTTP with Microsoft Entra ID (preauthorized)*.
2. Choose **Log in with Microsoft Entra ID**.
3. *Microsoft Entra ID Resource URI (Application ID URI)*: the value of the `AZURE_API_APP_ID_URI` variable, for example `api://44444444-…`.
4. *Base Resource URL*: the Function App base URL, for example `https://func-srclass-demo-ab12cd.azurewebsites.net`.
5. Sign in.
6. Read the connection ID and store it as a repository **variable** (a connection ID is an identifier, not a credential):

   ```powershell
   pac connection list --environment <environment-url>
   gh variable set POWER_PLATFORM_CONNECTION_ID_WEBCONTENTS --body <guid>
   gh variable set POWER_PLATFORM_CONNECTION_ID_OFFICE365   --body <guid>
   ```

CI then binds the existing connection through the deployment settings file. `scripts/Initialize-EntraResources.ps1` has already created the `oauth2PermissionGrant` that makes step 5 succeed without a consent prompt.

> Changing preauthorizations can take up to an hour to affect connections that already existed. New connections pick the change up immediately. — connector reference, Known Issues

---

## 3. Linking the enterprise policy to an environment is not an ARM operation

### What cannot be automated *in Bicep*

Associating the `Microsoft.PowerPlatform/enterprisePolicies` resource with a Power Platform environment.

### Why

Creating the policy is an Azure Resource Manager operation and **is** in this repository's Bicep. Linking it is a Power Platform control-plane operation on a different API. The documented mechanisms are the `Microsoft.PowerPlatform.EnterprisePolicies` PowerShell module and the Power Platform admin center UI:

> To assign your policy to your environment, sign in to the Power Platform admin center… Select the environment you want to assign to the enterprise policy, select the policy, and select Save.
> — [Set up VNet support](https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-setup-configure)

and:

> You can remove an enterprise policy from an environment **only through PowerShell** by using `Disable-SubnetInjection`.

`pac admin` has no enterprise-policy command.

### How this repository automates it anyway

`scripts/Set-PowerPlatformSubnetInjection.ps1` prefers Microsoft's supported cmdlet:

```powershell
Enable-SubnetInjection -EnvironmentId <env> -PolicyArmId <arm-id>
```

The `link-enterprise-policy` job installs the module and calls the script. When the module cannot be installed on the runner, the script falls back to the same REST call the module makes:

```http
POST https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/environments/{envId}/enterprisePolicies/NetworkInjection/link?api-version=2019-10-01
Authorization: Bearer <token for https://service.powerapps.com/>
Content-Type: application/json

{ "SystemId": "<enterprisePolicy.properties.systemId>" }
```

**Be aware:** that endpoint is not published in the Microsoft REST API reference. It is recoverable only from Microsoft's own MIT-licensed [PowerPlatform-EnterprisePolicies](https://github.com/microsoft/PowerPlatform-EnterprisePolicies) module source. It carries no documented SLA or versioning guarantee. The cmdlet path is preferred for that reason; the fallback exists so a clean CI runner is never blocked.

### Prerequisites the script cannot create for itself

* The calling identity needs the **Power Platform Administrator** directory role. Assigning a directory role is a tenant-administration action outside the workload's scope.
* It needs **Reader** on the enterprise policy resource. The Bicep *does* grant this — pass the object ID through the `POWER_PLATFORM_ADMIN_OBJECT_ID` repository variable.

---

## 4. Deploying code to a private function app needs a network-connected runner

### What cannot be automated from a standard GitHub-hosted runner

Pushing the function package to a Function App whose `publicNetworkAccess` is `Disabled`.

### Why

Disabling public network access closes the deployment endpoint as well as the application endpoint. App access is evaluated *before* site access, so there is no separate control for the SCM/Kudu site. Microsoft is explicit:

> When your function app has private endpoints enabled and public network access is disabled, the deployment endpoint isn't publicly reachable. Push deployment tools, including Core Tools, Visual Studio Code, Azure CLI, GitHub Actions, and Azure Pipelines, send packages to this endpoint. The machine, runner, or agent that performs the deployment must have both network connectivity and DNS resolution for the private deployment endpoint.
> — [Azure Functions deployment technologies](https://learn.microsoft.com/en-us/azure/azure-functions/functions-deployment-technologies), *Secured virtual networks*

The documented remedies are: a self-hosted runner on a connected network; a GitHub-hosted larger runner with Azure private networking; a VPN or ExpressRoute connection; or a Resource Manager deployment that supplies a package URL the deployment *service* can fetch.

Writing the package directly into the deployment container does **not** work:

> The deployment service stores the processed package in the configured deployment container; **directly uploading a package to this container doesn't deploy it.**
> — [Zip deployment for Azure Functions](https://learn.microsoft.com/en-us/azure/azure-functions/deployment-zip-push)

The Resource Manager `onedeploy` path needs a `packageUri` that the deployment service can reach, which in practice means a SAS-bearing URL — ruled out by this demo's constraints.

### What this repository does

`FUNCTION_DEPLOY_MODE` selects the behaviour.

**`private-runner`** — set `FUNCTION_DEPLOY_RUNNER_LABEL` to a self-hosted or privately networked runner. Public access is **never** enabled. This is the recommended mode and the one to use in a real environment.

**`deployment-window`** (default, so a fork works with no extra infrastructure) — the deploy job:

1. sets `publicNetworkAccess: Enabled`;
2. immediately adds an access restriction allowing **only** the runner's current egress `/32`, on both the app and the SCM site, with the default action set to `Deny`;
3. deploys;
4. removes the restriction and sets `publicNetworkAccess: Disabled` in an `if: always()` step;
5. asserts the final state is `Disabled` and fails the job if it is not.

Two things worth stating plainly to a customer:

* **This is a deployment-plane concession, never a runtime-plane one.** The Power Automate path is private at all times.
* **Microsoft does not publish this as a recommended pattern.** It is a pragmatic fallback, which is why it is parameterised and why `private-runner` exists. In an Azure Landing Zone with the `Deny-Public-Endpoints` policy assigned, the window will be blocked by policy and you **must** use `private-runner`.

---

## 5. Managed Environments and the Azure subscription association are prerequisites

### What cannot be created by this repository

* Enabling **Managed Environments** on the target Power Platform environment.
* Associating an Azure subscription with the Power Platform tenant.

### Why

Both are tenant-administration actions that logically precede any workload deployment.

> To enable virtual network support for Power Platform, environments must be managed environments.
> — [Set up VNet support](https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-setup-configure)

> Is linking an Azure subscription to my Power Platform tenant necessary to activate VNet support? **Yes**, to enable VNet support for Power Platform environments, you must associate an Azure subscription with the Power Platform tenant.
> — [VNet support overview, FAQ](https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-overview)

The FAQ entry states the requirement but publishes no procedure. The only documented Azure-subscription-to-Power-Platform link construct is a [pay-as-you-go billing policy](https://learn.microsoft.com/en-us/power-platform/admin/pay-as-you-go-overview), which does have a [REST API](https://learn.microsoft.com/en-us/rest/api/power-platform/licensing/billing-policy/create-billing-policy).

### Smallest manual action

Managed Environments **is** scriptable and is documented in `docs/deployment.md`:

```powershell
pac admin set-governance-config --environment <environment-id> --protection-level Standard
```

Requires the Power Platform Administrator or Dynamics 365 Administrator role. Dataverse is required for Production, Sandbox and Trial environment types.

The subscription association is a one-time tenant action performed in the Power Platform admin center.

---

## 6. Smaller notes

| Item | Detail |
| --- | --- |
| **Environment types** | Trial and Dataverse for Teams environments do **not** support VNet support. Production, Default, Sandbox and Developer do. |
| **US Government cloud** | Only GCC High and DoD. GCC is not supported. |
| **Enable/disable disruption** | Enabling or disabling subnet delegation can cause *"up to a 30-minute window of unavailability or instability as connections initialize"*. |
| **Subnet range immutability** | The delegated subnet's IP range and the VNet's DNS server setting cannot be changed while subnet injection is active. |
| **Connector throughput** | The connector is throttled at 100 API calls per connection per 60 seconds. Fine for a demo; size accordingly for real use. |
| **Synchronous responses only** | The connector does not support the asynchronous `Location`-header polling pattern, so the Function must answer synchronously. It does. |
| **Text payloads only** | The connector base64-encodes the request body on the wire and does not support raw binary. The demo sends JSON, which is fine. |
| **ARM API version** | Microsoft's docs use `2020-10-30-preview` for `enterprisePolicies` while Microsoft's own PowerShell module uses `2020-10-30`. This repository uses the documented `2020-10-30-preview`. No Microsoft source reconciles the two. |
| **Solution packager warnings** | `pac solution pack` reports *"Following root components are not defined in customizations"* for connection references and environment variable definitions. This is benign — both are packed correctly, verified by inspecting the produced zip. |
| **Azure Landing Zone DNS** | If the `Deploy-Private-DNS-Zones` DeployIfNotExists policy is assigned, set `CREATE_PRIVATE_DNS_ZONE_GROUPS=false`. Microsoft: *"if you use the DeployIfNotExists policy approach in this article, you shouldn't integrate DNS in your code."* |
