# VMSKURetirementReport - Executive Summary

> UNOFFICIAL ASSESSMENT - FOR PLANNING PURPOSES ONLY. Generated with read-only Azure Resource Manager / Resource Graph queries and Microsoft Learn lifecycle data. Validate every recommendation (workload, licensing, capacity) before resizing.

| Item | Value |
|---|---|
| Tenant | Contoso (Sample) (`22222222-2222-2222-2222-222222222222`) |
| Assessment date (as of) | 2026-10-05 |
| Generated (UTC) | 2026-10-08T13:32:40.7560919Z |
| Retirement evidence | Cached (2026-10-06 00:44 UTC) - Microsoft Learn |
| Source: RetiredList | [https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions) (updated 09/27/2026 11:03:00, retrieved 10/06/2026 00:44:07) |
| Source: PreviousGen | [https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/end-of-life-sizes-list](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/end-of-life-sizes-list) (updated 09/26/2026 06:04:00, retrieved 10/06/2026 00:44:07) |
| Source: MigrationGuide | [https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirement/retired-sizes-modernization-guide](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirement/retired-sizes-modernization-guide) (updated 09/26/2026 06:04:00, retrieved 10/06/2026 00:44:07) |
| Horizon | 36 months |

> **Warning:** Offline mode requested.

> **Microsoft lifecycle entries that are not VM sizes (validate separately):** Dsv3-Type1, Dsv3-Type2, Esv3-Type1, Esv3-Type2 (ADH, Retired 2023-06-30)

## Estate summary

| Metric | Count |
|---|---:|
| Total Subscriptions Scanned | 1 |
| Total VMs Scanned | 7 |
| Affected VMs (confirmed/announced retirement) | 6 |
| Already Retired | 1 |
| Retirement Within 12 Months | 0 |
| Retirement Within 12-24 Months | 2 |
| Retirement Within 24-36 Months | 1 |
| Retirement Beyond 36 Months | 2 |
| Modernization Recommended (Microsoft previous-gen) | 0 |
| Modernization Optional | 0 |
| Modernize to v7 | 0 |
| Modernize to v6 | 0 |
| Already on v6/v7 | 0 |
| No Retirement Announced | 1 |
| Unable to Determine | 0 |
| VMs Requiring Quota Increase | 4 |
| VMs With Regional Restrictions | 0 |
| VMs Requiring CPU Vendor Change | 0 |
| VMs Requiring Manual Review | 3 |
| High Confidence Recommendations | 0 |
| Medium Confidence Recommendations | 0 |
| Low Confidence Recommendations | 7 |

## Migration waves

Waves 1-3 contain only VMs with Microsoft-confirmed or announced retirement dates. Wave 4 is optional modernization and is never mixed with retirement requirements.

### Wave 1 - Urgent (1 VMs)

| CurrentSku | EvidenceClass | RetirementDate | RecommendedSku | VMs | Ready | QuotaIncrease | ManualReview |
|---|---|---|---|---|---|---|---|
| Standard\_NC6s\_v3 | Already Retired | 2025-09-30 | - | 1 | 0 | 0 | 1 |

### Wave 2 - Near Term (2 VMs)

| CurrentSku | EvidenceClass | RetirementDate | RecommendedSku | VMs | Ready | QuotaIncrease | ManualReview |
|---|---|---|---|---|---|---|---|
| Standard\_DS3\_v2 | Confirmed Retirement | 2028-05-01 | Standard\_D4ds\_v5 | 2 | 0 | 2 | 0 |

### Wave 3 - Planned (1 VMs)

| CurrentSku | EvidenceClass | RetirementDate | RecommendedSku | VMs | Ready | QuotaIncrease | ManualReview |
|---|---|---|---|---|---|---|---|
| Standard\_B2ms | Confirmed Retirement | 2028-11-15 | Standard\_B2s\_v2 | 1 | 0 | 0 | 1 |

### Beyond Horizon (2 VMs)

| CurrentSku | EvidenceClass | RetirementDate | RecommendedSku | VMs | Ready | QuotaIncrease | ManualReview |
|---|---|---|---|---|---|---|---|
| Standard\_D4s\_v3 | Confirmed Retirement | 2029-11-15 | Standard\_D4ds\_v5 | 2 | 0 | 2 | 0 |

## Groupings (VMs with an action)

### By subscription

| Key | Count |
|---|---|
| contoso-prod | 6 |

### By region

| Key | Count |
|---|---|
| eastus2 | 6 |

### By current SKU

| Key | Count |
|---|---|
| Standard\_D4s\_v3 | 2 |
| Standard\_DS3\_v2 | 2 |
| Standard\_B2ms | 1 |
| Standard\_NC6s\_v3 | 1 |

### By current SKU family

| Key | Count |
|---|---|
| standardDSv2Family | 2 |
| standardDSv3Family | 2 |
| ncsv3 | 1 |
| standardBSFamily | 1 |

### By recommended SKU

| Key | Count |
|---|---|
| Standard\_D4ds\_v5 | 4 |
| Standard\_B2s\_v2 | 1 |
| (none) | 1 |

### By recommended SKU family

| Key | Count |
|---|---|
| standardDDSv5Family | 4 |
| standardBsv2Family | 1 |
| (none) | 1 |

### By CPU vendor

| Key | Count |
|---|---|
| Intel | 6 |

### By retirement date

| Key | Count |
|---|---|
| 2028-05-01 | 2 |
| 2029-11-15 | 2 |
| 2025-09-30 | 1 |
| 2028-11-15 | 1 |

### By migration priority (action)

| Key | Count |
|---|---|
| Migration Required Within 24 Months | 2 |
| Plan Migration | 2 |
| Immediate Migration Required | 1 |
| Migration Required Within 36 Months | 1 |
| No Action Required | 1 |

### By deployment readiness

| Key | Count |
|---|---|
| Quota Increase Required | 4 |
| Manual Review Required | 2 |

## Quota actions

Demand is aggregated for all VMs moving into the same subscription / region / family. Minimum increase = (current usage + required) - limit. Recommended increase adds the safety margin. Scope 'Retirement' covers mandatory migrations to their retirement target; 'Retirement+Modernization' also includes optional Wave 4 moves; 'Modernization' (only with --check-modernization) covers the strategic v6/v7 targets with steady-state and peak demand.

| Scope | SubscriptionId | Region | QuotaDisplayName | QuotaName | Limit | CurrentUsage | RequiredVcpu | PostMigrationUsage | MinimumIncrease | RecommendedIncrease | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Retirement | 11111111-1111-1111-1111-111111111111 | eastus2 | - | standardbsv2family | - | - | 2 | - | - | - | Manual Validation Required |
| Retirement | 11111111-1111-1111-1111-111111111111 | eastus2 | Standard DDSv5 Family vCPUs | standardddsv5family | 100 | 95 | 16 | 111 | 11 | 15 | Quota Increase Required |
| Retirement+Modernization | 11111111-1111-1111-1111-111111111111 | eastus2 | - | standardbsv2family | - | - | 2 | - | - | - | Manual Validation Required |
| Retirement+Modernization | 11111111-1111-1111-1111-111111111111 | eastus2 | Standard DDSv5 Family vCPUs | standardddsv5family | 100 | 95 | 16 | 111 | 11 | 15 | Quota Increase Required |
| Modernization | 11111111-1111-1111-1111-111111111111 | eastus2 | - | standarddsv6family | - | - | 20 | - | - | - | Manual Validation Required |

## Data quality

- Retirement dates come only from Microsoft Learn (retired sizes list, previous-gen list, migration guide). No date is inferred.
- CPU vendor: Microsoft Learn size-series processor tables (Verified) or the Azure VM naming convention (Partially Verified).
- Regional availability and restrictions: subscription-scoped Azure Resource SKUs API (Verified).
- Physical regional capacity, nested virtualization use and temp-disk usage cannot be verified from the control plane (Unable to Verify).

