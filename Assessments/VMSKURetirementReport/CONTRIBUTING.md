# Contributing

Thanks for helping improve VMSKURetirementReport. Contributions of all sizes are welcome: bug reports, Microsoft series
mappings, rule improvements, report UX and docs.

## Ground rules

1. **Evidence first.** Retirement status, dates and recommended replacement series must come from an official
   Microsoft source (Microsoft Learn lifecycle pages, migration guides, Azure Updates). Link it in the PR.
2. **Read-only forever.** The tool must never modify Azure resources. PRs that add write operations will be declined.
3. **Never guess.** If something cannot be verified, label it (`Unable to Verify`, `Unable to Confirm`) rather than
   inferring it.
4. **No real customer data.** Tests, fixtures, screenshots and issues must use synthetic data such as `Contoso`,
   `11111111-...` IDs and `*.example` domains.

## Development setup

The assessment runtime supports PowerShell 7.2+ on Windows, Linux or macOS. Local lint and Pester development use
PowerShell 7.4+ because the locked Pester 6.2.0 and PSScriptAnalyzer 1.24.0 releases target .NET 8. The Azure CLI is
only needed for live runs; tests use a mock. Build dependencies are locked in `dependencies.psd1`; Bootstrap installs
only those exact versions and verifies their committed module-tree hashes before import. CI separately runs the
complete mock assessment under PowerShell 7.2.24.

```powershell
git clone https://github.com/AzaryaShaulov/Azure.git
cd Azure/Assessments/VMSKURetirementReport
./build.ps1                    # Bootstrap, Lint, Version, Test
./build.ps1 -Task Sample       # regenerate examples/sample-report
./build.ps1 -Task Package      # build dist/VMSKURetirementReport-v<version>.zip
```

## Repository layout

| Path | Purpose |
|---|---|
| `skills/vm-sku-retirement-report/SKILL.md` | Agent skill definition (what agents read) |
| `skills/vm-sku-retirement-report/scripts/` | Orchestrator, catalog refresh and modules |
| `skills/vm-sku-retirement-report/data/` | Cached Microsoft evidence, series map, processor catalog, scoring weights |
| `skills/vm-sku-retirement-report/references/` | Methodology, scoring, output schema and data-source docs |
| `skills/vm-sku-retirement-report/tests/` | Pester unit + end-to-end tests with a mock Azure CLI |
| `dist/` | Versioned customer ZIP packages and SHA-256 checksums |
| `examples/sample-report/` | Generated sample report (synthetic data) |

## Common changes

- **A new retired / End of Life series appears on Microsoft Learn.** Run `scripts/Update-Catalogs.ps1`. If it warns
  about an unmapped series, add its size-name pattern to `data/series-map.json` (from the Learn size page), add a
  classification test, and commit the refreshed catalogs. If a retired-list *section* lists things that are not VM sizes
  (for example `ADH` Dedicated Host SKUs), add the section name to `nonVmSizeCategories` instead of mapping it.
- **Scoring or rule changes.** Update `references/methodology.md` / `references/scoring.md` and add tests.
- **Report changes.** Keep all HTML values encoded through `ConvertTo-HtmlEncoded` and regenerate the sample. The sample
  build is offline and reproducible: it uses the cached catalog, `$script:SampleAsOfDate` in `build.ps1` and
  `tests/fixtures/retail-prices-eastus2.json`. After refreshing the catalog, bump the date and rebuild.

## Pull requests

- Keep changes focused, and add or update tests.
- `./build.ps1` must pass. CI runs the same tasks on Windows, Linux and macOS, including a PowerShell 7.2 lane.
- Add an entry under **Unreleased** in `CHANGELOG.md`.

## Releasing (maintainers)

1. Bump `$script:ToolVersion` in `scripts/modules/Common.psm1` and `metadata.version` in `SKILL.md`.
2. Move the **Unreleased** notes into a new `## [x.y.z] - YYYY-MM-DD` section in `CHANGELOG.md`.
3. From `Assessments/VMSKURetirementReport`, run `./build.ps1 -Task Version, Test, Package`.
4. Verify and commit `dist/VMSKURetirementReport-vX.Y.Z.zip` and its `.zip.sha256` checksum so customers can download
   both files directly from the repository.
5. Tag `vX.Y.Z` and push the tag. The parent repository's Release workflow also publishes the same files as GitHub
   release assets.
