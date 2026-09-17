# Support

## How to get help

This project is a **demonstration**, maintained on a best-effort basis. It is not a supported Microsoft product and carries no SLA.

**Before opening an issue**, check these — most questions are already answered:

| Question | Where |
| --- | --- |
| Something failed during deployment | [docs/troubleshooting.md](docs/troubleshooting.md), symptom → cause → fix |
| Why is this step manual? | [docs/limitations.md](docs/limitations.md), with citations |
| How do I deploy it? | [docs/deployment.md](docs/deployment.md) |
| How does the network path work? | [docs/networking-model.md](docs/networking-model.md) |
| Which identity can do what? | [docs/identity-model.md](docs/identity-model.md) |
| What is actually verified, and how? | [docs/verification.md](docs/verification.md) |

A deployment failure usually reports its own cause. In particular, the `Deploy Power Platform solution` job reads the real reason for a failed solution import out of Dataverse, because `pac solution import` reports every asynchronous failure as the unhelpful "An unexpected error occurred".

## Filing an issue

Open a [GitHub issue](https://github.com/tinodo/secure-request-classifier/issues) for bugs and feature requests. Please include:

* What you expected, and what happened instead.
* The failing workflow run, job and step, or the script and its output.
* Whether you changed any repository variable or secret from the documented defaults.

Redact tenant IDs, subscription IDs, environment URLs and anything else specific to your tenant. This repository deliberately treats those as secrets, and an issue is public.

## Security issues

Do **not** open a public issue. Follow [SECURITY.md](SECURITY.md).

## Microsoft product support

If the problem is with Power Platform, Azure Functions, virtual network support or another Microsoft product rather than with this demonstration's code, raise it through the normal support channel for that product — this repository cannot action it:

* [Azure support](https://azure.microsoft.com/support/options/)
* [Power Platform support](https://learn.microsoft.com/power-platform/admin/get-help-support)
