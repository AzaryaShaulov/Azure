# Output schema (v1.0)

All files are written to the run folder. CSVs are UTF-8 with headers; a CSV with no data rows (for example `candidates.csv`
when no VM needs a replacement, or every file when no VM was found) contains only its header row. `assessment.json` is the
complete, machine-readable result for Azure Workbooks, Power BI, Excel, Logic Apps, PowerShell, Python and pipelines.

## assessment.json

```text
{
  schemaVersion: "1.0", tool: "VMSKURetirementReport", generatedUtc, asOfDate, tenant: { Id, Name },
  signedInAccount (masked, e.g. "j****@contoso.com", unless -IncludeOperatorAccount),
  dataSource: "Live" | "Snapshot captured <yyyy-MM-dd HH:mm> UTC",
  pricingStatus: "Done" (all regions retrieved) | "Partial" (completed regions retained, failed/incomplete region discarded and remaining regions skipped) | "Unavailable" (no region completed) | "Skipped" (-SkipPricing),
  parameters: { SubscriptionId, Region, HorizonMonths, OfflineCatalog, QuotaSafetyPct, MaxCandidates, CheckModernization, IncludeRightsizing, IncludePricing (effective, true unless -SkipPricing), SkipPricing, IncludeOperatorAccount, KeepRawData, SaveSnapshot, FromSnapshot, HtmlIncludeOptionalModernization, HtmlMaxVmDetails, ExtendedDetails, ... },
  disclaimer (standard short disclaimer; plain text with two paragraphs),
  catalog: { source: "Live" | "Cached (<utc>)", warning, sources: [ { Name, Url, Title, UpdatedAt, GitCommitId, RetrievedUtc } ], unmappedSeries: [...],
             nonVmSizeEntries: [ { Category, Name, Status, PlannedRetirementDate, GuideUrl, SourceUrl } ] },
  counts: { Vms, Nics, Disks, AdeExtensions, AdvisorRetirement, ServiceHealthRetirement },
  summary: { <estate counts: see Summary counters>, ByEvidenceClass[], ByWave[], BySubscription[], ByRegion[], ByCurrentSku[], ByCurrentSkuFamily[],
             ByRecommendedSku[], ByRecommendedSkuFamily[], ByCpuVendor[], ByRetirementDate[], ByMigrationPriority[], ByDeploymentReadiness[] },
  quota: { family: [QuotaRow], regional: [QuotaRow] },
  collectionIssues: [ { subscriptionId, region, api, message, effect } ],   # data that could not be collected; [] when everything was read
  vms: [ {
    row: <same fields as vm-assessment.csv>,
    vm: <inventory record: ids, zone, availability set, PPG, host, VMSS, power state, OS, Hyper-V generation, disk controller,
         NIC / disk counts, disk SKUs, Premium / Ultra, accelerated networking, ephemeral OS, security, encryption, Spot, image ...>,
    lifecycle: { SkuName, SeriesKey, LearnSeriesName, EvidenceClass, RetirementStatus, AnnouncementDate, RetirementDate, MonthsRemaining,
                 Urgency, SourceUrl, AnnouncementUrl, MigrationGuideUrl, PreviousGenStatus, RecommendedTargets[], GuideDifferences[],
                 SizeTargets[], Notes[], CatalogSource, DataQuality },
    current: { sku, quotaFamily, seriesKey, generation, cpuVendor, cpuArchitecture, processors[], vCpu, memoryGB, memoryPerVcpu, tempDiskGB,
               premiumIO, acceleratedNetworking, maxNics, maxDataDisks, uncachedDiskIops, uncachedDiskMBps, hyperVGenerations[],
               diskControllerTypes[], zones[], capabilitiesSource },
    recommendation: { permittedSeries, candidatesEvaluated, vendorChangeRequired, vendorChangeReason, noCandidateReason,
                      primary: Candidate, secondary: Candidate, third: Candidate, secondaryReason, newerGenerationIfConverted: Candidate } | null,
    modernization: { enabled, currentGeneration, recommendedSku, recommendedGeneration, cpuVendor, cpuArchitecture,
                     region, regionAvailability, quotaStatus, status, reason, candidate: Candidate } | null,
    quota: VmQuota | null,                      # quota of Candidates.Primary (drives QuotaStatus / readiness)
    retirementQuota: VmQuota | null,            # retirement target, scope Retirement
    modernizationQuota: VmQuota | null,         # strategic v6/v7 target, scope Modernization (--check-modernization)
    strategy: Strategy | null,
    readiness, confidence: { Level, LowReasons[], ValidationItems[] }, action, nextStep, wave,
    dataQuality: { RetirementDate, CpuVendor, CpuArchitecture, CurrentSkuCapabilities, RegionalAvailability, Quota,
                   PhysicalCapacity, NestedVirtualization, TempDiskUsage },
    rightsizing: { Status, CpuP95, MemUsedP95Pct, SuggestedSku, Note } | null,
    pricing: { Os, CurrentMonthly, TargetMonthly, Basis } | null
  } ]
}
```

### Value shapes

Every field written with `[]` above is always a JSON array: no items is `[]` (never `null`) and one item is a one-element
array (never a bare value). This covers the twelve `summary.By*` groupings, `quota.family`, `quota.regional`,
`strategy.ValidationItems` and `strategy.TargetComparison`. Objects that can be absent (`recommendation`, `modernization`,
the per-VM `quota`, `strategy`, `rightsizing`, `pricing`) are `null` instead. Before 1.2.0 a single group, an empty list or
a single validation item was written as an object, `null` or a bare string, so a consumer that iterated those fields could
mis-read a single-subscription or single-region estate.

`materialDifferences[].Current` / `.Target` and `TargetComparison[].Current` / `.RetirementTarget` / `.ModernizationTarget` are
display values whose JSON type follows the `Attribute` (string, number, boolean or `null`); read them together with
`Attribute`, or as text. The CSV and the reports render them as text.

### Summary counters

`summary` holds estate counters and groupings. Each counts a defined set of VMs, so the numbers reconcile with the VM rows
(`vm-assessment.csv`, `vms[].row`):

| Counter | VMs it counts |
|---|---|
| `TotalSubscriptionsScanned`, `TotalVmsScanned` | Subscriptions with VMs in scope; every VM assessed |
| `AffectedVms` | VMs on a size with a confirmed or announced Microsoft retirement (`AffectedByRetirement` = `Yes`) |
| `ActionableVms` | VMs whose `Action` is not `No Action Required`; the set the groupings below cover |
| `AlreadyRetired`, `RetirementWithin12Months`, `RetirementWithin24Months`, `RetirementWithin36Months`, `RetirementBeyond36Months` | VMs by retirement urgency (`EvidenceClass` = `Already Retired`, or `Urgency`: under 12 months, 12-24, 24-36, over 36) |
| `ModernizationRecommended` | VMs on Microsoft's previous-generation list (`EvidenceClass` = `Modernization Recommended`): an older generation without an announced retirement |
| `ModernizationOptional` | VMs whose `Action` is `Modernization Optional`. The capacity-limited previous-generation sizes have the action `Plan Migration` and are not counted; these are the VMs that `-HtmlIncludeOptionalModernization` lists |
| `ModernizationTargetV7`, `ModernizationTargetV6` | VMs whose strategic modernization target (`strategy.ModernizationTargetSku`) is a v7 / v6 size, **whatever the path**: a direct resize, a conversion first, or a size held back by quota. VMs already on v6/v7 are not counted. `0` unless `--check-modernization` was used |
| `ConvertibleToV7`, `ConvertibleToV6` | The part of the two counters above that needs a Gen1 to Gen2 change and/or a SCSI to NVMe conversion first (`strategy.RequiresGenerationChange` or `RequiresNvmeConversion`) |
| `ModernizeToV7`, `ModernizeToV6` | VMs whose `modernization.status` is `Modernize to v7` / `Modernize to v6`: a deployable v7 / v6 size that passes every check and quota, so a **direct resize**. Never more than `ModernizationTargetV7` / `ModernizationTargetV6` |
| `AlreadyOnModernGeneration` | VMs whose `modernization.status` is `Already on modern generation` (a v6/v7 size). `0` unless `--check-modernization` was used |
| `NoRetirementAnnounced`, `UnableToDetermine` | VMs by evidence class (`No Retirement Announced`; `Unable to Confirm` or urgency `Unable to Determine`) |
| `VmsRequiringQuotaIncrease`, `VmsWithRegionalRestrictions`, `VmsRequiringCpuVendorChange`, `VmsRequiringManualReview` | VMs by `QuotaStatus` = `Quota Increase Required`; `Readiness` = `SKU Restricted` or `Regional Limitation`; `recommendation.vendorChangeRequired`; `Readiness` = `Manual Review Required` |
| `HighConfidence`, `MediumConfidence`, `LowConfidence` | VMs by `confidence.Level`; a VM that needs no action and had no replacement search has level `N/A` and is in none of the three |

A VM can have a modernization target and still need no action (a current v5 VM with a v6 target after an NVMe conversion), so
`ModernizationTargetV6` can exceed the VMs that have an action.

Each grouping lists `Key` and `Count`, largest first, and covers one set of VMs:

| Grouping | VMs it covers |
|---|---|
| `ByEvidenceClass`, `ByWave`, `ByMigrationPriority` (the action) | All VMs (`TotalVmsScanned`) |
| `BySubscription`, `ByRegion`, `ByCurrentSku`, `ByCurrentSkuFamily`, `ByRecommendedSku`, `ByRecommendedSkuFamily`, `ByCpuVendor`, `ByDeploymentReadiness` | Only the VMs with an action (`ActionableVms`); a VM with `No Action Required` is not in them, so their counts add up to `ActionableVms`, not to `TotalVmsScanned` |
| `ByRetirementDate` | Only the VMs on retiring sizes (`AffectedVms`) |

`executive-summary.md` shows the same counters in its estate table (the v6/v7 rows read `not evaluated` when the modernization
check did not run) and says what each grouping counts in its heading. The HTML *Modernization (Wave 4)* tile, the *Wave 4*
column of the Subscriptions table and each subscription page count the VMs in `Wave 4 - Modernization`: an older generation
without a retirement announcement, with the action `Modernization Optional` or `Plan Migration`.

### Rightsizing

`vms[].rightsizing` (and `RightsizingStatus` / `RightsizingSuggestedSku` in `vm-assessment.csv`) is `null` or empty for a VM
that was not assessed (not running, no action, no recommendation, or the telemetry could not be read) and has these fields
otherwise. It is informational and never changes the recommendation (see methodology section 10).

| Field | Meaning |
|---|---|
| `Status` | `Potential Rightsizing Opportunity`, `No Opportunity` or `Insufficient Data` (fewer than 7 days of hourly data, or none) |
| `CpuP95` | 95th percentile of the **hourly average** CPU, in percent; short bursts are averaged away, so `Note` adds the highest hourly maximum |
| `MemUsedP95Pct` | Memory used at the 95th percentile, in percent; `null` when the guest reports no available memory |
| `SuggestedSku` | The same-series size with half the vCPUs of `RecommendedSku`, only when it passes the same mandatory checks as a migration target for this VM; `null` when none does |
| `Note` | The figures in words and, when no size is suggested, the reason |

### Collection issues

`collectionIssues[]` lists every problem that left part of the data missing; it is `[]` when everything was read. Each entry
has `subscriptionId` and `region` (`null` when the problem is not tied to one scope), `api` (what was being read, for example
`Resource SKUs`, `Compute usage (az vm list-usage)`, `Resource Graph: Azure Advisor retirement recommendations`,
`Azure Monitor metrics (rightsizing)`, `Azure Retail Prices`), `message` (the sanitized reason; email addresses and the
signed-in identity's object id are masked) and `effect` (what it means for the results). For a VM in the affected
subscription and region the cause is also in `confidence.LowReasons` ("Data not collected (...): ...") and, when no
recommendation could be made, in the CSV column `RecommendationReason`. The same list is in `executive-summary.md`
("Data collection issues") and in a callout on the HTML pages. See the methodology, section 2.

### Candidate object

```text
Candidate = { role, variant, sku, quotaFamily, seriesKey, generation, cpuVendor, cpuArchitecture, cpuGeneration, processors[],
              vendorDataQuality, vCpu, memoryGB, tempDiskGB, regionAvailability, zoneAvailable, compatibilityScore, scoreBand,
              scoreBreakdown{12 criteria}, capacityHeadroomPct, vendorPreserved, familyMatch, rejected, rejectionReason,
              gates: [ { Gate, Result: Pass|Fail|Review|Info|Unknown, Detail } ],
              materialDifferences: [ { Attribute, Current, Target, Assessment: Same|Improved|Reduced|Changed|Unknown, Note } ] }
```

### Quota row

```text
QuotaRow = { SubscriptionId, Region, QuotaName, QuotaDisplayName, VmCount, TargetSkus, Limit, CurrentUsage, Remaining,
             RequiredVcpu, RequiredVcpuAllocatedOnly, PostMigrationUsage, MinimumIncrease, RecommendedIncrease, RecommendedNewLimit,
             Status, DataQuality, Scope,
             MigrationQuotaModel, SideBySideVmCount, SteadyStateRequiredVcpu, PeakMigrationRequiredVcpu, PeakPostMigrationUsage,
             PeakMinimumIncrease, PeakRecommendedIncrease, PeakRecommendedNewLimit, PeakStatus }
```

`RequiredVcpu`, `MinimumIncrease`, `RecommendedIncrease`, `RecommendedNewLimit` and `Status` are the steady-state values
(`RequiredVcpu` = `SteadyStateRequiredVcpu`). The `Peak*` columns assume side-by-side capacity for `SideBySide` moves.
`MigrationQuotaModel` is `InPlace`, `SideBySide` or `Mixed`; it is `SideBySide`/`Mixed` only in the `Modernization` scope.

### Per-VM quota

```text
VmQuota = { Status, PeakStatus, MigrationQuotaModel, SteadyStateRequiredVcpu, PeakMigrationRequiredVcpu,
            SteadyStateRegionalRequiredVcpu, PeakMigrationRegionalRequiredVcpu, DataQuality, Family: QuotaRow, Regional: QuotaRow }
```

The four vCPU values are this VM's own contribution; the `Family` / `Regional` rows are the aggregated quotas it belongs to.

### Strategy

```text
Strategy = { RetirementRequired, RetirementUnconfirmed, RetirementTarget: Candidate, RetirementTargetSku, RetirementTargetGeneration,
             RetirementQuotaStatus, ModernizationEnabled, AlreadyModern, ModernizationTarget: Candidate, ModernizationTargetSku,
             ModernizationTargetGeneration, ModernizationTargetSource, RequiresGenerationChange, RequiresNvmeConversion,
             RedeployReview, RedeployReason, MigrationQuotaModel, ModernizationQuotaStatus, ModernizationPeakQuotaStatus,
             ModernizationPath, Complexity, ModernizationReadiness, ValidationItems[], RecommendedMigrationPath,
             TargetComparison[] }

TargetComparison = { Attribute, Current, RetirementTarget, RetirementChange, ModernizationTarget, ModernizationChange,
                     RetirementNote, ModernizationNote }
```

`TargetComparison` has one row per attribute (vCPU, memory, temp disk, disk controller, Hyper-V generation, IOPS, ...)
with the result for the retirement target and for the modernization target (`*Change` is Same, Improved, Reduced,
Changed or Unknown). It is computed once from the material differences of each target and is what the HTML details and
`detailed-report.md` render. The modernization columns are empty when there is no strategic target (or the VM is already
modern). Differences for a target that was not ranked as a candidate (for example a convertible newer generation) are
computed for the comparison only; they are not added to that target's `materialDifferences`.

The `Current` value of the *Hyper-V Generation* and *Disk Controller* rows is the VM's own generation (`V1`, `V2`) and
disk controller (`SCSI`, `NVMe`), not everything its current size supports; the target value is what the target size
supports. The row is `Same` when the target supports the VM's value and `Changed` otherwise (a VM on Gen2 moving to a
Gen2-only size is no longer reported as `Changed`). When the VM's value is not available, the size's supported set is
compared instead. These values also appear in `materialDifferences`, `MaterialDifferences` and
`ModernizationMaterialDifferences`.

## vm-assessment.csv (one row per VM)

| Column group | Columns |
|---|---|
| Identity | `Subscription`, `SubscriptionId`, `ResourceGroup`, `VM`, `VmResourceId`, `Region`, `Zone`, `PowerState`, `OsType`, `HyperVGeneration` |
| Current | `CurrentSku`, `CurrentSkuGeneration`, `VmFamily`, `CpuVendor`, `CpuArchitecture`, `vCPU`, `MemoryGB`, `CurrentVcpu`, `CurrentMemoryGB` |
| Retirement | `AffectedByRetirement` (Yes/No/Unknown), `EvidenceClass`, `RetirementStatus`, `RetirementDate`, `TimeRemaining`, `Urgency` |
| Recommendation | `RecommendedSku`, `RecommendedSkuGeneration`, `TargetCpuVendor`, `TargetCpuArchitecture`, `TargetvCPU`, `TargetMemoryGB`, `RecommendedVcpu`, `RecommendedMemoryGB`, `CompatibilityScore`, `ScoreBand`, `CpuVendorPreserved`, `CpuVendorChangeRequired`, `RegionAvailable`, `SkuRegionalAvailability`, `ModernizationStatus`, `RecommendationReason` |
| Quota and readiness | `QuotaStatus`, `QuotaFamily`, `QuotaMinIncreaseFamily`, `QuotaMinIncreaseRegional`, `DeploymentReadiness`, `Confidence`, `Action`, `NextStep`, `Wave` |
| Alternatives | `AlternativeSku`, `AlternativeScore`, `AlternativeReason`, `ThirdCandidateSku`, `NewerGenerationIfConverted`, `NoCandidateReason`, `VendorChangeReason` |
| Explanation | `MaterialDifferences`, `ValidationItems` |
| Optional | `RightsizingStatus`, `RightsizingSuggestedSku`, `CurrentMonthlyUSD`, `TargetMonthlyUSD` (pricing is on by default; empty with `-SkipPricing`, when the Retail Prices API is unreachable or when no list price exists) |
| Evidence | `MicrosoftSource`, `AnnouncementUrl`, `MigrationGuideUrl` |
| Data quality | `DQ_RetirementDate`, `DQ_CpuVendor`, `DQ_RegionalAvailability`, `DQ_Quota`, `DQ_PhysicalCapacity`, `LifecycleNotes` |
| Microsoft lifecycle stage (appended) | `LifecycleStage` |
| Retirement vs modernization (appended) | `RetirementTargetSku`, `RetirementTargetGeneration`, `RetirementQuotaStatus`, `ModernizationTargetSku`, `ModernizationTargetGeneration`, `ModernizationTargetSource`, `ModernizationPath`, `ModernizationComplexity`, `ModernizationReadiness`, `ModernizationQuotaStatus`, `ModernizationPeakQuotaStatus`, `MigrationQuotaModel`, `RecommendedMigrationPath`, `ModernizationValidationItems` |
| Modernization differences (appended last) | `ModernizationMaterialDifferences` - changed, reduced or improved attributes of the modernization target against the current size (`Attribute: current -> target; ...`); empty without `--check-modernization`, without a target or when already v6/v7 |

Columns are written in the order listed; the retirement-vs-modernization group is appended after `LifecycleNotes` and
`ModernizationMaterialDifferences` is the last column, so existing column positions are unchanged. Columns are never
renamed or removed within 1.x.

**Overlapping columns.** Some columns carry the same value for most VMs (the CSV keeps both for compatibility):

| Columns | Relationship |
|---|---|
| `vCPU` and `CurrentVcpu`; `MemoryGB` and `CurrentMemoryGB` | Identical aliases of the current size |
| `TargetvCPU` / `TargetMemoryGB` and `RecommendedVcpu` / `RecommendedMemoryGB` | Same unless the VM is already modern (the `Recommended*` columns then show the current size) |
| `RecommendedSku` / `RecommendedSkuGeneration` and `RetirementTargetSku` / `RetirementTargetGeneration` | `Recommended*` is the primary candidate (promoted to the v6/v7 target when a direct move passes all checks); `RetirementTarget*` is the retirement target and is empty for VMs not in retirement scope |
| `RegionAvailable` and `SkuRegionalAvailability` | Same unless a modernization assessment exists, in which case `SkuRegionalAvailability` is the modernization target's availability |

## candidates.csv

One row per VM x evaluated candidate: `Role` (Primary/Secondary/Third/Candidate), `Variant` (Closest size /
Capability-preserving / Larger size), availability, score, band, rejection reason, review gates, and the 12 score-component
columns. `Larger size` marks a size added because the closest size of its series did not qualify; the VM's
`ValidationItems` (and `NoCandidateReason` when nothing qualifies) say why. `assessment.json` carries the same value as
`recommendation.primary.variant` (and `secondary`, `third`).

## quota-impact.csv

The QuotaRow fields, in QuotaRow order. Family rows use the ARM quota name (e.g. `standardddsv5family`); regional rows
use `cores`. `Scope` is one of:

- `Retirement` - retirement-affected and unconfirmed VMs moving to their retirement target.
- `Retirement+Modernization` - every VM with an action moving to `RecommendedSku` (retirement plus optional Wave 4 moves).
- `Modernization` - only with `--check-modernization`: every VM with a strategic v6/v7 target, with steady-state and peak demand.

The HTML quota table is a display view of these rows: a `Retirement+Modernization` row that repeats its `Retirement` row
is shown once and rows that need no action are omitted (every `Modernization` row is kept). The CSV always keeps every row.

## snapshot/ (only with -SaveSnapshot)

- `snapshot.json` - manifest: `SnapshotVersion`, `Tool`, `ToolVersion`, `CapturedUtc`, `AsOfDate`, `TenantId`, `TenantName`, `CatalogSource`,
  `SubscriptionId[]`, `Region[]` (capture scope; empty = all), `Subscriptions`, `Vms`, `IncludeRightsizing`, `RightsizingLookbackDays`.
  Written last, so an interrupted capture has no manifest and cannot be replayed.
- `retirement-catalog.json` - the Microsoft retirement evidence used by the capture; a replay reuses it under `CatalogSource`.
- `responses/<sha256>.json` - one recorded Azure read each: `{ Kind: az|rest, Request, Failed, Text }`. Requests are keyed
  without credentials; access tokens are never stored and the signed-in account is masked.

## retirement-evidence.json

Includes an additive top-level `disclaimer` property with the same standard short disclaimer as `assessment.json`.
HTML and Markdown render one labeled section near the bottom. CSV schemas are unchanged and have no disclaimer
rows or columns. Printed HTML/browser PDF includes the HTML section; there is no dedicated PDF output.

Contents:

- Microsoft source metadata
- Series-level evidence: retired-list, End of Life (previous-gen) and guide-FAQ entries, recommended targets, notes
- Unmapped series
- Lifecycle entries that are not VM sizes (`nonVmSizeEntries`, e.g. Dedicated Host SKUs)
- Isolated-size targets
- Advisor and Service Health corroboration rows

## Enumerations

| Field | Values |
|---|---|
| EvidenceClass | Confirmed Retirement, Retirement Announced, Already Retired, Modernization Recommended, No Retirement Announced, Unable to Confirm |
| Urgency | Already Retired, Less than 12 Months, 12-24 Months, 24-36 Months, More than 36 Months, No Retirement Announced, Unable to Determine |
| RegionAvailable | Available, Restricted, Not Available, Zone Restricted |
| QuotaStatus | Quota OK, Quota Increase Required, Quota Information Unavailable, Manual Validation Required |
| ModernizationStatus | Not Evaluated, Modernize to v7, Modernize to v6, Already on modern generation, No suitable modern SKU found, SKU unavailable in region, Insufficient quota, Architecture mismatch |
| DeploymentReadiness | Ready, Quota Increase Required, SKU Restricted, Regional Limitation, Capacity Validation Required, Manual Review Required, Not Applicable |
| Confidence | HIGH, MEDIUM, LOW, N/A |
| Action | No Action Required, Modernization Optional, Plan Migration, Migration Required Within 36/24/12 Months, Immediate Migration Required, Manual Review Required |
| NextStep | Proceed with Resize (change window) (readiness `Ready` and confidence `HIGH`), Validate Before Resize (readiness `Ready` but confidence below `HIGH`; the open items are in `ValidationItems`), Request Quota Increase, Validate Regional Capacity, Manual Review Required, None |
| Wave | Wave 1 - Urgent, Wave 2 - Near Term, Wave 3 - Planned, Beyond Horizon, Review - Unconfirmed, Wave 4 - Modernization, None |
| Data quality | Verified, Partially Verified, Unable to Verify, Not Evaluated |
| RetirementQuotaStatus, ModernizationQuotaStatus, ModernizationPeakQuotaStatus, PeakStatus | Same values as QuotaStatus |
| LifecycleStage | Retired, End of Life (Microsoft-announced retirement; includes every series on the End of Life list), Not End of Life (Current or Extended; Microsoft defines these per VM family), Unknown |
| ModernizationTargetSource | Selected (modernization candidate), Primary (v6/v7 recommendation), QuotaBlocked (v6/v7 option blocked by aggregate quota), Convertible (`NewerGenerationIfConverted`, blocked only by Gen1 and/or SCSI) |
| ModernizationPath | Already Modern, Direct Resize, SCSI to NVMe + Resize, Gen1 Modernization + Resize, Gen1 + NVMe + Resize, Redeploy / Rebuild Review, No Validated Modern Target |
| ModernizationComplexity | None, Low, Medium, High, Unknown |
| ModernizationReadiness | Current, Ready, Convertible, Quota Increase, Redeploy Review, Manual Review |
| MigrationQuotaModel | InPlace, SideBySide (per VM); InPlace, SideBySide, Mixed (per quota row) |

## Retirement target vs modernization target

The appended VM columns separate the lifecycle remediation decision from the strategic modernization decision, so
consumers do not need to infer intent from `RecommendedSku`:

- `RetirementTargetSku` / `RetirementTargetGeneration` / `RetirementQuotaStatus` - the supported replacement used to
  remediate an affected (`Yes`) or unconfirmed (`Unknown`) SKU, and its quota in scope `Retirement`. This can be a v5
  size. When `--check-modernization` promotes a v6/v7 size into `RecommendedSku`, the retirement target remains the
  original recommendation (`Candidates.Modernization.ExistingRecommendation`).
- `ModernizationTargetSku` / `ModernizationTargetGeneration` / `ModernizationTargetSource` - the strategic v6/v7
  destination. Populated only with `--check-modernization` (for already-modern VMs it is the current SKU).
- `ModernizationPath`, `ModernizationComplexity`, `ModernizationReadiness`, `MigrationQuotaModel`,
  `ModernizationQuotaStatus`, `ModernizationPeakQuotaStatus`, `ModernizationValidationItems` - derived planning data for
  the modernization target; empty without `--check-modernization`.
- `RecommendedMigrationPath` - the sequence connecting the current SKU, the retirement target (when needed) and the
  modernization target, e.g. `Retire to Standard_D4ds_v5 -> modernize to Standard_D4s_v6 (requires SCSI to NVMe conversion)`.

`RecommendedSku`, `QuotaStatus`, `DeploymentReadiness` and `NextStep` keep their previous meaning (the primary
recommendation).
