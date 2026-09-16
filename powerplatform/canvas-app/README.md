# Canvas app source

`src/RequestScreen.pa.yaml` is the Power Fx source for the **Secure Request Classifier** app: a
six-field form, a submit button, and a result card.

## Why there is no `.msapp` here

Microsoft's supported source-control mechanism for canvas apps is
[Power Platform Git integration](https://learn.microsoft.com/en-us/power-platform/alm/git-integration/canvas-apps-git-integration),
which stores the app as `.pa.yaml`. The CLI command that would turn that YAML back into a
binary `.msapp` is deprecated, and refuses to run on sources that have not been validated by
opening the app once in Power Apps Studio:

```
Canvas apps packed using yaml SourceCode must be validated first by opening the app for edit
within the Power Apps studio.  -- pac canvas pack
```

So the `.msapp` cannot be produced in CI from a clean clone. This is documented in full, with
citations, in [../../docs/limitations.md](../../docs/limitations.md#1-the-canvas-app-msapp-cannot-be-built-from-source-in-ci).

## What happens instead

`scripts/Build-Solution.ps1` tries `pac canvas pack` on every build. If it fails, it packs the
solution **without** the canvas app and prints the one-time action that fixes it permanently.

The demo still works: the **Classify and Notify** flow uses a PowerApps (V2) trigger, so running
it directly from Power Automate renders the same typed input form and exercises the identical
private network path.

## Adding the binary, once

1. Deploy the solution so the flow exists in the environment.
2. In [make.powerapps.com](https://make.powerapps.com), create a blank canvas app **inside the
   `SecureRequestClassifier` solution** and build the form described in `src/RequestScreen.pa.yaml`.
3. Add the `ClassifyandNotify` flow to the app and wire the Submit button to it.
4. Save and publish.
5. Export and unpack over this repository's solution source:

   ```powershell
   pac solution export --environment <url> --name SecureRequestClassifier --path ./export.zip --managed false
   pac solution unpack --zipfile ./export.zip --folder ./powerplatform/solution/src --packagetype Unmanaged
   ```

6. Commit the resulting `powerplatform/solution/src/CanvasApps/*.msapp` and `*.meta.xml`.

Every subsequent deployment then includes the app automatically. Microsoft's own CoE Starter Kit
commits the `.msapp` binary for the same reason.

## The app's contract with the flow

The Submit button calls:

```powerfx
ClassifyandNotify.Run(
    Trim(RequesterNameInput.Text),
    Trim(RequesterEmailInput.Text),
    Trim(RequestTitleInput.Text),
    CategoryDropdown.Selected.Value,
    ImpactDropdown.Selected.Value,
    Trim(DescriptionInput.Text)
)
```

and reads back `requestId`, `status`, `priority`, `assignedTeam`, `normalizedCategory`,
`targetResponseDate`, `classificationReason` and `correlationId` — the schema declared by the
flow's `Respond_to_the_app` action.
