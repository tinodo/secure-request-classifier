# Security model

Every control in the demo, what it defends against, and where it is expressed in code.

The guiding principle is that a security claim should be **enforced**, not merely **chosen**. Wherever possible the insecure option has been made impossible rather than simply avoided.

---

## Network controls

### The Function App has no public endpoint

```bicep
// infra/modules/function-app.bicep
publicNetworkAccess: publicNetworkAccess   // 'Disabled' by default
```

Disabling this closes the application endpoint **and** the SCM/Kudu deployment endpoint. App access is evaluated before site access, and there is no separate `publicNetworkAccess` for SCM. ([App Service access restrictions](https://learn.microsoft.com/en-us/azure/app-service/overview-access-restrictions))

**Defends against:** internet-originated requests of every kind — reconnaissance, credential stuffing against Easy Auth, exploitation of an application bug, and unauthorised deployment.

### Ingress is a private endpoint only

```bicep
// infra/main.bicep
groupId: 'sites'
subnetId: primaryNetwork.outputs.privateEndpointSubnetId
```

**Defends against:** any request that has not traversed your network. Access restrictions are not even evaluated for traffic arriving over a private endpoint, because such traffic is already inside the trust boundary you control.

### Storage is private and keyless

```bicep
// infra/modules/storage.bicep
allowSharedKeyAccess: false
allowBlobPublicAccess: false
defaultToOAuthAuthentication: true
publicNetworkAccess: 'Disabled'
networkAcls: { defaultAction: 'Deny' }
```

Private endpoints for `blob`, `queue` and `table`.

**Defends against:** exfiltration of the deployment package, tampering with the function payload, and the entire class of "leaked storage connection string" incidents. With shared-key access off, **no valid SAS token can be constructed at all** — the signing key does not work.

### Outbound integration is confined

The Function App's outbound traffic leaves through `snet-functions`, delegated to `Microsoft.App/environments`. It reaches storage over private endpoints.

**Defends against:** a compromised function reaching the internet freely, and data egressing over the public path.

---

## Identity and authentication controls

### Microsoft Entra ID authentication in front of the worker

```bicep
// infra/modules/function-app.bicep — authsettingsV2
globalValidation: {
  requireAuthentication: true
  unauthenticatedClientAction: 'Return401'
  excludedPaths: ['/api/health']
}
identityProviders: {
  azureActiveDirectory: {
    registration: {
      clientId: apiApplicationId
      openIdIssuer: '${environment().authentication.loginEndpoint}${tenantId}/v2.0'
      // No clientSecretSettingName. A pure token validator needs no secret.
    }
    validation: {
      allowedAudiences: ['api://${apiApplicationId}', apiApplicationId]
      defaultAuthorizationPolicy: {
        allowedApplications: allowedClientApplicationIds
      }
    }
  }
}
```

Three separate checks, combined with a logical AND:

1. **Issuer** — the token must come from your tenant's v2.0 endpoint.
2. **Audience** — the token must have been requested *for this API*. A token for Microsoft Graph is rejected.
3. **Allowed application** — the token's `azp`/`appid` claim must be on the list. Only the HTTP with Microsoft Entra ID connector is on it.

**Defends against:** unauthenticated calls from inside the network; token replay from a different audience; a different application in the same tenant calling the API.

**Why no client secret is needed:** a secret is only required for server-directed sign-in, where the app exchanges an authorization code. This API never initiates a sign-in — it returns `401` and stops. `login.tokenStore.enabled` is `false` for the same reason.

### Defence in depth in application code

`ClassifyRequestFunction` re-reads the Easy Auth client-principal header and can enforce its own allow-list via `Classifier__AllowedClientAppIds`. `CallerIdentityReader` degrades a malformed header to **anonymous**, never to trusted.

**Defends against:** a future misconfiguration of the platform layer silently removing the caller check.

### The health endpoint is deliberately excluded

`/api/health` is in `excludedPaths`.

This is a considered trade-off. It lets a probe from inside the virtual network answer *"is the network path working?"* separately from *"is the caller authorised?"*, which is what makes `Invoke-PrivateConnectivityProbe.ps1` a meaningful demonstration. It exposes only a fixed health document containing no business data, and only to callers that are already inside your network — from the public internet it is as unreachable as everything else.

To close it, remove `/api/health` from `authExcludedPaths`.

---

## Credential-elimination controls

This is the part worth dwelling on with a customer. Each row is a credential that **cannot exist**, not one that was merely not used.

| Credential | How it is eliminated | Where |
| --- | --- | --- |
| Azure deployment credential | GitHub OIDC federated identity credential; the app registration has no secret and no certificate | `scripts/Initialize-EntraResources.ps1` |
| Power Platform deployment credential | `pac auth create --githubFederated` — federation is selected by supplying `app-id` + `tenant-id` and omitting `client-secret` | `.github/workflows/deploy.yml` |
| Function key | Every trigger is `AuthorizationLevel.Anonymous`; Entra ID does the gating | `src/function/**/Endpoints/*.cs` |
| Storage account key | `allowSharedKeyAccess: false` | `infra/modules/storage.bicep` |
| SAS token | Impossible — the signing key is disabled | same |
| Storage connection string | `AzureWebJobsStorage__accountName` + `__credential: managedidentity` | `infra/modules/function-app.bicep` |
| Easy Auth client secret | Validation-only configuration, no `clientSecretSettingName` | same |
| SCM / FTP publishing password | `basicPublishingCredentialsPolicies` set to `allow: false` for both | same |
| Application Insights instrumentation key | `DisableLocalAuth: true` plus `APPLICATIONINSIGHTS_AUTHENTICATION_STRING=Authorization=AAD` | `infra/modules/monitoring.bicep` |
| Log Analytics shared key | `features.disableLocalAuth: true` | same |

### Enforced by CI

`.github/workflows/ci.yml` → `security-invariants` fails the build on any of:

* a workflow referencing `${{ secrets.* }}` that is not an allow-listed non-credential identifier, or any secret whose name looks like credential material;
* `allowSharedKeyAccess: true` anywhere in `infra/`;
* a `clientSecretSettingName:` assignment;
* `demo.bicepparam` no longer shipping `publicNetworkAccess = 'Disabled'`;
* `storage.bicep` no longer setting `allowSharedKeyAccess: false`;
* a credential-shaped literal in any source file;
* an `AuthorizationLevel` other than `Anonymous`.

A security property that is not tested is a security property that decays.

---

## Authorisation controls

### The Function App identity is data-plane only

| Role | Scope |
| --- | --- |
| Storage Blob Data Owner | its own storage account |
| Storage Queue Data Contributor | its own storage account |
| Storage Table Data Contributor | its own storage account |
| Monitoring Metrics Publisher | its own Application Insights component |

No control-plane role. It cannot read another resource, create anything, or modify its own configuration. `Test-Deployment.ps1` explicitly fails if this identity is ever granted Owner, Contributor or User Access Administrator.

### The deployment identity avoids Owner

`Contributor` cannot create role assignments — `Microsoft.Authorization/*/Write` is in its `notActions`. The usual fix is `Owner` or `User Access Administrator`. This demo uses **Role Based Access Control Administrator** instead, which holds only `roleAssignments/write`, `roleAssignments/delete` and read — strictly less than either alternative, and purpose-built for constrained delegation.

To tighten further, add an ABAC condition restricting which role definitions may be assigned:

```bash
az role assignment create \
  --assignee-object-id <oid> --assignee-principal-type ServicePrincipal \
  --role f58310d9-a9f6-439a-9e8d-f62e7b41a168 \
  --scope /subscriptions/<sub> \
  --condition-version 2.0 \
  --condition "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {b7e6dc6d-f1e8-4753-8033-0f276bb0955b, 974c5e8b-45b9-4653-ba55-5f855dd0fb88, 0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3, 3913510d-42f4-4e42-8a64-420c390055eb}))"
```

### Federated credentials are narrowly scoped

Three credentials, each pinned to an exact subject:

| Subject | Grants tokens to |
| --- | --- |
| `repo:<owner>/<repo>:ref:refs/heads/main` | the main branch only |
| `repo:<owner>/<repo>:pull_request` | pull-request validation only |
| `repo:<owner>/<repo>:environment:demo` | the `demo` GitHub environment only |

A fork, a different branch or a different repository produces a token with a different `sub` claim, and the exchange fails. Put required reviewers on the GitHub `demo` environment and a human must approve before a token is ever minted.

> **Note for repositories created after 15 July 2026:** GitHub issues *immutable* subject claims that embed numeric IDs, for example `repo:octo-org@123456/octo-repo@456789:ref:refs/heads/main`. If the exchange fails with a subject mismatch, read the actual `sub` from the failed run and update the federated credential.

---

## Application-level controls

| Control | Implementation |
| --- | --- |
| Input validation before any processing | `RequestValidator.Validate` runs first; failures return `400` with `application/problem+json` and a per-field error map |
| Length limits on every free-text field | name ≤ 100, email ≤ 256, title 3–120, description ≤ 2000 |
| Closed enumerations | impact must be Low/Medium/High; an unknown value is rejected rather than guessed |
| No reflection of unvalidated input into a sink | the response echoes only trimmed, normalised values; there is no database, no shell, no file system |
| Structured logging with correlation | every log entry carries `CorrelationId`, `CallerAppId` and `CallerObjectId` |
| No secrets in telemetry | only identifiers are logged; request bodies are not |
| Fail fast on misconfiguration | `ClassifierOptionsValidator` runs at start-up via `ValidateOnStart()` |
| Deterministic, side-effect-free logic | `RequestClassifier` is pure given its inputs, which is why 98 tests can pin it exactly |

---

## Monitoring

Log Analytics and Application Insights are deployed with local authentication disabled on both. A daily ingestion cap of 1 GB keeps demo cost predictable.

Telemetry flows over the public Azure Monitor ingestion endpoint by default. Adding an Azure Monitor Private Link Scope is possible but is **deliberately not** in the demo: AMPLS private DNS zones have tenant-wide effects that conflict with the isolation requirement, and a misconfigured AMPLS silently breaks telemetry. It is called out here so the omission is a visible decision rather than an oversight.

---

## Azure Landing Zone coexistence

The demo is designed to deploy into a governed subscription without fighting it.

| ALZ policy | Effect on this demo | Mitigation |
| --- | --- | --- |
| `Deny-Subnet-Without-Nsg` | **Blocks the deployment outright** — verified against a real ALZ subscription | Handled: every subnet ships with an NSG |
| `Deny-Public-Endpoints` | Blocks the transient deployment window | Set `FUNCTION_DEPLOY_MODE=private-runner` |
| `Deploy-Private-DNS-Zones` (DeployIfNotExists) | Wants to own DNS integration centrally | Set `CREATE_PRIVATE_DNS_ZONE_GROUPS=false`, and `CREATE_PRIVATE_DNS_ZONES=false` if the hub zones already exist |
| `Audit-PeDnsZones` | Audits workload-owned zones | Audit only by default; no action needed |
| `Deny-Public-IP-On-NIC` | No effect | The demo creates no public IP |
| Required-tag policies | May block resource creation | Pass them through the `tags` parameter |

The demo never attempts to modify or bypass a policy assignment.

---

## What this demo does **not** do

Called out so nobody mistakes a demo for a production baseline:

* No Web Application Firewall or DDoS Protection Standard — there is no public ingress to protect.
* No customer-managed keys — the storage account holds only a deployment package.
* No Azure Monitor Private Link Scope (see above).
* No network security groups, NAT gateway or user-defined routes on the delegated subnet. These are supported and are a customer responsibility; they are omitted so the demo's failure modes stay explainable.
* No resource lock or Azure Policy `deny` preventing re-enabling public access. In production, add both.
* No secrets management, because there are no secrets to manage.
