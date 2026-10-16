# Repository Audit — VMSKURetirementReport and parent repository

> **Status: read-only audit.** No application code, scripts, templates, schemas, dependencies or generated reports were
> modified. This document is the only artifact added to the repository. Nothing in the remediation plan has been applied.
>
> | | |
> |---|---|
> | **Audit date** | 2026-10-16 |
> | **Revision** | r2 — adds AUD-033 and AUD-034 after the GitHub Actions run history was checked (r1 had only read the workflow files) and corrects the CI and build ratings. r3 — runs the fault-injection scenarios: AUD-007 and AUD-013 become Confirmed, AUD-013 is re-rated from Medium to Low, and AUD-007 and AUD-016 gain executed evidence. |
> | **Repository** | `AzaryaShaulov/Azure` (monorepo, 152 tracked files, no submodules) |
> | **Baseline** | branch `modernizationv6`, HEAD `0b4e8a3`, plus 23 **staged, uncommitted** changes (the review-fix batch). `git status` was identical before and after the instrumented test run. |
> | **Primary scope** | `Assessments/VMSKURetirementReport` — tool v1.2.0 (PowerShell 7.2+, read-only Azure VM SKU retirement and modernization assessment) |
> | **Secondary scope** | AVD, azure-arc, AzureDashboards, AzureWorkbooks and `.github` — static checks only (links, secrets, references, structure) |
> | **Remediation scope** | In scope: the VM tool, the root files and `.github`. **Out of scope by owner decision (2026-10-16):** `AVD`, `azure-arc`, `AzureDashboards`, `AzureWorkbooks` — their findings stay in the register for the record but are not scheduled. |

## How to read this document

**Path shorthand** used in tables: `SKILL` = `Assessments/VMSKURetirementReport/skills/vm-sku-retirement-report`,
`MOD` = `SKILL/scripts/modules`, `TESTS` = `SKILL/tests`. Other paths are relative to the repository root.

| Term | Meaning |
|---|---|
| **Executed** | I ran the check during this audit and the result is stated as observed. |
| **Code-read** | Verified by reading the cited lines; not executed. |
| **Not tested** | Could not be run here; the validation matrix says what is required. |
| **Confirmed / Probable / Needs validation** | Confirmed = reproduced or proven by the cited evidence. Probable = follows from the code but was not executed. Needs validation = depends on external facts (Azure behaviour, Microsoft documentation). |
| **Critical** | Silent wrong or unsafe outcome on a common path, or a security exposure. **None found.** |
| **High** | Silent, deterministic or order-dependent error in the core recommendation path, or a defect that disables the verification or release path. |
| **Medium** | Real defect with limited reach, or a contract/documentation break that affects integrators or operators. |
| **Low** | Hygiene, minor inconsistency, optional hardening. |

> **Method note.** Five automated read-only reviews produced leads; every lead was re-verified against the code before it
> was kept. Ten leads were refuted or downgraded and are listed in [Appendix A](#appendix-a--refuted-and-unsubstantiated-claims).
> One of them (a "literal `******` Authorization header") was a **tool-output masking artefact**, not a defect — a hex
> dump of the raw bytes shows `"Bearer $tok"` / `"Bearer $token"`. Anyone re-reading this code through a tool that masks
> secrets will see the same artefact.

---

## 1. Repository Audit Summary

### Verdict

* **The VM SKU Retirement tool works as one coherent system on its main path.** Collection → lifecycle classification →
  candidate selection → quota → readiness/confidence → artifacts is connected end to end, the 221-test suite passes locally (never in CI — see below),
  the committed sample matches a fresh regeneration (only `generatedUtc` differs), the 20 summary KPIs reconcile with the VM rows, and a
  static scan found **no mutating Azure call and no secret**.
* **It is not yet fully reliable in its edges.** One **High** defect (an incomplete candidate-cache key makes results
  order-dependent), several **Medium** accuracy and contract issues (hidden larger sizes, vendor heuristic, "Ready" despite
  open reviews, KPIs that disagree with the detail rows, JSON shape that breaks for single-subscription tenants), and
  untested I/O boundaries.
* **The safety net is not working.** CI has failed on every recorded run since the first push (6 of 6): the tool-hash
  lock cannot be verified on a clean runner on any operating system, and the PowerShell 7.2 job references a container
  tag that no longer exists (AUD-033, AUD-034). The 221 tests have so far only ever run on the owner's machine, and the
  tag-triggered release workflow would fail the same way.
* **The parent repository is not yet one consistent system.** Eleven references still point to repositories that no
  longer exist (including links embedded in AVD alert e-mails), the documented dashboard file name does not exist, the
  root `SECURITY.md` is empty, and licensing is per-folder only. The four component folders are outside the agreed
  remediation scope; the root-level items are not.

**34 findings: 0 Critical · 2 High · 12 Medium · 20 Low.** Full register in [section 3](#3-findings-register).

### Scorecard

| Area | Rating | Basis |
|---|---|---|
| Core assessment logic | **Fair → Good** | Sound design and explicit gates; AUD-001 (High), AUD-002/003/006/022 shape the "overly confident" cases |
| Data collection and resilience | **Fair** | Good retry/fallback and graceful degradation (executed); failure *causes* are not persisted and a missing SKU catalog hides the VM detail panels (AUD-007); malformed quota JSON prints an unwrapped error but the run completes (AUD-013) |
| Output and schema contract | **Fair** | Object key sets match the documentation; array/typing and KPI-semantics problems (AUD-004/005/014/016) |
| Documentation (VM tool) | **Good** | Parameters complete, versions consistent, disclaimers present; small schema omissions (AUD-017) |
| Documentation (other components) | **Needs work** | Stale repo URLs, wrong file names, 2 broken links (AUD-009/010/028); these folders are excluded from remediation |
| Tests and CI | **Pipeline broken; good local breadth** | CI failed on 6 of 6 recorded runs (AUD-033, AUD-034); 221 tests pass locally at 72.2 % in-process command coverage; REST/paging/rightsizing/fault paths untested (AUD-008) |
| Security | **Good** | 0 secret-pattern hits, 0 mutating calls, tokens memory-only; policy file missing at repo root (AUD-011) |
| Build, packaging, release | **Fair** | SHA-pinned actions and a verified checksum, but the module-hash lock does not reproduce on clean runners, so the release workflow would fail at tag time (AUD-033); minor packaging hygiene (AUD-025/026/027) |

### Top findings (fix first)

1. **AUD-033 (High)** — CI has never passed: the Pester / PSScriptAnalyzer tree-hash lock fails on all three runners and every test job stops in Bootstrap, so no test runs in CI and no release can be built. *Reproduced locally and in 3 inspected CI runs.*
2. **AUD-001 (High)** — candidate-cache key omits `DedicatedHostGroupId`; a dedicated-host VM can be reported `Ready`/`HIGH`
   with no Dedicated Host gate, and the result flips with VM enumeration order. *Reproduced.*
3. **AUD-002 (Medium)** — only the smallest size per series is gated; larger valid sizes are never tried. *Reproduced.*
4. **AUD-006 (Medium)** — availability-set and scale-set members still show "Proceed with Resize (change window)". *Reproduced.*
5. **AUD-003 (Medium)** — CPU vendor falls back to a naming heuristic that ignores confidence; `Standard_HB60rs` resolves as Intel. *Reproduced.*
6. **AUD-005 / AUD-004 (Medium)** — single-group `By*` blocks serialize as objects; "Modernize to v6" KPI is 0 while 5 of 7 VMs show a v6 path. *Reproduced.*
7. **AUD-007 (Medium)** — SKU/quota retrieval failures never reach the report: affected VMs show `Manual Review Required` / `LOW` with no stated cause, and with no SKU data the HTML renders no detail panels. *Reproduced (fault-injection runs).*
8. **AUD-034 (Medium)** — the PowerShell 7.2 CI job references a container tag that does not exist (`7.2-ubuntu-22.04` does), so the stated minimum version is never verified.
9. **AUD-009 / AUD-010 / AUD-011 (Medium)** — stale repo links in AVD alert e-mails and the Arc dashboard, wrong dashboard file name, empty root `SECURITY.md`. (AUD-009 and AUD-010 are in folders the owner excluded from remediation; AUD-011 is not.)

### What is working (verified, do not change unnecessarily)

* **Read-only by construction** — scan of `SKILL/scripts` found no `PUT/PATCH/DELETE`, no mutating `az` verb, no `Invoke-Expression`; the only POSTs are Resource Graph and Azure Monitor queries.
* **Relocation is clean** — no hard-coded local paths (`C:\…`, `/Users/…`, user name) in the project; Copilot `applyTo`, workflows and `build.ps1` use project-relative paths.
* **Reproducible sample** — regenerated with the build's offline settings: 6 of 9 files byte-identical, the other 3 differ only by `generatedUtc`.
* **Contract tests** — the CSV header (87 original columns + 1 appended) is pinned; schema object key sets match the generated JSON (only `LifecycleStage` is undocumented).
* **Defensive evidence handling** — zero-row guards on all three Learn pages, cached-catalog fallback with a visible warning and `Partially Verified` quality, unmapped series surfaced as `Unable to Confirm`.
* **Honest limits** — physical capacity, nested virtualization and temp-disk usage are always `Unable to Verify`; the independent-tool disclaimer is in the JSON, both Markdown reports and every HTML page (CSVs intentionally carry none).
* **Supply chain (partly)** — Actions pinned by SHA with least-privilege tokens; release ZIP checksum verified (`2170836d…97cc`). The Pester / PSScriptAnalyzer version pin works, but its tree-hash check does not reproduce on clean runners (AUD-033).

---

## 2. Component and Dependency Map

### 2.1 Parent repository

| Folder | Tracked files | Purpose | Automation | Audit depth |
|---|---:|---|---|---|
| `Assessments/VMSKURetirementReport` | 64 | VM SKU retirement and modernization assessment (v1.2.0) | CI + release workflows (both failing, AUD-033/034), Pester | **Deep** |
| `AVD` | 54 | Azure Virtual Desktop diagnostics, alerts, Logic App e-mail, insights KQL and runbooks | none | Static (secrets, references, links) |
| `azure-arc` | 12 | Arc-enabled servers dashboard JSON, images, ESU guidance fragment | none | Static |
| `AzureDashboards` | 5 | Azure Update Manager dashboard (7/14/30-day) | none | Static |
| `AzureWorkbooks` | 5 | Arc SQL migration assessment workbook | none | Static (valid JSON) |
| `.github` | 8 | 2 workflows, issue/PR templates, Dependabot (Actions), `QA-agent.agent.md` | — | Reviewed |
| Root | — | `readme.md`, `SECURITY.md` (2 bytes), `.vscode/` | — | Reviewed |

### 2.2 VM SKU tool — execution chain

```mermaid
flowchart LR
  A[Azure CLI auth + scope<br/>orchestrator :177-208] --> B[Microsoft Learn evidence<br/>Get-RetirementCatalog :242-256]
  A --> C[Inventory via Resource Graph<br/>Get-EstateInventory :263]
  B --> F[Lifecycle classification<br/>Resolve-SkuLifecycle :268]
  C --> F
  C --> D[Resource SKUs per sub/region<br/>Get-SkuCatalogs :280]
  C --> E[Compute usage per sub/region<br/>Get-QuotaUsages :287]
  D --> G[Candidates + gates + scoring<br/>New-VmAssessment :301]
  F --> G
  G --> H[Aggregate quota + choices<br/>Resolve-ModernizationQuotaChoices :316<br/>Measure-QuotaImpact :336-345]
  E --> H
  H --> I[Readiness, confidence, action, wave<br/>Complete-VmAssessment :356]
  I --> R[Rightsizing + retail pricing<br/>opt-in / default :366-390]
  R --> O[Summary + outputs<br/>New-AssessmentSummary :405<br/>Export-* :421-424]
  I --> O
```

| Phase | Function (module) | Source of truth | On failure |
|---|---|---|---|
| Evidence | `Get-RetirementCatalog` (Retirement) | 3 Microsoft Learn pages, parsed from HTML | Throws on zero parsed rows → falls back to cached `data/retirement-catalog.json` with a warning; cached evidence is `Partially Verified` |
| Inventory | `Get-EstateInventory` → `Invoke-ArgQuery` (Inventory) | Azure Resource Graph (REST with tenant token, else CLI) | VM query fails fast; ADE/Advisor/Service Health queries use `-AllowFailure` (AUD-019) |
| SKU data | `Get-SkuCatalogs` → `Get-RegionSkuCatalog` (SkuCatalog) | ARM Resource SKUs REST, fallback `az vm list-skus` | Empty catalog → console warning, VMs get no candidates (AUD-007) |
| Quota | `Get-QuotaUsages` → `Get-QuotaUsage` (Quota) | `az vm list-usage` | `$null` usage → `Quota Information Unavailable` |
| Selection | `Find-ReplacementCandidates`, `Test-CandidateGates` (Candidates) | SKU capabilities (API) + migration-guide targets + scoring weights | No candidate → `NoCandidateReason` |
| Decision | `Complete-VmAssessment` (Assessment), `Get-MigrationConfidence`, `Get-DeploymentReadiness` (Scoring) | Gate results, quota status, lifecycle | — |
| Outputs | `Export-AssessmentData`, `Export-ExecutiveSummaryMarkdown`, `Export-DetailedReportMarkdown`, `Export-HtmlReports` (Output) | Assessment objects | Pricing failure discards the incomplete region and completes with one warning (tested) |

### 2.3 Module dependency graph

`Common` is imported by every module. Further imports: `Candidates` → `Retirement`, `SkuCatalog`, `Scoring`;
`Assessment` → `Retirement`, `SkuCatalog`, `Candidates`, `Scoring`, `Quota`; `Output` → `Retirement`, `Assessment`.
`Inventory`, `Quota`, `Rightsizing`, `Scoring`, `SkuCatalog` and `Retirement` import only `Common`.
The orchestrator imports all ten modules in one loop (`Invoke-VMSKURetirementReport.ps1:138-140`).

| Module | Responsibility | In-process command coverage | Notes |
|---|---|---:|---|
| `Assessment.psm1` | Per-VM assessment, quota choice, strategy, summary | 88.7 % | AUD-001, 004, 005, 006, 014, 024 |
| `Output.psm1` | CSV/JSON/Markdown/HTML builders | 83.8 % | AUD-004, 015, 018 |
| `Candidates.psm1` | Candidate pool, gates, selection | 83.6 % | AUD-001, 002, 022 |
| `Retirement.psm1` | Learn parsing, lifecycle | 83.4 % | AUD-021 |
| `Quota.psm1` | Usage, aggregate demand, increases | 83.4 % | AUD-013 |
| `Scoring.psm1` | Score, confidence, readiness, wave | 80.3 % | AUD-003, 006 |
| `SkuCatalog.psm1` | Resource SKUs, processor info, prices | 65.0 % | AUD-003, 020 |
| `Inventory.psm1` | ARG paging, VM record | 52.5 % | AUD-019 |
| `Common.psm1` | `az` wrapper, snapshot, helpers | 49.7 % | AUD-013 |
| `Rightsizing.psm1` | Azure Monitor utilization | 27.1 % | AUD-012 |
| `Invoke-VMSKURetirementReport.ps1` | Orchestrator | 0 % in-process (run as a child process by the integration tests) | AUD-007, 008 |

> Coverage is measured **in process** by Pester. Code that runs in the child `pwsh` used by the 36 integration tests, or in
> `ForEach-Object -Parallel` runspaces (`Get-SkuCatalogs`, `Get-QuotaUsages`), is exercised but cannot be instrumented, so
> those figures understate real coverage. Overall: 5,677 of 7,863 commands (72.2 %).

### 2.4 Artifact map

| Artifact | Producer | Consumers / documentation | Verified by |
|---|---|---|---|
| `assessment.json` | `Export-AssessmentData` → `ConvertTo-AssessmentJsonObject` | `references/output-schema.md`; Power BI / Logic Apps / scripts | Integration test; executed key-set and type scan |
| `vm-assessment.csv` (88 columns) | `Export-AssessmentData` ← `ConvertTo-AssessmentRow` | schema doc; Excel | Header order pinned (`TESTS/Integration.Tests.ps1:159-163`) |
| `candidates.csv`, `quota-impact.csv` | `Export-AssessmentData` | schema doc | Executed reconciliation against JSON |
| `retirement-evidence.json` | `Export-AssessmentData` | schema doc | Disclaimer test |
| `executive-summary.md`, `detailed-report.md` | `Export-*Markdown` | people | Integration tests; executed KPI reconciliation |
| `index.html`, `<subscription>-<id>.html` | `Export-HtmlReports` + `SKILL/templates/report.css` | browsers (no scripts) | Executed static id/anchor check (0 issues); cross-browser smoke run before the audit (not re-run) |
| `snapshot/` (opt-in) | `Common.psm1` snapshot helpers | `-FromSnapshot` replay | 6 snapshot integration tests |
| `dist/*.zip` + `.sha256` | `build.ps1 -Task Package` | README download/verify steps; release workflow | Executed checksum match |
| `examples/sample-report/` | `build.ps1 -Task Sample` | README, docs | Executed byte comparison |

### 2.5 Build, CI and release chain

`build.ps1` tasks: `Bootstrap` (locked Pester 6.2.0 / PSScriptAnalyzer 1.24.0, tree-hash verified) → `Lint` → `Version`
(module vs `SKILL.md` vs `CHANGELOG`) → `Test` → `Sample` (offline, fixed as-of `2026-10-05`) → `Package`.
`vm-sku-retirement-report-ci.yml`: PowerShell 7.2 smoke (container) + Lint/Version/Test on Windows, Linux and macOS +
Package. `…-release.yml`: tag `v*.*.*` → verify tag equals tool version → build → `gh release create` with ZIP and checksum.

> **Status (r2).** Neither workflow can currently succeed. In all 6 recorded CI runs the `Lint and test` job stops in
> `Bootstrap` on every operating system (AUD-033) and the PowerShell 7.2 job cannot start (AUD-034). The `Package` job is
> skipped (`needs: test`), and the release workflow runs the same `build.ps1` call, so it has never been triggered and
> would fail. No tag or GitHub Release exists, and `origin/main` still ships only v1.0.0 in `dist/`; v1.2.0 exists only on
> the `modernizationv6` branch.

---

## 3. Findings register

Columns: Finding ID · Severity · Category · Component · File and line · Finding · Evidence · Impact · Recommended fix · Confidence.
"Executed" evidence was produced during this audit; in-memory experiments imported the repository modules and the test
fixtures and wrote nothing to the repository.

### 3.1 High

| ID | Severity | Category | Component | File and line | Finding | Evidence | Impact | Recommended fix | Confidence |
|---|---|---|---|---|---|---|---|---|---|
| AUD-001 | High | Logic | Candidate evaluation cache | `MOD/Assessment.psm1:73-76` (key), `MOD/Candidates.psm1:146` (gate) | The cache key lists `[bool]$Vm.DedicatedHostId` but not `DedicatedHostGroupId`, which the *Dedicated Host* gate also reads. VMs that differ only by host-group placement share one cached evaluation, so the outcome depends on which VM is evaluated first. The key also omits `AcceleratedNicCount` and `DiskControllerReported` (they change only gate text). | **Executed** (in memory, shared cache as in the orchestrator): plain VM first → host-group VM gets **no** Dedicated Host gate and is `Ready` / `HIGH`; host-group VM first → the plain VM inherits the gate and becomes `Manual Review Required` / `MEDIUM`. One cache entry was created (two expected). | A VM on a dedicated host (automatic placement) can be told to "Proceed with Resize". Results differ between runs when Resource Graph returns rows in a different order. | Add `[bool]$Vm.DedicatedHostGroupId`, `DiskControllerReported` and `AcceleratedNicCount` to `$sig`. Add a unit test that reads every `$Vm.<property>` used by `Candidates`/`Scoring` and fails when one is missing from the key. | Confirmed |
| AUD-033 | High | Build / CI | Test-tool integrity lock; CI job "Lint and test" | `build.ps1:38-53` (`Get-ModuleTreeHash`, sort at `:42`), `:55-62` (`Get-LockedModule`), `:66` (check order); `dependencies.psd1:5,10`; `.github/workflows/vm-sku-retirement-report-ci.yml:58-59`, `vm-sku-retirement-report-release.yml:31` | The integrity check that guards the test tooling cannot be satisfied on a clean machine. `Get-ModuleTreeHash` hashes every file under the installed module folder, sorted with the culture-sensitive `Sort-Object FullName`. That tree contains the install-specific `PSGetModuleInfo.xml`, and culture order differs from ordinal order, so the hash can differ between operating systems (consistent with Pester passing on Windows and macOS but failing on Ubuntu). | **Executed.** GitHub Actions history (`gh`): all 6 recorded "VMSKURetirementReport CI" runs failed (4 pushes to `main`, 2 pull requests). In the 3 runs read in detail, "Lint and test" stops in the Bootstrap step with "failed integrity verification" — Pester on Ubuntu, PSScriptAnalyzer on Windows and macOS — the same module on the same OS each time. Local reproduction with four hash variants: the PSScriptAnalyzer lock equals the hash that includes `PSGetModuleInfo.xml` (dated 2026-02-20) and no variant without it matches; the Pester lock equals only the culture-sorted variant. The three `build.ps1` functions and `dependencies.psd1` are identical on `main` and on the branch. | CI has never passed, so no test runs in CI and nothing is validated on Linux or macOS. The "Package skill" job (`needs: test`) is skipped. The tag-triggered release workflow runs the same build (`vm-sku-retirement-report-release.yml:31`) and would fail, so no GitHub Release can be published. | Make the hash platform-independent: sort relative paths with `[StringComparer]::Ordinal` and exclude install metadata (`PSGetModuleInfo.xml`), or verify the package hash (`PackageHash`, see AUD-025) at download time. Recompute both locks and confirm on all three runners. Require a green run before merging to `main`. | Confirmed |

### 3.2 Medium

| ID | Severity | Category | Component | File and line | Finding | Evidence | Impact | Recommended fix | Confidence |
|---|---|---|---|---|---|---|---|---|---|
| AUD-002 | Medium | Logic | `Find-ReplacementCandidates` | `MOD/Candidates.psm1:283-299` (pruning), `:301` (gates run afterwards) | Only the smallest fitting size per series (plus one capability-preserving variant) is gated and ranked. Size-dependent gates (NIC count, data-disk count, zone/Ultra support, restrictions) are never tried on larger sizes of the same series. | **Executed:** a VM with 3 NICs → every candidate rejected on `NIC Count` (max 2) and `Primary` is empty, although `Standard_D8s_v5` (max 4 NICs) is in the catalog and would pass. With `D4ds_v5`, `D4s_v5`, `D4s_v6` restricted, `D8s_v5` is not evaluated either. | False "no valid candidate / Manual Review Required / LOW", or a cross-vendor fallback, when a same-vendor larger size passes. The report does not say larger sizes were skipped. | After gating, retry the next one or two sizes of a series whose smallest size fails a size-dependent gate or availability (bounded, never down-sizing). State "larger sizes not evaluated" in `NoCandidateReason`. | Confirmed |
| AUD-003 | Medium | Logic | CPU vendor classification and confidence | `MOD/Common.psm1:218`, `MOD/SkuCatalog.psm1:172-205`, `MOD/Scoring.psm1:99-124` | When a series is absent from `processor-catalog.json`, vendor comes from the size-name hint (`a` = AMD, `p` = ARM, otherwise Intel). `Get-MigrationConfidence` never reads `VendorQuality`, although its description says CPU vendor must be verified for `HIGH`. | **Executed:** 42 real size names probed — 41 correct, 26 catalog-verified, 16 heuristic. `Standard_HB60rs` (AMD EPYC) resolves as **Intel**. Heuristic names include older F, G/GS, L, M, NC, H, HC, ND and DC sizes. | An AMD VM judged as Intel: vendor preservation is evaluated against the wrong baseline and confidence can stay `HIGH`. | Extend the processor catalog (or add overrides) for older series and refresh via `scripts/Update-Catalogs.ps1`. Add a validation item "CPU vendor not verified" when current or target `VendorQuality` is not `Verified`. | Confirmed |
| AUD-004 | Medium | Consistency | Summary KPIs | `MOD/Assessment.psm1:705-706`, `MOD/Output.psm1:235` | `ModernizeToV7`/`ModernizeToV6` count only VMs whose modernization *status* is `Modernize to vN` (directly resizable). VMs whose strategic target is a convertible v6/v7 size (Gen1→Gen2 or SCSI→NVMe) are not counted. | **Executed** on the sample: both counters are 0 while 5 of 7 VMs have `ModernizationTargetSku = Standard_D4s_v6` (source `Convertible`). The Markdown estate table prints "Modernize to v6 = 0". | The executive summary reads "no v6 modernization" while the VM table and detail blocks show five v6 paths. | Add `ModernizationTargetV6/V7` and `ConvertibleToV6/V7`, or rename the existing two "Direct resize to v6/v7", and document them. | Confirmed |
| AUD-005 | Medium | Schema | `assessment.json` summary | `MOD/Assessment.psm1:689-725`, `SKILL/references/output-schema.md:19`, `examples/sample-report/assessment.json:147-154,219-222` | `& $grp` returns a one-element array that PowerShell unrolls, so with exactly one group the `By*` property is serialized as an **object**, not an array. | **Executed:** in the sample `BySubscription`, `ByRegion` and `ByCpuVendor` are objects; `ByEvidenceClass`, `ByCurrentSku`, `ByRetirementDate` are arrays. The schema documents every `By*` as `[]`. | Array-iterating consumers (Power BI, `jq`, Logic Apps) break or mis-iterate for a single-subscription or single-region tenant — the most common estate. | Return `, @(...)` (or cast to `[object[]]`) from `$grp`; add a test with one group; record it in the CHANGELOG as a contract correction. | Confirmed |
| AUD-006 | Medium | Logic | Readiness and next step | `MOD/Assessment.psm1:316-333`, `MOD/Candidates.psm1:146-151`, `MOD/Scoring.psm1:126-141` | `Review` gates for Availability Set and VM Scale Set (and temp-disk removal) lower confidence but never change readiness; `NextStep` stays "Proceed with Resize (change window)". Only Dedicated Host, Confidential, GPU, vendor change and unconfirmed lifecycle force manual review. | **Executed** (in memory): plain VM → `Ready`/`HIGH`; availability-set member → `Ready`/`MEDIUM`; scale-set member → `Ready`/`MEDIUM`; availability set + scale set (+ Spot, hibernation) → `Ready`/`LOW`. All say "Proceed with Resize (change window)". | An imperative next step for VMs whose resize may need every VM in the set deallocated, or must go through the scale-set model. | Give Availability Set / VMSS reviews their own readiness or next step ("Validate before resize"), or reword `NextStep` whenever confidence is not `HIGH`. | Confirmed |
| AUD-007 | Medium | Dead end / diagnostics | Data-collection failure reporting | `SKILL/scripts/Invoke-VMSKURetirementReport.ps1:281-282,299`, `MOD/Assessment.psm1:307-311`, `MOD/SkuCatalog.psm1:121-125` | When the Resource SKUs call fails, returns invalid JSON or returns nothing, the only signal is one console `Write-Warning`. Every affected VM gets `recommendation = null`, `Manual Review Required`, confidence `LOW` with **empty** `LowReasons`, an empty `QuotaStatus` and `Not Evaluated` data quality, and the HTML renders **no detail panel** for it (`MOD/Output.psm1:1360` keeps only VMs that have a `Candidates` object). Quota retrieval failures (denied, empty, malformed) print **no warning at all**. The REST-to-CLI fallback logs only at `Write-Verbose`. | **Executed** (r3): 7 runs of the orchestrator against the repository mock `az`, one injected fault each; all exited 0 and wrote every output. **SKU API denied, invalid JSON, empty:** 1-2 generic console warnings ("No SKU data returned ... (permissions or provider registration)", plus the parse error for invalid JSON); the Azure error text is never printed (it showed on the console only because the test wrapper writes past stream redirection, as the repository mock does). 0 of 7 VMs have a recommendation, `LowReasons` is empty, HTML detail rows and toggles are 0 (baseline 6 and 6), the HTML shows only its two standard callouts, the Markdown summary only "Offline mode requested", there is no `collectionIssues`, and in the SKU-denied run `quota-impact.csv` and `candidates.csv` are zero-byte files. The generic warning also reaches `run.log`, which the build strips from the published sample. **Quota API denied, empty, malformed:** 0 warnings (malformed prints one unwrapped `ConvertFrom-Json` error); VMs show `Quota Information Unavailable` or `Manual Validation Required`, readiness `Manual Review Required` for all 7 (baseline: 4 `Quota Increase Required`), and `LowReasons` carries only the effect ("Quota could not be validated"), never the cause. | A reader of the HTML/JSON/CSV cannot tell "no recommendation because evidence was missing" from "no suitable size exists", and the expandable details that would explain the status are missing for every affected VM. | Add `collectionIssues[]` (scope, API, message) to `assessment.json`, the Markdown summary and an HTML callout; put the cause into `LowReasons`; render a detail panel for every listed VM, stating the reason when no candidates exist; warn when quota retrieval fails; write header-only CSVs when there are no rows. | Confirmed |
| AUD-008 | Medium | Testing | I/O-boundary coverage | `TESTS/mock/az.ps1:19,36`, `TESTS/Integration.Tests.ps1:504` | The mock refuses subscription-scoped tokens, so the production ARM SKU REST path never runs in tests; Resource Graph always returns `skip_token = $null` (no paging); `-IncludeRightsizing` runs only with zero VMs (the call is skipped); `-QuotaSafetyPct`, `-RightsizingLookbackDays` and `-SkipHtml` appear in no test, and `-HtmlIncludeOptionalModernization` is covered only through its filter helper (`TESTS/VMSKURetirementReport.Tests.ps1:823-825`); the mock has three modes only (token hang, empty inventory, multi-region). | **Executed:** 221/221 pass; in-process command coverage 72.2 % (5,677/7,863). Lowest: `Rightsizing` 27.1 %, `Common` 49.7 %, `Inventory` 52.5 %, `SkuCatalog` 65.0 %. | Regressions in paging, REST retry/fallback, error handling and rightsizing would not fail CI. | Add injectable REST/token seams and mock modes for paging, 429 throttling, denied, malformed and empty responses; add a rightsizing end-to-end test; cover the untested flags end to end. | Confirmed |
| AUD-009 | Medium | Dead end / stale reference | AVD, azure-arc, AzureWorkbooks | `AVD/AVD-AzAlerts/AVD-AzAlerts-Deploy-Alert-LogicApp.ps1:1337-1339`, `AVD/AVD-SessionHost-Insights-Alerts/AVD-Insights-Alerts-Deploy-LogicApp.ps1:803-805`, `azure-arc/files/AzureArc-EnabledServers.json:695`, `AzureWorkbooks/Arc - SQL Migration Assessment/*.workbook:287`, `REPOSITORY:` headers in 6 AVD scripts | Eleven references still point to the pre-consolidation repositories `AzaryaShaulov/AVD`, `…/azure-arc` and `…/AzureWorkbooks`. | **Executed:** a GitHub search for `user:AzaryaShaulov` returns 7 repositories and none of these three. The AVD deploy scripts write the URLs into the alert e-mail HTML; the Arc dashboard tile loads `markdownUri` from the old repository. | Alert Matrix and Runbook links in AVD alert e-mails, and the Arc ESU-guidance tile, return 404; headers mislead. | *Out of remediation scope (owner decision).* Replace with `https://github.com/AzaryaShaulov/Azure/blob/main/AVD/<folder>/<file>` (target files verified to exist) and `…/azure-arc/files/esuguidelines`; add a link check to CI. | Confirmed |
| AUD-010 | Medium | Documentation / config | AzureDashboards, azure-arc | `AzureDashboards/AUM-UpdateStatus-Dashboard/README.md:43,83`, `…/dist/Azure Update Manager-Dashboard-30d.json:532`, `azure-arc/files/AzureArc-EnabledServers.json:824` | The README documents `dist/azure-update-manager-dashboard.json` as the recommended 30-day file; the file is `Azure Update Manager-Dashboard-30d.json` (spaces, capitals). The 7- and 14-day files use `"location": "global"`, while the 30-day and Arc dashboards keep the unresolved placeholder `"INSERT LOCATION"`. | **Executed** (file listing, grep). | The documented import command fails on the stated path; importing the 30-day file as-is needs an undocumented edit. | *Out of remediation scope (owner decision).* Rename to `azure-update-manager-dashboard-30d.json`, fix the README, and set the location or document the replacement step. | Confirmed |
| AUD-011 | Medium | Security process | Root `SECURITY.md` | `SECURITY.md` (2 bytes), `readme.md:46`, `Assessments/VMSKURetirementReport/SECURITY.md` (2,827 bytes) | The root readme sends readers to `SECURITY.md` for vulnerability reporting but the file is empty. The real policy is in a project subfolder that GitHub does not surface. The advisory link in `.github/ISSUE_TEMPLATE/config.yml:4` does work. | **Executed** (`git ls-files`, byte counts: 2 bytes on disk, 1 in git). History: a policy was added in PR #1 on 2026-10-05, removed the same day (`17348ec`), and an empty file was re-added in `0eac1d8`; `origin/main` has the same empty file. | Reporters find no policy at repository level; scope across components is ambiguous. | Move or mirror the project policy to the root `SECURITY.md` and state the scope per component. | Confirmed |
| AUD-012 | Medium | Logic / testing | Rightsizing (`-IncludeRightsizing`) | `MOD/Rightsizing.psm1:67-103` | The suggestion is any same-series size with exactly half the vCPUs and not `LocationRestricted`: no gates, no zone or quota check; constrained-vCPU sizes share the series key and can match; `Select-Object -First 1` over `.Values` is not deterministic; thresholds use the P95 of **hourly averages**. | Code-read. `Get-VmUtilization` 0 % covered, `Get-Percentile` has no direct test, end-to-end only with zero VMs. | A suggested size may fail the gates that govern the migration target; short bursts are hidden by hourly averaging. | Reuse `Test-CandidateGates`, exclude constrained sizes, sort deterministically, add unit and end-to-end tests, document the heuristic. | Confirmed |
| AUD-034 | Medium | Build / CI | CI job "PowerShell 7.2 runtime compatibility" | `.github/workflows/vm-sku-retirement-report-ci.yml:23-26` | The job that is meant to prove PowerShell 7.2 compatibility runs in the container `mcr.microsoft.com/powershell:7.2.24-ubuntu-22.04`. That tag does not exist, so the job fails at "Initialize containers" before any step runs. | **Executed.** The same "manifest unknown" error in all 3 runs read in detail. The Microsoft Container Registry tag list (4,853 tags) has no `7.2.24-ubuntu-22.04` but does have `7.2-ubuntu-22.04` and `lts-7.2-ubuntu-22.04`. | The documented minimum (README badge, `PSScriptAnalyzerSettings.psd1` `TargetVersions = 7.2`) is never verified; the only cross-version check is dead. PowerShell 7.2 left Microsoft support in November 2024. | Use an existing tag pinned by digest (for example `7.2-ubuntu-22.04`) or install a checksum-verified 7.2.x archive on the runner; decide whether 7.2 stays the supported floor. | Confirmed |

### 3.3 Low

| ID | Severity | Category | Component | File and line | Finding | Evidence | Impact | Recommended fix | Confidence |
|---|---|---|---|---|---|---|---|---|---|
| AUD-013 | Low | Reliability | `Invoke-AzJson` / quota retrieval | `MOD/Common.psm1:102-165` (parse at `:142`), `MOD/Quota.psm1:4-33` | `-AllowFailure` covers only a non-zero exit code; malformed JSON from an exit-0 `az` call throws. `Get-QuotaUsage` has no `try/catch` and runs inside `ForEach-Object -Parallel`, so the error is raised per pair and the pair is absent from the usage map. The SKU path handles the same fault with a clean warning (`Get-SkuCatalogs`), so the two paths are inconsistent. | **Executed** (r3, `usage-garbage` run): the run completes with exit 0 and quota becomes `Quota Information Unavailable` or `Manual Validation Required`; the only console output is one unwrapped `ConvertFrom-Json` error record with no subscription or region. | Graceful degradation, but an unexplained raw error; together with AUD-007 the reader cannot tell why quota is missing. Re-rated from Medium after execution. | Wrap the parse in `try/catch` when `-AllowFailure` is set (return `$null`, sanitized message that names the scope); add tests. | Confirmed |
| AUD-014 | Low | Documentation | Summary `By*` denominators | `MOD/Assessment.psm1:689-731` | `ByEvidenceClass`, `ByWave`, `ByMigrationPriority` cover all VMs; `BySubscription`, `ByRegion`, `ByCurrentSku`, `ByRecommendedSku`, `ByCpuVendor`, `ByDeploymentReadiness` cover only VMs with an action. | **Executed:** 7 VMs scanned, `BySubscription` sums to 6. | Totals do not reconcile to `TotalVmsScanned`; undocumented. | State the scope per group in `output-schema.md` or add an `ActionableVms` count. | Confirmed |
| AUD-015 | Low | Terminology | HTML KPI tile | `MOD/Output.psm1:1287` vs `:234`, `MOD/Scoring.psm1:153,185` | The tile "Optional modernization" prints `ModernizationRecommended` (evidence class), while `ModernizationOptional` (action) is a different counter. Capacity-limited previous-generation sizes are counted in the tile yet have action `Plan Migration` and land in Wave 4. | Code-read. | Two numbers under one label family; mandatory-leaning VMs presented as optional. | Rename the tile ("Previous-generation sizes") and align the counters. | Confirmed |
| AUD-016 | Low | Schema | JSON value types | sample `assessment.json` | `strategy.ValidationItems` is `null` for 2 VMs and `TargetComparison` is `null` for 1 (documented as arrays). `materialDifferences[].Current/Target` and `TargetComparison.*` mix string, number, boolean and null in one field (11 paths). | **Executed:** type scan of 940 JSON paths. Fault runs (r3) add: with no SKU data `quota.family` and `quota.regional` are `null`, and `quota-impact.csv` and `candidates.csv` are zero-byte files with no header row. | Typed consumers (Power BI, Parquet) infer inconsistent column types. | Emit `[]` instead of `null` (including `quota.family` and `quota.regional`); write header-only CSVs when there are no rows; stringify heterogeneous values or add typed companions. | Confirmed |
| AUD-017 | Low | Documentation | Schema document | `SKILL/references/output-schema.md:26-28,128` | The `lifecycle` object omits `LifecycleStage` (present in JSON). The text says CSV columns "are written in the order listed", but the grouped table places `CurrentVcpu`/`CurrentMemoryGB` earlier than they appear (39 positional differences). The column **set** is identical (88 of 88). | **Executed.** The integration test pins the real order (`TESTS/Integration.Tests.ps1:159-163`). | Integrations built from the table would mis-order columns. | Add `LifecycleStage`; replace the table with the ordered list or say "grouped by topic". | Confirmed |
| AUD-018 | Low | Reporting | HTML footer | `MOD/Output.psm1:521` | The footer always says "Report generated successfully", regardless of evidence warnings, replayed data or partial collection. | Code-read. | Reads as a quality statement. | Show "Report generated" plus the number of warnings, or remove. | Confirmed |
| AUD-019 | Low | Reliability | Optional Resource Graph queries | `MOD/Inventory.psm1:48,190-195` | With `-AllowFailure` (ADE, Advisor, Service Health) a failure after page 1 returns the partial rows with only `Write-Verbose`. | Code-read. | ADE/Advisor corroboration may be incomplete without notice (effect limited to Info gates and notes). | Warn when a paged optional query is truncated. | Confirmed |
| AUD-020 | Low | Reliability | SKU REST paging | `MOD/SkuCatalog.psm1:111,121-125` | The loop stops after 50 pages without a warning; REST failures fall back silently (`Write-Verbose`). | Code-read. | Theoretical partial catalog; the fallback hides REST problems. | Warn when the cap is reached; record the REST-to-CLI fallback in the run log. | Needs validation |
| AUD-021 | Low | Data currency | Retirement catalog | `MOD/Retirement.psm1:247-250,385-428` | Zero-row guards exist, but a *partial* parse (some rows dropped) is not detected, and the cached catalog has no maximum age (current `generatedUtc` 2026-10-06). Cached evidence is `Partially Verified`, so confidence cannot reach `HIGH`. | Code-read. | Stale or partial evidence may not stand out. | Compare series counts with the cached catalog and warn on regression; warn when the cache is older than a set number of days. | Confirmed |
| AUD-022 | Low | Logic | Primary selection | `MOD/Candidates.psm1:349-369`, `SKILL/references/methodology.md:215` | The "no ageing fallback" rule applies to the secondary; the primary may fall back to an older generation when newer sizes are restricted and still be `Ready`/`HIGH`. | **Executed:** `Standard_D4s_v3` with `D4ds_v5`/`D4s_v5`/`D4s_v6` restricted → primary `Standard_D4ds_v4`, `Ready`/`HIGH`. | An older-generation target with no validation note. | Add a validation item when the primary generation is below the newest offered. | Confirmed |
| AUD-023 | Low | Assumption | Gen1 to Trusted launch upgrade | `MOD/Assessment.psm1:364,390-395` | The redeploy decision rests on a static guest-OS pattern (Windows Server 2016, Debian, CBL-Mariner, Azure Linux). | Code-read; not compared with current Microsoft documentation. | Unlisted unsupported OS/image combinations are reported as "Convertible". | Re-validate the list against Learn each release; surface "guest OS unknown/unsupported" explicitly. | Needs validation |
| AUD-024 | Low | Dead code / semantics | `SafetyPct` and `-QuotaSafetyPct` | `MOD/Assessment.psm1:147-160` | `Resolve-ModernizationQuotaChoices -SafetyPct` is accepted and ignored (analyzer suppression). `-QuotaSafetyPct` only enlarges the *recommended increase*; "Quota OK" ignores thin headroom. | Code-read; AST scan: the only unused parameter among 130 functions. | The parameter can be misread as a safety buffer. | Remove the dead parameter or document the semantics precisely. | Confirmed |
| AUD-025 | Low | Config | Dependency lock | `dependencies.psd1:4,9`, `build.ps1:55-62` | `PackageHash` is recorded but never verified; only `TreeHash` is — and that is the part that fails on clean runners (AUD-033). A package-level hash would be platform-independent. | **Executed** (grep). | Implies an integrity check that does not exist. | Verify it or delete it. | Confirmed |
| AUD-026 | Low | Packaging | Release ZIP | `build.ps1:163-166` | `Copy-Item $skill` ships `tests/` (Pester files, fixtures, mock `az.ps1`) but no README or CHANGELOG; top level holds only `SKILL.md`, `LICENSE`, `THIRD-PARTY-NOTICES.md`. | **Executed:** 35 files, 199,027 bytes; checksum matches. | Customers receive test scaffolding and no readme. | Exclude `tests/`; add the README. | Confirmed |
| AUD-027 | Low | CI | Workflows | `.github/workflows/vm-sku-retirement-report-ci.yml:3-13`, `…-release.yml:3-5` | CI does not run `Sample` (reproducibility) or `tools/browser-smoke.js`; `push` is limited to `main` (pull requests are unfiltered); the release tag filter `v*.*.*` is repository-wide. | Code-read. Sample reproducibility was checked manually (byte-identical). | Sample or HTML drift would go unnoticed in CI. | Add a sample-diff job (ignore `generatedUtc`), an optional browser smoke job, and scope the tag filter. | Confirmed |
| AUD-028 | Low | Documentation | Broken links | `AVD/README.md:76`, `AVD/AVD-SessionHost-Insights/README.md:139` | Both link to `AVD-Insights-Alerts-Runbook.md`; the file is `AVD-hosts-Insights-Alerts-Runbook.md`. | **Executed:** 34 Markdown files scanned, 2 broken relative links. | 404 inside the docs. | *Out of remediation scope (owner decision).* Correct the file name. | Confirmed |
| AUD-029 | Low | Hygiene | azure-arc assets | `azure-arc/images/Azure Arc-enabled Servers.png`, `…-ESU.png`, `azure-arc/files/esuguidelines`, `azure-arc/images/dashbaordready5.jpg` | Two PNGs are unreferenced; `esuguidelines` has no extension and is referenced only through the stale URL (AUD-009); one file name has a typo. | **Executed** (reference search). | Clutter and confusion. | *Out of remediation scope (owner decision).* Remove or rename after AUD-009 is fixed. | Confirmed |
| AUD-030 | Low | Governance | Licences | repo root, `AVD/LICENSE`, `AzureWorkbooks/LICENSE`, project `LICENSE` | No root licence; `azure-arc` and `AzureDashboards` have none; the root readme defers to the individual projects. | **Executed** (`git ls-files`). | Unclear reuse terms for two folders. | *Folder licences are out of remediation scope (owner decision); a root licence remains an open choice.* Add a root licence or one per folder. | Confirmed |
| AUD-031 | Low | Hygiene | QA agent definition | `.github/agents/QA-agent.agent.md:3-4` | The front matter still has template placeholders ("Describe what this custom agent does…"). | Code-read. | Poor agent discoverability. | Fill in `description` and `argument-hint`. | Confirmed |
| AUD-032 | Low | Assumption | Disk-controller default | `MOD/Inventory.psm1:294-296`, `MOD/Candidates.psm1:84-89` | A missing `diskControllerType` is treated as SCSI (the documented platform default) and passes the gate; `DiskControllerReported` never reduces confidence. Every VM in the sample is "not reported". | **Executed** (sample) and code-read. | Low risk; confidence is unchanged when the controller was inferred. | Optional: mention the inference in the confidence tooltip. | Confirmed |

---

## 4. Inconsistency Report

### 4.1 Reconciliations that passed (executed unless noted)

| Check | Result |
|---|---|
| README parameter table vs the script `param` block | 24 of 24 user-facing parameters are documented; `RemainingArguments` is the internal double-dash catch-all (covered by two integration tests). `SKILL.md` is a deliberate subset (it omits `-OutputPath`, `-RightsizingLookbackDays`, `-IncludePricing`). |
| Version | `Common.psm1` = `SKILL.md` metadata = latest `CHANGELOG` = `assessment.json` `toolVersion` = ZIP name = **1.2.0**; no stale `1.1.x` strings outside the CHANGELOG (code-read + grep). |
| Schema object key sets vs generated JSON (`tenant`, `current`, `candidate`, `gates`, `materialDifferences`, `VmQuota`, `QuotaRow`, `strategy`, `modernization`) | Exact match. Only `lifecycle.LifecycleStage` is undocumented (AUD-017). |
| CSV column **set** | 88 of 88 present in both the document and the file; the order statement is inaccurate (AUD-017). |
| Summary KPIs vs `vm-assessment.csv` | 20 of 20 scalar metrics reconcile (affected, retired, urgency buckets, quota, readiness, confidence, …). |
| Quota artifacts | Per scope, the sum of family-row `VmCount` equals the regional-row `VmCount`; 8 CSV rows = 5 family + 3 regional JSON rows; Retirement regional `RequiredVcpu` (4) = sum of per-VM `SteadyStateRegionalRequiredVcpu` (4). No double-counting across the three scopes. |
| Candidates | `candidates.csv` Primary 5 / Secondary 5 / Third 2 = `vm-assessment.csv` `RecommendedSku` 5 / `AlternativeSku` 5 / `ThirdCandidateSku` 2. |
| Disclaimer | Present in `assessment.json`, `retirement-evidence.json`, both Markdown reports, `index.html` and the subscription page; absent from the three CSVs by documented design. |
| Placeholders | 0 placeholder-like values in `vm-assessment.csv`; three columns are empty for every sample row (`VendorChangeReason`, `RightsizingStatus`, `RightsizingSuggestedSku`) because the sample has no vendor change and no rightsizing run. |
| HTML static integrity | 29 + 9 ids with 0 duplicates; 9 + 9 internal hrefs with 0 missing targets; 7 `label for` targets exist; 0 `<script>`, 0 inline handlers; external hosts limited to `learn.microsoft.com` and `github.com`. |
| Local paths after relocation | None in the project; `applyTo: "Assessments/VMSKURetirementReport/**"` in the Copilot instructions matches the current location. |
| Sample freshness | Regenerated with the build's offline settings: 6 of 9 files byte-identical; the other 3 differ only by `generatedUtc`. **No stale artifact.** |

### 4.2 Inconsistencies found

| Topic | Conflict | Where | IDs |
|---|---|---|---|
| Modernization KPI vs detail | Summary says 0 v6/v7 moves; five VMs show a v6 target | `MOD/Assessment.psm1:705-706` vs strategy rows | AUD-004 |
| KPI label vs counter | Tile "Optional modernization" is `ModernizationRecommended`; `ModernizationOptional` is a different count | `MOD/Output.psm1:234,1287` | AUD-015 |
| Wave 4 definition | "Wave 4 is optional modernization and is never mixed with retirement requirements" (`Output.psm1:247`) yet action `Plan Migration` (capacity-limited previous-gen) is placed in Wave 4 | `MOD/Scoring.psm1:153,185` | AUD-015 |
| Summary denominators | Some `By*` groups count all VMs, others only VMs with an action | `MOD/Assessment.psm1:689-731` | AUD-014 |
| JSON shape vs schema | Single-group `By*` objects vs documented arrays; `null` vs `[]`; mixed value types | sample `assessment.json`, `output-schema.md:19` | AUD-005, 016 |
| Confidence description vs behaviour | Description requires verified CPU vendor for `HIGH`; the function never checks vendor quality | `MOD/Scoring.psm1:99-124` | AUD-003 |
| Dependency lock | `PackageHash` recorded but unused; the verified `TreeHash` does not reproduce on clean runners | `dependencies.psd1`, `build.ps1:38-62` | AUD-025, AUD-033 |
| Supported PowerShell floor | README and analyzer settings claim 7.2+; the only CI job that tests 7.2 cannot start | README badge, `PSScriptAnalyzerSettings.psd1`, `ci.yml:23-26` | AUD-034 |
| Repeated default | The safety margin default `20` is repeated in five signatures (orchestrator, `Get-QuotaIncrease`, `New-QuotaImpactRow`, `Measure-QuotaImpact`, `Resolve-ModernizationQuotaChoices`); no conflict today, but a change in one place would not propagate | `MOD/Quota.psm1`, `MOD/Assessment.psm1:159`, orchestrator `param` | observation |
| Other components | Documented file name vs real file; stale repository URLs; wrong runbook link; empty security policy | AUD-009, 010, 011, 028 | — |

---

## 5. Dead-End Analysis

### 5.1 Unused code, parameters and configuration

| Item | Evidence | Verdict |
|---|---|---|
| Functions | AST scan (executed earlier in the audit): 130 functions across modules and scripts; every production function has at least one call site | **No orphaned function** |
| `Resolve-ModernizationQuotaChoices -SafetyPct` | `MOD/Assessment.psm1:147-160` | Dead parameter, kept for compatibility (AUD-024) |
| `PackageHash` | `dependencies.psd1:4,9` | Unused configuration (AUD-025) |
| `RemainingArguments` | orchestrator `param` (line 114) | Intentional: turns `--check-modernization` into a helpful error or the opt-in flag |
| Direct test references | 67 of 128 module functions have no *direct* test reference | Misleading on its own — most run through callers or the end-to-end test; see 5.3 for what truly never runs |

### 5.2 Orphaned and stale artifacts

* Three screenshots (`report-cross-vendor.png`, `report-sku-families.png`, `report-waves.png`) illustrated sections that no longer exist; they are already staged for deletion. The three remaining images are all referenced by `README.md` (lines 17, 55, 60).
* `azure-arc`: two unreferenced PNGs and an extensionless `esuguidelines` file (AUD-029).
* `examples/sample-report/` is current (byte-identical to a regeneration).

### 5.3 Workflows that cannot fully complete, or complete without saying so

| Flow | Outcome | Where information is lost | IDs |
|---|---|---|---|
| Resource SKUs unavailable for a scope | Run completes (exit 0); VMs → `Manual Review Required` / `LOW`; no detail panels; zero-byte `candidates.csv` and `quota-impact.csv` (**executed**) | The cause never reaches an artifact; `LowReasons` empty | AUD-007 |
| Quota API denied, empty or malformed | Run completes; quota `Unavailable`; **no console warning**, except one unwrapped error record for malformed JSON (**executed**) | Cause and scope are never reported | AUD-007, AUD-013 |
| Optional ARG query fails mid-paging | Partial rows returned silently | ADE/Advisor corroboration | AUD-019 |
| Learn page layout changes | Total failure is guarded (throw → cached catalog + warning); a partial parse is not detected | Series dropped silently | AUD-021 |
| `-IncludeRightsizing` with VMs | `Get-VmUtilization` and `Get-Percentile` are **executed by no test** (the zero-VM test skips the call, orchestrator `:367`); any failure is downgraded to a warning (`:376`) | Cause and metrics detail | AUD-012 |
| Pricing failure | Incomplete region discarded, run completes with one warning | None (tested) | — |
| Snapshot record and replay | Tested end to end (6 tests) | None | — |
| HTML interactions | No scripts; "Expand all" is a CSS checkbox; static integrity check clean; cross-browser smoke (14 checks × Edge, Firefox, WebKit) passed before the audit (not re-run) | — | — |
| CI on push and pull request | Fails before any test runs (hash lock; missing 7.2 image); "Package skill" is skipped; the release workflow would fail the same way | The whole cross-platform safety net | AUD-033, AUD-034 |

### 5.4 Information-loss points, collection → report

| Stage | Collected | Lost or not consumed | IDs |
|---|---|---|---|
| Candidate pool | Every size offered in the region | Larger sizes of a series are pruned before gating | AUD-002 |
| Processor lookup | `VendorQuality`, `ArchitectureQuality` | Not used by confidence or readiness | AUD-003 |
| Collection | Failed or empty API calls | Not persisted in any artifact | AUD-007, 019, 020 |
| Inventory | `HyperVGenerationSource` (instance view vs OS disk), `DiskControllerReported` | In JSON only; neither affects confidence | AUD-032 |
| Candidate cache | Per-VM attributes | `DedicatedHostGroupId`, `DiskControllerReported`, `AcceleratedNicCount` ignored by the key | AUD-001 |
| Quota | `-QuotaSafetyPct` | Affects only the recommended increase | AUD-024 |

---

## 6. Functional Gap Analysis

| Feature (where exposed) | State | Gap | IDs |
|---|---|---|---|
| `-IncludeRightsizing` (README, SKILL) | Implemented | No test with VMs; suggestion ignores gates; hourly-average P95 | AUD-012, 008 |
| `-QuotaSafetyPct` (README) | Implemented for the recommended increase | "Quota OK" has no headroom buffer; appears in no test | AUD-024, 008 |
| `-SkipHtml`, `-HtmlIncludeOptionalModernization` | Implemented | `-SkipHtml` appears in no test; the optional-modernization listing is covered only through its filter helper (`Test-HtmlListedVm -IncludeOptional`) | AUD-008 |
| `--check-modernization` convertible paths | Implemented (Gen1→Gen2, SCSI→NVMe, redeploy review) | Summary counters omit convertible targets; guest readiness is text only (documented) | AUD-004 |
| Dedicated Host handling | `Review` gate plus Learn "ADH" entries shown as notes | The host SKU is not evaluated (documented: "verify separately"); the gate can be lost through the cache | AUD-001 |
| Microsoft lifecycle stages | Retired / End of Life / Not End of Life / Unknown | *Current* and *Extended* not distinguished — documented in `Get-LifecycleStage` | by design |
| Capacity, nested virtualization, temp-disk usage, network bandwidth | Always `Unable to Verify` / `Unknown` | Control-plane limits; documented | by design |
| Sorting, filtering, export in HTML | None exist | No gap against the documentation | — |
| AVD alert e-mail links; Arc ESU tile | Implemented | Point to repositories that no longer exist | AUD-009 |
| Update Manager dashboard import (README) | Documented | Wrong file name; unresolved location placeholder | AUD-010 |

---

## 7. Azure VM SKU Retirement and Modernization Logic

### 7.1 Basis of each decision

**Verified** = read from an Azure API in the customer's subscription. **Documented** = a Microsoft platform rule encoded
in the tool. **Assumed** = a tool heuristic or an embedded list.

| Topic | Verified (API) | Documented constraint | Assumed (embedded) | Overconfidence risk |
|---|---|---|---|---|
| Retiring / retired identification | — | Microsoft Learn retired, End-of-Life and migration-guide pages (HTML-parsed) | `series-map.json` (38 series, 14 composite names) maps Learn names to SKU patterns | Partial parse not detected (AUD-021); unmapped series are surfaced, not guessed |
| Dates and lifecycle | — | Learn planned retirement date; `Already Retired` beats a future date (`Retirement.psm1:529`) | Urgency buckets and waves; `-HorizonMonths` | Cached catalog has no age limit (AUD-021) |
| Direct-resize compatibility | VM generation, controller, NICs, disks, premium/Ultra, accelerated networking, ephemeral OS, security type (Resource Graph); target capabilities (Resource SKUs) | Resize may need deallocation or cluster move | Gate set and severity (`Fail`/`Review`/`Info`) | `Ready` despite open reviews (AUD-006) |
| Replacement SKU | Target availability and restrictions | Migration-guide target series | Smallest fitting size per series; score weights; same-vendor preference | Hidden larger sizes (AUD-002); cache key (AUD-001) |
| v5 / v6 / v7 modernization | Same as above | v6/v7 same-family targets | "Two generations behind" optional threshold; v4-or-older heuristic (`methodology.md:134,434`) | Counters (AUD-004) |
| CPU vendor and architecture | Architecture (`CpuArchitectureType`) | — | Vendor from the curated processor catalog, else the name hint | Heuristic ignored by confidence; `HB60rs` (AUD-003) |
| Gen1 vs Gen2 | Instance view, else OS disk (`Inventory.psm1:262-265`) | Gen2-only targets cannot host Gen1 in place | Gen1→Trusted launch OS-support pattern (`Assessment.psm1:364`) | List can go stale (AUD-023) |
| SCSI vs NVMe | `diskControllerType` | Missing value means SCSI | — | Inference not reflected in confidence (AUD-032) |
| Regional availability | `restrictions`, `locationInfo` (Resource SKUs) | — | — | Availability is not capacity; stated as `Unable to Verify` |
| Quota | `az vm list-usage` (family and `cores`) | Resize into another family needs full family quota; same family needs the delta | In-place vs side-by-side model; 20 % margin on recommended increases | `Quota OK` has no buffer (AUD-024) |
| Redeployment | — | — | Static OS pattern | AUD-023 |
| Manual validation | Nested virtualization, temp-disk use, licensing, guest drivers | — | Always flagged `Unknown` / `Review` | Appropriately conservative |

### 7.2 Scenarios that can produce incomplete, misleading or over-confident output

| Scenario | Observed or expected output | Evidence | ID |
|---|---|---|---|
| Dedicated-host (automatic placement) VM evaluated after a plain VM of the same size | `Ready` / `HIGH`, no Dedicated Host gate | Executed | AUD-001 |
| Estate where the smallest fitting size fails a size-dependent gate | "All candidates fail mandatory requirements", no primary | Executed | AUD-002 |
| AMD HPC VM without `a` in the size name (`Standard_HB60rs`) | Treated as Intel | Executed | AUD-003 |
| Availability-set or scale-set member | "Proceed with Resize (change window)" with `MEDIUM`/`LOW` | Executed | AUD-006 |
| Newer sizes restricted for the subscription | Older-generation primary, `Ready` / `HIGH` | Executed | AUD-022 |
| Single-subscription tenant consuming `summary.BySubscription[]` | Object instead of array | Executed | AUD-005 |
| Executive reader of the estate table | "Modernize to v6 = 0" next to five v6 paths | Executed | AUD-004 |
| `Microsoft.Compute/skus/read` denied or provider unregistered | Every VM `LOW` / manual review, no stated cause, no detail panels | Executed | AUD-007 |
| Learn restructures one table (partial parse) | Series silently missing from the catalog | Code-read | AUD-021 |
| `-IncludeRightsizing` on a bursty VM | "Potential Rightsizing Opportunity" with an ungated size | Code-read | AUD-012 |
| Quota used at 99 % after the move | `Quota OK` | Code-read | AUD-024 |

---

## 8. Risk Register

| Risk | Description | Likelihood | Impact | Severity | Findings | Mitigation |
|---|---|---|---|---|---|---|
| R-01 | A dedicated-host VM is told to resize, or results differ between runs | Medium | High | **High** | AUD-001 | Fix the cache key; add the key-completeness test |
| R-02 | Valid same-vendor size missed → false "no candidate" or an unnecessary CPU-vendor change | Medium | Medium | Medium | AUD-002, 022 | Bounded size expansion; disclose skipped sizes |
| R-03 | CPU vendor mis-classified for older series | Low | Medium | Medium | AUD-003 | Extend processor catalog; confidence rule |
| R-04 | Integrations break for single-subscription tenants | High | Medium | Medium | AUD-005, 016, 017 | Force arrays; type tests; correct the schema document |
| R-05 | Executive KPIs contradict detail rows | High | Medium | Medium | AUD-004, 014, 015 | Add strategic-target counters; rename tiles |
| R-06 | Operators act on "Ready" without noticing set or scale-set effects | Medium | Medium | Medium | AUD-006 | Distinct readiness / next-step wording |
| R-07 | Collection problems look like "no suitable size" | Medium | Medium | Medium | AUD-007, 013, 019, 020 | Persist `collectionIssues[]`; harden `Invoke-AzJson` |
| R-08 | Regressions in untested I/O paths ship | Medium | Medium | Medium | AUD-008, 012 | Fault-injection mock, paging and rightsizing tests |
| R-09 | Stale or partially parsed Microsoft evidence | Low | High | Medium | AUD-021, 023 | Catalog regression and age checks; periodic list review |
| R-10 | Broken operator links in AVD alert e-mails and the Arc tile | High | Low | Medium | AUD-009, 028 | Out of remediation scope (owner decision); recorded only |
| R-11 | Documented dashboard import fails | High | Low | Medium | AUD-010 | Out of remediation scope (owner decision); recorded only |
| R-12 | No discoverable vulnerability-reporting policy | Medium | Medium | Medium | AUD-011 | Root `SECURITY.md` |
| R-13 | Sample or HTML drift unnoticed | Low | Low | Low | AUD-027 | Sample-diff and smoke jobs |
| R-14 | Ambiguous reuse terms for two folders | Low | Low | Low | AUD-030 | Folder licences out of remediation scope; a root licence is an open choice |
| R-15 | CI never passes: no cross-platform signal, and no release can be built | High | High | **High** | AUD-033 | Repair the lock check first; require a green run before merging |
| R-16 | The PowerShell 7.2 floor is unverified | Medium | Medium | Medium | AUD-034 | Fix or drop the 7.2 job; decide the supported floor |

---

## 9. Remediation Plan

> **Nothing below has been applied.** Phases are ordered by risk reduction and dependency. Every code phase ends with the
> same regression gate; documentation-only phases need only the link check.

**Scope (owner decision, 2026-10-16):** `AVD`, `azure-arc`, `AzureDashboards` and `AzureWorkbooks` are **not** in scope for
remediation. Their findings (AUD-009, 010, 028, 029 and the folder-level part of AUD-030) stay in the register for the
record; steps 5.1 and 5.2 are therefore not scheduled.

**Regression gate for every code phase:** `./build.ps1 -Task Lint,Version,Test` stays green (221 tests today) and, once step 0.1 is done, CI is green on all three operating systems and PowerShell 7.2; regenerate
the sample (`-Task Sample`) and review the diff — only intended changes; `-Task Package` and verify the checksum; run
`tools/browser-smoke.js` when HTML or CSS changes; add a CHANGELOG entry and update `output-schema.md` when a contract changes.

| Phase | Step | Findings | Change | Tests to add | Depends on |
|---|---|---|---|---|---|
| **0** | Publish this audit | — | Add `docs/REPOSITORY_AUDIT.md` (no code change) | — | — |
| **0b — Safety net** | 0.1 | AUD-033, 034 | Make the module-hash check platform-independent (ordinal sort and no install metadata, or verify the package hash); recompute both locks; replace the missing 7.2 container tag; confirm green on Windows, Linux, macOS and 7.2 | The CI run itself | — |
| **1 — Core correctness** | 1.1 | AUD-001 | Complete the candidate-cache key | Two VMs sharing a cache (both orders); AST test that every `$Vm.<property>` read by `Candidates`/`Scoring` is in the key | — |
| | 1.2 | AUD-005, 016 | `$grp` always returns arrays; `[]` instead of `null` (including `quota.family` and `quota.regional`); header-only CSVs when empty; stringify or type heterogeneous values | JSON-shape tests with 0, 1 and many groups | — |
| | 1.3 | AUD-006, 022 | "Validate before resize" readiness or next step for Availability Set / VMSS; validation item for an older-generation primary | Unit tests using the scenarios in this audit | — |
| | 1.4 | AUD-003 | "CPU vendor not verified" validation item; extend the processor catalog for older series | Data-driven vendor table (the 42-size probe) | Learn access for the catalog |
| **2 — Evidence and diagnostics** | 2.1 | AUD-007, 019, 020 | `collectionIssues[]` in JSON, Markdown and HTML; cause in `LowReasons`; a detail panel (with the reason) for every listed VM; a console warning when quota retrieval fails | Integration tests with the fault shim | — |
| | 2.2 | AUD-013 | Guard JSON parse in `Invoke-AzJson -AllowFailure`; `try/catch` in `Get-QuotaUsage` | Fake-`az` unit tests | 2.1 |
| | 2.3 | AUD-021 | Catalog regression and age warnings | Unit tests with a truncated catalog | — |
| **3 — Selection depth and KPIs** | 3.1 | AUD-002 | Bounded size expansion after gating; disclose skipped sizes | 3-NIC and restricted-smallest scenarios | 1.1 |
| | 3.2 | AUD-004, 014, 015 | Strategic-target and convertible counters; clear tile labels; documented denominators | Integration + sample refresh + HTML check | 1.2 |
| | 3.3 | AUD-012 | Gated, deterministic rightsizing suggestion | Unit + end-to-end with VMs | 2.1 |
| **4 — Test and CI hardening** | 4.1 | AUD-008 | Mock modes (paging, 429, denied, malformed, empty); REST/token seam; cover the untested flags | The new modes themselves | 2.1, 2.2 |
| | 4.2 | AUD-027 | Sample-diff job (ignore `generatedUtc`); optional browser smoke; scope the release tag filter | CI run | 3.2 |
| | 4.3 | AUD-025, 026 | Verify or remove `PackageHash`; exclude `tests/` from the ZIP; add the README | Package test listing the ZIP | — |
| **5 — Documentation and hygiene** | 5.1 | AUD-009, 028, 029 | **Out of scope (owner decision).** Would replace stale URLs and runbook links, remove orphans and add a Markdown link check | — | — |
| | 5.2 | AUD-010 | **Out of scope (owner decision).** Would rename the 30-day dashboard, fix the README and resolve `INSERT LOCATION` | — | — |
| | 5.3 | AUD-011, 030, 031 | Root `SECURITY.md`; agent front matter; a root licence if the owner wants one (folder licences for azure-arc and AzureDashboards are out of scope) | — | — |
| | 5.4 | AUD-005, 014, 016, 017 | Correct `output-schema.md` | — | 1.2, 3.2 |
| | 5.5 | AUD-018, 023, 024, 032 | Footer wording; re-validate the Gen1 OS list; remove or document `SafetyPct`; tooltip note | — | — |

**Dependency chains:** 0.1 → every later phase (CI becomes the validator) · 1.1 → 3.1 · 1.2 → 3.2 → 4.2 · 2.1 → 2.2 → 4.1 · 2.1 → 3.3 · 1.2 + 3.2 → 5.4.

**Compatibility.** AUD-005 changes a JSON shape; consumers that adapted to the object form need a CHANGELOG note. Keeping
`schemaVersion` at `1.0` is reasonable only because the change restores the documented contract; adding fields is additive.

**Keep as is** (verified strengths): the read-only guarantee, same-vendor-first and never-down-size rules, fail-closed gates,
disclaimers, the reproducible sample, SHA-pinned CI and the locked test tooling.

---

## 10. Validation Matrix

### 10.1 Checks performed

| # | Check | Method | Result |
|---|---|---|---|
| V-01 | PowerShell parse of every tracked `.ps1`, `.psm1`, `.psd1` | `Parser::ParseFile` (executed earlier in the audit) | 28 files, 0 errors |
| V-02 | JSON validity of every `.json` and the `.workbook` | `ConvertFrom-Json` (executed earlier) | All valid |
| V-03 | Markdown relative links | Script (executed) | 34 files, **2 broken** (AUD-028) |
| V-04 | Pester suite | `Invoke-Pester` 6.2.0 with coverage (executed) | **221 passed, 0 failed** (36 integration + 185 unit), 142 s |
| V-05 | Command coverage | Pester JaCoCo, in-process (executed) | 72.2 % (5,677 of 7,863) |
| V-06 | Unused code | AST call-site analysis (executed earlier) | 0 orphan functions, 1 unused parameter |
| V-07 | Sample reproducibility | Regenerate with the build's offline settings into a scratch folder; SHA-256 compare (executed) | 6 of 9 identical; 3 differ only by `generatedUtc` |
| V-08 | KPI reconciliation | Recompute from `vm-assessment.csv` vs `assessment.json` summary (executed) | 20 of 20 match |
| V-09 | Quota and candidate artifacts | Script (executed) | Consistent across CSV and JSON |
| V-10 | JSON key sets and value types | Script + Node over 940 paths (executed) | Key sets match; 11 mixed-type paths; 3 shape findings |
| V-11 | CSV header vs documentation | Script (executed) | 88 of 88 columns; order statement wrong (AUD-017) |
| V-12 | HTML static integrity | Node (executed) | 0 issues in 2 pages |
| V-13 | Disclaimer presence | Script (executed) | 6 of 6 required files; none in the 3 CSVs (by design) |
| V-14 | Release package | ZIP listing and SHA-256 (executed) | 35 files; checksum matches; tests shipped (AUD-026) |
| V-15 | Secret scan | `git grep`, 9 patterns plus GUID review (executed) | 0 hits; GUIDs are built-in role ids, placeholders or a portal `queryId` |
| V-16 | Read-only guarantee | Search of `SKILL/scripts` for mutating verbs and `Invoke-Expression` (executed) | 0 hits |
| V-17 | Hard-coded paths after relocation | Search (executed) | None |
| V-18 | Stale repository URLs | `git grep` plus GitHub repository search (executed) | 11 stale (AUD-009) |
| V-19 | Parameter documentation | AST vs README, SKILL, methodology (executed) | 24 of 24 in the README |
| V-20 | CPU vendor resolution | 42 representative size names (executed) | 41 correct; `Standard_HB60rs` wrong (AUD-003) |
| V-21 | Scenario tests | Repository modules plus test fixtures, in memory (executed) | AUD-001, 002, 006, 022 reproduced |
| V-22 | Cross-browser smoke | `tools/browser-smoke.js`, Edge, Firefox, WebKit, 14 checks each incl. 390 px width | **Executed before the audit (same HTML templates); not re-run during it** |
| V-23 | Workflow review (r1) | Code-read of both workflow files | Only AUD-027 found by reading — the run history (V-24) shows the workflows do not work |
| V-24 | CI run history | `gh run list` and `gh run view --log-failed`: all 6 recorded runs; 3 read in detail (executed) | **6 of 6 failed**: "Lint and test" stops in Bootstrap on all three operating systems; the 7.2 job cannot pull its image (AUD-033, AUD-034) |
| V-25 | Hash-lock reproduction | Recompute the module tree hash locally with four variants (executed) | The lock matches only the culture-sorted hash that includes `PSGetModuleInfo.xml` (AUD-033) |
| V-26 | Container image tags | Microsoft Container Registry tag list (executed) | `7.2.24-ubuntu-22.04` is absent; `7.2-ubuntu-22.04` and `lts-7.2-ubuntu-22.04` exist (AUD-034) |
| V-27 | Fault injection | Orchestrator against the repository mock `az` with one injected fault per run: SKU API denied, invalid JSON, empty; quota API denied, invalid JSON, empty; plus a baseline (executed, 7 runs) | All 7 runs exit 0 and write every output. SKU faults hide the cause and the VM detail panels (AUD-007); quota faults print no warning (AUD-007); malformed quota JSON prints one unwrapped error (AUD-013); null arrays and zero-byte CSVs (AUD-016) |

### 10.2 Not tested

| Area | Why | What is required |
|---|---|---|
| Fault injection against a real `az` | The r3 runs used the repository mock, so real `az` error text, exit codes and stderr handling were not exercised | Repeat the six scenarios against a sandbox subscription: an identity without `Microsoft.Compute/skus/read`, and a subscription where the Compute provider is unregistered |
| Live Azure: Resource Graph paging, ARM SKU REST, `list-usage`, Azure Monitor, Retail Prices | Needs credentials and a real estate | Reader (plus Monitoring Reader) on a test subscription |
| Live Microsoft Learn parsing | An offline catalog was used | Run `Update-Catalogs.ps1` and diff against the cached catalog |
| Gen1 → Trusted launch OS-support list and v6/v7 platform constraints | Needs current Microsoft documentation | Compare with Learn guidance (AUD-023) |
| Large estates and throttling | No such data | Synthetic mock with several thousand VMs; measure time and memory |
| PowerShell 7.2, macOS and Linux behaviour | Covered only by CI | Review the latest CI run |
| HTML in browsers without `:has()` | No such browser available | Manual check; the `@supports` fallback shows every block open |

---

## Appendix A — Refuted and unsubstantiated claims

Automated reviews produced these leads; each was re-checked and **not** carried into the register.

| # | Claim | Verdict | Basis |
|---|---|---|---|
| 1 | "The `Authorization` header is the literal `******`" (`MOD/SkuCatalog.psm1:114`, `MOD/Rightsizing.psm1:39`, `MOD/Inventory.psm1:42`) and the derived token/replay claims | **Refuted — tool-output masking artefact** | Hex dump of the raw bytes: `"Bearer $tok"` / `"Bearer $token"`. Tools that redact secrets display `******` |
| 2 | "The release ZIP and checksum are not published" | Refuted | `dist/VMSKURetirementReport-v1.2.0.zip` and `.sha256` exist; checksum matches |
| 3 | "HTML filters, sorting or exports do not work" | Refuted | None exist; the report is script-free by design; static integrity check is clean |
| 4 | "AVD builds and runs a dynamic command" | Refuted | `AVD/AVD-AzAlerts/AVD-AzAlerts-Category-Alerts.ps1:984-994` only prints a copy-and-paste hint; `:196` `catch {}` is deliberate best-effort trace logging |
| 5 | "Quota demand is overwritten across scopes" | Refuted | `MOD/Quota.psm1` keys demand by unique VM id and builds it once per scope call |
| 6 | "Gen1 / NVMe conversion paths end as `Ready`" | Refuted | Such targets receive readiness `Convertible`; `Ready` requires no conversion |
| 7 | "Review and Unknown gates are not consumed by confidence" | Partly refuted | Consumed except *CPU Vendor* and *Nested Virtualization* (`MOD/Assessment.psm1:313`); the real gap is readiness (AUD-006) |
| 8 | "An empty SKU catalog is silent" | Partly refuted | Console warning and `$null` catalog (`orchestrator:281-282,299`); the gap is persistence (AUD-007) |
| 9 | "The Arc SQL workbook is empty" | Refuted | Valid JSON, 93,109 bytes; the empty result came from a quoted non-ASCII path |
| 10 | "CI does not run on `modernizationv6`" | Partly refuted | `pull_request` has no branch filter; only `push` is limited to `main` (AUD-027, Low). The review (and r1 of this audit) missed the larger fact that every CI run fails (AUD-033, AUD-034) |

## Appendix B — Reproducing the executed checks

* **Build gate:** from `Assessments/VMSKURetirementReport`, `./build.ps1 -Task Lint,Version,Test`.
* **Coverage:** run Pester 6.2.0 with `CodeCoverage.Path` set to `scripts/modules/*.psm1` and the orchestrator, output to a scratch path. Expect about 72 %.
* **Sample reproducibility:** run the `Sample` task in a scratch clone and `git diff`; only `generatedUtc` (in `assessment.json`, `executive-summary.md`, `retirement-evidence.json`) should change.
* **Scenario tests (AUD-001, 002, 006, 022):** import the ten modules and the fixtures exactly as `BeforeAll` in `TESTS/VMSKURetirementReport.Tests.ps1` does; evaluate VMs with one shared `-CandidateCache`.
* **Stale URLs:** `git grep -n -E "github\.com/AzaryaShaulov/[A-Za-z0-9_.-]+"` and compare with the repositories the owner actually has.
* **Fault injection (executed in r3, V-27):** save the wrapper below as `az.ps1` in a scratch folder, put that folder first on `PATH`, set `AUDIT_FAULT`, and run the orchestrator with `-OfflineCatalog -SkipPricing -OutputPath <scratch>`. The wrapper's `[Console]::Error` writes bypass PowerShell stream redirection, so the injected error text also shows on the console; a real `az` process would not do that.

```powershell
# az.ps1 - wraps the repository mock Azure CLI and injects one fault chosen by $env:AUDIT_FAULT
$real   = '<repo>/Assessments/VMSKURetirementReport/skills/vm-sku-retirement-report/tests/mock/az.ps1'
$joined = @($args) -join ' '
switch ($env:AUDIT_FAULT) {
    'skus-denied'   { if ($joined -match '^vm list-skus')  { [Console]::Error.WriteLine('(AuthorizationFailed) ...skus/read'); exit 1 } }
    'skus-garbage'  { if ($joined -match '^vm list-skus')  { Write-Output 'this-is-not-json'; exit 0 } }
    'skus-empty'    { if ($joined -match '^vm list-skus')  { Write-Output '[]'; exit 0 } }
    'usage-denied'  { if ($joined -match '^vm list-usage') { [Console]::Error.WriteLine('(AuthorizationFailed) ...usages/read'); exit 1 } }
    'usage-garbage' { if ($joined -match '^vm list-usage') { Write-Output '{ not valid json'; exit 0 } }
    'usage-empty'   { if ($joined -match '^vm list-usage') { Write-Output '[]'; exit 0 } }
}
& $real @args
exit $LASTEXITCODE
```

## Appendix C — Decisions for the owner

1. **Location of this document.** Published at `Assessments/VMSKURetirementReport/docs/REPOSITORY_AUDIT.md` (the repository root has no `docs/` folder); move it if you want it at the root.
2. **Which remediation phases to start.** Step 0.1 (repair CI) first, then Phase 1 (removes the logic High finding). Phases 1-4 and steps 5.3-5.5 are open; 5.1 and 5.2 are out of scope.
3. **Contract policy for AUD-005 — resolved by the release facts.** No tag or GitHub Release exists and `main` still ships v1.0.0, so v1.2.0 is unreleased: the array fix can ship inside 1.2.0 with a "Fixed" note in the CHANGELOG, with no separate patch release.
4. **Parent-repository scope — resolved.** The owner decided on 2026-10-16 that AVD, azure-arc, AzureDashboards and AzureWorkbooks are not in scope for remediation.
