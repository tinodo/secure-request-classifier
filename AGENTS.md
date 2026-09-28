# Working on this repository

Grounding for anyone — human or agent — picking this project up. Read this before changing
anything. `RESUME.md` has the current state; this file has the rules and the traps.

---

## What this is

A public Microsoft demo proving one claim:

> A Power Automate cloud flow can call an Azure Function that has **no public endpoint**, over
> Power Platform VNet support, deployed entirely by GitHub Actions with **no stored credential**.

Everything else — the classification logic, the email — exists to make that claim demonstrable.
The application is deliberately small so the network and identity story is the thing under
discussion.

| Part | Where | What |
| --- | --- | --- |
| Function | `src/function/` | .NET 10 isolated worker, Flex Consumption, 103 tests |
| Infrastructure | `infra/` | Bicep, subscription scope, `main.bicep` + 10 modules |
| Power Platform | `powerplatform/solution/src/` | One cloud flow, 2 connection references, 4 environment variables. **No canvas app** |
| Automation | `scripts/` | 17 PowerShell scripts, all PowerShell 7 |
| Pipelines | `.github/workflows/` | `ci.yml`, `deploy.yml`, `destroy.yml` |

---

## Hard rules

These are not preferences. Each one was learned by breaking something.

1. **Never trigger a workflow run unless explicitly asked.** Deploy re-imports the solution, which
   resets the owner's connections and switches the flow off. Every unrequested run costs them
   manual work.
2. **Never create, bind or automate Power Platform connections.** Both connectors use
   delegated-user OAuth. The pipeline runs as a service principal with no permission on a user's
   connection: binding fails with `ConnectionAuthorizationFailed` *and destroys the working
   binding on the way out*. `deploymentSettings.template.json` has no `ConnectionReferences`
   section, and CI asserts it stays that way.
3. **Microsoft-native tooling only.** Azure CLI, Bicep, `pac`, PowerShell, GitHub Actions. No
   Terraform, no third-party providers.
4. **Never run `az account set`.** It mutates CLI state the whole machine shares. Pass
   `--subscription` on every call instead. CI asserts this.
5. **Never commit a real tenant, subscription or environment identifier.** The repository is
   public. Identifiers live in GitHub **secrets** — not variables — because GitHub masks secrets in
   run logs and does not mask variables. A CI gate rejects any GUID outside an allow-list of public
   Microsoft values.
6. **Do not re-run a command that appears to have failed** until you have checked whether it
   actually succeeded. Several "failures" here were successful operations reported badly.

---

## How to validate

Run these before proposing anything. They are fast and they are the same checks CI runs.

```powershell
dotnet test                                   # 103 tests
./scripts/Test-RepositoryConsistency.ps1      # 147 cross-artefact invariants
./scripts/Test-DocumentationLinks.ps1         # every internal link and anchor
./scripts/Test-FunctionHostStartup.ps1        # starts the real Functions host
./scripts/Build-Solution.ps1                  # packs the Power Platform solution
./scripts/Test-SolutionPackage.ps1            # rejects a package Dataverse cannot import
az bicep build --file infra/main.bicep --outfile $env:TEMP/main.json
```

Against a live deployment:

```powershell
./scripts/Test-Deployment.ps1 `
    -ResourceGroupName          rg-srclass-demo `
    -SubscriptionId             <subscription-guid> `
    -PowerPlatformEnvironmentId <environment-guid>
```

Expect **36 passed, 0 failed, 4 warnings**. The four warnings say role assignments could not be
read with the current credentials — see [Known non-issues](#known-non-issues).

---

## The guard convention

`scripts/Test-RepositoryConsistency.ps1` holds 147 assertions that keep artefacts agreeing with
each other. When you fix a defect here, add a guard for it.

**A guard is only worth having if it fails on the real defect.** Verify both directions: reintroduce
the bug, watch the guard fail, then fix it and watch it pass. Several guards in this file initially
passed on broken code, and two of them failed on their own explanatory comments because they grepped
for a pattern the fix had to describe. Read code, not prose.

---

## Traps that have already cost a day

Each of these looked like something else first.

### The build is green and every route still returns 404

The isolated worker crashes at startup, the host indexes nothing, and only its built-in warm-up
endpoint survives. Build, tests and deployment all stay green, because none of them start the host.

`Microsoft.ApplicationInsights.WorkerService` is **pinned to 2.x on purpose**.
`Microsoft.Azure.Functions.Worker.ApplicationInsights` binds against 2.x, where
`ITelemetryInitializer` lives in `Microsoft.ApplicationInsights.Extensibility`. Version 3.x moved
it, and the worker aborts with `TypeLoadException`. **Do not upgrade it.**

`0 functions found (Custom)` in the logs is **not** a fault — it appears in healthy startups too,
because this project ships no `functions.metadata` and the custom provider legitimately finds
nothing before worker indexing finds everything. Judge by whether `Found the following functions:`
follows.

### Role assignments look missing when they are not

`az role assignment list --assignee` resolves the principal through Microsoft Graph first. A caller
who can read ARM but not the directory gets an **empty list rather than an error**, so correct
infrastructure reads as missing RBAC.

Listing at a scope returns that scope and everything it *inherits*, never anything below it. These
assignments are scoped to individual resources, so asking at the resource group finds nothing.

### The Power Platform token must not carry a subscription

`az account get-access-token --resource https://service.powerapps.com/` is tenant-scoped. Adding
`--subscription` turns a passing environment-link check into a 404. It is the one deliberate
exception to rule 4, and it is commented where it lives.

### Connections reset on every import

Importing the solution replaces the flow with the version in source control, which has no
connections selected and is switched off. The connections themselves survive — the owner reselects
them, they do not recreate them. Plan for this after any deploy that touches the solution.

### The solution format is not interchangeable

SolutionPackager keeps environment variables and connection references **inline in
`Other/Customizations.xml`**. Power Platform Git integration splits them into folders. `pac solution
pack` tolerates the mix and exits 0; Dataverse then fails the import with a useless error.
`Test-SolutionPackage.ps1` catches it.

Component type **372 is a custom connector**, not a connection reference. Connection references and
environment variable definitions must never appear in `<RootComponents>`.

### Two connectors that look identical

`shared_webcontents` — "HTTP with Microsoft Entra ID (preauthorized)", client
`7ab7862c-4c57-491e-8a45-d52a7e023983` — is the **only** VNet-supported HTTP-style connector.
`shared_webcontentsv2` (`d2ebd3a9-…`) is not. Microsoft's own samples reference the wrong one.

OpenApiConnection parameters use slash notation: `request/method`, `emailMessage/To`. Bare names
bind to nothing and the designer renders empty fields.

### Comments that assert the opposite of the code

The single most productive bug class in this repository. Four separate examples shipped:
`scopeResourceId` documented as scoping an assignment while only feeding `guid()`; a deployment
window documented as never briefly public while being exactly that; an output justified by naming
two consumers that did not exist; four documents advertising a federated credential the bootstrap
deletes.

**Verify the comment against the code.** Confident prose is where the bugs hide.

---

## PowerShell notes

* Every script is PowerShell 7 and declares `#Requires -Version 7.0`. On Windows the default shell
  is still 5.1, where ternaries and `-SkipHttpErrorCheck` are parse errors.
* `Set-StrictMode -Version Latest` is on everywhere. Reading an absent property **throws**, and
  Azure and Power Platform APIs omit properties rather than returning null. Navigate defensively, or
  the "thing is not configured" case becomes a property error instead of a clear message.
* PowerShell 7.4 turns on `$PSNativeCommandUseErrorActionPreference`, so a native command exiting
  non-zero throws while `$ErrorActionPreference` is `Stop`.
* `-Force` must never short-circuit `ShouldProcess` — `$Force -or $PSCmdlet.ShouldProcess(...)`
  makes `-Force -WhatIf` delete for real. Lower `$ConfirmPreference` instead.

---

## Known non-issues

Do not "fix" these.

| Observation | Why it is fine |
| --- | --- |
| `Test-Deployment.ps1` reports 4 warnings about role assignments | The owner's account cannot read them. The grants exist and work — the host runs with shared key access disabled, which is impossible without them. Reported as a warning naming the required permission rather than a failure |
| Every HTTP trigger is `AuthorizationLevel.Anonymous` | Deliberate. App Service Authentication enforces Entra ID in front of the app. There are no Function keys, and CI fails the build if a non-anonymous level appears |
| CI has not run on `main` for a while | CI runs on pull requests only. A push and its PR each published a check run under the same required-context name, and a cancelled one blocked merges outright |
| There is no canvas app | `pac canvas pack` is deprecated and cannot build an `.msapp` from YAML in CI. The flow's PowerApps (V2) trigger renders the form |
| `api.loganalytics.io` times out from the owner's machine | Local network restriction, not Azure. Query telemetry through ARM instead: `POST https://management.azure.com<workspace-id>/query?api-version=2017-10-01` |

---

## Tone

The commit messages and comments here explain **why**, not what, and they name the defect plainly
rather than softening it. Match that. A comment that says "kept for compatibility" when it means
"this crashes without it" is the thing this repository has spent the most time undoing.
