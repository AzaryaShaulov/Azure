# Customer downloads

This directory contains versioned customer packages for VMSKURetirementReport.

For each release, download both files:

- `VMSKURetirementReport-v<version>.zip`
- `VMSKURetirementReport-v<version>.zip.sha256`

Verify the ZIP's SHA-256 hash before extracting it. On Windows, run `Unblock-File` on the verified ZIP before
extracting it; otherwise the `RemoteSigned` execution policy blocks the unsigned scripts and modules.

Packages are generated from the project root with:

```powershell
./build.ps1 -Task Version, Test, Package
```

The package contains the complete `vm-sku-retirement-report` skill, including its scripts, modules, templates,
bundled data, license, and third-party notices.

### Disclaimer – Independent Assessment Tool

**This tool is provided "AS IS," without warranties or guarantees of any kind.**

This is an independently developed assessment tool and is **not an official Microsoft product or Microsoft-supported solution**. Microsoft does not provide support, maintenance, warranties, or guarantees for this tool or its generated reports.

Assessment results, Azure VM SKU recommendations, retirement timelines, and modernization guidance are provided for informational and planning purposes only. Findings may not reflect the latest Azure capabilities, regional availability, pricing, retirement announcements, or Microsoft documentation.

**Before making production changes, users must independently validate:**

- VM SKU compatibility and supported migration paths.
- Regional SKU availability and subscription quotas.
- Pricing and capacity requirements.
- VM generation, disk controller, NVMe, and storage compatibility.
- Redeployment, downtime, and migration requirements.
- Official Azure retirement dates and Microsoft documentation.

Users are solely responsible for validating assessment findings, evaluating potential operational impacts, and planning and executing changes within their environments.

**Use of this tool and reliance on its outputs are at the user's own risk.**
