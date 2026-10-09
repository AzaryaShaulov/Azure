# Methodology

How the assessment turns Azure inventory plus Microsoft evidence into recommendations.

## 1. Retirement evidence

Fetched live from Microsoft Learn on every run (fallback: `data/retirement-catalog.json`, labelled `Cached (<time>)`):

| Source | Used for |
|---|---|
| [VM size series retirements and capacity restrictions](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions) (formerly *retired-sizes-list*) | Status (Announced / Retired), announcement date + Azure Updates link, planned retirement date, modernization guide |
| [End of Life VM size series](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/end-of-life-sizes-list) (formerly *previous-gen-sizes-list*) | End of Life stage (an announced retirement). The legacy previous-gen format with a status column (Capacity limited / Next-gen available) is still parsed |
| [Retired sizes modernization guide](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirement/retired-sizes-modernization-guide) (formerly *d-ds-dv2-dsv2-ls-series-migration-guide*) | Microsoft-recommended target series, isolated-size targets, FAQ retirement dates |
| Azure Advisor `ServiceUpgradeAndRetirement` (ARG) | Per-VM corroboration note only |
| Service Health retirement advisories (ARG) | Recorded in `retirement-evidence.json` as context |

Each Learn page's `updated_at`, `git_commit_id` and retrieval time are stored with the run. Microsoft renamed all three
pages in September 2026; the old URLs redirect to the new ones.

Learn series names are mapped to exact VM size patterns through `data/series-map.json`. Retired sizes are no longer
returned by the Resource SKUs API, so matching is on the size name, following the size lists on the Learn size pages.
A Learn series without a mapping is reported as **unmapped** (each name once, even if several pages list it). VMs of
that series are classified **Unable to Confirm**, never guessed.

Retired-list sections whose rows are not VM sizes (`nonVmSizeCategories` in the series map, currently `ADH`: Azure
Dedicated Host SKUs such as *Dsv3-Type1*) are recorded as `nonVmSizeEntries`. They are shown in the reports and noted on
VMs that run on a dedicated host, but never matched to VM sizes.

Modernization-guide targets are series keys (e.g. `ddsv5`) or, for phrases such as *"v6 and v7 D-family series"*,
family/version keys (`d-family-v6`, `d-family-v7`) that admit every D-family size of that generation.

### Microsoft lifecycle stage

Every VM also gets the Microsoft lifecycle stage ([VM lifecycle overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/lifecycle-overview)):

| Stage | Rule | Recommended action (Microsoft) |
|---|---|---|
| Retired | Evidence class *Already Retired* | Migrate now |
| End of Life | Retirement announced (*Confirmed Retirement* or *Retirement Announced*), or the series is on the [End of Life list](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/end-of-life-sizes-list) | Plan modernization or SKU migration before the retirement date |
| Not End of Life | No announced retirement (Current or Extended; Microsoft assigns these per VM family) | None required |
| Unknown | *Unable to Confirm* | Manual review |

The HTML report lists VMs in the Retired and End of Life stages that need action, with the stage shown as a badge.

### Evidence classes

| Class | Rule |
|---|---|
| Already Retired | Retired list status `Retired`, or the Microsoft planned date is on or before the as-of date |
| Confirmed Retirement | On the retired list as `Announced` with a planned retirement date |
| Retirement Announced | Announced without a parseable date; dated only in the modernization-guide FAQ and absent from the retired list (source conflict noted); or on the End of Life list without any planned date |
| Modernization Recommended | On the legacy previous-gen list (Capacity limited / Next-gen available) and not dated for retirement |
| No Retirement Announced | No Microsoft retirement or End of Life entry. The guide may say "Product active" |
| Unable to Confirm | Unparseable name; size in an unmapped Learn series; or size not in the retirement lists **and** not returned by the Resource SKUs API for its region |

Precedence: retired list > modernization-guide FAQ > End of Life / previous-gen list. Series on several lists (e.g.
Dv2) keep the retirement classification; the End of Life status is shown as extra context.

**Evidence changes over time.** Until September 2026 the guide FAQ listed Dv3/Dsv3/Ev3/Esv3 as **Product active**, so
they were Modernization Recommended. Microsoft then added them to the retired list with a planned retirement of
**2029-11-15**, so they are now Confirmed Retirement (Beyond Horizon with the default 36-month horizon). Ev4/Esv4 are
not End of Life and remain optional modernization. Refresh the cache with `Update-Catalogs.ps1` after such changes.

### Urgency

Months are counted from `-AsOfDate` to the Microsoft date:

- Already Retired
- Less than 12 Months
- 12-24 Months
- 24-36 Months
- More than 36 Months
- No Retirement Announced
- Unable to Determine

## 2. Inventory

Azure Resource Graph is queried across every in-scope subscription, in chunks of 200 subscriptions with skip-token
paging. Each VM is joined to:

- **NICs** by `properties.virtualMachine.id` (exact resource ID, not name matching): accelerated networking, NIC count.
- **Managed disks** by `managedBy`: disk SKUs, Premium/Ultra/PremiumV2, customer-managed keys, and the OS-disk
  Hyper-V generation fallback.
- **ADE extensions:** Azure Disk Encryption.

VM properties used:

- Zone
- Availability set
- Proximity placement group (PPG)
- Dedicated host / host group
- Scale set (VMSS) membership
- Capacity reservation group
- Spot priority
- Security type (Trusted Launch / Confidential VM)
- Encryption at host
- Ephemeral OS (and its placement)
- Write Accelerator
- Disk controller type
- Gallery image
- Hyper-V generation
- Hibernation
- Power state

**Not observable from the control plane** (always `Unable to Verify`): nested virtualization, actual temp-disk
usage, physical regional capacity.

Deallocated VMs are included. They do not consume quota today but will when started, so quota math counts them
(see section 7).

## 3. Hardware characteristics

- **Capabilities** come from the subscription-scoped Resource SKUs API (`az vm list-skus --all`):
  - vCPU and vCPUs available, memory
  - Temp disk (MaxResourceVolumeMB), NVMe local disk
  - PremiumIO; Ultra availability per zone
  - Accelerated networking; max NICs; max data disks
  - Uncached and cached IOPS / MBps
  - Hyper-V generations; CpuArchitectureType; disk controller types
  - Ephemeral OS support and placements
  - Encryption at host; Trusted Launch disabled; confidential type; Write Accelerator limit; GPUs
  - Zones; restrictions (location / zone, reason code), applied only when the restriction includes the assessed region
- **CPU vendor / processor** come from `data/processor-catalog.json`. It is built by `Update-Catalogs.ps1` from the
  `Processor` row of every Learn size-series spec table. An exact series-key match is **Verified**. A broader
  base-series match or the Azure naming convention (`a` = AMD, `p` = ARM, otherwise Intel) is **Partially Verified**.
  For example, Lsv2 is AMD EPYC 7551 even though its name has no `a`.
- **Architecture** comes from `CpuArchitectureType` (Verified).
- **Network bandwidth** is not exposed by the Resource SKUs API. It is listed as Unknown and shown in material
  differences with a pointer to the Learn size page.

## 4. Candidate pool

For each VM that needs analysis, a candidate pool is built. By default, VMs needing analysis are any class other than
No Retirement Announced, plus sizes of generation v4 or older (heuristic modernization check). With
`--check-modernization`, every VM is evaluated; v6/v7 VMs are reported as already modern, and older VMs add same-family
v6/v7 sizes to the candidate pool.

Candidates come from the Resource SKUs for the **VM's subscription and region**. A size is in the pool only if all of
these hold:

1. **Permitted series.** If the Microsoft modernization guide lists targets for the retiring series (or isolated-size
   targets), only those, including family/version targets such as all v6/v7 D-family sizes. Otherwise, the same
   workload family (D, E, F, L, M, NC, ...).
2. **Current generation only.** The candidate's own lifecycle must be *No Retirement Announced*: not retiring, not
   End of Life.
3. **Generation.** For retirements, the same or newer generation (e.g. Av2 -> Bsv2 is allowed). For modernization,
   strictly newer.
4. **Same CPU architecture.** Never x64 <-> Arm64.
5. **Never smaller.** vCPUs available >= current, memory >= current (3% tolerance for the Microsoft rounding between
   generations, e.g. 14 GB -> 16 GB). GPU count >= current.
6. **Excluded:** constrained-core and isolated sizes (unless the VM already uses one), Promo, Basic tier.
7. **Per series:** the **smallest fitting size**. If that size lowers the VM-level uncached disk IOPS/MBps caps, the
   smallest size in the same series that preserves them (up to 2x vCPU) is also evaluated, as the
   *Capability-preserving* variant.

**Headroom policy.** Sizes come in discrete steps, so capacity is preserved (>=) rather than inflated by a fixed
10-20%. The newer generation provides the compute headroom. `CapacityHeadroomPct` reports the actual vCPU/memory
headroom per candidate. Capability reductions are never hidden: see [scoring.md](scoring.md).

The explicit modernization check preserves CPU vendor and architecture (Intel/x64 -> Intel/x64, AMD/x64 -> AMD/x64,
ARM/Arm64 -> ARM/Arm64). It selects a suitable v7 candidate first, then v6, then retains the existing retirement/upgrade
recommendation if no v6/v7 candidate passes. The candidate must be returned for the VM's subscription and region, have
no announced retirement, pass the mandatory workload gates, and pass the existing aggregated quota assessment.

## 5. Mandatory gates

| Gate | Fail when |
|---|---|
| CPU Architecture | Differs |
| VM Generation | VM Hyper-V generation not supported by target (e.g. Gen1 VM -> Gen2-only v6) |
| Disk Controller | VM controller (SCSI default) not supported (e.g. SCSI VM -> NVMe-only v6) |
| Premium Storage | VM uses Premium/Ultra/PremiumV2 and target lacks PremiumIO |
| Ultra Disk | Ultra not available for target in VM zone/region |
| Accelerated Networking | Any NIC uses it and target lacks it |
| Ephemeral OS Disk | Unsupported, or placement unsupported |
| NIC Count / Data Disk Count / Write Accelerator | VM usage exceeds target maximum |
| Security Type | Trusted Launch VM -> TL-disabled size; Confidential VM -> non-confidential size |
| Encryption at Host | Used and unsupported |
| GPU | Fewer GPUs |
| Region / Zone | Not offered in VM zone, or zone restricted |

**Review** (validation item, not a rejection):

- CPU vendor change
- Temp disk removed
- Subscription restriction (`NotAvailableForSubscription`)
- Dedicated host
- Proximity placement group
- Availability set
- VMSS membership
- Confidential type details
- GPU model change

**Info:**

- Azure Disk Encryption
- Spot
- Hibernation
- Nested virtualization (Unknown)

**Newer generation if converted:** if the best newer-generation same-vendor size is blocked *only* by the Hyper-V
generation or disk-controller gates, it is reported as `NewerGenerationIfConverted`. It is never a directly
deployable resize. With `--check-modernization` it can become the **convertible modernization target** (section 7),
with the required Gen1 and/or SCSI -> NVMe path. Guest readiness is never assumed from control-plane data.

## 6. Selection

1. **Valid:** no failed gate. Same CPU vendor first. If no same-vendor candidate is valid, cross-vendor (x64 only)
   candidates are used and **CPU Vendor Change Required** is set, with the blocking reasons.
2. **Primary:** among valid candidates with regional availability `Available` (a restricted size is never primary):
   - within each workload family, keep the newest generation that has a candidate scoring >= 80 (Good Match or better).
     Generation numbers are compared only within a family: Bsv2 is the current B-series while D-series is on v6/v7;
   - then pick by highest score, then **feature similarity** to the current size (fewest added or removed feature
     letters; e.g. E8s_v3 -> E8ds_v5 rather than the specialised E8bds_v5), then closest size.
3. **Secondary:** never older than the primary's generation (no ageing fallback such as v4 for a v3 -> v5 move).
   Prefers a different quota family, as a real fallback for quota, capacity or regional constraints.
   Its reason text states quota headroom, capability preservation, vendor, family and temp-disk differences.
4. **Third:** next best.

When `--check-modernization` is enabled, selection adds a higher-priority tier before the normal primary:

1. suitable same-vendor/same-architecture v7;
2. suitable same-vendor/same-architecture v6;
3. the primary selected by the existing logic.

Modernization status is finalized after quota evaluation: `Modernize to v7`, `Modernize to v6`,
`Already on modern generation`, `No suitable modern SKU found`, `SKU unavailable in region`, `Insufficient quota`,
or `Architecture mismatch`. A deployable v6 candidate is selected ahead of a quota-blocked v7 candidate; the v7 size
remains visible as the quota-blocked alternative.

## 7. Retirement target vs modernization target

The report separates the **lifecycle remediation decision** from the **strategic modernization decision**. They can be
the same SKU, but they are modeled independently. All values come from one function, `Get-TargetStrategy`
(`Assessment.psm1`); the CSV, JSON and HTML outputs only render it.

| Field | Meaning |
|---|---|
| `RetirementTargetSku` | Supported replacement that remediates a retiring/retired (`Yes`) or unconfirmed (`Unknown`) SKU. May be v5. |
| `ModernizationTargetSku` | Strategic v6/v7 destination. Only with `--check-modernization`. |
| `RecommendedMigrationPath` | Sequence connecting the current SKU, the retirement target and the modernization target. |

**Retirement target.** `Candidates.Modernization.ExistingRecommendation` when modernization ran (it preserves the
original recommendation even when quota resolution promotes a v6/v7 size into `Candidates.Primary`), otherwise
`Candidates.Primary`.

**Modernization target** (first match, `--check-modernization` only):

1. `Selected` - the modernization candidate chosen by the quota-aware v7 -> v6 selection.
2. `Primary` - the primary recommendation when it is already v6/v7.
3. `QuotaBlocked` - the newest v6/v7 option rejected only by aggregate quota (shown as a quota action, never as redeploy).
4. `Convertible` - `NewerGenerationIfConverted`: a v6/v7 size blocked *only* by the Hyper-V generation and/or disk
   controller gates.

Conversion flags (`RequiresGenerationChange`, `RequiresNvmeConversion`) come from the **selected target's** failed gates,
so a VM with a directly deployable v6 is never labelled as needing NVMe conversion because a blocked v7 exists.

**Migration path text:**

- not affected and already v6/v7: `No retirement move required; already on modern generation`;
- retirement target older than the modernization target: `Retire to <v5> -> modernize to <v6/v7>` plus the required
  conversion, e.g. `(requires SCSI to NVMe conversion)`;
- retirement target newer or equal but a different SKU: `Retire to <X>; alternative modern target <Y>`;
- same SKU: `Move directly to <X>`;
- no modernization target: `Retire to <X>; no validated v6/v7 target` (or `Retire to <X>` without the flag);
- unconfirmed lifecycle: prefixed with `Retirement unconfirmed - validate lifecycle;`;
- not affected with a modernization target: `Optional modernization to <X>`.

### Modernization path classification

| Path | Meaning |
|---|---|
| `Already Modern` | Current SKU is v6/v7. |
| `Direct Resize` | The target passed every mandatory gate; an in-place resize is possible. |
| `SCSI to NVMe + Resize` | The target is NVMe-only; convert the disk controller (in place), then resize. |
| `Gen1 Modernization + Resize` | The target is Gen2-only; Microsoft supports Gen1 -> Gen2 only through the [Trusted launch upgrade](https://learn.microsoft.com/azure/virtual-machines/trusted-launch-existing-vm-gen-1). |
| `Gen1 + NVMe + Resize` | Both conversions are required. |
| `Redeploy / Rebuild Review` | Gen1 conversion is required **and** the reported guest OS or image is not supported by the Trusted launch upgrade (Windows Server 2016, Debian, Azure Linux / CBL-Mariner). Deploy a Gen2 VM and migrate the workload. |
| `No Validated Modern Target` | No v6/v7 size passed the workload gates or is available; see `ModernizationStatus` and the candidate table. |

Redeploy is only recommended on evidence (unsupported guest OS); a missing target is reported as manual review.

### Modernization complexity and readiness

`ModernizationComplexity`:

- **None** - already modern; **Unknown** - no modernization target.
- **Low** - direct resize with no material prerequisite.
- **Medium** - exactly one material prerequisite: SCSI -> NVMe conversion, a modernization quota increase, or removal
  of a temp disk the current size has.
- **High** - Gen1 -> Gen2, redeploy, or two or more material prerequisites.

`ModernizationReadiness`, first match: `Current` (already modern), `Manual Review` (no target), `Redeploy Review`,
`Quota Increase` (modernization quota insufficient or the target is quota-blocked), `Convertible` (Gen1 and/or NVMe
conversion), `Manual Review` (modernization quota not verifiable, or the target is the primary and its readiness is
SKU Restricted, Regional Limitation or Manual Review Required), otherwise `Ready`.

Complexity and readiness are sequencing aids, not guarantees of change-window duration or application impact.

### Data classes

| Class | Examples |
|---|---|
| Authoritative assessment data | Microsoft lifecycle evidence, Resource SKU capabilities, availability and restrictions, quota usage and limits, inventory |
| Derived assessment data | Gate results, retirement and modernization targets, conversion flags, migration path, complexity, readiness |
| Planning estimates | Steady-state and peak quota demand, `MigrationQuotaModel`, recommended quota increases |
| Guest validation requirements | `ModernizationValidationItems` and `ValidationItems` - never assumed from control-plane data |

### Guest and workload validation

The assessment is control-plane only. These are reported as **Validation Required** / **Unknown** items, never as ready:

- **Guest NVMe readiness** when the target is NVMe-only: Azure controller support does not prove the guest has NVMe
  drivers or discovers its disks over NVMe.
- **Gen1 -> Gen2**: supported OS and size for the Trusted launch upgrade, MBR -> GPT conversion, boot and rollback
  (also flags when the guest OS is not reported).
- **MANA networking** when the source uses Accelerated Networking and the target is v6/v7: Accelerated Networking on the
  source does not prove guest MANA driver support.
- **Temporary disk dependency** (`Unknown / workload validation required`) when the current size has a temp disk and
  the target has none, or presents local storage as NVMe. The SKU having temp storage does not show whether the
  workload depends on it.
- Physical regional capacity.
## 8. Quota

`az vm list-usage` is read per subscription/region. The target family is matched through the SKU's `family` field,
e.g. `standardDDSv5Family`.

- **Aggregation:** demand is summed for all VMs moving into the same subscription / region / family.
- **Family requirement:** for an allocated same-family resize, + max(0, target - current) vCPU; for a cross-family
  resize or a deallocated VM, + target vCPU.
- **Regional vCPUs:** + (target - current) for allocated VMs, + target for deallocated VMs.
- **Formulas:**
  - Minimum increase = max(0, usage + required - limit).
  - Recommended increase = ceil(minimum + required x `QuotaSafetyPct`%).
  - Worked example: 100 limit, 92 used, 16 required -> +8 minimum, +12 recommended.
- **Scopes:**
  - `Retirement`: retirement-affected and unconfirmed VMs moving to their **retirement target**. Used for
    `RetirementQuotaStatus`.
  - `Retirement+Modernization`: every VM with an action moving to `Candidates.Primary` (retirement plus optional Wave 4
    moves). Used for the `QuotaStatus` of non-affected VMs.
  - `Modernization` (`--check-modernization` only): every VM with a strategic v6/v7 target, with steady-state and peak
    demand. Used for `ModernizationQuotaStatus` / `ModernizationPeakQuotaStatus`.
  - `QuotaStatus`, `DeploymentReadiness` and `NextStep` always describe `Candidates.Primary`; affected VMs are aggregated
    with the other mandatory moves only, so optional work never inflates mandatory quota.
- **Status values:**
  - Quota OK
  - Quota Increase Required
  - Quota Information Unavailable (no usage data)
  - Manual Validation Required (family not reported for the region)

Quota OK does **not** mean physical capacity exists (see readiness).

### Steady-state vs peak migration planning

Every quota row carries steady-state and peak values. `RequiredVcpu`, `MinimumIncrease`, `RecommendedIncrease`,
`RecommendedNewLimit` and `Status` remain the steady-state values; the original columns keep their order and the new
columns are appended.

`MigrationQuotaModel` per move:

- `InPlace` - resizes and SCSI -> NVMe conversions (Microsoft's conversion deallocates and resizes the same VM).
  Peak = steady state.
- `SideBySide` - Gen1 -> Gen2 (Trusted launch upgrade) and redeploy paths, modeled conservatively as if a target VM
  coexists with the source. Family peak: + target vCPU for a same-family move (the source keeps its usage), otherwise =
  steady. Regional peak: + target vCPU.
- A quota row is `Mixed` when it contains both.

`Peak*` = the steady-state formulas applied to the peak demand. Side-by-side is only used in the `Modernization` scope;
`Retirement` and `Retirement+Modernization` model in-place resizes. Retirement (e.g. Dsv5) and modernization (e.g. Dsv7)
demand are computed in separate scopes and never merged.

The HTML modernization section renders the `Modernization` rows of `quota-impact.csv` and each VM's own steady/peak
contribution; it does not recalculate quota.

Peak quota is a **planning estimate**, not proof of deployable physical capacity. Validate the final migration method,
target-family quota, regional vCPU quota and Azure capacity before execution.
## 9. Readiness, confidence, actions, waves

**Deployment readiness**, first match wins:

1. No primary -> Manual Review Required
2. Primary restricted -> SKU Restricted
3. Primary not offered / zone restricted -> Regional Limitation
4. Vendor change, dedicated host, confidential or GPU review, or unconfirmed lifecycle -> Manual Review Required
5. Quota increase needed -> Quota Increase Required
6. Quota unknown -> Manual Review Required
7. Capacity-sensitive (PPG, dedicated host, capacity reservation, Ultra, GPU, >= 64 vCPU) -> Capacity Validation Required
8. Otherwise -> Ready

**Confidence:**

- **LOW** if any of these apply:
  - no valid target
  - vendor change
  - current-size capabilities unknown
  - primary not Available
  - quota not validated
  - lifecycle unconfirmed
  - two or more validation items
- **MEDIUM:** exactly one validation item. Examples:
  - quota increase
  - temp disk removed
  - disk-throughput reduction
  - availability set or PPG
  - cached / partially verified lifecycle evidence
- **HIGH:** nothing left to validate.

Nested virtualization and physical capacity are always `Unable to Verify` and are reported in data quality. They are
excluded from the confidence count because no control-plane signal exists.

**Action values:**

| Lifecycle | Action |
|---|---|
| Already Retired | Immediate Migration Required |
| Less than 12 Months | Migration Required Within 12 Months |
| 12-24 Months | Migration Required Within 24 Months |
| 24-36 Months | Migration Required Within 36 Months |
| More than 36 Months | Plan Migration |
| Unable to Confirm / undated | Manual Review Required |
| Previous-gen (legacy format), Capacity limited | Plan Migration |
| Previous-gen (legacy format), Next-gen available | Modernization Optional |
| No retirement, and v4 or older with a same-vendor option >= 2 generations newer | Modernization Optional |
| Otherwise | No Action Required |

`NextStep` carries the blocking action:

- Request Quota Increase
- Validate Regional Capacity
- Manual Review Required
- Proceed with Resize

**Waves** (`H` = `-HorizonMonths`, 12-120, default 36):

| Wave | Contains |
|---|---|
| Wave 1 - Urgent | Already retired, or retiring in less than 12 months (never deferred by the horizon) |
| Wave 2 - Near Term | Retiring in 12-24 months, when that is before `H` |
| Wave 3 - Planned | Retiring in 24 months up to `H` |
| Beyond Horizon | Retiring `H` or more months after the as-of date |
| Review - Unconfirmed | Unconfirmed lifecycle |
| Wave 4 - Modernization | Previous-gen / optional modernization only |

`-MaxCandidates` limits the recommendations per VM: `1` = primary only, `2` = primary + alternative, `3` (default) =
primary + alternative + third.

### Modernization report presentation

The HTML report lists only VMs affected by a Microsoft retirement announcement with a published retirement date and a
required action (tenant *Migration Waves*, subscription *VMs with Retiring SKUs* and its details, and the modernization
table). Optional modernization, unconfirmed and current-generation VMs remain in `vm-assessment.csv`, `assessment.json`
and the Markdown reports. `-HtmlIncludeOptionalModernization` also lists optional-modernization VMs (older generations
without an announced retirement). `-HtmlMaxVmDetails` (default 250) caps the expandable per-VM detail blocks per page,
in wave order, so very large subscriptions stay fast to open; the summary tables and every other output keep all VMs.
Each page links the Microsoft Learn upgrade path, SCSI to NVMe conversion and Gen1 to Trusted launch guidance.

Subscription pages are split into two colour-coded parts so customers can tell required work from optional work:

- **Part 1 - Required: Retirement remediation** (orange): *VMs with Retiring SKUs* and *VMs with Retiring SKUs details*.
- **Part 2 - Optional: v6/v7 Modernization** (purple, only with `--check-modernization`): *v6/v7 Modernization Readiness*.

Each part starts with a banner (part number, Required / Optional label, icon and short description) and every card in
the part has a coloured left edge. The navigation groups the links under *Retirement* and *Modernization*, the
Overview has a tile per part (VM count, earliest retirement date) linking to it, and the modernization table tints
the retirement-target and modernization-target columns in the matching colours. Labels and icons carry the meaning as
well as colour, the colours have dark-mode variants, and when printed Part 2 starts on a new page with colours kept.

With `--check-modernization`, the **v6/v7 Modernization Readiness** section covers the same VMs as Part 1. It renders `Get-TargetStrategy` and the `Modernization` quota rows:

- KPIs: direct resize ready, NVMe conversion, Gen1 modernization, quota increase, redeploy/rebuild review, manual review,
  already v6/v7;
- a table of VMs that are not already modern: current SKU, retirement target, modernization target, path, complexity,
  key blocker, modernization quota and readiness, each with an expandable detail row (current configuration, targets,
  blockers, remediation, the VM's steady/peak quota contribution, validation checklist, gates, differences,
  alternatives);
- action groups (direct resize, SCSI -> NVMe, Gen1, redeploy, quota, manual review);
- steady-state vs peak quota from the `Modernization` scope;
- guidance shown only when a VM in the subscription has the matching condition or validation item;
- migration-path examples taken from assessed VMs.
## 10. Rightsizing (optional)

With `-IncludeRightsizing`, hourly `Percentage CPU` and `Available Memory Bytes` metrics are read over the lookback
window through the Azure Monitor batch API (50 VMs per call). This applies only to running VMs that have an action.

A VM is flagged *Potential Rightsizing Opportunity* when:

- CPU P95 < 20%, and
- memory used (from the P05 of available memory) < 40%, and
- at least 7 days of data exist.

A half-size in the primary series is suggested. The result is reported in separate columns and **never** changes the
primary recommendation.

## 11. Pricing (on by default)

Prices come from the public Retail Prices API: pay-as-you-go hourly x 730, by OS, in USD. Use `-SkipPricing` to turn
pricing off (`-IncludePricing` is still accepted). If the API cannot be reached, the run warns once, continues without
prices and records `pricingStatus: "Unavailable"`.

- Informational only; never used for ranking.
- Excludes EA/MCA discounts, reservations, savings plans and Azure Hybrid Benefit.
