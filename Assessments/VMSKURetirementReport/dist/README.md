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
