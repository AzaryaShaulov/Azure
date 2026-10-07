# Third-party notices

VMSKURetirementReport is released under the [MIT License](LICENSE). It includes or is derived from the following third-party
material, which remains under its own terms.

## Microsoft Learn documentation content (CC BY 4.0)

**Source:** [Microsoft Learn](https://learn.microsoft.com/azure/virtual-machines/sizes/overview) and the
[MicrosoftDocs/azure-compute-docs](https://github.com/MicrosoftDocs/azure-compute-docs) repository.
Copyright (c) Microsoft Corporation. Licensed under
[Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/).

**Used in:**

- `skills/vm-sku-retirement-report/data/retirement-catalog.json`: VM size series names, retirement statuses, dates,
  recommended target series and short specification-difference notes extracted from the
  [retirements and capacity restrictions](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions),
  [End of Life sizes](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/end-of-life-sizes-list) and
  [retired sizes modernization guide](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirement/retired-sizes-modernization-guide)
  pages.
- `skills/vm-sku-retirement-report/data/processor-catalog.json`: processor models, CPU vendor and architecture per size
  series, extracted from the size-series pages in MicrosoftDocs/azure-compute-docs.
- `skills/vm-sku-retirement-report/data/series-map.json`: VM size name patterns derived from the size lists on the
  Microsoft Learn size-series pages.
- `skills/vm-sku-retirement-report/tests/fixtures/*.html`: abbreviated, synthetic test pages modeled on the structure
  of the Microsoft Learn lifecycle pages.
- `examples/sample-report/`: the generated sample includes the same extracted lifecycle data.

**Changes made:** the content was extracted, reduced to the fields listed above and converted to JSON; the test pages
are shortened and partly synthetic. The data is refreshed with `scripts/Update-Catalogs.ps1` and may lag the live
pages. Use of this material does not imply endorsement by Microsoft.

At run time the tool reads the current versions of these public pages directly from Microsoft Learn.

## Azure Retail Prices API data

`skills/vm-sku-retirement-report/tests/fixtures/retail-prices-eastus2.json` is a small snapshot of public
pay-as-you-go list prices from the [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices),
used only to build the sample report offline. Prices are informational and may be out of date.

## Design acknowledgement

The visual style of the HTML report (application header, dashboard tiles, table styling) was inspired by the
[Azure FinOps Multitool](https://github.com/z-larsen/Azure-FinOps-Multitool) GUI by Zac Larsen (MIT License). No
code from that project is included.

## Trademarks

Microsoft, Azure and related marks are trademarks of the Microsoft group of companies. This project is not affiliated
with, sponsored by or endorsed by Microsoft.
