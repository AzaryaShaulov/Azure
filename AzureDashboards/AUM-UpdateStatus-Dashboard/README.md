# Azure Update Manager Operations Dashboard

Production-ready Azure Portal Dashboard for monitoring Azure Update Manager maintenance activity across Azure virtual machines and Azure Arc-enabled servers.

The project generates a `Microsoft.Portal/dashboards` resource backed by Azure Resource Graph (ARG). It is an Azure Portal Dashboard, not an Azure Monitor Workbook.

## What the dashboard shows

### Progress

- Server counts by operating system SKU and version:
  - targeted;
  - completed;
  - failed;
  - in progress.
- Completed, targeted, and failed server counts by maintenance configuration.
- Maintenance reporting freshness.
- Current Azure Arc Agent status:
  - `Expired`;
  - `Connected`;
  - `Offline` (`Disconnected` and `Offline` source values).

### Summary

- Targeted, not started, in progress, succeeded, succeeded with warnings, failed, unknown, and stale servers.
- Completion and success percentages.
- Failed, stalled, long-running, restart-required, stale, and pending-update totals.
- Current patch assessment compliance and available update totals.

### Immediate attention

- Servers with operation failures, failed or pending patches, stale status, stalled or long-running operations, or pending restarts.
- Operation timing, update counts, restart state, and error information for initial triage.

### Pending updates

- Update name, KB ID, classification, version, and distinct number of servers missing each update.

## Import artifacts

| Reporting range | File |
|---|---|
| 30 days (recommended/default) | `dist/azure-update-manager-dashboard.json` |
| 14 days | `dist/azure-update-manager-dashboard-14d.json` |
| 7 days | `dist/azure-update-manager-dashboard-7d.json` |

Azure Portal Dashboard ARG tiles cannot substitute a dropdown value into KQL like a Workbook parameter. Each artifact therefore contains queries generated for its stated range.

The Arc Agent tile always reports current resource status and is not constrained by the maintenance-history range.

## Prerequisites

- Azure Update Manager data available in Azure Resource Graph.
- Azure VMs and/or Azure Arc-enabled servers visible to the dashboard users.
- `Reader` access, or equivalent permissions that include `Microsoft.ResourceGraph/resources/read`, at every subscription or management-group scope that the dashboard must report.
- Permission to create or update `Microsoft.Portal/dashboards` in the destination resource group. Use the narrowest suitable built-in or custom role.
- Azure CLI only when using command-line import or live validation.
- PowerShell 7 or Windows PowerShell 5.1 for generation and tests.

No credentials, subscription IDs, resource groups, maintenance configurations, or run IDs are embedded in the dashboard.

## Import through the Azure portal

1. Sign in to the Azure portal with access to all required subscriptions.
2. Open **Dashboard**.
3. Select **Upload**.
4. Choose one JSON file from `dist`.
5. Confirm that Resource Graph uses the intended subscription scope.
6. Save the dashboard to the production resource group.
7. Share it only with the required operations groups.
8. Open every tile once with a representative production account to confirm access and data visibility.

## Import with Azure CLI

Authenticate interactively, select the intended subscription, and import the default dashboard:

```powershell
az login
az account set --subscription <subscription-id-or-name>
az portal dashboard import `
  --resource-group <dashboard-resource-group> `
  --name aum-operations-dashboard `
  --input-path .\dist\azure-update-manager-dashboard.json
```

Do not put access tokens, client secrets, or tenant-specific identifiers in this repository. For automated delivery, use workload identity federation or managed identity and least-privilege RBAC.

## Production readiness

Before production approval, also verify:

- all expected subscriptions are visible to the operator account;
- dashboard totals match Azure Update Manager for a representative maintenance cycle;
- failed, stale, stalled, restart-pending, and pending-update examples drill down as expected;
- the dashboard owner and support group are recorded;
- access is reviewed and restricted to operational need;
- the selected 7-, 14-, or 30-day artifact matches the operational reporting policy.

## Operational definitions

| Term | Definition |
|---|---|
| Latest run | Greatest maintenance start time for each maintenance configuration in the selected range. |
| Completion percentage | Terminal operations divided by targeted servers. |
| Success percentage | Succeeded plus succeeded-with-warnings operations divided by terminal operations. |
| Stale | No source status update for more than 10 minutes. |
| Stalled | In progress and stale. |
| Long-running | In progress for more than 90 minutes while source data is fresh. |
| Offline Arc Agent | Arc resource status is `Disconnected` or `Offline`. |

Zero denominators display `N/A`; the dashboard does not present them as 0% or 100%.

## Data and platform limitations

- Azure Portal ARG tile queries must remain at or below 4,096 characters. Generation compacts KQL and structural validation enforces the limit.
- Azure Resource Graph can reject queries with multiple unsupported remote-table joins. Queries intentionally use constrained joins and separate tiles.
- Patch assessment software-update details are retained by ARG for approximately seven days. A 14- or 30-day dashboard cannot extend Azure's retention for pending-update details.
- Azure Update Manager and Arc data can arrive asynchronously. A stale or empty tile must be checked against source timestamps and permissions before being interpreted as zero.
- The dashboard itself does not send Teams or email notifications. Configure Azure Monitor alerting separately if active notification is required.
- Portal dashboard export behavior and visual styling are controlled by Azure Portal capabilities.

## Troubleshooting

### A tile is blank

1. Open the tile query in Resource Graph Explorer.
2. Confirm the viewer can read every required subscription.
3. Confirm the query is below the 4,096-character portal limit.

### Counts differ from Azure Update Manager

1. Confirm the imported dashboard range.
2. Confirm both views use the same subscription scope.
3. Check ingestion timestamps and stale status.

### Arc machines appear Offline

The dashboard maps both `Disconnected` and `Offline` Arc resource statuses to `Offline`. Investigate the Azure Connected Machine agent, outbound connectivity, proxy/firewall rules, certificates, and machine clock.

## Change control

1. Select the artifact that matches the approved reporting range.
2. Review the JSON for environment-specific values.
3. Test with a representative maintenance cycle.
4. Obtain operations-owner approval before replacing the production dashboard.
