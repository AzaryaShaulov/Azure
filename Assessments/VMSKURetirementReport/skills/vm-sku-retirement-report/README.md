# VMSKURetirementReport

Read-only assessment of the Azure VMs in your tenant that run on VM sizes Microsoft has retired or scheduled for
retirement. It recommends the closest current-generation, same-CPU-vendor replacement, checks regional availability,
subscription restrictions and vCPU quota, and writes an HTML, Markdown, CSV and JSON report. It never resizes,
redeploys or otherwise changes a VM and never requests a quota increase.

This file is part of the skill folder and of the release ZIP. The full documentation, the screenshots and a sample
report are in the source repository:
<https://github.com/AzaryaShaulov/Azure/tree/main/Assessments/VMSKURetirementReport>

> **This tool is provided "AS IS," without warranties or guarantees.** It is independently developed, is not an
> official Microsoft product, and is not supported or endorsed by Microsoft. Findings, retirement timelines, SKU
> compatibility and modernization recommendations are informational only. Verify every recommendation, regional
> availability, quota, price, VM generation, storage compatibility and migration requirement against current official
> Microsoft documentation before you change a production VM.

## Requirements

- PowerShell 7.2 or later on Windows (Linux, macOS and containers are not supported)
- Azure CLI 2.60 or later, signed in to the tenant to assess, with the Resource Graph extension
- **Reader** on every subscription to assess; **Monitoring Reader** as well when you use `-IncludeRightsizing`
- Network access to Azure and Microsoft Learn (`-OfflineCatalog` uses the bundled lifecycle evidence instead)

## Run it

The scripts are not digitally signed. If you extracted a downloaded ZIP with Windows Explorer, unblock the files first
(extracting with `Expand-Archive` after `Unblock-File` on the ZIP avoids this):

```powershell
Get-ChildItem <this-folder> -Recurse -File | Unblock-File
```

Then, from this folder:

```powershell
az login --tenant <tenant-id>
az extension add --name resource-graph
pwsh ./scripts/Invoke-VMSKURetirementReport.ps1 -OutputPath C:\Reports\vm-sku\run1
Invoke-Item C:\Reports\vm-sku\run1\index.html
```

`-OutputPath` must be a new or empty folder. Add `--check-modernization` for the optional v7/v6 assessment,
`-SubscriptionId`, `-Region` or `-TenantId` to limit the scope, and `-OfflineCatalog` if Microsoft Learn cannot be
reached. `SKILL.md` describes the main parameters; the full list is in the repository README.

## Use it as an agent skill

Copy this whole folder to the skills folder of your agent, for example `.github/skills/vm-sku-retirement-report/` for
GitHub Copilot or `~/.copilot/skills/vm-sku-retirement-report/` for a user-wide install, and ask the agent to run the VM
SKU retirement assessment. The agent reads `SKILL.md` and runs the script next to it.

## What is in this folder

| Path | Contents |
|---|---|
| `SKILL.md` | What the agent (or you) needs to run the assessment, with the main parameters |
| `scripts/` | `Invoke-VMSKURetirementReport.ps1` (the entry point), `Update-Catalogs.ps1` and the modules |
| `data/` | The cached Microsoft retirement evidence, the series map, the processor catalog and the scoring weights |
| `templates/` | The report stylesheet |
| `references/` | Methodology, scoring, output schema and data sources |
| `CHANGELOG.md` | What changed in each version |
| `LICENSE`, `THIRD-PARTY-NOTICES.md` | The MIT license and third-party notices |
