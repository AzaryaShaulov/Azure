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
generation or disk-controller gates, it is reported as `NewerGenerationIfConverted`. Gen1 -> Gen2 and SCSI -> NVMe
conversions are possible but are not in-place resizes.

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

## 7. Quota

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
- **Two scopes:**
  - `Retirement`: mandatory migrations only. Used for affected VMs.
  - `Retirement+Modernization`: also includes Wave 4 moves. Used for modernization VMs.
- **Status values:**
  - Quota OK
  - Quota Increase Required
  - Quota Information Unavailable (no usage data)
  - Manual Validation Required (family not reported for the region)

Quota OK does **not** mean physical capacity exists (see readiness).

## 8. Readiness, confidence, actions, waves

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

## 9. Rightsizing (optional)

With `-IncludeRightsizing`, hourly `Percentage CPU` and `Available Memory Bytes` metrics are read over the lookback
window through the Azure Monitor batch API (50 VMs per call). This applies only to running VMs that have an action.

A VM is flagged *Potential Rightsizing Opportunity* when:

- CPU P95 < 20%, and
- memory used (from the P05 of available memory) < 40%, and
- at least 7 days of data exist.

A half-size in the primary series is suggested. The result is reported in separate columns and **never** changes the
primary recommendation.

## 10. Pricing (optional)

With `-IncludePricing`, prices come from the Retail Prices API: pay-as-you-go hourly x 730, by OS, in USD.

- Informational only; never used for ranking.
- Excludes EA/MCA discounts, reservations, savings plans and Azure Hybrid Benefit.
