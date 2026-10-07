# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Optional `--check-modernization` assessment for every VM, preferring suitable same-vendor/same-architecture v7,
  then v6 SKUs, with regional availability, capability gates, quota status, explicit modernization status and reason.

### Changed

- Renamed the project, skill paths, command, generated report branding, output folders and release artifacts to
  `VMSKURetirementReport` (`vm-sku-retirement-report` where the Agent Skills specification requires a lowercase slug).
- Corrected quota accounting for same-family allocated resizes and made modernization fallback quota-aware, so a
  deployable v6 size is preferred over a quota-blocked v7 size.
- Scoped SKU restrictions to the assessed region and downgraded base-series processor matches to Partially Verified.
- Made cached mode compatible with PowerShell 7.2, fail closed on migration-guide parser drift, and preserve the
  existing processor catalog when a refresh is incomplete.
- Hardened CSV and Markdown exports against formula/markup injection and made output folders collision resistant.
- Locked Pester and PSScriptAnalyzer to exact verified versions, pinned GitHub Actions to immutable commits, added a
  PowerShell 7.2 CI lane, and separated read-only release builds from write-enabled publication.

### Security

- Neutralized spreadsheet formulas in CSV exports while preserving raw JSON data.
- Removed the PowerShell Gallery publisher-check bypass and added committed dependency integrity hashes.

## [1.0.0] - 2026-10-06

First public release.

### Added

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
[1.0.0]: https://github.com/AzaryaShaulov/Azure/tree/main/Assessments/VMSKURetirementReport/dist