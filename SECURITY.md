# Security Policy

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Report them privately through [GitHub Security Advisories](https://github.com/tinodo/secure-request-classifier/security/advisories/new), which lets us discuss and fix the issue before it is public.

If the issue is in a **Microsoft product or service** rather than in this repository's own code, report it to the Microsoft Security Response Center instead, at [msrc.microsoft.com/create-report](https://msrc.microsoft.com/create-report) or by email to [secure@microsoft.com](mailto:secure@microsoft.com). See the [MSRC guidance](https://www.microsoft.com/msrc) and [PGP key](https://aka.ms/security.md/msrc/pgp) for details.

Please include as much of the following as you can, because it decides how quickly the report can be triaged:

* What kind of issue it is — for example privilege escalation, credential exposure, authentication bypass, or a template that deploys an insecure resource.
* The file, workflow or template involved, and the line if you have it.
* Any configuration required to reproduce it.
* Step-by-step reproduction instructions.
* Proof-of-concept or exploit code, if you have it.
* What an attacker gains, and how you think they would use it.

You should get an acknowledgement within three working days.

## Scope

This repository is a **demonstration**. It deploys real Azure and Power Platform resources and is intended to be read, adapted and deployed into environments you control.

In scope:

* Anything that would let an unauthorised party reach the Function App, the storage account, or the Dataverse environment.
* Anything that weakens the deployment identity model — for example a credential, a federated identity credential subject that is broader than it should be, or a role assignment wider than the task needs.
* Any template default that deploys a resource less secure than this repository claims it to be.
* Any secret, credential, or private tenant identifier committed to the repository or written to a workflow log or step summary.

Out of scope:

* The documented, deliberate limitations in [docs/limitations.md](docs/limitations.md). These are known trade-offs with stated reasoning, not undisclosed weaknesses. The `deployment-window` function deployment mode is the most significant one, and `private-runner` exists as the secure alternative.
* Resources you deploy into your own subscription and then configure differently from what this repository produces.

## Security invariants

Several security properties are asserted automatically in CI, in the `Security invariants` job of [`.github/workflows/ci.yml`](.github/workflows/ci.yml), so that a regression fails the build rather than reaching a deployment:

* No workflow may reference a stored credential — this deployment authenticates only through GitHub OIDC workload identity federation.
* No credential-shaped literal may appear anywhere in the repository.
* The Function App and the storage account must ship with public network access disabled.
* Storage shared key access must stay disabled, and App Service Authentication must not reference a client secret.
* API authentication must fail closed: `apiApplicationId` is required, so an unset secret fails the deployment rather than deploying an unauthenticated API.
* No federated identity credential may be scoped to `pull_request`, which would bypass the GitHub environment approval gate on a subscription-scope identity.

If you find a way around any of these, that is exactly the kind of report we want.
