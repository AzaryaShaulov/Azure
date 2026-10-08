# Output schema (v1.0)

All files are written to the run folder. CSVs are UTF-8 with headers. `assessment.json` is the complete,
machine-readable result for Azure Workbooks, Power BI, Excel, Logic Apps, PowerShell, Python and pipelines.

## assessment.json

```text
{
  schemaVersion: "1.0", tool: "VMSKURetirementReport", generatedUtc, asOfDate, tenant: { Id, Name },
  signedInAccount (masked, e.g. "j****@contoso.com", unless -IncludeOperatorAccount),
  dataSource: "Live" | "Snapshot captured <yyyy-MM-dd HH:mm> UTC",
  parameters: { SubscriptionId, Region, HorizonMonths, OfflineCatalog, QuotaSafetyPct, MaxCandidates, CheckModernization, IncludeRightsizing, IncludeOperatorAccount, KeepRawData, SaveSnapshot, FromSnapshot, HtmlIncludeOptionalModernization, HtmlMaxVmDetails, ... },
  disclaimer,
  catalog: { source: "Live" | "Cached (<utc>)", warning, sources: [ { Name, Url, Title, UpdatedAt, GitCommitId, RetrievedUtc } ], unmappedSeries: [...],
             nonVmSizeEntries: [ { Category, Name, Status, PlannedRetirementDate, GuideUrl, SourceUrl } ] },
  counts: { Vms, Nics, Disks, AdeExtensions, AdvisorRetirement, ServiceHealthRetirement },
  summary: { <estate counts>, ByEvidenceClass[], ByWave[], BySubscription[], ByRegion[], ByCurrentSku[], ByCurrentSkuFamily[],
             ByRecommendedSku[], ByRecommendedSkuFamily[], ByCpuVendor[], ByRetirementDate[], ByMigrationPriority[], ByDeploymentReadiness[] },
  quota: { family: [QuotaRow], regional: [QuotaRow] },
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
             ModernizationPath, Complexity, ModernizationReadiness, ValidationItems[], RecommendedMigrationPath }
```

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
| Optional | `RightsizingStatus`, `RightsizingSuggestedSku`, `CurrentMonthlyUSD`, `TargetMonthlyUSD` |
| Evidence | `MicrosoftSource`, `AnnouncementUrl`, `MigrationGuideUrl` |
| Data quality | `DQ_RetirementDate`, `DQ_CpuVendor`, `DQ_RegionalAvailability`, `DQ_Quota`, `DQ_PhysicalCapacity`, `LifecycleNotes` |
| Retirement vs modernization (appended) | `RetirementTargetSku`, `RetirementTargetGeneration`, `RetirementQuotaStatus`, `ModernizationTargetSku`, `ModernizationTargetGeneration`, `ModernizationTargetSource`, `ModernizationPath`, `ModernizationComplexity`, `ModernizationReadiness`, `ModernizationQuotaStatus`, `ModernizationPeakQuotaStatus`, `MigrationQuotaModel`, `RecommendedMigrationPath`, `ModernizationValidationItems` |

Columns are written in the order listed; the retirement-vs-modernization group is appended after `LifecycleNotes`, so
existing column positions are unchanged.

## candidates.csv

One row per VM x evaluated candidate: `Role` (Primary/Secondary/Third/Candidate), `Variant` (Closest size /
Capability-preserving), availability, score, band, rejection reason, review gates, and the 12 score-component columns.

## quota-impact.csv

The QuotaRow fields, in QuotaRow order. Family rows use the ARM quota name (e.g. `standardddsv5family`); regional rows
use `cores`. `Scope` is one of:

- `Retirement` - retirement-affected and unconfirmed VMs moving to their retirement target.
- `Retirement+Modernization` - every VM with an action moving to `RecommendedSku` (retirement plus optional Wave 4 moves).
- `Modernization` - only with `--check-modernization`: every VM with a strategic v6/v7 target, with steady-state and peak demand.

## snapshot/ (only with -SaveSnapshot)

- `snapshot.json` - manifest: `SnapshotVersion`, `Tool`, `ToolVersion`, `CapturedUtc`, `AsOfDate`, `TenantId`, `TenantName`, `CatalogSource`,
  `SubscriptionId[]`, `Region[]` (capture scope; empty = all), `Subscriptions`, `Vms`, `IncludeRightsizing`, `RightsizingLookbackDays`.
  Written last, so an interrupted capture has no manifest and cannot be replayed.
- `retirement-catalog.json` - the Microsoft retirement evidence used by the capture; a replay reuses it under `CatalogSource`.
- `responses/<sha256>.json` - one recorded Azure read each: `{ Kind: az|rest, Request, Failed, Text }`. Requests are keyed
  without credentials; access tokens are never stored and the signed-in account is masked.

## retirement-evidence.json

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
| NextStep | Proceed with Resize (change window), Request Quota Increase, Validate Regional Capacity, Manual Review Required, None |
| Wave | Wave 1 - Urgent, Wave 2 - Near Term, Wave 3 - Planned, Beyond Horizon, Review - Unconfirmed, Wave 4 - Modernization, None |
| Data quality | Verified, Partially Verified, Unable to Verify, Not Evaluated |
| RetirementQuotaStatus, ModernizationQuotaStatus, ModernizationPeakQuotaStatus, PeakStatus | Same values as QuotaStatus |
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
