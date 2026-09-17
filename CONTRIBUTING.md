# Contributing

Thanks for your interest. This repository is a demonstration of Power Platform calling a private Azure Function over virtual network support, so contributions are most useful when they keep it accurate, reproducible and honest about its own limits.

## Code of conduct

This project has adopted the [Microsoft Open Source Code of Conduct](CODE_OF_CONDUCT.md).

## Security issues

Do **not** open a public issue for a security vulnerability. Follow [SECURITY.md](SECURITY.md).

## Before you open a pull request

Run the checks locally. They are the same ones CI runs, and they are fast:

```powershell
# Everything agrees with everything else: Bicep outputs, workflow references,
# environment variables, connection references, the README script list.
./scripts/Test-RepositoryConsistency.ps1

# The Power Platform solution packs, and the package is one Dataverse can import.
./scripts/Build-Solution.ps1
./scripts/Test-SolutionPackage.ps1
```

```bash
# Infrastructure builds.
az bicep build --file infra/main.bicep --outfile /tmp/main.json
az bicep build-params --file infra/parameters/demo.bicepparam --outfile /tmp/demo.json

# Function builds and tests pass.
dotnet test
```

## What this repository expects of a change

**No secrets, ever.** Deployment authenticates through GitHub OIDC workload identity federation. There is no client secret, no certificate password and no SAS token anywhere in this repository, and CI asserts it. If a change appears to need one, that is a design discussion first.

**Fail closed.** A missing input should fail a deployment, never silently produce a less secure resource. `apiApplicationId` is the worked example: it used to default to empty, which switched off App Service Authentication entirely.

**Document what cannot be automated.** [docs/limitations.md](docs/limitations.md) records every manual step, why it is manual, and the authoritative Microsoft source for that conclusion. If you automate one of them, delete the entry. If you hit a new one, add it with a citation.

**Keep the claims true.** A comment or document that overstates what the code does is treated as a defect here, not as cosmetic. Several CI checks exist purely to enforce that — for example, the Destroy pipeline may not claim to remove everything while leaving things behind, and the README's script list must match the `scripts/` folder.

**Add a guard with a fix.** When you fix something that CI did not catch, add the assertion that would have caught it, and verify the assertion fails when the old behaviour is restored. `scripts/Test-RepositoryConsistency.ps1` and the `Security invariants` job are the two usual homes for this.

## Commit messages

Explain the problem and the reasoning, not just the change. Say what was observed, why it happened, and what the fix does about it. The existing history is the reference.

## Contributor Licence Agreement

Most contributions require you to agree to a Contributor Licence Agreement declaring that you have the right to, and actually do, grant us the rights to use your contribution. For details, visit [cla.opensource.microsoft.com](https://cla.opensource.microsoft.com).

When you submit a pull request, a CLA bot will automatically determine whether you need to provide a CLA and decorate the PR appropriately. Follow the instructions provided by the bot. You only need to do this once across all repositories using our CLA.

## Trademarks

This project may contain trademarks or logos for projects, products or services. Authorised use of Microsoft trademarks or logos is subject to and must follow [Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/legal/intellectualproperty/trademarks/usage/general). Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship. Any use of third-party trademarks or logos is subject to those third parties' policies.
