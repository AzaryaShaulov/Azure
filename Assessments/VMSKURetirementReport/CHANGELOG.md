# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- **A "Ready" VM no longer says "Proceed with Resize" when something is still open.** The next step is now
  `Validate Before Resize` whenever readiness is `Ready` but confidence is below `HIGH` (availability-set or scale-set
  member, removed temp disk, reduced disk throughput, an older-generation target, partially verified lifecycle evidence);
  `Proceed with Resize (change window)` is kept for `Ready` VMs with `HIGH` confidence. `NextStep` in the CSV, JSON, HTML and
  Markdown can therefore contain the new value; the other values are unchanged.
- **The estate summary no longer reads "no v6 modernization" next to v6 paths.** `ModernizeToV7` / `ModernizeToV6` count
  only the VMs that can move by a direct resize, so a VM whose v6 target needs a Gen1 to Gen2 change or a SCSI to NVMe
  conversion first was in neither; the sample showed 0 next to five v6 paths. `assessment.json` `summary` gains
  `ModernizationTargetV7` / `ModernizationTargetV6` (a v7 / v6 target on any path), `ConvertibleToV7` / `ConvertibleToV6`
  (the part that needs a conversion first) and `ActionableVms` (VMs with an action); no existing field changed. In
  `executive-summary.md` the old rows are renamed "Direct resize to v7/v6 (every check passes)", the new ones are added, and
  all v6/v7 rows read `not evaluated` when the modernization check did not run instead of a misleading 0. The groupings
  cover different sets of VMs (all VMs, only VMs with an action, or only VMs on retiring sizes); each heading in the
  executive summary now says which, and `references/output-schema.md` documents every counter and grouping.
- **One "modernization" count in the HTML.** The index tile "Optional modernization" printed the number of VMs on Microsoft's
  previous-generation list, while the Subscriptions table, each subscription page and the bottom line counted Wave 4 VMs, so
  the numbers could differ and capacity-limited sizes (action `Plan Migration`) were called optional. All of them now count
  the Wave 4 VMs, the tile is labelled "Modernization (Wave 4)", the table column "Wave 4", and the bottom line no longer
  says the upgrade is optional.
- **CI and the release workflow run on Windows only.** The tool runs through Azure CLI and local PowerShell, as a GitHub
  Copilot skill or as a standalone script; Linux, macOS and containers are not supported. The Linux and macOS test legs
  and the Linux container job were removed, and the Package and release jobs moved to a Windows runner. PowerShell 7.2 and
  later stay supported: a new `powershell-compat` job runs the complete mock assessment under PowerShell 7.2.24 and 7.4.21,
  installed from pinned, checksum-verified official archives, and the main job runs on the runner's own PowerShell. The
  README, `SKILL.md` and `CONTRIBUTING.md` no longer claim Linux or macOS support.
- **The release ZIP no longer contains the tests, and it has a README.** The package held the whole skill folder, including
  `tests/` (Pester files, fixtures and a mock `az.ps1`), and no README or changelog. It now holds the skill folder without
  `tests/` plus a short `README.md` (requirements, how to run, what is in the folder, the disclaimer), `CHANGELOG.md`,
  `LICENSE` and `THIRD-PARTY-NOTICES.md` (26 files instead of 35). `./build.ps1 -Task Package` compares the finished ZIP with
  the skill folder and fails on a missing or unexpected file; `-DistPath <folder>` builds somewhere other than `dist/`.
  The installation through `npx skills add` copies the skill folder from the repository as it is, so it still includes
  `tests/`. The checksummed ZIP in `dist/` is not rebuilt here; it is rebuilt when the release is made.
- **CI checks the sample and the HTML, and the release tag names the project.** A new `sample-diff` job runs the new
  `./build.ps1 -Task SampleDiff`, which rebuilds the sample offline in a scratch folder and fails when it differs from
  `examples/sample-report` (generation time and line endings are ignored), so a change that alters the sample but was
  committed without regenerating it is caught. An informational `browser-smoke` job opens the sample in Edge with
  `tools/browser-smoke.js` (`playwright-core` 1.64.0, install scripts off); it does not fail the workflow. The release workflow
  starts on tags named `vm-sku-retirement-report-vX.Y.Z` instead of any `vX.Y.Z` tag of the repository, and still checks the
  tag against the tool version. Release maintainers use the new tag name (see `CONTRIBUTING.md`).
- `dependencies.psd1` no longer records a `PackageHash` for each locked tool: it was never verified (the build only sees the
  installed module, which its `TreeHash` covers). `tools/browser-smoke.js` now says so when the report folder has no page
  to open.

### Fixed

- **CI could never pass.** The check that verifies the locked Pester and PSScriptAnalyzer modules hashed every file under
  the installed module folder in culture-sensitive order, including the install-specific `PSGetModuleInfo.xml`, so the
  committed hashes only matched the machine they were computed on and every "Lint and test" job stopped in Bootstrap,
  including the Windows job. The hash now covers a manifest of the module files in ordinal path order, includes hidden
  files and ignores installer metadata, so it is independent of the culture-specific sort order and of the installer. A
  mismatch prints the module's file manifest, and `dependencies.psd1` holds the new hashes.
- The PowerShell 7.2 compatibility check never ran (its container image tag did not exist). It is replaced by the Windows
  `powershell-compat` job described above.
- **Failed Azure reads were invisible in the results.** When the Resource SKUs call was denied, returned bad JSON or nothing,
  every affected VM silently became `Manual Review Required` / `LOW` with no reason, no detail panel and one generic
  console warning; when the quota call failed there was no warning at all, and a Resource Graph query that stopped after
  its first page (Advisor, Service Health, disk-encryption extensions) or an SKU list cut off after 50 pages gave only a
  verbose log line. Each such failure is now recorded with what was being read, the subscription and region, the sanitized
  reason and its effect, and shown in the console, `run.log`, `assessment.json` (`collectionIssues`, always an array), the
  executive summary and a callout on the HTML pages. The cause is added to the VM's low-confidence reasons and
  `RecommendationReason`, and every listed VM without a recommendation gets a detail panel that explains why. Error text now
  also masks the signed-in identity's object id. A REST failure that the `az vm list-skus` fallback covered is noted in
  `run.log` only. Rightsizing and pricing failures are listed with the other problems.
- **Stale or incomplete retirement evidence did not stand out.** The cached catalog had no maximum age, and a live parse that
  silently lost series or list rows (for example after a Learn page format change) was used without a word, which would turn
  retiring sizes into "No Retirement Announced". The report now warns when the cache is more than 90 days older than the
  assessment date, and when the live parse lacks series that the cache has or covers fewer series on the retired-sizes or
  previous-generation list; `Update-Catalogs.ps1` then keeps the existing cache. The warning is in the console,
  `retirement-evidence.json`, the executive summary and the HTML evidence callout.
- **Malformed JSON from a successful `az` call escaped `-AllowFailure`.** A tolerated call (quota, Resource SKUs, optional
  Resource Graph queries) that exited 0 but printed text that is not JSON still threw, and in the parallel quota runspaces
  that surfaced as an unwrapped `ConvertFrom-Json` error record with no subscription or region. It now returns nothing and
  records "The answer is not valid JSON: ..." for that subscription and region (a call that is not tolerated throws the same
  sanitized message with the command). The quota reader also records an answer it cannot read (a row without a quota name,
  a non-numeric limit) instead of letting the error escape.
- **A CPU vendor inferred from the size name no longer leaves confidence at `HIGH`.** The confidence calculation says CPU
  vendor must be verified for `HIGH` but never looked at the vendor's data quality, so a size missing from the processor
  catalog (for example an older HB or NC size, resolved as Intel from its name) could still be `HIGH`. A VM whose current
  or recommended size has only a `Partially Verified` vendor now gets the validation item "CPU vendor not verified for ...",
  and with it `MEDIUM` confidence (or `LOW` together with another item). The processor catalog was refreshed with
  `scripts/Update-Catalogs.ps1` and gained eight newer series (Ebdsv5, Ebsv5, Ecasv5/Ecadsv5, Ecasccv5/Ecadsccv5, Ecedsv6,
  Ecesv6, Laosv5, Lasv5); no existing entry changed. The older series (the original HB, G, F, L and NC) are not covered by
  Microsoft's current size-series pages, so the generator cannot produce them: their vendor stays inferred from the name and
  is flagged "not verified" (the original HB, which is AMD, still resolves as Intel until it is checked).
- **An older-generation target came without a note.** When the newest valid size of the family was restricted or not offered
  for the VM, the primary silently fell back to an older generation and the VM stayed `Ready` with `HIGH` confidence. It now
  gets the validation item "Newer generation unavailable: ..." (naming the size and its availability), which lowers confidence
  and sets the next step to `Validate Before Resize`.
- **JSON arrays and empty CSV files had unstable shapes.** In `assessment.json` a single group in a `summary.By*` list
  (a one-subscription or one-region estate, the common case) was written as an object, no groups as `null`; the top-level
  `quota.family` and `quota.regional` and the per-VM `strategy.ValidationItems` and `strategy.TargetComparison` had the same
  problem, and a VM with exactly one validation item got a bare string. The documented array fields are now always arrays
  (`[]` when empty). `vm-assessment.csv`, `candidates.csv` and `quota-impact.csv` were zero-byte files when there were no
  rows, which fails a Power BI refresh; they now always contain the header row. The values of
  `materialDifferences[].Current` / `.Target` are documented as display values of mixed type rather than changed.
- **Replacement sizes could be taken from another VM's evaluation.** VMs with the same size and settings share one
  candidate evaluation, but the sharing key left out whether the VM is placed through a dedicated host group, whether the
  VM reported its disk controller and how many NICs use Accelerated Networking. Which VM was assessed first therefore decided
  whether a VM on a host group lost its Dedicated Host review, whether "controller not reported" showed on the wrong VM and
  which NIC count appeared in a rejection. The key now includes all three, and a test fails if candidate selection or
  scoring ever reads a VM property that is not in the key.
- **A larger size of a series was never tried.** Only the smallest fitting size of each series was checked, so when that
  size failed a size-dependent check (more NICs or data disks than it allows, or zone availability) or was restricted, the
  whole series was dropped even though the next size would pass. A VM with three NICs got `Manual Review Required` / `LOW`
  with no recommendation although a same-series size with four NICs was offered, or silently fell back to an older
  generation or another CPU vendor. When the smallest size of a series does not qualify for such a reason, the next sizes are
  now evaluated (`primarySelection.maxLargerSizeSteps` in `data/scoring-weights.json`, default 2, 0 turns it off) and the
  first one that qualifies is offered as the new *Larger size* variant, never smaller than the current size. The
  recommendation then carries the validation item "Larger size: ... is larger than the closest fit ..., which does not qualify
  (...)", so confidence is below `HIGH` and the next step is `Validate Before Resize`; the same sentence is added to the
  modernization reason. When nothing qualifies, `NoCandidateReason` lists the larger sizes that were tried and says that
  sizes beyond the bound were not evaluated. Nothing changes for a VM whose closest size qualifies. The new `Variant` value
  appears in `candidates.csv` and `recommendation.*.variant`.
- **The rightsizing suggestion ignored the checks that govern a migration target, and was not repeatable.** With
  `-IncludeRightsizing`, the suggested half size was any size of the series with half the vCPUs that was not restricted: a
  VM with three NICs was pointed at a size that allows two, a zonal VM at a size that is not offered in its zone, and
  constrained-vCPU sizes (billed for the full core count) competed with the real half size, so the answer changed from
  run to run (four different answers in eight runs of the same input). The suggestion must now pass the same mandatory
  checks as a migration target, is never a constrained-vCPU size, is chosen in a fixed order, and the note says why when
  no size qualifies. A VM with no memory left at the 5th percentile was read as having low memory use and flagged; it is
  now `No Opportunity`. The note shows the highest hourly maximum next to the P95 of the hourly averages, because
  averaging hides short bursts. The percentile helper, the metrics reader (batching, retry, give-up), the suggestion and a
  run with VMs are now tested; the mock `az` accepts `MOCK_AZ_SKUS_FILE` to serve a test's own Resource SKU list.

## [1.2.0] - 2026-10-12

### Changed

- **Current Hyper-V generation and disk controller are the VM's own.** In the *Current vs target size* comparison, the
  current-column value for *Hyper-V Generation* and *Disk Controller* is now the VM's generation (`V1`) and controller
  (`SCSI`) instead of everything its size supports (`V1,V2`). The row is `Same` when the target supports the VM's value
  and `Changed` otherwise, so a Gen2 VM moving to a Gen2-only size no longer shows a false change. This changes values in
  `strategy.TargetComparison` (JSON), `MaterialDifferences` and `ModernizationMaterialDifferences` (CSV); scoring and the
  compatibility checks are unchanged (they already used the VM's own values).
- The Details toggle text is larger (0.8rem), and in dark mode the opened toggle uses dark text on the teal (white was
  1.9:1; now 7.9:1).
- VM row, detail-row and toggle ids now end in a short hash of the resource group and VM name, because two different
  pairs (`app-prod`+`db`, `app`+`prod-db`) produced the same id; the VM name is no longer an in-page link.
- The detail block no longer asks for a quota step when the VM has no target, treats `https://` in a validation item as
  text rather than a "Topic:" prefix, keeps the VM name and resource group selectable, and opens *Show all attributes*
  when printed.
- **Collapsible VM details under each VM row.** The separate *VMs with Retiring SKUs details* section and its
  navigation link are gone. Each row of the *VMs with Retiring SKUs* table has a **Details** toggle (and the whole row
  toggles) that opens a tinted, edged block directly under that VM; an *Expand all details* switch opens every block.
  The report stays script-free: the toggle is a hidden checkbox + label and a CSS `:has()` rule. Browsers without `:has()`
  and printed reports show every block open. The block is shorter and ordered by what the reader needs: a header with
  the move (green arrows), badges, wave, retirement date, next step and *Blockers* chips; *What to do* (one numbered
  list merging the quota request and remediation steps); *What changes* (only the attributes that differ, with *Show
  all N attributes*); *Validate before resizing* (two columns, bold topics, wording unchanged); and *Recommended sizes*.
  `-ExtendedDetails` adds the facts summary, explanations, mandatory checks and every evaluated size. `-HtmlMaxVmDetails`
  now caps the VMs that get details.
- **One table and one detail block per VM.** The *VMs with Retiring SKUs* table and each VM's details now carry the required
  retirement target and, with `--check-modernization`, the optional v6/v7 target, path and blockers, so each VM is
  rendered once instead of four times (the sample subscription page is about 15% smaller). The table gains the
  retirement date, stage, material changes, next step, readiness and confidence for every VM; its disk-capability
  column is replaced by the material changes and the details' comparison table.
- The *Current size*, *Retirement target* and *Modernization target* columns of that table use the same layout, one
  attribute per line: Vendor (CPU vendor), vCPU, vRAM, VM Gen (Gen1 or Gen2) and Disk controller (SCSI or NVMe). For a
  target the VM Gen and Disk controller lines list what the size supports, followed by its score and quota status (and
  the modernization status).
- *Material changes* and *Next step* use the same *Label: value* lines instead of coloured pills: one
  `Attribute: current -> target` line per difference, and *Readiness* and *Confidence* lines. The *Action* line
  (for example *Migration Required Within 24 Months* or *Plan Migration*) is no longer repeated in *Next step*; a VM that
  needs no action shows *No action required*. The severity colour is on the text, so the value is readable without it.
  The *Retirement target* column is 20% wider.
- VM cards are shorter by default. The facts summary (Microsoft status, action, recommended size, targets, path,
  quota, candidate series), *Assessment explanations* and *Mandatory requirement checks* are shown only with the
  new `-ExtendedDetails` switch, and the sizes table lists only the Primary, Secondary and Third sizes (headed
  *Recommended sizes*, with a note of how many more were evaluated); `-ExtendedDetails` lists every evaluated size
  (*Sizes evaluated*, no longer capped at eight). The badge hover text still carries the explanations.
- The table's v6/v7 *Migration path* column (formerly *Path and blockers*) keeps only the short path label, such as
  *Gen1 + NVMe + Resize*, *SCSI to NVMe + Resize* or *No Validated Modern Target*. The sequence sentence and the blocker
  text are no longer repeated there; they are in each VM card (*Blockers and required changes*).
- The blue *Bottom line* box and the information callouts on the index and subscription pages are slimmer: a thin accent
  edge, smaller radius, tighter padding and smaller type.
- The tenant index no longer has a *Quota Actions* section (quota actions stay on each subscription page, and the bottom
  line points there), and its *Migration Waves* section is collapsed by default.
- The README checksum verification step now prints a green `Verified: SHA-256 checksum matches (<hash>)` line when the
  package checksum matches; a mismatch still stops with *Package checksum verification failed.*
- README *Option A* and *Option B* are collapsed sections that expand on select, so the two ways to run the tool are
  easier to scan.
- The badge legend above the *VMs with Retiring SKUs* table is one slim panel (a row each for Microsoft status,
  confidence, readiness and score, with the badges inline) instead of four tall cards, about 60% shorter at typical
  widths. The caveat that neither *Ready* nor *HIGH* guarantees a successful resize stays visible; the longer
  explanation is in a collapsed *More about confidence and readiness* note that is expanded when printed.
- The card's *Current vs target size* table compares the current size with the retirement target and the modernization
  target (Attribute, Current, Retirement target, Modernization target, Note), and now also renders for convertible
  modernization targets. One compatibility-gate table (a result column per target) and one sizes-evaluated table replace
  the duplicated per-track tables.
- The *Current vs target size* table in each VM card is compact (smaller type and padding, sized to its content instead
  of the full card width). The *Upgrade and Modernization Scenarios* section (formerly *Upgrade Path and SCSI to NVMe
  Guidance*) is collapsed and now combines the upgrade
  sequence, the former *Migration Path Examples* (now recommended steps with an example for each path) and the Microsoft
  Learn links. *Cross-Vendor Migration Warnings*, *SKU Family Quick Reference*, *CPU Vendor from SKU Name* and *Known
  Limitations* use slimmer headers, tighter rows and smaller callouts.
- Removed the *Part 2 - Optional: v6/v7 Modernization* band, its overview tile and navigation group, and the *v6/v7
  Generation Modernization Paths* section (action groups, contextual guidance and path examples). The v6/v7 target, path
  and blockers stay in the table and cards; the overview tile and band now read *Required* without a part number.
- The per-VM modernization table and its extended rows are removed from the HTML.
- One quota table with steady-state and peak demand replaces the separate quota-impact table. A `Retirement+Modernization`
  row that repeats its `Retirement` row is shown once in the HTML; `quota-impact.csv` keeps every scope.
- `detailed-report.md` renders the same current-vs-target comparison and uses the modernization readiness, target and path
  instead of the earlier status text that could contradict the target.
- Contradictory wording removed: the table no longer shows *v6/v7: No suitable modern SKU found* next to a convertible
  v6/v7 target. Readiness and confidence are labelled as relating to the retirement target.
- Standardized independent-tool and AS IS disclaimers in repository READMEs and assessment documentation.
  Generated HTML/Markdown reports include one labeled disclaimer near the bottom; both JSON outputs carry the
  same wording. CSV structures and assessment calculations are unchanged.

### Added

- `tools/browser-smoke.js`: optional Playwright smoke test of the HTML report (toggle, whole-row click, expand all,
  print, narrow screens) for Edge/Chrome, Firefox and WebKit; development only, not packaged.
- `-ExtendedDetails` (HTML only): adds the confidence and readiness explanations, the mandatory requirement checks and
  every evaluated size to each VM card. Recorded in `assessment.json` under `parameters`.
- A *Gen1 VMs* card on the tenant index and on every subscription page: the number of VMs on Hyper-V generation 1, out
  of the VMs in that scope.
- `strategy.TargetComparison` in `assessment.json`: one row per attribute with the retirement and modernization target
  results, computed once and used by the HTML and Markdown reports.
- `ModernizationMaterialDifferences`, appended as the last `vm-assessment.csv` column. All 87 earlier columns keep their
  names and positions.
- The CSV overlapping columns (aliases) are documented in the output schema.

### Fixed

- Facts, legend items and badges no longer overflow the page at 320 px; table header SKU boxes are readable.

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
[1.2.0]: https://github.com/AzaryaShaulov/Azure/tree/main/Assessments/VMSKURetirementReport/dist/VMSKURetirementReport-v1.2.0.zip
[1.1.2]: https://github.com/AzaryaShaulov/Azure/tree/main/Assessments/VMSKURetirementReport/dist
[1.1.0]: https://github.com/AzaryaShaulov/Azure/tree/main/Assessments/VMSKURetirementReport/dist
[1.0.0]: https://github.com/AzaryaShaulov/Azure/tree/main/Assessments/VMSKURetirementReport/dist