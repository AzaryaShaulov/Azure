---
name: vm-sku-retirement-report
description: >-
  Evidence-based Azure VM SKU retirement and upgrade assessment. Scans all accessible subscriptions, finds VMs on
  retired or retiring sizes (Microsoft Learn evidence only, 36-month horizon), recommends the closest
  current-generation same-CPU-vendor replacement, validates regional availability, subscription SKU restrictions and
  VM-family quota (aggregated), scores compatibility 0-100, rates confidence and plans migration waves. Outputs
  Markdown, CSV, JSON and HTML. Read-only. Use when asked about "VM SKU retirement", "retiring VM sizes",
  "which VMs are affected by retirement", "Dv2/Dsv2/Av2/B-series/F-series retirement", "upgrade path for old VM
  sizes", "VM modernization assessment", "replacement SKU", "migration waves", or "quota for VM resize".
  For quota increase requests afterwards use azure-quotas; for general VM sizing/pricing use azure-compute.
license: MIT
metadata:
  version: "1.0.0"
  requires: "PowerShell 7.2+, Azure CLI 2.60+ with the resource-graph extension, Reader role"
---

# VMSKURetirementReport

Read-only assessment engine (PowerShell 7 + Azure CLI) that turns an Azure estate into an auditable retirement and
upgrade plan. **It never changes Azure resources and never guesses** - anything it cannot verify is labelled.

In the commands below, `<skill-dir>` is the folder that contains this `SKILL.md` (for example
`~/.copilot/skills/vm-sku-retirement-report`, `.github/skills/vm-sku-retirement-report` or
`skills/vm-sku-retirement-report`).

## When to use

- "Which of our VMs are on retiring / retired sizes, and by when?"
- "What should each VM move to, and can we do it without a quota increase?"
- "Build a migration wave plan for VM size retirements."
- "Is Dsv3 / Esv4 / Basv2 being retired?" (answer from the evidence, not from age)

Do **not** use for: generic VM right-sizing (use `azure-compute`), filing quota requests (use `azure-quotas`), cost
analysis of actual spend (use `cost-optimization` / `cost-analysis`).

## Prerequisites

| Requirement | Check |
|---|---|
| PowerShell 7.2+ (Windows, Linux or macOS) | `pwsh -v` |
| Azure CLI signed in to the target tenant | `az account show` (else `az login --tenant <tenant>`) |
| Resource Graph extension | `az extension add --name resource-graph` |
| RBAC | **Reader** on the subscriptions. Rightsizing: **Monitoring Reader**. Advisor/Service Health corroboration is best-effort |
| Tests (optional) | In a source checkout, run `Assessments/VMSKURetirementReport/build.ps1 -Task Bootstrap,Test` from the Azure repository root; the repository locks and verifies the exact Pester version |

## Workflow

1. **Confirm scope with the user**: tenant, subscriptions (default: all enabled in the signed-in tenant), regions,
   whether to check every VM for v7/v6 modernization (`--check-modernization`), and whether to include rightsizing
   telemetry (`-IncludeRightsizing`) and PAYGO prices (`-IncludePricing`).
2. **Preflight**: `az account show` - confirm the tenant is the one the user means. If not signed in, ask the user to
   run `az login --tenant <tenant>` (interactive; never automate or handle credentials). The script checks the token
   first and fails within `-AuthTimeoutSec` (default 60) with the exact `az login` command when a cached token has
   expired - on Windows az may otherwise wait indefinitely on a sign-in popup. To assess another signed-in tenant
   without changing the Azure CLI default subscription, pass `-TenantId <tenant-id>`.
3. **Run** the assessment (default output:
   `reports/<tenant>/<UTC yyyy-MM-dd_HHmmss>-<run-id>-VMSKURetirementReport/`, two folders above `<skill-dir>`):

   ```powershell
   pwsh <skill-dir>/scripts/Invoke-VMSKURetirementReport.ps1
   # scoped / optional extras
   pwsh <skill-dir>/scripts/Invoke-VMSKURetirementReport.ps1 `
       -TenantId <tenant-id> -SubscriptionId <id1>,<id2> -Region eastus2 --check-modernization -IncludeRightsizing -IncludePricing
   ```

   Key parameters: `-TenantId`, `-AuthTimeoutSec 60`, `-HorizonMonths 36` (12-120; dated retirements this far out or
   more go to *Beyond Horizon*), `-QuotaSafetyPct 20`, `-MaxCandidates 3` (1 = primary only, 2 = + alternative,
   3 = + third), `--check-modernization` (opt-in v7 then v6 assessment for every VM), `-OfflineCatalog` (use cached
   Microsoft evidence), `-AsOfDate`, `-SkipHtml`, `-ThrottleLimit 6`,
   `-IncludeOperatorAccount` (record the full signed-in account; masked by default), `-KeepRawData` (write raw `data/`).
4. **Report back** from `executive-summary.md` (counts, waves, quota actions) and point the user to `index.html`.
   Answer drill-down questions from `vm-assessment.csv` / `assessment.json`; quote the Microsoft source URL for any
   retirement claim.
5. **Follow-ups**: quota increases -> hand the `quota-impact.csv` rows (`Scope = Retirement` first) to the
   `azure-quotas` skill. Resizes are the customer's change - provide `az vm resize` guidance only when asked and only
   for `Ready` / `HIGH` rows, with the listed validation items.

## Outputs (per run folder)

Outputs contain tenant, subscription and VM identifiers, and resource names can contain people's names. Treat them as
confidential, do not commit them to source control, and delete them when the assessment is no longer needed. The
operator's account is masked (`j****@contoso.com`) unless `-IncludeOperatorAccount` is used.

| File | Purpose |
|---|---|
| `executive-summary.md` | Estate counts, migration waves, groupings, quota actions, data-quality notes |
| `detailed-report.md` | Per affected/unconfirmed VM: current config, retirement evidence, primary + alternative, material differences, considerations, action, data quality |
| `vm-assessment.csv` | One row per VM - the primary assessment table (Power BI / Excel) |
| `candidates.csv` | One row per VM x evaluated candidate, with score breakdown and rejection reasons |
| `quota-impact.csv` | Aggregated demand per subscription/region/family and regional vCPUs, in two scopes |
| `assessment.json` | Versioned structured document (schema in [output-schema.md](references/output-schema.md)) |
| `retirement-evidence.json` | Exact Microsoft evidence used (URLs, git commit, retrieval time) + Advisor/Service Health signals |
| `index.html` + `<subscription>-<id>.html` | Browsable report: summary cards and plain-language bottom line, waves, quota, per-VM recommendation cards, Cross-Vendor Migration Warnings, and collapsed reference sections for SKU families, CPU Vendor from SKU Name, and Known Limitations. Styling lives in `templates/report.css` |
| `run.log` | Console transcript with a minimal header (no local user or machine name); the account is masked unless `-IncludeOperatorAccount` |
| `data/` | Only with `-KeepRawData`: raw VM inventory and Resource SKU responses for audit |

## Rules the skill enforces (do not override when explaining results)

- Retirement status comes **only** from Microsoft sources: Learn *retirements and capacity restrictions* (retired and
  retiring series), the *End of Life* list and the *retired sizes modernization guide*; Advisor
  ServiceUpgradeAndRetirement is corroboration only. **Never invent a date.**
- **Old is not retired.** Age never implies retirement. A series is in a retirement wave only when Microsoft lists it
  with a planned date. Example: Dv3/Dsv3/Ev3/Esv3 were "Product active" until September 2026, when Microsoft announced
  their retirement for 2029-11-15; Ev4/Esv4 have no announced retirement and stay optional modernization (Wave 4).
- Lifecycle rows that are not VM sizes (e.g. Dedicated Host SKUs such as Dsv3-Type1) are reported as context, never
  matched to VM sizes.
- Preserve CPU vendor (Intel->Intel, AMD->AMD, ARM->ARM). Cross-vendor only when no same-vendor size passes, flagged
  **CPU Vendor Change Required** with the reason. **Never cross architecture** (x64 <-> Arm64).
- Candidates must be current generation (not retiring, not End of Life), in the VM's region, and **never smaller**
  than the current vCPU / memory. Disk-throughput reductions are surfaced, lower confidence and trigger a
  capability-preserving alternative.
- Mandatory requirements (Hyper-V generation, disk controller SCSI/NVMe, Premium/Ultra, accelerated networking,
  ephemeral OS, NIC/data-disk counts, Trusted Launch/Confidential, encryption at host, zone) reject a candidate
  regardless of score. Dedicated host, PPG, availability set, VMSS are review items.
- Quota demand is **aggregated** across all VMs moving into the same subscription/region/family; optional
  modernization never inflates the quota needed for mandatory retirements. Quota OK does not mean capacity exists.
- HIGH confidence only when lifecycle, target, vendor, features, region and quota are all verified with no open
  validation item. Unknowns are labelled `Unable to Verify`, never assumed.
- Rightsizing (optional) is a separate column and never changes the retirement recommendation.

Details: [methodology.md](references/methodology.md) | [scoring.md](references/scoring.md) |
[output-schema.md](references/output-schema.md) | [data-sources.md](references/data-sources.md)

## Maintenance

- `scripts/Update-Catalogs.ps1` refreshes `data/retirement-catalog.json` (cached Microsoft evidence) and
  `data/processor-catalog.json` (CPU vendor per series from Learn size pages). Run it when Microsoft updates the
  lifecycle pages or new series ship. Set `GITHUB_TOKEN` to avoid the anonymous GitHub API rate limit.
- A run warning **"Unmapped Microsoft series"** means Learn lists a series with no SKU pattern in
  `data/series-map.json`. Add the pattern (from the Learn size page) - affected VMs stay `Unable to Confirm` until then.
- Tests (offline, mock Azure CLI, no Azure access): `Invoke-Pester -Path <skill-dir>/tests`.
