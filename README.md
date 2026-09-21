# Secure Request Classifier

A complete, self-contained demonstration of **Microsoft Power Platform calling a private Azure Function over private networking**, with the Function App's public endpoint switched off, deployed entirely by GitHub Actions using federated identity.

Everything is in this repository: the Azure infrastructure, the application code, the Power Platform solution, the CI/CD pipelines, the verification checks and the cleanup path.

---

## What this demonstrates

| Claim | How this repository proves it |
| --- | --- |
| A cloud flow can reach a backend that has **no public endpoint** | The Function App ships with `publicNetworkAccess: Disabled`; the flow reaches it through the Power Platform delegated subnet and a private endpoint |
| Power Platform traffic can be pinned into **your** virtual network | A `Microsoft.PowerPlatform/enterprisePolicies` network-injection policy binds delegated subnets in both Azure regions of the Power Platform region pair |
| Backend authentication needs **no shared secret** | App Service Authentication validates Microsoft Entra ID tokens; no client secret, no Function key, no SAS token |
| Azure access needs **no stored credential** | GitHub OIDC / workload identity federation for both Azure **and** Power Platform. A CI job fails the build if any workflow references a stored credential; only non-credential identifiers are allow-listed |
| The whole thing is **source controlled** | Infrastructure (Bicep), application (.NET 10), Power Platform solution (unpacked), pipelines (Actions), docs |
| It coexists with enterprise governance | No hub networking, no shared DNS zones, no pre-existing resources; Azure Landing Zone coexistence switches are parameters |

---

## Business scenario

An employee submits a simple internal request — a broken laptop, a meeting-room problem, an HR question. The organisation wants that request triaged consistently, and wants the triage logic to live in Azure on a service that is **not reachable from the internet**.

1. The employee fills in a short form. The **Classify and Notify** cloud flow uses a PowerApps (V2) trigger, which renders that form when the flow is run from Power Automate.
2. The flow calls an **HTTP-triggered Azure Function** over private networking.
3. The Function validates and normalises the request, generates a request ID, derives a priority, assigns a responsible team and calculates a response target — using plain deterministic rules, no AI.
4. The flow emails the requester through **Office 365 Outlook**.
5. The classification is returned to the caller.

The application logic is deliberately small. The interesting part is the network path and the identity model.

> **There is no canvas app in this repository's deployment.** `pac canvas pack` is deprecated and
> refuses to build an `.msapp` from YAML that has not been opened in Power Apps Studio, so no app
> binary can be produced in CI. The flow's PowerApps (V2) trigger renders the same typed input
> form and exercises the identical network path, which is what the demonstration is about. See
> [docs/limitations.md](docs/limitations.md#1-there-is-no-canvas-app-and-one-cannot-be-built-in-ci).

---

## Architecture overview

```mermaid
flowchart TB
    subgraph user["User"]
        U["Employee"]
    end

    subgraph pp["Power Platform environment (Managed Environment)"]
        FLOW["Cloud flow<br/>Classify and Notify<br/>(PowerApps V2 trigger)"]
        CONN["Connector:<br/>HTTP with Microsoft Entra ID<br/>(preauthorized)"]
        O365["Office 365 Outlook<br/>connector"]
    end

    subgraph azure["Azure subscription — one isolated resource group"]
        subgraph vnet1["Primary VNet (e.g. westeurope)"]
            SNETPP1["snet-powerplatform<br/>delegated to<br/>Microsoft.PowerPlatform/enterprisePolicies"]
            SNETFN["snet-functions<br/>delegated to<br/>Microsoft.App/environments"]
            SNETPE["snet-private-endpoints"]
            PE["Private endpoint<br/>groupId: sites"]
        end

        subgraph vnet2["Failover VNet (e.g. northeurope)"]
            SNETPP2["snet-powerplatform<br/>delegated"]
        end

        DNS["Private DNS zones<br/>privatelink.azurewebsites.net<br/>privatelink.blob/queue/table"]
        FUNC["Azure Function App<br/>.NET 10 isolated, Flex Consumption<br/>publicNetworkAccess: Disabled"]
        ST["Storage account<br/>no shared keys, private endpoints"]
        AI["Application Insights<br/>local auth disabled"]
        EP["Enterprise policy<br/>kind: NetworkInjection"]
    end

    MAIL["Requester mailbox<br/>Microsoft 365"]

    U -->|"1. run the flow, fill in the trigger form"| FLOW
    FLOW --> CONN
    CONN -->|"2. egress from the delegated subnet"| SNETPP1
    SNETPP1 -->|"3. resolve via VNet DNS"| DNS
    SNETPP1 -->|"4. private IP"| PE
    PE --> FUNC
    FUNC -->|"outbound VNet integration"| SNETFN
    SNETFN --> ST
    FUNC --> AI
    FUNC -->|"5. JSON response"| FLOW
    FLOW --> O365 -->|"6. email"| MAIL
    FLOW -->|"7. result"| U

    EP -.->|"binds"| SNETPP1
    EP -.->|"binds"| SNETPP2
    vnet2 <-->|"peering"| vnet1
    DNS -.->|"linked to both"| vnet2

    classDef disabled fill:#ffe6e6,stroke:#c00,stroke-width:2px
    class FUNC disabled
```

**The Function App has no public endpoint.** The only way in is the private endpoint, reachable from the delegated subnet.

### Request sequence

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Flow as Power Automate<br/>cloud flow
    participant Subnet as Delegated subnet<br/>(Power Platform VNet support)
    participant DNS as Azure Private DNS<br/>privatelink.azurewebsites.net
    participant PE as Private endpoint
    participant Func as Azure Function<br/>(public access disabled)
    participant Outlook as Office 365 Outlook
    participant Mail as Requester mailbox

    User->>Flow: Run the flow, fill in the trigger form
    Flow->>Flow: Generate correlation id, compose JSON payload
    Flow->>Subnet: InvokeHttp via "HTTP with Microsoft Entra ID (preauthorized)"
    Note over Subnet: Connector runs in a container<br/>inside YOUR delegated subnet
    Subnet->>DNS: Resolve func-xxxx.azurewebsites.net
    DNS-->>Subnet: 10.60.2.x (private IP of the private endpoint)
    Subnet->>PE: HTTPS + Microsoft Entra ID bearer token
    PE->>Func: Forward over Private Link
    Note over Func: App Service Authentication validates the token<br/>(issuer, audience, allowed application)
    Func->>Func: Validate, normalise, classify, compute SLA
    Func-->>PE: 200 OK, JSON result
    PE-->>Subnet: Response
    Subnet-->>Flow: Response body
    Flow->>Flow: Parse JSON
    Flow->>Outlook: Send email (request id, priority, team, target)
    Outlook->>Mail: Confirmation email
    Flow-->>User: Request id, priority, assigned team, response target

    rect rgba(255, 220, 220, 0.5)
        Note over User,Func: A request from the public internet to the same host<br/>never reaches the Function App at all.
    end
```

### Deployment identity

```mermaid
sequenceDiagram
    autonumber
    participant GH as GitHub Actions runner
    participant OIDC as GitHub OIDC provider<br/>token.actions.githubusercontent.com
    participant Entra as Microsoft Entra ID<br/>app registration + federated credential
    participant ARM as Azure Resource Manager
    participant DV as Power Platform / Dataverse

    GH->>OIDC: Request an ID token (permissions: id-token: write)
    OIDC-->>GH: JWT with sub = repo:OWNER/REPO:environment:demo
    GH->>Entra: Exchange the JWT (audience api://AzureADTokenExchange)
    Note over Entra: Federated identity credential matches<br/>issuer + subject + audience.<br/>No client secret exists on this app.
    Entra-->>GH: Access token for Azure Resource Manager
    GH->>ARM: az deployment sub create (Bicep)
    ARM-->>GH: Outputs (function app name, URLs, policy id)

    GH->>OIDC: Request a second ID token
    OIDC-->>GH: JWT
    GH->>Entra: pac auth create --githubFederated (app-id + tenant-id, no secret)
    Entra-->>GH: Access token for Dataverse
    GH->>DV: Import the Power Platform solution

    rect rgba(220, 255, 220, 0.5)
        Note over GH,DV: Nothing in GitHub stores an Azure or Power Platform credential.<br/>Only identifiers are stored, as repository secrets so they<br/>are masked in the public run logs.
    end
```

---

## Repository structure

```
.
├── .github/
│   └── workflows/
│       ├── deploy.yml            Primary orchestrator: validate → infra → function → Power Platform → verify
│       ├── ci.yml                Build, test, lint, and enforce the security invariants
│       └── destroy.yml           Guarded cleanup
├── src/
│   └── function/
│       ├── SecureRequestClassifier.Functions/        .NET 10 isolated-worker Function App
│       │   ├── Configuration/    Options + start-up validation
│       │   ├── Endpoints/        HTTP triggers (classify, health)
│       │   ├── Models/           Request, response, problem and health contracts
│       │   └── Services/         Deterministic classifier, validator, Easy Auth principal reader
│       └── SecureRequestClassifier.Functions.Tests/  xUnit tests (98 cases)
├── infra/
│   ├── main.bicep                Subscription-scope orchestrator
│   ├── bicepconfig.json          Linter configuration
│   ├── modules/
│   │   ├── virtual-network.bicep
│   │   ├── virtual-network-peering.bicep
│   │   ├── network-security-group.bicep
│   │   ├── private-dns-zone.bicep
│   │   ├── private-endpoint.bicep
│   │   ├── storage.bicep
│   │   ├── monitoring.bicep
│   │   ├── function-app.bicep
│   │   ├── role-assignment.bicep
│   │   └── power-platform-enterprise-policy.bicep
│   └── parameters/
│       └── demo.bicepparam       Safe, committable demo defaults
├── powerplatform/
│   ├── solution/src/             Unpacked, source-controlled solution
│   │   ├── Other/                Solution.xml, Customizations.xml, Relationships.xml
│   │   └── Workflows/            The cloud flow definition (Logic App JSON + metadata)
│   └── config/
│       └── deploymentSettings.template.json
├── scripts/
│   ├── Initialize-EntraResources.ps1       One-time bootstrap, creates no secrets
│   ├── New-PowerPlatformEnvironment.ps1    Creates/adopts the environment, enables Managed Environments
│   ├── Resolve-PowerPlatformEnvironment.ps1 Resolves the environment by display name, per job
│   ├── Build-Solution.ps1                  Packs the Power Platform solution
│   ├── Test-SolutionPackage.ps1            Rejects a package Dataverse cannot import
│   ├── Test-FunctionHostStartup.ps1        Starts the Functions host and checks every function indexes
│   ├── Test-DocumentationLinks.ps1         Checks every internal documentation link and anchor resolves
│   ├── New-DeploymentSettings.ps1          Renders the deployment settings file
│   ├── Get-SolutionImportFailure.ps1       Reads the real import error out of Dataverse
│   ├── Set-FunctionAppDeploymentWindow.ps1 Opens/closes the transient deployment window
│   ├── Set-PowerPlatformSubnetInjection.ps1 Links the environment to the enterprise policy
│   ├── Test-Deployment.ps1                 40+ post-deployment assertions
│   ├── Test-FlowConnectorParameters.ps1    Flow action parameters vs the live connector schema
│   ├── Test-RepositoryConsistency.ps1      Asserts every artefact agrees with every other
│   ├── Invoke-PrivateConnectivityProbe.ps1 Proves private reachability and public unreachability
│   ├── Remove-Demo.ps1                     Guarded cleanup
│   └── Remove-PowerPlatformEnvironment.ps1 Deletes the environment Deploy created
├── docs/
│   ├── architecture.md           Component-by-component walkthrough
│   ├── networking-model.md       Subnets, delegation, DNS, region pairing
│   ├── security-model.md         Every control and what it defends against
│   ├── identity-model.md         Every identity and what it can do
│   ├── deployment.md             Step-by-step deployment and configuration reference
│   ├── demo-script.md            Presenter's guide for a customer demonstration
│   ├── verification.md           What is checked and how to check it manually
│   ├── troubleshooting.md        Symptom → cause → fix
│   └── limitations.md            What cannot be automated, why, with citations
├── global.json
├── SecureRequestClassifier.slnx
├── LICENSE                      MIT
├── SECURITY.md                  How to report a vulnerability, and the CI-enforced invariants
├── SUPPORT.md                   Where to get help, and what is out of scope
├── CONTRIBUTING.md              What a change to this repository is expected to do
├── CODE_OF_CONDUCT.md           Microsoft Open Source Code of Conduct
└── README.md
```

---

## Prerequisites

### Azure
* An Azure subscription. It may sit inside an Azure Landing Zone; see [docs/deployment.md](docs/deployment.md#azure-landing-zone-coexistence).
* Permission to create app registrations and role assignments in Microsoft Entra ID (Application Administrator or Cloud Application Administrator, plus the ability to assign Azure roles).
* Resource providers `Microsoft.Network`, `Microsoft.Web`, `Microsoft.App`, `Microsoft.Storage`, `Microsoft.PowerPlatform`, `Microsoft.Insights`, `Microsoft.OperationalInsights` — the deploy workflow registers these automatically.

### Power Platform
* **The environment is created for you.** The `Provision Power Platform environment` job creates it, waits for its Dataverse database, enables Managed Environments and adds the deployment identity as a Dataverse application user. If an environment with the configured display name already exists it is adopted rather than replaced.
* Environment type must be **Production**, **Sandbox**, **Developer** or **Default** — Trial and Dataverse for Teams are **not** supported by VNet support. The provisioning script defaults to a supported type; override with `POWER_PLATFORM_ENVIRONMENT_SKU`.
* An Azure subscription must be associated with the Power Platform tenant. This is a one-time tenant action and is **not** automated — see [docs/limitations.md](docs/limitations.md#5-the-azure-subscription-association-is-a-tenant-prerequisite).
* Power Platform Administrator (or Dynamics 365 Administrator) is required, both to enable Managed Environments and to link the enterprise policy.
* The environment's Power Platform geography must have a documented Azure region pair. See [docs/networking-model.md](docs/networking-model.md#region-pairing).

### Local tooling (only for the one-time bootstrap)
* [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.60+
* [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
* [Power Platform CLI](https://learn.microsoft.com/power-platform/developer/cli/introduction) (`pac`) 2.7+
* [GitHub CLI](https://cli.github.com/) (optional, for setting repository secrets quickly)

Local .NET, Bicep and Node tooling are **not** required — GitHub Actions does the building.

---

## Deployment

The full, annotated walkthrough is in **[docs/deployment.md](docs/deployment.md)**. The short version:

### 1. Fork or clone, then bootstrap identity (once)

```powershell
az login
pwsh ./scripts/Initialize-EntraResources.ps1 `
    -GitHubRepository <owner>/<repo> `
    -SubscriptionId   <subscription-guid>
```

This creates the deployment app registration with a **federated credential** (no client secret), the API app registration, the delegated permission grant for the connector, and the least-privilege Azure role assignments. It prints the repository secrets to set and the exact `gh secret set` commands.

### 2. Set repository secrets and variables

None of the values below is a credential — they are identifiers, and nothing here grants access on its own. The tenant-specific ones are still stored as **secrets** rather than variables, for one practical reason: **GitHub masks secrets in run logs and step summaries, and does not mask variables.** This repository is public, so anything held in a variable would be printed in the clear on the first successful deployment.

Settings → Secrets and variables → Actions → *Secrets*:

| Secret | Required | Example |
| --- | --- | --- |
| `AZURE_CLIENT_ID` | yes | `11111111-…` |
| `AZURE_TENANT_ID` | yes | `22222222-…` |
| `AZURE_SUBSCRIPTION_ID` | yes | `33333333-…` |
| `AZURE_API_APP_ID` | yes | `44444444-…` |
| `AZURE_API_APP_ID_URI` | yes | `api://44444444-…` |
| `POWER_PLATFORM_APP_ID` | for solution import | same as `AZURE_CLIENT_ID` |
| `POWER_PLATFORM_TENANT_ID` | for solution import | same as `AZURE_TENANT_ID` |
| `POWER_PLATFORM_ADMIN_OBJECT_ID` | recommended | object id that will link the policy |

Settings → Secrets and variables → Actions → *Variables* (non-sensitive configuration):

| Variable | Required | Example |
| --- | --- | --- |
| `POWER_PLATFORM_REGION` | recommended | `europe` |
| `POWER_PLATFORM_ENVIRONMENT_NAME` | optional | `srclass-demo` (default) |
| `AZURE_LOCATION` | optional | `westeurope` |
| `FUNCTION_DEPLOY_MODE` | optional | `deployment-window` (default) or `private-runner` |

You never supply the environment ID or Dataverse URL. The Deploy workflow provisions the
environment and each later stage resolves it by display name. They are deliberately not passed
between jobs: both are masked, and GitHub redacts any job output whose value contains a secret,
so passing them that way would silently yield an empty string.

The full table, including the Azure Landing Zone switches, is in [docs/deployment.md](docs/deployment.md#configuration-reference).

### 3. Complete the Power Platform prerequisites

For a **new** environment there is nothing to do here. The `Provision Power Platform environment`
job creates it, enables Managed Environments and adds the deployment identity as a Dataverse
application user.

Two things must be true at the tenant level, once, and neither can be done by this repository:

* An Azure subscription is associated with the Power Platform tenant — see [docs/limitations.md](docs/limitations.md#5-the-azure-subscription-association-is-a-tenant-prerequisite).
* The deployment app registration holds **Power Platform Administrator** in Microsoft Entra ID, so it can link the enterprise policy.

If you are pointing the demo at an environment that already exists and was created some other way,
apply the two commands in [docs/deployment.md](docs/deployment.md#5-power-platform-prerequisites-once).

### 4. Run the workflow

Actions → **Deploy** → *Run workflow*.

One run performs validation, Azure infrastructure, Function build and deployment, enterprise-policy linking, Power Platform solution import, and post-deployment verification.

### 5. Finish in Power Automate

The deployment cannot create the two connections — both connectors sign in as a person, so
automating them would mean storing a credential. **The flow does not run until you do this**, and
you do it again after any deployment that re-imports the solution:

1. Open the **Classify and Notify** flow in [Power Automate](https://make.powerautomate.com) and select **Edit**.
2. On **Invoke classification API**, add a connection — **HTTP with Microsoft Entra ID (preauthorized)**, not the v2 connector. It asks for two values, both of which are in the solution's **Environment variables**: `srcls_FunctionApplicationIdUri` and `srcls_FunctionBaseUrl`.
3. On **Send confirmation email**, add an **Office 365 Outlook** connection.
4. **Save**, then **turn the flow on**.

The first run after a fresh network link can take a while and may fail once while Power Platform
settles; run it again before investigating. Full detail, and what a redeployment does and does not
reset, is in [docs/deployment.md](docs/deployment.md#create-the-connections-and-turn-the-flow-on).

---

## Identity model

Five distinct identities, each with the narrowest job that works.

| Identity | Type | Authenticates with | Can do |
| --- | --- | --- | --- |
| GitHub Actions deployment identity | Entra app registration | **Federated credential** (GitHub OIDC). No secret exists. | Contributor + Role Based Access Control Administrator on the subscription; Dataverse System Administrator; Power Platform Administrator |
| Function App | System-assigned managed identity | Managed identity | Storage Blob Data Owner / Queue / Table Contributor on **its own** storage account; Monitoring Metrics Publisher on **its own** Application Insights. Nothing else. |
| Function API | Entra app registration | Nothing — it is a token *audience* | Exposes `api://<appId>/user_impersonation`; validated by App Service Authentication |
| HTTP with Microsoft Entra ID connector | Microsoft first-party app `7ab7862c-4c57-491e-8a45-d52a7e023983` | Delegated user consent | Obtains a token for the API on behalf of the signed-in user. Listed in `allowedApplications` |
| Signed-in user | Entra user | Interactive | Runs the app; their identity flows through to the Function |

Details, including exactly what each grant permits, are in [docs/identity-model.md](docs/identity-model.md).

---

## Networking model

| Subnet | Virtual network | Delegation | Purpose |
| --- | --- | --- | --- |
| `snet-powerplatform` | primary **and** failover | `Microsoft.PowerPlatform/enterprisePolicies` | Where Power Platform connector containers run |
| `snet-functions` | primary | `Microsoft.App/environments` | Function App outbound VNet integration |
| `snet-private-endpoints` | primary | none | Private endpoints for the Function App and storage |

Every subnet carries a network security group — Azure Landing Zones assign
`Deny-Subnet-Without-Nsg` as a `Deny` effect, so a subnet without one simply cannot be created.

Key points, each explained in [docs/networking-model.md](docs/networking-model.md):

* **Two virtual networks are mandatory** in a paired Power Platform geography. A Power Platform environment can fail over between the two Azure regions of its region pair, so both need a delegated subnet, and they are peered so the failover region can still reach the private endpoints.
* **Private DNS zones are linked to both networks.** Power Platform resolves names using the DNS configured on the virtual network the delegated subnet lives in. A zone linked to only one network resolves to a public IP address after a failover.
* **The delegated subnet is dedicated.** It cannot hold private endpoints or any other resource, and it cannot be shared between enterprise policies.
* **The three delegations are different services.** Power Platform and Flex Consumption cannot share a subnet.

---

## Security model

| Control | Setting | What it prevents |
| --- | --- | --- |
| No public endpoint | `publicNetworkAccess: Disabled` on the Function App | Any internet-originated request, including to the SCM/Kudu site |
| Private ingress only | Private endpoint, `groupId: sites` | Traffic that has not traversed your network |
| Microsoft Entra ID authentication | `authsettingsV2`, `requireAuthentication: true`, `unauthenticatedClientAction: Return401` | Unauthenticated calls, even from inside the network |
| Caller allow-list | `defaultAuthorizationPolicy.allowedApplications` | Any application other than the approved connector |
| No Function keys | Every trigger is `AuthorizationLevel.Anonymous` behind Easy Auth | A leaked key granting access |
| No storage keys or SAS | `allowSharedKeyAccess: false` | Key- or SAS-based access to the deployment package or host storage |
| No publishing credentials | SCM and FTP basic auth policies set to `allow: false` | Username/password deployment |
| No telemetry key | Application Insights `DisableLocalAuth: true` | Instrumentation-key-as-credential |
| No stored CI credentials | GitHub OIDC for Azure *and* Power Platform | Credential theft from the repository or its settings |
| Least privilege | Scoped data-plane roles; `Role Based Access Control Administrator` instead of `Owner` | Lateral movement |

A CI job (`security-invariants`) fails the build if any of these regress. See [docs/security-model.md](docs/security-model.md).

---

## How to run the demo

The flow must be switched on and both connections selected — see step 5 above. A freshly deployed
flow is off.

1. In [Power Automate](https://make.powerautomate.com), open the **Classify and Notify** flow.
2. Select **Test** → **Manually** → **Test**. The PowerApps (V2) trigger renders a typed input form.
3. Enter a requester name and email, a title, pick a category and impact, add a description.
4. Select **Run flow**.
5. The run detail shows the request ID, priority, assigned team and response target returned by the Function — over the private network path.
6. The requester receives the confirmation email.

The presenter's script, with talking points for each stage, is in **[docs/demo-script.md](docs/demo-script.md)**.

---

## Validating private connectivity

```powershell
# 40+ assertions: public access disabled, private endpoint approved, DNS records present,
# RBAC correct and correctly scoped, delegations correct, no shared keys, and more.
pwsh ./scripts/Test-Deployment.ps1 `
    -ResourceGroupName            rg-srclass-demo `
    -SubscriptionId               <subscription-guid> `
    -PowerPlatformEnvironmentId   <environment-guid>

# Two live probes: from the public internet (must fail) and from inside the VNet (must succeed).
pwsh ./scripts/Invoke-PrivateConnectivityProbe.ps1 -ResourceGroupName rg-srclass-demo
```

`-SubscriptionId` is optional but worth passing: without it the Azure CLI's current subscription is
used, which is the usual reason for an otherwise inexplicable "resource group could not be found".
`-PowerPlatformEnvironmentId` adds the check that the environment is actually linked to the
enterprise policy, which is the one thing that makes the private path work at all.

Reading role assignments needs `Microsoft.Authorization/roleAssignments/read`. Without it those
checks report a warning that says so, rather than claiming the grants are missing.

Manual checks, including `nslookup` from the delegated subnet using Microsoft's own diagnostics cmdlets, are in [docs/verification.md](docs/verification.md).

---

## Configuration

Behaviour is controlled by Bicep parameters (see `infra/parameters/demo.bicepparam`) and GitHub repository secrets and variables. Nothing in this repository is tied to a particular tenant, subscription or environment; the defaults are generic and safe.

The full reference is in [docs/deployment.md](docs/deployment.md#configuration-reference).

---

## Troubleshooting

Common symptoms and their causes are catalogued in **[docs/troubleshooting.md](docs/troubleshooting.md)**, including:

* the flow returns 403 after the connection was created successfully;
* the host name resolves to a public IP address from the delegated subnet;
* the function deploy step fails with a connection timeout;
* `Enable-SubnetInjection` reports that the policy cannot be read.

---

## Cleanup

```powershell
pwsh ./scripts/Remove-Demo.ps1 `
    -ResourceGroupName             rg-srclass-demo `
    -PowerPlatformEnvironmentId    <environment-id> `
    -PowerPlatformEnvironmentName  srclass-demo
```

or run the **Destroy** workflow and type `DESTROY` to confirm.

This removes everything the **Deploy** workflow creates:

| Item | Removed by default | Notes |
| --- | --- | --- |
| Resource group `rg-srclass-demo` and everything in it | **Yes** | Waits for the deletion to finish, so a green run means it is actually gone |
| Power Platform environment, its Dataverse database and the solution | **Yes** | `-KeepPowerPlatformEnvironment` keeps it |
| The two Entra app registrations | **No** | Created by the *bootstrap*, not by a deployment — see below |
| The `HTTP with Microsoft Entra ID` connector service principal and its grant | **Never** | Shared, tenant-wide Microsoft first-party application. Not ours to delete |

### Why the app registrations survive

They are created once by `scripts/Initialize-EntraResources.ps1`, which is a bootstrap step, not part of a deployment. The deployment one is the identity the pipelines sign in with, so deleting it means re-running the bootstrap and re-setting every repository secret before you can deploy again.

Deploy runs happily against the same pair any number of times, so keeping them costs nothing and blocks nothing. If you do want a bare tenant:

```powershell
pwsh ./scripts/Remove-Demo.ps1 -ResourceGroupName rg-srclass-demo -RemoveEntraApplications
```

or tick `remove-entra-applications` on the Destroy workflow. Expect to re-run the bootstrap afterwards.

Every run prints a **Left in place** list, and the workflow summary states which of the above applied, so the boundary is never implied.

Order matters, and the script enforces it: the environment is unlinked from the enterprise policy first, then deleted, and only then is the resource group removed — otherwise the delegated subnet can still be held and the virtual network refuses to delete.

Two guards stop it being aimed at the wrong thing: the resource group must be tagged `workload=secure-request-classifier`, and the environment's display name must match the one you supply. The latter matters because provisioning runs with `-AdoptExisting`, so an environment carrying the configured name is not necessarily one the pipeline created.

`scripts/Test-RepositoryConsistency.ps1` asserts in CI that every `New-*.ps1` the Deploy workflow calls has a matching `Remove-*.ps1` that the Destroy path actually invokes, so the two pipelines cannot drift apart again.

---

## Known limitations

Fully documented, with citations, in **[docs/limitations.md](docs/limitations.md)**. Summary:

1. **There is no canvas app, and one cannot be built in CI.** `pac canvas pack` is deprecated and refuses to pack YAML that has not been opened once in Power Apps Studio, so no `.msapp` can be produced by the pipeline. The flow's PowerApps (V2) trigger renders the same typed input form and exercises the identical network path, so the demonstration is complete without it.
2. **The two connections are created and bound by a person, and rebound after every solution import.** Both connectors use delegated-user OAuth, so there is no service-principal path that does not introduce a stored secret. The pipeline deliberately never binds connection references: it runs as a service principal that has no permission on a user's connection, and attempting it destroys the binding. The connections themselves persist; the *binding* and the flow's on/off state do not survive an import.
3. **Linking the enterprise policy to an environment is not an ARM operation.** It is automated here using Microsoft's `Enable-SubnetInjection` cmdlet, with a documented REST fallback.
4. **Deploying code to a function app with public access disabled needs a network-connected runner.** Microsoft documents this explicitly. The default mode opens a transient, single-IP-restricted deployment window and re-seals it; `private-runner` mode avoids it entirely.
5. **An associated Azure subscription is a tenant prerequisite** that must exist before this repository can deploy anything. Managed Environments is handled automatically by the environment provisioning script.

---

## Licence

MIT. See [LICENSE](LICENSE).

This is demonstration code. It is optimised for clarity and for showing security properties, not for production-scale application complexity.
