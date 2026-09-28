# Resuming work on this project

Written 28 September 2026, at the end of the session that took the demo from broken to verified.
Read [AGENTS.md](AGENTS.md) first for the rules and the traps; this file is the state.

---

## Status: complete and working

Nothing is outstanding. The demo was verified end to end on the final build — a flow run reached
the private function and returned HTTP 200, and the requester received the email.

| | |
| --- | --- |
| Branch | `main`, in sync with `origin`, clean tree, no open pull requests |
| Last commit | `8a94a99` — *Finish the polish: no ambient state, no undocumented parameter, no silent path* |
| Deploy | 8/8 jobs green |
| Live verification | **36 passed, 0 failed, 4 warnings** |
| Tests | 103 |
| Consistency checks | 147 |
| Documentation links | 53, all resolving |

The four warnings are expected — see *Known non-issues* in [AGENTS.md](AGENTS.md#known-non-issues).

---

## Where things live

```
C:\Users\tinodo\secure-request-classifier        the repository
    .session/                                    prior working notes, git-ignored
```

Remote: `https://github.com/tinodo/secure-request-classifier` (public).

The repository used to sit under OneDrive. It was moved out because OneDrive holds reparse points
on synced folders, which made directory deletions fail with access-denied during normal work. Keep
it outside OneDrive.

---

## Before you can run anything

The deployment needs values that are **not** in this repository, by design. They live as GitHub
repository secrets, and the bootstrap script prints them when it runs.

| Needed | Where to get it |
| --- | --- |
| Subscription, tenant, client IDs | GitHub → Settings → Secrets and variables → Actions |
| Power Platform environment ID | Power Platform admin centre, or `pac env list` |
| Function app base URL, Application ID URI | The solution's **Environment variables** in the maker portal |

If you need the environment's Dataverse URL, resolve it by display name with
`scripts/Resolve-PowerPlatformEnvironment.ps1` rather than hard-coding it.

---

## What happens after a deploy

**Importing the solution resets the connections and switches the flow off.** This is a Power
Platform behaviour, not a choice this repository made, and it happens on *every* deploy that
touches the solution — not just the first.

Somebody then has to:

1. Open the **Classify and Notify** flow in Power Automate and select **Edit**.
2. On **Invoke classification API**, select the **HTTP with Microsoft Entra ID (preauthorized)**
   connection — not the v2 connector.
3. On **Send confirmation email**, select the **Office 365 Outlook** connection.
4. **Save**, then **turn the flow on**. Saving alone does not enable it.

The connections themselves survive, so this is a pick from a list rather than a sign-in. The first
run after a network change can fail once while Power Platform settles — run it again before
investigating.

**Do not deploy on the morning of a demo.** It undoes the setup.

---

## What was done, and why it mattered

Ten pull requests. The substantive ones:

| # | Problem | Consequence |
| --- | --- | --- |
| 1 | Wrong connector app ID; flow parameters not slash-qualified | Connector could not bind; designer showed empty fields |
| 3 | Pipeline bound connection references | Destroyed the owner's manual bindings on every deploy |
| 4 | App Insights 3.x crashed the isolated worker | Every route returned 404 while build, tests and deploy stayed green |
| 5 | `role-assignment.bicep` ignored its scope parameter | Every "least privilege" grant covered the whole resource group |
| 6 | Docs advertised a `pull_request` federated credential | Recommended the exact privilege escalation the repo removes |
| 7 | `-Force` short-circuited `ShouldProcess` | `-Force -WhatIf` deleted the resource group for real |
| 8 | Deployment window opened public access before restricting it | App briefly reachable from the entire internet |
| 10 | 21 `az` calls used the ambient subscription | A destructive script one stale `az account set` from the wrong estate |

Four audits covered every part of the repository: markdown, C#, security and versions, Bicep, the
17 scripts, the workflows, and the Power Platform solution. Every finding is closed.

---

## If you change something

The seventeen guards exist because each of these bugs survived a review. Before proposing a change:

```powershell
dotnet test
./scripts/Test-RepositoryConsistency.ps1
./scripts/Test-DocumentationLinks.ps1
./scripts/Test-FunctionHostStartup.ps1
```

If you fix a defect, add a guard — and verify it **fails** on the unfixed code before you trust it.

---

## The one thing never explained

The owner's account cannot read the function identity's role assignments, through either the CLI or
a direct ARM query, even though all four `rbac-*` module deployments record `Succeeded` and the app
demonstrably works with shared keys disabled. Almost certainly a directory-read limitation on a
guest account.

`Test-Deployment.ps1` handles it honestly — it reports a warning naming the permission that would
settle it, rather than claiming the grants are missing. The underlying cause was never established,
and it is not blocking anything.

---

## Tearing it down

```powershell
./scripts/Remove-Demo.ps1 `
    -ResourceGroupName            rg-srclass-demo `
    -SubscriptionId               <subscription-guid> `
    -PowerPlatformEnvironmentName srclass-demo `
    -WhatIf
```

Drop `-WhatIf` to do it. It previews correctly, it distinguishes a preview from a deletion, and it
reports what it actually removed rather than what it was asked to remove.

The two Entra app registrations survive by default — they are created by the bootstrap, not by a
deployment, and the deployment one is the identity the pipelines sign in with. Deleting them means
re-running the bootstrap and resetting every repository secret.
