# Data sources, permissions and blind spots

All calls are read-only.

| Data | Source / call | Scope | RBAC |
|---|---|---|---|
| Retirement status and dates | Microsoft Learn: [retirements and capacity restrictions](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions), [End of Life sizes](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/end-of-life-sizes-list), [modernization guide](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirement/retired-sizes-modernization-guide) (HTTPS GET) | Public | None |
| CPU vendor per series | Microsoft Learn size-series spec pages (via the public `MicrosoftDocs/azure-compute-docs` repository); refreshed by `Update-Catalogs.ps1` | Public | None |
| VM inventory | Azure Resource Graph `Resources` (`microsoft.compute/virtualmachines`) via `az graph query`; with `-TenantId` for a non-default tenant, the Resource Graph REST API with a tenant-scoped token | All in-scope subscriptions | Reader |
| NICs / disks / ADE | ARG `microsoft.network/networkinterfaces`, `microsoft.compute/disks`, `microsoft.compute/virtualmachines/extensions` | Subscriptions with VMs | Reader |
| Advisor retirement signals | ARG `advisorresources` (`recommendationSubCategory = ServiceUpgradeAndRetirement`) | Subscriptions with VMs | Reader (best effort) |
| Service Health retirements | ARG `servicehealthresources` (HealthAdvisory / Retirement) | Subscriptions with VMs | Reader (best effort) |
| Size capabilities and restrictions | Compute SKUs REST `GET /subscriptions/<s>/providers/Microsoft.Compute/skus?$filter=location eq '<r>'` with a subscription-scoped token (fallback: `az vm list-skus --all`) | Each subscription/region needing recommendations, plus one per remaining region for capabilities | Reader |
| Quota | `az vm list-usage --location <r> --subscription <s>` | Same pairs as above | Reader |
| Utilization (optional) | Azure Monitor `metrics:getBatch` (`Percentage CPU`, `Available Memory Bytes`) | Running VMs with an action | Monitoring Reader |
| Prices (default; `-SkipPricing` to skip) | `https://prices.azure.com/api/retail/prices` | Public | None |

## Performance notes

- Resource SKUs are read through the REST API. Measured: about 7-9 s per subscription/region, versus about 106 s for
  `az vm list-skus` (1,327 VM sizes in eastus2).
- Authentication is checked up front with a timeout (`-AuthTimeoutSec`) so an expired token fails fast instead of
  waiting on an interactive sign-in.
- SKU catalogs and quota are fetched in parallel (`-ThrottleLimit`, default 6). They are only requested for
  subscription/region pairs that contain VMs needing recommendations.
- Candidate evaluation is memoized by (subscription, region, size, requirement signature). Estates with thousands of
  VMs usually reduce to a few hundred evaluations.
- Raw Resource SKU responses and the VM inventory are written under `data/` only with `-KeepRawData`.

## Known blind spots (reported as `Unable to Verify`)

| Item | Why |
|---|---|
| Physical regional capacity | Quota and restrictions do not guarantee allocatable hardware; resize or deploy to confirm (or use Capacity Reservations) |
| Nested virtualization use | Not exposed by the control plane |
| Temp-disk usage | Only presence on the size is known; pagefile / tempdb / scratch usage must be confirmed in the guest |
| Network bandwidth caps | Not in the Resource SKUs API; see the Microsoft Learn size page |
| Licensing impact of vCPU or vendor changes | Workload-specific (per-core / per-socket licences) |
| VM Scale Set (Uniform) instances | Not in the VM resource type; assess the scale-set model separately |
