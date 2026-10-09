# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- Standardized independent-tool and AS IS disclaimers in repository READMEs and assessment documentation.
  Generated HTML/Markdown reports include one labeled disclaimer near the bottom; both JSON outputs carry the
  same wording. CSV structures and assessment calculations are unchanged.

## [1.1.2] - 2026-10-08

### Added

- Repository links in HTML report footers and Markdown summaries/details.

### Changed

- Renamed the subscription modernization section to *v6/v7 Generation Modernization Paths* and aligned README
  screenshot labels. Removed Complexity from the HTML modernization table and expanded details; existing CSV/JSON
  complexity fields remain available for compatibility.

### Fixed

- Qualified Ready and HIGH confidence explanations: assessed platform/quota checks do not guarantee hardware
  allocation, guest/workload compatibility or a successful resize.
- Incomplete Retail Prices API pagination now discards that region's prices instead of silently using partial data.
  Completed regions retain their prices; the run warns, skips remaining pricing regions and records Partial or
  Unavailable rather than Done.
- VM detail confidence/readiness explanations are readable after keyboard or touch expansion, not only on hover.
  Badge labels wrap on narrow screens; closed VM detail bodies are visible in print.

## [1.1.0] - 2026-10-07

### Added

- Microsoft lifecycle stage per VM (`LifecycleStage`: Retired, End of Life, Not End of Life, Unknown) in the CSV, JSON,
  Markdown and HTML. Every series on the Microsoft End of Life list is reported as **End of Life**, with a link to the list,
  and listed in the HTML for modernization or SKU migration even before Microsoft publishes a date.
- `-SaveSnapshot` / `-FromSnapshot`: record a run's Azure reads and replay them later with different options (for example
  `--check-modernization`) without calling Azure. Snapshots contain no access tokens and mask the signed-in account; reports
  and `assessment.json` (`dataSource`) show when data was replayed. Snapshots also store the Microsoft retirement
  evidence, so a replay reproduces the capture, and replays warn when the data is more than 7 days old.
- `-HtmlIncludeOptionalModernization` to also list optional-modernization VMs in the HTML, and `-HtmlMaxVmDetails`
  (default 250) to cap per-VM HTML detail blocks on very large subscription pages.
- *Upgrade Path and SCSI to NVMe Guidance* section and contextual Microsoft Learn links (resize, SCSI to NVMe conversion,
  NVMe OS support and FAQ, Gen1 to Trusted launch, Gen2, MANA, sizes without temp disk).
- Optional `--check-modernization` assessment for every VM, preferring suitable same-vendor/same-architecture v7,
  then v6 SKUs, with regional availability, capability gates, quota status, explicit modernization status and reason.
- Retirement target vs strategic modernization target: appended `vm-assessment.csv` / JSON fields
  (`RetirementTargetSku`, `ModernizationTargetSku`, `RecommendedMigrationPath`, `ModernizationPath`,
  `ModernizationComplexity`, `ModernizationReadiness`, `MigrationQuotaModel`, retirement and modernization quota status,
  `ModernizationValidationItems`) and a `strategy` object per VM in `assessment.json`.
- Steady-state vs peak (side-by-side) quota planning: appended `quota-impact.csv` columns (`MigrationQuotaModel`,
  `SideBySideVmCount`, `SteadyStateRequiredVcpu`, `PeakMigrationRequiredVcpu`, `Peak*`) and a `Modernization` scope with
  `--check-modernization`. Gen1 -> Gen2 (Trusted launch upgrade) and redeploy paths are modeled side by side.
- *v6/v7 Modernization Readiness* section on subscription pages (KPIs, actionable table with expandable VM details,
  action groups, backend quota impact, guidance, migration-path examples).
- Guest validation items for NVMe driver readiness, MANA networking, temp-disk dependency and the Gen1 Trusted launch
  upgrade; redeploy review only when the guest OS is not supported by that upgrade.

### Changed

- VM detail cards label their badges (*Confidence: MEDIUM*, *Readiness: Ready*). Hovering a badge lists the items to
  validate first or explains the readiness value, and the legend now has a *Readiness* section.
- Retail PAYGO pricing is on by default (the *PAYGO / month* column, `CurrentMonthlyUSD` / `TargetMonthlyUSD`); use the
  new `-SkipPricing` to turn it off. `-IncludePricing` is still accepted. If `prices.azure.com` is unreachable the run
  warns once, continues without prices and records `pricingStatus: "Unavailable"` in `assessment.json`.
- Subscription pages separate *Part 1 - Required: Retirement remediation* (orange) from *Part 2 - Optional: v6/v7
  Modernization* (purple) with banners, coloured card edges, grouped navigation, Overview tiles, tinted target columns
  and a print page break before Part 2.
- HTML report lists only VMs with an announced Microsoft retirement date and a required action (CSV/JSON/Markdown still
  include every VM). Subscription pages: *VM Assessment* is now *VMs with Retiring SKUs* and *Recommendations in Detail*
  is now *VMs with Retiring SKUs details*, both directly under Overview. *Cross-Vendor Migration Warnings* is collapsed.
- Renamed the project, skill paths, command, generated report branding, output folders and release artifacts to
  `VMSKURetirementReport` (`vm-sku-retirement-report` where the Agent Skills specification requires a lowercase slug).
- Corrected quota accounting for same-family allocated resizes and made modernization fallback quota-aware, so a
  deployable v6 size is preferred over a quota-blocked v7 size.
- Scoped SKU restrictions to the assessed region and downgraded base-series processor matches to Partially Verified.
- `Retirement` quota scope now uses each VM's retirement target; `Retirement+Modernization` keeps its meaning. Existing
  CSV columns keep their order (new columns are appended). `Manual Validation Required` quota badges are now yellow.
- Made cached mode compatible with PowerShell 7.2, fail closed on migration-guide parser drift, and preserve the
  existing processor catalog when a refresh is incomplete.
- Hardened CSV and Markdown exports against formula/markup injection and made output folders collision resistant.
- Locked Pester and PSScriptAnalyzer to exact verified versions, pinned GitHub Actions to immutable commits, added a
  PowerShell 7.2 CI lane, and separated read-only release builds from write-enabled publication.

### Fixed

- VMs with identical configurations shared one cached candidate object, so a modernization quota decision for one VM
  could change another's recommendation. Each VM now gets its own copy.
- Modernization quota resolution re-aggregated the whole estate for every option of every VM (quadratic). It now updates
  aggregate demand incrementally with the same rules (1,000 modernizing VMs resolve in about 1.5 s).

### Security

- Neutralized spreadsheet formulas in CSV exports while preserving raw JSON data.
- Removed the PowerShell Gallery publisher-check bypass and added committed dependency integrity hashes.

## [1.0.0] - 2026-10-06

First public release.

### Added

- Microsoft lifecycle stage per VM (`LifecycleStage`: Retired, End of Life, Not End of Life, Unknown) in the CSV, JSON,
  Markdown and HTML. Every series on the Microsoft End of Life list is reported as **End of Life**, with a link to the list,
  and listed in the HTML for modernization or SKU migration even before Microsoft publishes a date.
- `vm-sku-retirement-report` agent skill (`skills/vm-sku-retirement-report/SKILL.md`), compatible with GitHub Copilot,
  Claude Code and other Agent Skills clients, and runnable directly from PowerShell 7.2+.
- **Retirement evidence** fetched live from Microsoft Learn (*retirements and capacity restrictions*, *End of Life
  sizes* and the *retired sizes modernization guide*), with provenance (URL, git commit, retrieval time) and a cached
  fallback catalog. Legacy page formats are still parsed. No retirement date is ever inferred: older series without a
  Microsoft date are optional modernization; End of Life series without a date are *Retirement Announced*.
- Size mappings for every series currently on the Microsoft lifecycle pages, including DCsv2, DCsv3/DCdsv3,
  DCas_cc_v5/DCads_cc_v5, ECas_cc_v5/ECads_cc_v5, HC and the Msv2/Mdsv2 isolated sizes. Lifecycle rows that are not VM
  sizes (Azure Dedicated Host SKUs) are reported separately as `nonVmSizeEntries` and noted on VMs that run on a
  dedicated host.
- **Estate inventory** through Azure Resource Graph across all accessible subscriptions (paged and chunked), joined
  to NICs, disks and disk-encryption extensions, with Advisor and Service Health retirement signals as corroboration.
- **Replacement engine** that:
  - keeps the same CPU vendor and architecture and recommends current-generation sizes only;
  - never downsizes;
  - follows Microsoft's recommended target series, including family/version targets such as "v6 and v7 D-family";
  - enforces mandatory gates (Hyper-V generation, disk controller, Premium/Ultra, accelerated networking, ephemeral
    OS, NIC/disk limits, security type, encryption at host, zone);
  - offers primary, alternative and third candidates (`-MaxCandidates` 1-3), plus the "newer generation if
    converted" option.
- 0-100 compatibility score, HIGH/MEDIUM/LOW confidence and per-field data-quality labels.
- Regional availability and subscription restrictions from the Compute Resource SKUs REST API.
- Aggregated VM-family and regional quota impact across subscriptions and regions, in two scopes (retirement only, and
  retirement plus modernization), with minimum and recommended increases.
- Migration waves (1-3 for retirements, *Beyond Horizon* from `-HorizonMonths`, 4 for modernization) and documented
  action / next-step values.
- Optional Azure Monitor rightsizing signal (`-IncludeRightsizing`) and retail PAYGO pricing (`-IncludePricing`).
- **Outputs** (default folder `<repository>/reports/<tenant>/<yyyy-MM-dd_HHmm>-VMSKURetirementReport`, git-ignored):
  - `assessment.json` (versioned schema), `vm-assessment.csv`, `candidates.csv`, `quota-impact.csv` and
    `retirement-evidence.json`;
  - `executive-summary.md` and `detailed-report.md`;
  - a responsive, dark-mode aware, script-free HTML report: tenant summary (waves, quota actions, subscriptions,
    evidence) and per-subscription pages (overview, quota actions, VM table with current -> recommended disk
    capabilities, per-VM detail), plus Cross-Vendor Migration Warnings and collapsible reference sections.
- **Privacy by default:** the signed-in account is masked unless `-IncludeOperatorAccount`; `run.log` uses a minimal
  transcript header; displayed paths hide the home directory; Azure CLI error text is sanitized; raw inventory dumps are
  written only with `-KeepRawData`. Inventory queries never read admin usernames, computer names, IP addresses or tags.
- `-TenantId` to assess any signed-in tenant without changing the Azure CLI default, and an up-front
  authentication check (`-AuthTimeoutSec`) that fails fast instead of hanging on an expired token.
- `build.ps1` (Bootstrap, Lint, Version, Test, Sample, Package), PSScriptAnalyzer settings, an offline Pester suite
  with a mock Azure CLI, a reproducible offline sample report, CI on Windows, Linux and macOS, and a tag-driven
  release workflow.
- `.github/copilot-instructions.md` with strict read-only rules for agents that access an Azure tenant.

[Unreleased]: https://github.com/AzaryaShaulov/Azure/commits/main/Assessments/VMSKURetirementReport
[1.1.2]: https://github.com/AzaryaShaulov/Azure/tree/main/Assessments/VMSKURetirementReport/dist/VMSKURetirementReport-v1.1.2.zip
[1.1.0]: https://github.com/AzaryaShaulov/Azure/tree/main/Assessments/VMSKURetirementReport/dist
[1.0.0]: https://github.com/AzaryaShaulov/Azure/tree/main/Assessments/VMSKURetirementReport/dist