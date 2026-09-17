# Customer demonstration script

A 20–30 minute walkthrough. Each stage states **what you show**, **what you say** and, most importantly, **what it proves**.

Run through it once beforehand: stages 6–10 depend on a working connection and a linked enterprise policy.

---

## Before you start

| Check | Command |
| --- | --- |
| Everything is deployed and healthy | `pwsh ./scripts/Test-Deployment.ps1 -ResourceGroupName rg-srclass-demo` |
| A connection exists for the connector | Power Automate → Connections |
| The environment is linked to the policy | included in the verification output |
| You have two browser windows | Azure portal, and Power Apps / Power Automate |

Have a terminal open. Several stages are far more convincing from a command line than from a portal blade.

**Framing sentence to open with:**

> Everything you are about to see — the network, the application, the Power App, the flow and the pipeline that deployed all of it — is in one Git repository. There is not a single Azure credential stored anywhere in GitHub, and the backend has no address on the internet.

---

## Stage 1 — The deployed Azure architecture

**Show:** the resource group in the Azure portal, grouped by type.

```powershell
az resource list --resource-group rg-srclass-demo --output table
```

**Say:** one resource group holds the whole demo. Two virtual networks, a Flex Consumption Function App, a storage account, Log Analytics and Application Insights, four private endpoints, four private DNS zones, and one Power Platform enterprise policy.

**Proves:** the workload is **isolated**. It does not reuse a hub network, a shared private DNS zone, a route table or a firewall. That matters for governance because its blast radius is exactly one resource group, and cleanup is a single delete.

---

## Stage 2 — The Function App has no public endpoint

**Show:** Function App → Networking. Public network access is **Disabled**.

Then, from the terminal:

```powershell
az functionapp show -g rg-srclass-demo -n <function-app> --query publicNetworkAccess -o tsv
# Disabled

curl -i https://<function-app>.azurewebsites.net/api/health
```

**Say:** that host name resolves publicly. The request still does not arrive.

**Proves:** this is not a firewall rule that someone could widen, and not an authentication check that a leaked key would bypass. There is no listener on the public internet.

Worth adding: **this also closes the deployment endpoint.** Microsoft documents that the SCM/Kudu site is evaluated after app access, so disabling public access closes both. That has real consequences for CI, which stage 12 comes back to.

---

## Stage 3 — The private endpoint and private DNS

**Show:** Function App → Networking → Private endpoint connections. One connection, state **Approved**, sub-resource `sites`.

Then the DNS:

```powershell
az network private-dns record-set a list `
  -g rg-srclass-demo -z privatelink.azurewebsites.net -o table
```

Two A records — the app and its `scm` host — both pointing at a `10.60.2.x` address.

```powershell
az network private-dns link vnet list `
  -g rg-srclass-demo -z privatelink.azurewebsites.net --query "[].name" -o tsv
```

Two links: primary **and** failover.

**Say:** one private endpoint with the `sites` sub-resource covers both the application and its deployment endpoint. The zone is linked to both virtual networks deliberately.

**Proves:** the name resolves to a private address *inside your network*. And because Power Platform resolves names using the DNS of the virtual network its delegated subnet runs in, linking the zone to both networks is what keeps the demo working after a Power Platform regional failover. This is the single most common cause of "it worked yesterday" in real deployments.

---

## Stage 4 — The Power Platform VNet configuration

**Show:** the delegated subnets.

```powershell
az network vnet subnet show `
  -g rg-srclass-demo --vnet-name vnet-srclass-demo-primary -n snet-powerplatform `
  --query "delegations[].serviceName" -o tsv
# Microsoft.PowerPlatform/enterprisePolicies
```

Then the enterprise policy:

```powershell
az resource list -g rg-srclass-demo `
  --resource-type Microsoft.PowerPlatform/enterprisePolicies -o table
```

Then Power Platform admin center → **Security** → **Data and privacy** → **Azure Virtual Network policies**, showing the environment bound to the policy.

**Say:** this subnet is delegated to Power Platform and is dedicated to it — nothing else can be placed in it. There are two of them, one in each Azure region of our Power Platform region pair, because an environment can fail over between them without any action from us.

**Proves:** Power Platform connector workloads for this environment execute **inside your virtual network**, subject to your network policy, and can therefore reach resources that have no public address. This is the mechanism that makes the whole demo possible.

---

## Stage 5 — The Power App

**Show:** the Secure Request Classifier app in Power Apps.

**Say:** a plain form. Six fields and a button. This is deliberately the least interesting part.

**Proves:** the maker experience is unchanged. There is no gateway to install, no special SDK, no custom code in the app. From the maker's point of view they are calling an ordinary flow.

---

## Stage 6 — Submit a request

**Show:** fill in a realistic request, for example:

| Field | Value |
| --- | --- |
| Requester name | Priya Sharma |
| Requester email | *your own address* |
| Request title | Laptop will not power on after the update |
| Category | IT |
| Impact | High |
| Description | Nothing happens when I press the power button. |

Select **Submit**.

**Say:** watch for the result card.

**Proves:** nothing yet — but this is the request that the next four stages trace.

---

## Stage 7 — The Power Automate run

**Show:** Power Automate → **Classify and Notify** → run history → the run that just completed. Expand each action.

**Say:** the trigger received the six inputs. `Invoke_classification_API` called the private Function. `Parse_classification_response` shows the JSON that came back. `Send_confirmation_email` sent the mail.

**Proves:** the flow ran to completion with **no gateway**, **no public endpoint** and **no stored secret**. Point at the connector name: *HTTP with Microsoft Entra ID (preauthorized)*. That connector is on Microsoft's supported-services list for VNet support, which is why its traffic egresses from the delegated subnet. The plain HTTP action is not on that list and would not have worked.

---

## Stage 8 — The private invocation itself

**Show:** expand `Invoke_classification_API`. The URL is `https://<function-app>.azurewebsites.net/api/requests/classify` — the same host name that failed in stage 2.

Then, from the terminal:

```powershell
pwsh ./scripts/Invoke-PrivateConnectivityProbe.ps1 -ResourceGroupName rg-srclass-demo
```

This runs two probes side by side: one from the public internet (must fail) and one from a container placed in the demo's own subnet (must succeed, and prints the private IP it resolved).

**Say:** the same URL, two different network positions, two completely different outcomes.

**Proves:** this is the crux of the demonstration. It is not that the call is authenticated — it is that from outside your network there is nothing to authenticate *to*.

---

## Stage 9 — The Function response

**Show:** the parsed JSON from the flow run.

```json
{
  "requestId": "SRC-20260916-3F7A2B91",
  "status": "Accepted",
  "priority": "P1",
  "priorityRank": 1,
  "assignedTeam": "Digital Workplace Support",
  "normalizedCategory": "IT",
  "normalizedImpact": "High",
  "targetResponseDate": "2026-09-16T14:00:00+00:00",
  "slaBusinessHours": 4,
  "classificationReason": "Category 'IT' with 'High' impact maps to P1; P1 carries a 4 business-hour response target.",
  "correlationId": "…"
}
```

**Say:** the rules are deterministic — a category-by-impact matrix, a fixed SLA per priority, and a business-hours calculation that skips weekends. No AI, no database, no external call. 98 unit tests pin this behaviour.

**Proves:** the application is intentionally small so the architecture is the thing under discussion. Show `src/function/SecureRequestClassifier.Functions/Services/RequestClassifier.cs` if anyone asks — it is one readable file.

---

## Stage 10 — The email arrives

**Show:** the confirmation email in Outlook, with the request ID, priority, assigned team and response target.

**Say:** sent by the Office 365 Outlook connector using the requester's own identity.

**Proves:** the round trip completes in a normal Microsoft 365 experience. There is no bespoke notification service and no additional infrastructure.

---

## Stage 11 — The repository

**Show:** the GitHub repository tree.

**Say, pointing at each:**

* `infra/` — every Azure resource, in Bicep, in nine modules. Including the enterprise policy.
* `src/function/` — the .NET 10 Function App and its tests.
* `powerplatform/` — the unpacked solution: the flow definition, the connection references, the environment variables, and the Power Fx source of the app.
* `scripts/` — bootstrap, verification and cleanup.
* `docs/` — architecture, networking, security, identity and a full limitations register.

**Proves:** *"source controlled"* means all of it, not just the application. Nothing about this environment exists only as a click someone made in a portal.

Open `docs/limitations.md` briefly. Say plainly: here is everything that cannot currently be automated, why, and the Microsoft documentation that says so. Customers trust a demo far more when it tells them where the edges are.

---

## Stage 12 — The deployment pipeline

**Show:** Actions → the most recent **Deploy** run, and its job graph:

`validate → build-function → infrastructure → deploy-function → link-enterprise-policy → power-platform → verify`

Open the run summary. It contains the deployment outputs, the function deployment mode, and the verification table.

**Say:** one workflow. Fork the repository, run one bootstrap script, set the variables it prints, and press Run.

**Proves:** the environment is reproducible. Anyone can rebuild it from scratch without tribal knowledge.

Worth calling out the `deploy-function` job's summary text, which explains — with the Microsoft citation — why deploying to a private function app from a hosted runner needs either a network-connected runner or a transient, single-IP deployment window, and which one this run used. Then show the final step:

```
publicNetworkAccess = Disabled
::notice::Function App public network access is Disabled.
```

That assertion runs with `if: always()`. The job fails if the app is left open.

---

## Stage 13 — Federated deployment authentication

**Show:** Microsoft Entra ID → App registrations → *Secure Request Classifier - GitHub deployment* → **Certificates & secrets**.

**Empty.** No client secrets, no certificates.

Then → **Certificates & secrets** → *Federated credentials*. Three entries:

| Name | Subject |
| --- | --- |
| `github-branch-main` | `repo:<owner>/<repo>:ref:refs/heads/main` |
| `github-pull-request` | `repo:<owner>/<repo>:pull_request` |
| `github-environment-demo` | `repo:<owner>/<repo>:environment:demo` |

**Say:** when the workflow runs, GitHub mints a short-lived OIDC token whose subject is one of those exact strings. Entra ID exchanges it for an Azure access token. There is no long-lived credential to steal, and the trust is scoped to this repository, this branch and this environment.

Show the workflow step:

```yaml
- uses: azure/login@v3
  with:
    client-id: ${{ vars.AZURE_CLIENT_ID }}
    tenant-id: ${{ vars.AZURE_TENANT_ID }}
    subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

`vars`, not `secrets`. A client ID is an identifier.

**Then the part people do not expect** — the Power Platform import step:

```yaml
- uses: microsoft/powerplatform-actions/import-solution@v1
  with:
    app-id:    ${{ vars.POWER_PLATFORM_APP_ID }}
    tenant-id: ${{ vars.POWER_PLATFORM_TENANT_ID }}
    # client-secret intentionally omitted -> workload identity federation
```

The Power Platform CLI supports `--githubFederated`, so Dataverse authentication is federated too.

**Proves:** the *entire* deployment path — Azure and Power Platform — is secretless.

---

## Stage 14 — Prove the absence

**Show:** Settings → Secrets and variables → Actions.

* **Secrets** tab: empty.
* **Variables** tab: identifiers only — tenant ID, subscription ID, client IDs, environment URL, connection IDs.

Then the CI job that enforces it. Actions → **CI** → `security-invariants`:

| Check | Enforces |
| --- | --- |
| No workflow references a stored credential | fails the build on any `${{ secrets.* }}` that is not an allow-listed non-credential identifier, and on any secret named like credential material |
| Storage shared key access stays disabled | fails on `allowSharedKeyAccess: true` |
| Easy Auth never references a client secret | fails on a `clientSecretSettingName` assignment |
| Defaults ship with public access disabled | fails if `demo.bicepparam` is weakened |
| No credential-shaped literals anywhere | fails on hard-coded secret material |
| No Function keys | fails on any `AuthorizationLevel` other than `Anonymous` |

Finish with the runtime side:

```powershell
az storage account show -g rg-srclass-demo -n <storage> --query allowSharedKeyAccess -o tsv
# false
```

**Say:** there is no Function key in play — every trigger is anonymous at the Functions layer and Microsoft Entra ID does the gating in front of it. There is no storage key and no SAS, because shared key access is switched off at the account, so no valid SAS can even be constructed. Publishing credentials for SCM and FTP are disabled. Application Insights rejects its own instrumentation key unless the caller also presents a managed-identity token.

**Proves:** the claim is not "we chose not to use secrets". It is "secrets have been made unusable, and CI fails if anyone reintroduces one."

---

## Closing

> This entire demonstration is source controlled. Azure infrastructure, application code, Power Platform components and CI/CD are all represented here. Deployment uses federated identity rather than stored Azure credentials. The backend has no public endpoint. Power Automate reaches it through private enterprise networking, and the entire demo can be deployed — and removed — as one isolated workload.

Then, if they want it gone:

```powershell
pwsh ./scripts/Remove-Demo.ps1 -ResourceGroupName rg-srclass-demo -PowerPlatformEnvironmentId <env-id> -PowerPlatformEnvironmentName srclass-demo
```

---

## Questions you should expect

**"Could someone just re-enable public access?"**
Yes — with Azure RBAC write permission on the site. That is why the deployment identity is `Contributor` + `Role Based Access Control Administrator` rather than `Owner`, why the setting is declared in Bicep so drift is visible, and why the pipeline asserts the end state on every run. In a real tenant you would also add an Azure Policy `deny` and a resource lock.

**"What does this cost?"**
Flex Consumption bills per execution, the storage account and Log Analytics are trivial at demo volume, private endpoints are a small hourly charge each, and the two virtual networks are free. The enterprise policy is free. Realistically a few pounds a month idle.

**"Does the delegated subnet cost anything or slow things down?"**
No charge for the delegation. Latency is a single extra hop inside the Azure backbone.

**"Can this work with an on-premises API instead?"**
Yes — that is the same pattern. Point the connector at a name your VNet DNS can resolve over ExpressRoute or VPN. Power Platform VNet support is explicitly Microsoft's recommended alternative to the on-premises data gateway for supported connectors.

**"What happens to in-flight work when the environment fails over?"**
That is exactly why there are two delegated subnets and why the private DNS zones are linked to both networks. Show stage 3 again.

**"Why not just use the HTTP action?"**
It is not on Microsoft's supported-services list for VNet support. Its traffic would not egress from your delegated subnet, so it could not reach a private endpoint. The `HTTP with Microsoft Entra ID (preauthorized)` connector is the supported one — and it also gives you Entra ID authentication for free.
