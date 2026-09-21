# Limitations

This document lists everything in the demo that **cannot** currently be automated end to end with supported Microsoft tooling, why, the authoritative source for that conclusion, and the smallest manual action that works around it.

Nothing here is papered over with a secret, and nothing here blocks the security demonstration itself.

---

## 1. There is no canvas app, and one cannot be built in CI

### What this means for the deployment

**Nothing this repository deploys includes a Power App.** The solution contains a cloud flow, two connection references and four environment variables — no app. Do not go looking for one in the maker portal after deploying; it is not there.

The flow's **PowerApps (V2) trigger** renders a typed input form when the flow is run from Power Automate, so the demonstration has a working front end and the complete private-network path from the first deployment.

### What cannot be automated

Producing the binary `.msapp` for a canvas front end from Power Fx YAML source, inside a GitHub Actions job, with no prior human interaction.

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

* The cloud flow uses a **PowerApps (V2) trigger**, which renders a typed input form when the flow is run directly from Power Automate. The presenter therefore has a working input form and the complete private-network path from the first deployment.
* `scripts/Build-Solution.ps1` packs the solution as it is committed. It no longer attempts `pac canvas pack`, because that attempt could not succeed from a clean clone and its failure path was the only path anyone ever took.
* The Power Fx source that used to be committed under `powerplatform/canvas-app/` has been removed. It described an app that was never built, never deployed and never demonstrated, so keeping it only suggested a front end existed.

### Smallest manual action

None is needed. The demonstration is complete without an app.

If you want one anyway, it is once per repository rather than per deployment:

1. Deploy the solution (the flow imports).
2. In [make.powerapps.com](https://make.powerapps.com), create a blank canvas app inside the `SecureRequestClassifier` solution: six inputs (requester name, requester email, title, category, impact, description), a submit button and a result card. Add the `ClassifyandNotify` flow to it and call it from the button.
3. Save and publish.
4. Export the unmanaged solution and unpack it over the repository source:

   ```powershell
   pac solution export --environment <url> --name SecureRequestClassifier --path ./export.zip --managed false
   pac solution unpack --zipfile ./export.zip --folder ./powerplatform/solution/src --packagetype Unmanaged
   ```

5. Commit the resulting `CanvasApps/*.msapp` and `CanvasApps/*.meta.xml`. Every subsequent deployment then includes the app, because `pac solution pack` packs whatever is in the source tree.

Microsoft's own CoE Starter Kit commits the `.msapp` binary to source control for exactly this reason.

---

## 2. Connections are created and bound by a person, once per environment

### What cannot be automated

Creating the two connections the flow uses, and binding them to the solution's connection references:

* **HTTP with Microsoft Entra ID (preauthorized)** — carries the call to the private Function
* **Office 365 Outlook** — sends the confirmation email

### Why

Both connectors use **delegated user** authentication. From the [connector reference](https://learn.microsoft.com/en-us/connectors/webcontents/):

> This preauthorization empowers the connector to interact with these services using delegated access **on behalf of the user**.

Read from the live connector definition, `shared_webcontents` requires a connection parameter `Token` of type `oauthSetting`, with `redirectUrl: https://global.consent.azure-apim.net/redirect/webcontents`. Acquiring that token is an OAuth authorization-code exchange against a signed-in user. Its other two required parameters — *Microsoft Entra ID Resource URI* and *Base Resource URL* — are plain strings and are deployment outputs, so they look automatable, but the token defeats it regardless.

There is no app-only path that this repository will take:

* The `CertOauth` variant needs a client certificate **and its password** — a stored secret, which this demo exists to avoid.
* The gateway variant needs a `username` and `password` — likewise.
* `IsOnbehalfofLoginSupported: true` appears in the connector metadata, but [on-behalf-of](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-on-behalf-of-flow#client-limitations) requires a user principal; it does not give an app-only service principal a way in.
* `pac connection create` creates a **Dataverse** connection for the CLI's own auth profiles. It does not create connector API connections.

### Why the pipeline does not bind them either

The deployment settings file deliberately contains **no `ConnectionReferences` section**.

The pipeline imports the solution as the deployment service principal. A connection created by a person is owned by that person, and the service principal has no permission on it, so asking the import to bind it fails:

```
ConnectionAuthorizationFailed
The caller with object id '<service-principal>' does not have the minimum required permission
to perform the requested operation on connection '<id>' under API 'shared_webcontents'
   at Microsoft.Dynamics.PowerPlatformConnectionReferences.Plugins.PreValidateConnectionReferenceUpdate
```

Worse, the attempt **destroys a binding that was already working**. Omitting the section means each import leaves the existing bindings alone.

Microsoft does document sharing a connection with a service principal so that it can be bound centrally — see [Share connections with another user so flows can be enabled](https://learn.microsoft.com/en-us/power-apps/maker/data-platform/create-connection-reference#share-connections-with-another-user-so-flows-can-be-enabled). That is a reasonable pattern for a managed ALM pipeline with a dedicated service account. It is **not** used here, because it trades one manual step for a different manual step plus a sharing model to maintain, and this is a demonstration.

### Why the alternative connectors do not help

| Connector | VNet supported? | Notes |
| --- | --- | --- |
| **HTTP with Microsoft Entra ID (preauthorized)** (`shared_webcontents`) | **Yes** | The only VNet-routed HTTP-style connector |
| HTTP With Microsoft Entra ID v2 (`shared_webcontentsv2`) | No | Not on the supported-services list |
| HTTP (built-in action) | No | Not on the supported-services list |
| Custom connector | Yes | Supported, but the connection has the same delegated-auth characteristics |

The supported-services table in the [VNet support overview](https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-overview) is the definitive list, and the plain HTTP action is absent from it.

Additionally, under VNet support the connector's **Get web resource** action is unsupported, so the flow uses `InvokeHttp` ("Invoke an HTTP request") exclusively.

### The manual step

Once per Power Platform environment, after the first deployment.

**Where the values come from.** You do not need Azure portal access. The deployment writes both
into the solution's own environment variables, in the environment you are already working in —
[make.powerapps.com](https://make.powerapps.com) → **Solutions** → **Secure Request Classifier** →
**Environment variables**:

| Environment variable | Use it for |
| --- | --- |
| `srcls_FunctionBaseUrl` | *Base Resource URL* |
| `srcls_FunctionApplicationIdUri` | *Microsoft Entra ID Resource URI (Application ID URI)* |

**The steps.**

1. Open the **Classify and Notify** flow in Power Automate and select **Edit**.
2. On the **Invoke classification API** action, create a new connection:
   * Connector: **HTTP with Microsoft Entra ID (preauthorized)** — not the v2 connector
   * *Microsoft Entra ID Resource URI (Application ID URI)*: the `srcls_FunctionApplicationIdUri` value
   * *Base Resource URL*: the `srcls_FunctionBaseUrl` value
   * Sign in
3. On the **Send confirmation email** action, create an **Office 365 Outlook** connection.
4. **Save** the flow, then **turn it on**. Saving alone does not enable a flow the import left off.

`scripts/Initialize-EntraResources.ps1` has already created the `oauth2PermissionGrant` that lets
step 2 complete without a consent prompt.

Create both connections from inside the flow designer. Creating one first under **Data** →
**Connections** and then selecting it in the flow can leave a second connection reference for the
same connector, duplicating what the solution already ships.

**It is once per environment, but not once per lifetime.** The connections are made once. The
*binding* is not: every import replaces the flow, so the replacement arrives with nothing selected
and switched off, and steps 1 to 4 have to be repeated — as a pick from a list rather than a
sign-in, since the connections are still there. Anything that claims a redeployment leaves the
flow runnable is wrong; see
[deployment.md](deployment.md#what-a-redeployment-resets) for what survives and what does not.

Full walkthrough, including other places the same values can be read from, in
[deployment.md](deployment.md#create-the-connections-and-turn-the-flow-on).

> Changing preauthorizations can take up to an hour to affect connections that already existed. New connections pick the change up immediately. — connector reference, Known Issues

### A note on "no secrets"

Microsoft defines a connection as a *stored authentication credential*, so a delegated connection is itself a credential — held by Power Platform, created by a human, never seen by this repository. The accurate claim is: **this repository stores no credentials, and its pipeline holds none.** Deployment authenticates only through GitHub OIDC workload identity federation.

The GitHub Actions secrets the workflows do use are all **identifiers** — subscription, tenant, application and object IDs. They are secrets so GitHub masks them in run logs, which are world-readable on a public repository:

| Kind | Where | Why |
| --- | --- | --- |
| Credentials | **nowhere** | Deployment is GitHub OIDC only. None exist to store |
| Identifiers that reveal tenant, subscription or environment topology | repository **secrets** | So they are masked in public run logs |
| Non-identifying configuration — region, labels, feature switches | repository **variables** | Harmless in a log, and useful to see there |

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
* It needs **Reader** on the enterprise policy resource. The Bicep *does* grant this — pass the object ID through the `POWER_PLATFORM_ADMIN_OBJECT_ID` repository secret.

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

## 5. The Azure subscription association is a tenant prerequisite

### What cannot be created by this repository

Associating an Azure subscription with the Power Platform tenant.

> Is linking an Azure subscription to my Power Platform tenant necessary to activate VNet support? **Yes**, to enable VNet support for Power Platform environments, you must associate an Azure subscription with the Power Platform tenant.
> — [VNet support overview, FAQ](https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-overview)

The FAQ states the requirement but publishes no procedure. The only documented Azure-subscription-to-Power-Platform link construct is a [pay-as-you-go billing policy](https://learn.microsoft.com/en-us/power-platform/admin/pay-as-you-go-overview), which does have a [REST API](https://learn.microsoft.com/en-us/rest/api/power-platform/licensing/billing-policy/create-billing-policy).

### Smallest manual action

A one-time tenant action performed in the Power Platform admin center.

### Managed Environments is *not* a manual step

It used to be listed here. It is now automated: `scripts/New-PowerPlatformEnvironment.ps1` creates the environment, waits for its Dataverse database, and enables Managed Environments over the Business Application Platform API, which VNet support requires:

> To enable virtual network support for Power Platform, environments must be managed environments.
> — [Set up VNet support](https://learn.microsoft.com/en-us/power-platform/admin/vnet-support-setup-configure)

The calling identity still needs the Power Platform Administrator or Dynamics 365 Administrator role — that part is a tenant grant, not something a workload can give itself. `-SkipManagedEnvironment` exists for environments where it is managed centrally, and warns that VNet support will not work without it.

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
| **Solution packager warnings** | `pac solution pack` used to report *"Following root components are not defined in customizations"* for connection references and environment variable definitions. That was a symptom of a real bug — both were listed in `Solution.xml` as root components, which they must never be — and it no longer appears. `scripts/Test-SolutionPackage.ps1` now asserts the package is clean; see [troubleshooting.md](troubleshooting.md). |
| **Azure Landing Zone DNS** | If the `Deploy-Private-DNS-Zones` DeployIfNotExists policy is assigned, set `CREATE_PRIVATE_DNS_ZONE_GROUPS=false`. Microsoft: *"if you use the DeployIfNotExists policy approach in this article, you shouldn't integrate DNS in your code."* |
