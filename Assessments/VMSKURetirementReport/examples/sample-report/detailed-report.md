# Detailed VM Reports - Retirement and Modernization Assessment

[Source repository](https://github.com/AzaryaShaulov/Azure)

Tenant: **Contoso (Sample)** (`22222222-2222-2222-2222-222222222222`) | As of: **2026-10-05** | Tool: VMSKURetirementReport v1.1.2

## Subscription: contoso-prod

### VM: vm-d4sv5

- **Subscription:** contoso-prod (`11111111-1111-1111-1111-111111111111`)
- **Resource Group:** rg-app
- **Region:** eastus2

**CURRENT CONFIGURATION**

| Attribute | Value |
|---|---|
| Current SKU | Standard\_D4s\_v5 |
| Current SKU Generation | v5 |
| VM Family | standardDSv5Family |
| CPU Vendor | Intel (Verified) |
| CPU Architecture | x64 |
| Processors | Intel Xeon Platinum 8473C (Sapphire Rapids); Intel Xeon Platinum 8370C (Ice Lake); Intel Xeon Platinum 8573C (Emerald Rapids) |
| vCPU | 4 |
| Memory (GB) | 16 |
| Premium Storage (in use) | Yes |
| Accelerated Networking (in use) | Yes |
| Temp Disk | None |
| Data Disks | 0 |
| Disk SKUs | Premium\_LRS |
| NIC Count | 1 |
| Availability Zone | None (regional deployment) |
| Hyper-V Generation | V2 |
| Disk Controller | SCSI (default, not reported) |
| Security Type | Standard |
| Power State | Running |

**RETIREMENT**

| Attribute | Value |
|---|---|
| Retirement Status | No Retirement Announced |
| Retirement Date | Unknown |
| Months Remaining | Unknown |
| Microsoft Series | Unknown |
| Microsoft Retirement Source | - |
| Announcement | Unknown |
| Migration Guide | - |
| Microsoft Lifecycle Stage | Not End of Life |
| Evidence Classification | No Retirement Announced |
| Data Quality | Verified |

**MODERNIZATION ASSESSMENT**

| Attribute | Value |
|---|---|
| Status | No suitable modern SKU found |
| Recommended SKU | Unknown |
| Recommended SKU Generation | Unknown |
| Regional Availability | Not Available |
| Quota Status | Manual Validation Required |
| Reason | No same-vendor v6/v7 size passed all workload requirements: Standard\_D4s\_v6: Disk Controller: VM uses SCSI; target supports NVMe only - controller conversion required (validate OS NVMe driver support) |

**PRIMARY RECOMMENDATION**

_No primary recommendation: All candidates fail mandatory requirements: Standard_D4s_v6 [Disk Controller: VM uses SCSI; target supports NVMe only - controller conversion required (validate OS NVMe driver support)]_

**MIGRATION CONSIDERATIONS**

- Low confidence: No valid replacement candidate
- Low confidence: Quota could not be validated
- Nested virtualization / temp-disk usage / physical capacity: Unable to Verify from Azure control plane

**RECOMMENDED ACTION**

No Action Required. Next step: Manual Review Required.

**DATA QUALITY**

- RetirementDate: Verified (no date)
- CpuVendor: Verified
- CpuArchitecture: Verified
- CurrentSkuCapabilities: Verified
- RegionalAvailability: Partially Verified
- Quota: Unable to Verify
- PhysicalCapacity: Unable to Verify
- NestedVirtualization: Unable to Verify
- TempDiskUsage: Unable to Verify

---

### VM: vm-nc6

- **Subscription:** contoso-prod (`11111111-1111-1111-1111-111111111111`)
- **Resource Group:** rg-app
- **Region:** eastus2

**CURRENT CONFIGURATION**

| Attribute | Value |
|---|---|
| Current SKU | Standard\_NC6s\_v3 |
| Current SKU Generation | v3 |
| VM Family | Unknown |
| CPU Vendor | Intel (Verified) |
| CPU Architecture | x64 |
| Processors | Intel Xeon E5-2690 v4 (Broadwell) |
| vCPU | 6 |
| Memory (GB) | Unknown |
| Premium Storage (in use) | Yes |
| Accelerated Networking (in use) | Yes |
| Temp Disk | Unknown |
| Data Disks | 0 |
| Disk SKUs | Premium\_LRS |
| NIC Count | 1 |
| Availability Zone | None (regional deployment) |
| Hyper-V Generation | V1 |
| Disk Controller | SCSI (default, not reported) |
| Security Type | Standard |
| Power State | Running |

**RETIREMENT**

| Attribute | Value |
|---|---|
| Retirement Status | Retired |
| Retirement Date | 2025-09-30 |
| Months Remaining | 0 |
| Microsoft Series | NCv3-Series |
| Microsoft Retirement Source | \[https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions\](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions) |
| Announcement | Unknown |
| Migration Guide | \[link\](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirement/ncv3-retirement) |
| Microsoft Lifecycle Stage | Retired |
| Evidence Classification | Already Retired |
| Data Quality | Partially Verified |

> Note: Retirement evidence from cached catalog: Cached (2026-10-06 00:44 UTC).

**MODERNIZATION ASSESSMENT**

| Attribute | Value |
|---|---|
| Status | SKU unavailable in region |
| Recommended SKU | Unknown |
| Recommended SKU Generation | Unknown |
| Regional Availability | Not Available |
| Quota Status | Manual Validation Required |
| Reason | No suitable v6/v7 NC-series size is available to this subscription in eastus2. |

**PRIMARY RECOMMENDATION**

_No primary recommendation: No current-generation size with >= 6 vCPU / unknown GB (current size not in Resource SKUs API) in the permitted series (NC-series) is offered in eastus2 for this subscription_

**MIGRATION CONSIDERATIONS**

- Current size capabilities not available from Resource SKUs API
- Lifecycle evidence partially verified
- Low confidence: No valid replacement candidate
- Low confidence: Current SKU characteristics incomplete
- Low confidence: Quota could not be validated
- Nested virtualization / temp-disk usage / physical capacity: Unable to Verify from Azure control plane

**RECOMMENDED ACTION**

Immediate Migration Required. Next step: Manual Review Required.

**DATA QUALITY**

- RetirementDate: Partially Verified
- CpuVendor: Verified
- CpuArchitecture: Verified
- CurrentSkuCapabilities: Unable to Verify
- RegionalAvailability: Partially Verified
- Quota: Unable to Verify
- PhysicalCapacity: Unable to Verify
- NestedVirtualization: Unable to Verify
- TempDiskUsage: Unable to Verify

---

### VM: vm-dealloc

- **Subscription:** contoso-prod (`11111111-1111-1111-1111-111111111111`)
- **Resource Group:** rg-app
- **Region:** eastus2

**CURRENT CONFIGURATION**

| Attribute | Value |
|---|---|
| Current SKU | Standard\_DS3\_v2 |
| Current SKU Generation | v2 |
| VM Family | standardDSv2Family |
| CPU Vendor | Intel (Verified) |
| CPU Architecture | x64 |
| Processors | Intel Xeon Platinum 8370C (Ice Lake); Intel Xeon Platinum 8272CL (Cascade Lake); Intel Xeon 8171M (Skylake) |
| vCPU | 4 |
| Memory (GB) | 14 |
| Premium Storage (in use) | Yes |
| Accelerated Networking (in use) | Yes |
| Temp Disk | 28 GB |
| Data Disks | 0 |
| Disk SKUs | Premium\_LRS |
| NIC Count | 1 |
| Availability Zone | None (regional deployment) |
| Hyper-V Generation | V1 |
| Disk Controller | SCSI (default, not reported) |
| Security Type | Standard |
| Power State | Deallocated |

**RETIREMENT**

| Attribute | Value |
|---|---|
| Retirement Status | Announced |
| Retirement Date | 2028-05-01 |
| Months Remaining | 18 |
| Microsoft Series | Dsv2-series / Dv2 and Dsv2-series / Dsv2 |
| Microsoft Retirement Source | \[https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions\](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions) |
| Announcement | \[2025-03-31\](https://azure.microsoft.com/updates?id=485569) |
| Migration Guide | \[link\](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirement/retired-sizes-modernization-guide) |
| Microsoft Lifecycle Stage | End of Life |
| Evidence Classification | Confirmed Retirement |
| Data Quality | Partially Verified |

> Note: Retirement evidence from cached catalog: Cached (2026-10-06 00:44 UTC).

**MODERNIZATION ASSESSMENT**

| Attribute | Value |
|---|---|
| Status | No suitable modern SKU found |
| Recommended SKU | Standard\_D4ds\_v5 |
| Recommended SKU Generation | v5 |
| Regional Availability | Available |
| Quota Status | Quota Increase Required |
| Reason | No same-vendor v6/v7 size passed all workload requirements: Standard\_D4s\_v6: VM Generation: VM is V1; target supports V2 only - in-place resize not possible (Gen1-\>Gen2 conversion or rebuild required) \| Disk Controller: VM uses SCSI; target supports NVMe only - controller conversion required (validate OS NVMe driver support) Retaining existing recommendation Standard\_D4ds\_v5. |

**PRIMARY RECOMMENDATION**

| Attribute | Value |
|---|---|
| Recommended SKU | Standard\_D4ds\_v5 |
| VM Family | standardDDSv5Family |
| CPU Vendor | Intel (Verified) |
| CPU Generation | Ice Lake |
| vCPU | 4 |
| Memory (GB) | 16 |
| Compatibility Score | 93 (Excellent Match) |
| Migration Confidence | LOW |
| CPU Vendor Preserved | Yes |
| CPU Architecture Preserved | Yes |
| Region Available | Available |
| Zone Available | N/A (regional VM) |
| Quota Available | Quota Increase Required |
| Quota Increase Required | Family +11 / Regional +0 vCPU (recommended request: family +15) |
| Feature Compatibility | All mandatory requirements met |
| Deployment Readiness | Quota Increase Required |
| Permitted series | Microsoft migration guide: dsv5, ddsv5, dasv5, dadsv5, dasv6, dadsv6, dsv6, ddsv6, dasv7, dadsv7, esv6, edsv6, easv6, eadsv6, easv7, eadsv7 |

**ALTERNATIVE RECOMMENDATION**

- Alternative SKU: **Standard\_D4s\_v5** (Intel, 4 vCPU / 16 GB)
- Compatibility Score: 90 (Excellent Match)
- Reason for Alternative: Quota: standardDSv5Family has headroom while the primary family needs an increase; Feature: no temp disk (lower cost where local scratch is unused)
- Third candidate: Standard_D8s_v5 (score 84; Capability-preserving)
- Newer generation if converted: Standard_D4s_v6 - blocked by VM Generation, Disk Controller

**MATERIAL DIFFERENCES**

| Attribute | Current | Target | Assessment | Note |
|---|---|---|---|---|
| CPU Vendor | Intel | Intel | Same | - |
| CPU Architecture | x64 | x64 | Same | - |
| Processor | Intel Xeon Platinum 8370C (Ice Lake); Intel Xeon Platinum 8272CL (Cascade Lake) | Intel Xeon Platinum 8370C (Ice Lake); Intel Xeon Platinum 8573C (Emerald Rapids) | Changed | - |
| vCPU | 4 | 4 | Same | - |
| Memory (GB) | 14 | 16 | Improved | - |
| Temp / Local Disk | 28 GB | 150 GB | Changed | - |
| Disk Controller | SCSI | SCSI | Same | - |
| Hyper-V Generation | V1,V2 | V1,V2 | Same | - |
| Uncached Disk IOPS | 12800 | 6400 | Reduced | - |
| Uncached Disk MBps | 192 | 144 | Reduced | - |
| Max Data Disks | 16 | 8 | Reduced | - |
| Max NICs | 4 | 2 | Reduced | - |
| Accelerated Networking | True | True | Same | - |
| Premium Storage | True | True | Same | - |
| Availability Zones | 1,2,3 | 1,2,3 | Same | - |
| Network Bandwidth | - | - | Unknown | Not exposed by Resource SKUs API; see Microsoft Learn size page |

**MIGRATION CONSIDERATIONS**

- Capability reduced (Uncached Disk IOPS 12800 -\> 6400, Uncached Disk MBps 192 -\> 144); validate against observed disk throughput or use the capability-preserving alternative
- Lifecycle evidence partially verified
- Quota increase required
- Nested virtualization / temp-disk usage / physical capacity: Unable to Verify from Azure control plane

**RECOMMENDED ACTION**

Migration Required Within 24 Months. Next step: Request Quota Increase. Resize Standard_DS3_v2 -> Standard_D4ds_v5 (LOW confidence, Quota Increase Required).

**DATA QUALITY**

- RetirementDate: Partially Verified
- CpuVendor: Verified
- CpuArchitecture: Verified
- CurrentSkuCapabilities: Verified
- RegionalAvailability: Verified
- Quota: Verified
- PhysicalCapacity: Unable to Verify
- NestedVirtualization: Unable to Verify
- TempDiskUsage: Unable to Verify

---

### VM: vm-ds3v2

- **Subscription:** contoso-prod (`11111111-1111-1111-1111-111111111111`)
- **Resource Group:** rg-app
- **Region:** eastus2

**CURRENT CONFIGURATION**

| Attribute | Value |
|---|---|
| Current SKU | Standard\_DS3\_v2 |
| Current SKU Generation | v2 |
| VM Family | standardDSv2Family |
| CPU Vendor | Intel (Verified) |
| CPU Architecture | x64 |
| Processors | Intel Xeon Platinum 8370C (Ice Lake); Intel Xeon Platinum 8272CL (Cascade Lake); Intel Xeon 8171M (Skylake) |
| vCPU | 4 |
| Memory (GB) | 14 |
| Premium Storage (in use) | Yes |
| Accelerated Networking (in use) | Yes |
| Temp Disk | 28 GB |
| Data Disks | 0 |
| Disk SKUs | Premium\_LRS |
| NIC Count | 1 |
| Availability Zone | None (regional deployment) |
| Hyper-V Generation | V1 |
| Disk Controller | SCSI (default, not reported) |
| Security Type | Standard |
| Power State | Running |

**RETIREMENT**

| Attribute | Value |
|---|---|
| Retirement Status | Announced |
| Retirement Date | 2028-05-01 |
| Months Remaining | 18 |
| Microsoft Series | Dsv2-series / Dv2 and Dsv2-series / Dsv2 |
| Microsoft Retirement Source | \[https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions\](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions) |
| Announcement | \[2025-03-31\](https://azure.microsoft.com/updates?id=485569) |
| Migration Guide | \[link\](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirement/retired-sizes-modernization-guide) |
| Microsoft Lifecycle Stage | End of Life |
| Evidence Classification | Confirmed Retirement |
| Data Quality | Partially Verified |

> Note: Retirement evidence from cached catalog: Cached (2026-10-06 00:44 UTC).

**MODERNIZATION ASSESSMENT**

| Attribute | Value |
|---|---|
| Status | No suitable modern SKU found |
| Recommended SKU | Standard\_D4ds\_v5 |
| Recommended SKU Generation | v5 |
| Regional Availability | Available |
| Quota Status | Quota Increase Required |
| Reason | No same-vendor v6/v7 size passed all workload requirements: Standard\_D4s\_v6: VM Generation: VM is V1; target supports V2 only - in-place resize not possible (Gen1-\>Gen2 conversion or rebuild required) \| Disk Controller: VM uses SCSI; target supports NVMe only - controller conversion required (validate OS NVMe driver support) Retaining existing recommendation Standard\_D4ds\_v5. |

**PRIMARY RECOMMENDATION**

| Attribute | Value |
|---|---|
| Recommended SKU | Standard\_D4ds\_v5 |
| VM Family | standardDDSv5Family |
| CPU Vendor | Intel (Verified) |
| CPU Generation | Ice Lake |
| vCPU | 4 |
| Memory (GB) | 16 |
| Compatibility Score | 93 (Excellent Match) |
| Migration Confidence | LOW |
| CPU Vendor Preserved | Yes |
| CPU Architecture Preserved | Yes |
| Region Available | Available |
| Zone Available | N/A (regional VM) |
| Quota Available | Quota Increase Required |
| Quota Increase Required | Family +11 / Regional +0 vCPU (recommended request: family +15) |
| Feature Compatibility | All mandatory requirements met |
| Deployment Readiness | Quota Increase Required |
| Permitted series | Microsoft migration guide: dsv5, ddsv5, dasv5, dadsv5, dasv6, dadsv6, dsv6, ddsv6, dasv7, dadsv7, esv6, edsv6, easv6, eadsv6, easv7, eadsv7 |

**ALTERNATIVE RECOMMENDATION**

- Alternative SKU: **Standard\_D4s\_v5** (Intel, 4 vCPU / 16 GB)
- Compatibility Score: 90 (Excellent Match)
- Reason for Alternative: Quota: standardDSv5Family has headroom while the primary family needs an increase; Feature: no temp disk (lower cost where local scratch is unused)
- Third candidate: Standard_D8s_v5 (score 84; Capability-preserving)
- Newer generation if converted: Standard_D4s_v6 - blocked by VM Generation, Disk Controller

**MATERIAL DIFFERENCES**

| Attribute | Current | Target | Assessment | Note |
|---|---|---|---|---|
| CPU Vendor | Intel | Intel | Same | - |
| CPU Architecture | x64 | x64 | Same | - |
| Processor | Intel Xeon Platinum 8370C (Ice Lake); Intel Xeon Platinum 8272CL (Cascade Lake) | Intel Xeon Platinum 8370C (Ice Lake); Intel Xeon Platinum 8573C (Emerald Rapids) | Changed | - |
| vCPU | 4 | 4 | Same | - |
| Memory (GB) | 14 | 16 | Improved | - |
| Temp / Local Disk | 28 GB | 150 GB | Changed | - |
| Disk Controller | SCSI | SCSI | Same | - |
| Hyper-V Generation | V1,V2 | V1,V2 | Same | - |
| Uncached Disk IOPS | 12800 | 6400 | Reduced | - |
| Uncached Disk MBps | 192 | 144 | Reduced | - |
| Max Data Disks | 16 | 8 | Reduced | - |
| Max NICs | 4 | 2 | Reduced | - |
| Accelerated Networking | True | True | Same | - |
| Premium Storage | True | True | Same | - |
| Availability Zones | 1,2,3 | 1,2,3 | Same | - |
| Network Bandwidth | - | - | Unknown | Not exposed by Resource SKUs API; see Microsoft Learn size page |

**MIGRATION CONSIDERATIONS**

- Capability reduced (Uncached Disk IOPS 12800 -\> 6400, Uncached Disk MBps 192 -\> 144); validate against observed disk throughput or use the capability-preserving alternative
- Lifecycle evidence partially verified
- Quota increase required
- Nested virtualization / temp-disk usage / physical capacity: Unable to Verify from Azure control plane

**RECOMMENDED ACTION**

Migration Required Within 24 Months. Next step: Request Quota Increase. Resize Standard_DS3_v2 -> Standard_D4ds_v5 (LOW confidence, Quota Increase Required).

**DATA QUALITY**

- RetirementDate: Partially Verified
- CpuVendor: Verified
- CpuArchitecture: Verified
- CurrentSkuCapabilities: Verified
- RegionalAvailability: Verified
- Quota: Verified
- PhysicalCapacity: Unable to Verify
- NestedVirtualization: Unable to Verify
- TempDiskUsage: Unable to Verify

---

### VM: vm-b2ms

- **Subscription:** contoso-prod (`11111111-1111-1111-1111-111111111111`)
- **Resource Group:** rg-app
- **Region:** eastus2

**CURRENT CONFIGURATION**

| Attribute | Value |
|---|---|
| Current SKU | Standard\_B2ms |
| Current SKU Generation | v1 |
| VM Family | standardBSFamily |
| CPU Vendor | Intel (Verified) |
| CPU Architecture | x64 |
| Processors | Intel Xeon Platinum 8370C (Ice Lake); Intel Xeon Platinum 8272CL (Cascade Lake); Intel Xeon 8171M (Skylake) |
| vCPU | 2 |
| Memory (GB) | 8 |
| Premium Storage (in use) | No |
| Accelerated Networking (in use) | No |
| Temp Disk | 16 GB |
| Data Disks | 0 |
| Disk SKUs | StandardSSD\_LRS |
| NIC Count | 1 |
| Availability Zone | None (regional deployment) |
| Hyper-V Generation | V1 |
| Disk Controller | SCSI (default, not reported) |
| Security Type | Standard |
| Power State | Running |

**RETIREMENT**

| Attribute | Value |
|---|---|
| Retirement Status | Announced |
| Retirement Date | 2028-11-15 |
| Months Remaining | 25 |
| Microsoft Series | B-series (V1) / Bv1 |
| Microsoft Retirement Source | \[https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions\](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions) |
| Announcement | \[2025-10-15\](https://azure.microsoft.com/updates?id=500682) |
| Migration Guide | \[link\](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirement/retired-sizes-modernization-guide) |
| Microsoft Lifecycle Stage | End of Life |
| Evidence Classification | Confirmed Retirement |
| Data Quality | Partially Verified |

> Note: Retirement evidence from cached catalog: Cached (2026-10-06 00:44 UTC).

**MODERNIZATION ASSESSMENT**

| Attribute | Value |
|---|---|
| Status | SKU unavailable in region |
| Recommended SKU | Standard\_B2s\_v2 |
| Recommended SKU Generation | v2 |
| Regional Availability | Available |
| Quota Status | Manual Validation Required |
| Reason | No suitable v6/v7 B-series size is available to this subscription in eastus2. Retaining existing recommendation Standard\_B2s\_v2. |

**PRIMARY RECOMMENDATION**

| Attribute | Value |
|---|---|
| Recommended SKU | Standard\_B2s\_v2 |
| VM Family | standardBsv2Family |
| CPU Vendor | Intel (Verified) |
| CPU Generation | Sapphire Rapids |
| vCPU | 2 |
| Memory (GB) | 8 |
| Compatibility Score | 97 (Excellent Match) |
| Migration Confidence | LOW |
| CPU Vendor Preserved | Yes |
| CPU Architecture Preserved | Yes |
| Region Available | Available |
| Zone Available | N/A (regional VM) |
| Quota Available | Manual Validation Required |
| Quota Increase Required | Family + / Regional +0 vCPU (recommended request: family +) |
| Feature Compatibility | Review: Temp / Local Disk |
| Deployment Readiness | Manual Review Required |
| Permitted series | Microsoft migration guide: bsv2, basv2, dlsv5, dldsv5, dalsv5, daldsv5, dlsv6, dldsv6, dalsv6, daldsv6 |

**ALTERNATIVE RECOMMENDATION**

- Alternative SKU: **Standard\_D4ls\_v5** (Intel, 4 vCPU / 8 GB)
- Compatibility Score: 84 (Good Match)
- Reason for Alternative: Different quota family (standardDLSv5Family) - fallback if primary quota, capacity or regional availability is constrained

**MATERIAL DIFFERENCES**

| Attribute | Current | Target | Assessment | Note |
|---|---|---|---|---|
| CPU Vendor | Intel | Intel | Same | - |
| CPU Architecture | x64 | x64 | Same | - |
| Processor | Intel Xeon Platinum 8370C (Ice Lake); Intel Xeon Platinum 8272CL (Cascade Lake) | Intel Xeon Platinum 8473C (Sapphire Rapids); Intel Xeon Platinum 8370C (Ice Lake) | Changed | - |
| vCPU | 2 | 2 | Same | - |
| Memory (GB) | 8 | 8 | Same | - |
| Temp / Local Disk | 16 GB | None | Changed | Temp disk removed - validate pagefile / tempdb / scratch usage |
| Disk Controller | SCSI | SCSI | Same | - |
| Hyper-V Generation | V1,V2 | V1,V2 | Same | - |
| Uncached Disk IOPS | 1920 | 3750 | Improved | - |
| Uncached Disk MBps | 22 | 85 | Improved | - |
| Max Data Disks | 4 | 4 | Same | - |
| Max NICs | 2 | 2 | Same | - |
| Accelerated Networking | False | True | Changed | - |
| Premium Storage | True | True | Same | - |
| Availability Zones | 1,2,3 | 1,2,3 | Same | - |
| Network Bandwidth | - | - | Unknown | Not exposed by Resource SKUs API; see Microsoft Learn size page |

**MIGRATION CONSIDERATIONS**

- Temp / Local Disk: Current size has a 16 GB temp disk; target has none - validate pagefile, tempdb, caches or scripts using the temp drive
- Lifecycle evidence partially verified
- Low confidence: Quota could not be validated
- Nested virtualization / temp-disk usage / physical capacity: Unable to Verify from Azure control plane

**RECOMMENDED ACTION**

Migration Required Within 36 Months. Next step: Manual Review Required. Resize Standard_B2ms -> Standard_B2s_v2 (LOW confidence, Manual Review Required).

**DATA QUALITY**

- RetirementDate: Partially Verified
- CpuVendor: Verified
- CpuArchitecture: Verified
- CurrentSkuCapabilities: Verified
- RegionalAvailability: Verified
- Quota: Partially Verified
- PhysicalCapacity: Unable to Verify
- NestedVirtualization: Unable to Verify
- TempDiskUsage: Unable to Verify

---

### VM: vm-d4sv3

- **Subscription:** contoso-prod (`11111111-1111-1111-1111-111111111111`)
- **Resource Group:** rg-app
- **Region:** eastus2

**CURRENT CONFIGURATION**

| Attribute | Value |
|---|---|
| Current SKU | Standard\_D4s\_v3 |
| Current SKU Generation | v3 |
| VM Family | standardDSv3Family |
| CPU Vendor | Intel (Verified) |
| CPU Architecture | x64 |
| Processors | Intel Xeon Platinum 8370C (Ice Lake); Intel Xeon Platinum 8272CL (Cascade Lake); Intel Xeon 8171M (Skylake) |
| vCPU | 4 |
| Memory (GB) | 16 |
| Premium Storage (in use) | Yes |
| Accelerated Networking (in use) | Yes |
| Temp Disk | 32 GB |
| Data Disks | 0 |
| Disk SKUs | Premium\_LRS |
| NIC Count | 1 |
| Availability Zone | None (regional deployment) |
| Hyper-V Generation | V2 |
| Disk Controller | SCSI (default, not reported) |
| Security Type | Standard |
| Power State | Running |

**RETIREMENT**

| Attribute | Value |
|---|---|
| Retirement Status | Announced |
| Retirement Date | 2029-11-15 |
| Months Remaining | 37 |
| Microsoft Series | Dsv3-series / Dv3 and Dsv3-series / Dsv3 |
| Microsoft Retirement Source | \[https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions\](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions) |
| Announcement | Unknown |
| Migration Guide | \[link\](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirement/retired-sizes-modernization-guide) |
| Microsoft Lifecycle Stage | End of Life |
| Evidence Classification | Confirmed Retirement |
| Data Quality | Partially Verified |

> Note: Planned retirement date listed on Microsoft Learn without a linked Azure Updates announcement.

> Note: Retirement evidence from cached catalog: Cached (2026-10-06 00:44 UTC).

**MODERNIZATION ASSESSMENT**

| Attribute | Value |
|---|---|
| Status | No suitable modern SKU found |
| Recommended SKU | Standard\_D4ds\_v5 |
| Recommended SKU Generation | v5 |
| Regional Availability | Available |
| Quota Status | Quota Increase Required |
| Reason | No same-vendor v6/v7 size passed all workload requirements: Standard\_D4s\_v6: Disk Controller: VM uses SCSI; target supports NVMe only - controller conversion required (validate OS NVMe driver support) Retaining existing recommendation Standard\_D4ds\_v5. |

**PRIMARY RECOMMENDATION**

| Attribute | Value |
|---|---|
| Recommended SKU | Standard\_D4ds\_v5 |
| VM Family | standardDDSv5Family |
| CPU Vendor | Intel (Verified) |
| CPU Generation | Ice Lake |
| vCPU | 4 |
| Memory (GB) | 16 |
| Compatibility Score | 100 (Excellent Match) |
| Migration Confidence | LOW |
| CPU Vendor Preserved | Yes |
| CPU Architecture Preserved | Yes |
| Region Available | Available |
| Zone Available | N/A (regional VM) |
| Quota Available | Quota Increase Required |
| Quota Increase Required | Family +11 / Regional +0 vCPU (recommended request: family +15) |
| Feature Compatibility | All mandatory requirements met |
| Deployment Readiness | Quota Increase Required |
| Permitted series | Microsoft migration guide: dv5, dsv5, ddv5, ddsv5, dasv5, dadsv5, d-family-v6, d-family-v7 |

**ALTERNATIVE RECOMMENDATION**

- Alternative SKU: **Standard\_D4s\_v5** (Intel, 4 vCPU / 16 GB)
- Compatibility Score: 97 (Excellent Match)
- Reason for Alternative: Quota: standardDSv5Family has headroom while the primary family needs an increase; Feature: no temp disk (lower cost where local scratch is unused)
- Newer generation if converted: Standard_D4s_v6 - blocked by Disk Controller

**MATERIAL DIFFERENCES**

| Attribute | Current | Target | Assessment | Note |
|---|---|---|---|---|
| CPU Vendor | Intel | Intel | Same | - |
| CPU Architecture | x64 | x64 | Same | - |
| Processor | Intel Xeon Platinum 8370C (Ice Lake); Intel Xeon Platinum 8272CL (Cascade Lake) | Intel Xeon Platinum 8370C (Ice Lake); Intel Xeon Platinum 8573C (Emerald Rapids) | Changed | - |
| vCPU | 4 | 4 | Same | - |
| Memory (GB) | 16 | 16 | Same | - |
| Temp / Local Disk | 32 GB | 150 GB | Changed | - |
| Disk Controller | SCSI | SCSI | Same | - |
| Hyper-V Generation | V1,V2 | V1,V2 | Same | - |
| Uncached Disk IOPS | 6400 | 6400 | Same | - |
| Uncached Disk MBps | 96 | 144 | Improved | - |
| Max Data Disks | 8 | 8 | Same | - |
| Max NICs | 2 | 2 | Same | - |
| Accelerated Networking | True | True | Same | - |
| Premium Storage | True | True | Same | - |
| Availability Zones | 1,2,3 | 1,2,3 | Same | - |
| Network Bandwidth | - | - | Unknown | Not exposed by Resource SKUs API; see Microsoft Learn size page |

**MIGRATION CONSIDERATIONS**

- Lifecycle evidence partially verified
- Quota increase required
- Nested virtualization / temp-disk usage / physical capacity: Unable to Verify from Azure control plane

**RECOMMENDED ACTION**

Plan Migration. Next step: Request Quota Increase. Resize Standard_D4s_v3 -> Standard_D4ds_v5 (LOW confidence, Quota Increase Required).

**DATA QUALITY**

- RetirementDate: Partially Verified
- CpuVendor: Verified
- CpuArchitecture: Verified
- CurrentSkuCapabilities: Verified
- RegionalAvailability: Verified
- Quota: Verified
- PhysicalCapacity: Unable to Verify
- NestedVirtualization: Unable to Verify
- TempDiskUsage: Unable to Verify

---

### VM: vm-zonal

- **Subscription:** contoso-prod (`11111111-1111-1111-1111-111111111111`)
- **Resource Group:** rg-app
- **Region:** eastus2 (zone 3)

**CURRENT CONFIGURATION**

| Attribute | Value |
|---|---|
| Current SKU | Standard\_D4s\_v3 |
| Current SKU Generation | v3 |
| VM Family | standardDSv3Family |
| CPU Vendor | Intel (Verified) |
| CPU Architecture | x64 |
| Processors | Intel Xeon Platinum 8370C (Ice Lake); Intel Xeon Platinum 8272CL (Cascade Lake); Intel Xeon 8171M (Skylake) |
| vCPU | 4 |
| Memory (GB) | 16 |
| Premium Storage (in use) | Yes |
| Accelerated Networking (in use) | Yes |
| Temp Disk | 32 GB |
| Data Disks | 0 |
| Disk SKUs | Premium\_LRS |
| NIC Count | 1 |
| Availability Zone | 3 |
| Hyper-V Generation | V1 |
| Disk Controller | SCSI (default, not reported) |
| Security Type | Standard |
| Power State | Running |

**RETIREMENT**

| Attribute | Value |
|---|---|
| Retirement Status | Announced |
| Retirement Date | 2029-11-15 |
| Months Remaining | 37 |
| Microsoft Series | Dsv3-series / Dv3 and Dsv3-series / Dsv3 |
| Microsoft Retirement Source | \[https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions\](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions) |
| Announcement | Unknown |
| Migration Guide | \[link\](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirement/retired-sizes-modernization-guide) |
| Microsoft Lifecycle Stage | End of Life |
| Evidence Classification | Confirmed Retirement |
| Data Quality | Partially Verified |

> Note: Planned retirement date listed on Microsoft Learn without a linked Azure Updates announcement.

> Note: Retirement evidence from cached catalog: Cached (2026-10-06 00:44 UTC).

**MODERNIZATION ASSESSMENT**

| Attribute | Value |
|---|---|
| Status | No suitable modern SKU found |
| Recommended SKU | Standard\_D4ds\_v5 |
| Recommended SKU Generation | v5 |
| Regional Availability | Available |
| Quota Status | Quota Increase Required |
| Reason | No same-vendor v6/v7 size passed all workload requirements: Standard\_D4s\_v6: VM Generation: VM is V1; target supports V2 only - in-place resize not possible (Gen1-\>Gen2 conversion or rebuild required) \| Disk Controller: VM uses SCSI; target supports NVMe only - controller conversion required (validate OS NVMe driver support) Retaining existing recommendation Standard\_D4ds\_v5. |

**PRIMARY RECOMMENDATION**

| Attribute | Value |
|---|---|
| Recommended SKU | Standard\_D4ds\_v5 |
| VM Family | standardDDSv5Family |
| CPU Vendor | Intel (Verified) |
| CPU Generation | Ice Lake |
| vCPU | 4 |
| Memory (GB) | 16 |
| Compatibility Score | 100 (Excellent Match) |
| Migration Confidence | LOW |
| CPU Vendor Preserved | Yes |
| CPU Architecture Preserved | Yes |
| Region Available | Available |
| Zone Available | Yes |
| Quota Available | Quota Increase Required |
| Quota Increase Required | Family +11 / Regional +0 vCPU (recommended request: family +15) |
| Feature Compatibility | All mandatory requirements met |
| Deployment Readiness | Quota Increase Required |
| Permitted series | Microsoft migration guide: dv5, dsv5, ddv5, ddsv5, dasv5, dadsv5, d-family-v6, d-family-v7 |

**ALTERNATIVE RECOMMENDATION**

- Alternative SKU: **Standard\_D4s\_v5** (Intel, 4 vCPU / 16 GB)
- Compatibility Score: 97 (Excellent Match)
- Reason for Alternative: Quota: standardDSv5Family has headroom while the primary family needs an increase; Feature: no temp disk (lower cost where local scratch is unused)
- Newer generation if converted: Standard_D4s_v6 - blocked by VM Generation, Disk Controller

**MATERIAL DIFFERENCES**

| Attribute | Current | Target | Assessment | Note |
|---|---|---|---|---|
| CPU Vendor | Intel | Intel | Same | - |
| CPU Architecture | x64 | x64 | Same | - |
| Processor | Intel Xeon Platinum 8370C (Ice Lake); Intel Xeon Platinum 8272CL (Cascade Lake) | Intel Xeon Platinum 8370C (Ice Lake); Intel Xeon Platinum 8573C (Emerald Rapids) | Changed | - |
| vCPU | 4 | 4 | Same | - |
| Memory (GB) | 16 | 16 | Same | - |
| Temp / Local Disk | 32 GB | 150 GB | Changed | - |
| Disk Controller | SCSI | SCSI | Same | - |
| Hyper-V Generation | V1,V2 | V1,V2 | Same | - |
| Uncached Disk IOPS | 6400 | 6400 | Same | - |
| Uncached Disk MBps | 96 | 144 | Improved | - |
| Max Data Disks | 8 | 8 | Same | - |
| Max NICs | 2 | 2 | Same | - |
| Accelerated Networking | True | True | Same | - |
| Premium Storage | True | True | Same | - |
| Availability Zones | 1,2,3 | 1,2,3 | Same | - |
| Network Bandwidth | - | - | Unknown | Not exposed by Resource SKUs API; see Microsoft Learn size page |

**MIGRATION CONSIDERATIONS**

- Lifecycle evidence partially verified
- Quota increase required
- Nested virtualization / temp-disk usage / physical capacity: Unable to Verify from Azure control plane

**RECOMMENDED ACTION**

Plan Migration. Next step: Request Quota Increase. Resize Standard_D4s_v3 -> Standard_D4ds_v5 (LOW confidence, Quota Increase Required).

**DATA QUALITY**

- RetirementDate: Partially Verified
- CpuVendor: Verified
- CpuArchitecture: Verified
- CurrentSkuCapabilities: Verified
- RegionalAvailability: Verified
- Quota: Verified
- PhysicalCapacity: Unable to Verify
- NestedVirtualization: Unable to Verify
- TempDiskUsage: Unable to Verify

---


## Disclaimer

**This assessment and its recommendations are provided "AS IS," without warranties or guarantees.** This independently developed tool is not an official Microsoft product and is not supported or endorsed by Microsoft.

Findings, retirement timelines, SKU compatibility, and modernization recommendations are informational only. Users must verify all recommendations, regional availability, quotas, pricing, VM generation, storage compatibility, and migration requirements against current official Microsoft documentation before implementing production changes.

