# AVD Diagnostics Configuration Tool

## Overview

Ideally, the Azure Virtual Desktop Configuration Workbook should be used to validate and configure the monitoring setup required for Azure Virtual Desktop Insights, including diagnostic settings, data collection rules, and Log Analytics integration.

Alternatively, `AVD-Enable-Diagnostic-Logs.ps1` can programmatically locate all host pools, application groups, and workspaces within a subscription and enable required diagnostic settings in a single operation.

The script enables diagnostics for:

- `Microsoft.DesktopVirtualization/hostPools`
- `Microsoft.DesktopVirtualization/applicationGroups`
- `Microsoft.DesktopVirtualization/workspaces`

This ensures telemetry and operational logs are sent to Log Analytics for monitoring and troubleshooting.

This script does not enable Azure Monitor Insights and does not deploy AMA or a DCR for host-level performance metrics.

## Purpose

Azure Virtual Desktop diagnostic settings are not enabled by default. This script automates configuration across all AVD resources to ensure consistent logging coverage.

**Key goals:**

- Automate diagnostic settings configuration across all AVD resources.
- Standardize logging configuration using `allLogs`.
- Eliminate manual overhead and reduce configuration drift.
- Ensure comprehensive observability for operations teams.

**Why this is a best practice:**

| Best Practice | Benefits |
| --- | --- |
| **Proactive Monitoring and Alerting** | Detect issues before users report them; alert on connection failures, agent health, and resource errors. |
| **Troubleshooting and Root Cause Analysis** | Investigate failed connections with detailed error codes and correlate events across AVD resource types. |
| **Security and Compliance** | Audit administrative changes and access patterns; support compliance and forensics use cases. |
| **Performance Optimization** | Identify bottlenecks, analyze latency, and optimize scaling decisions. |
| **Capacity Planning** | Track trends over time and plan growth with evidence. |
| **Cost Management** | Correlate resource usage with cost and optimize infrastructure sizing. |
| **Azure Monitor Integration** | Feed dashboards, workbooks, automated remediation, and SIEM exports. |
| **Microsoft Support Readiness** | Accelerate support case resolution with historical diagnostic evidence. |

## Prerequisites

- Azure CLI installed ([Install guide](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli))
- Azure account with **Monitoring Contributor** permissions
- PowerShell 5.1 or later
- Active Azure subscription with AVD resources

## Run Order

1. Authenticate with Azure (`az login`) and select the correct subscription.
2. Optionally run check-only mode to audit current diagnostic state.
3. Run deployment mode to enable diagnostics across discovered AVD resources.
4. Review CSV output and perform a post-run check-only validation.

### Quick Start

1. Login to Azure:

    ```powershell
    az login
    ```

2. Run the script:

    ```powershell
    .\AVD-Enable-Diagnostic-Logs.ps1 -SubscriptionId "YOUR-SUBSCRIPTION-ID"
    ```

### Best Practice Checklist

Before running this script, ensure:

- [ ] Log Analytics workspace exists and is properly sized
- [ ] You have Monitoring Contributor permissions on AVD resources
- [ ] Azure CLI is installed and you are signed in (`az login`)
- [ ] You reviewed workspace retention policy
- [ ] You planned for log ingestion costs
- [ ] You have an alerting and query strategy (see [../AVD-AzAlerts](../AVD-AzAlerts/))

## Post-Run Validation

After running deployment mode, validate that all resources report `Enabled (allLogs)` and that logs are arriving in your target Log Analytics workspace.

Recommended validation command:

```powershell
.\AVD-Enable-Diagnostic-Logs.ps1 -SubscriptionId "YOUR-SUB-ID" -CheckOnly
```

## Usage Examples

### Starter Example 1: Enable Diagnostics with Defaults

Discovers all AVD resources in the subscription and enables `allLogs` diagnostic settings pointing to the default workspace (`AVD-LAW` in `rg-avd-monitoring`):

```powershell
.\AVD-Enable-Diagnostic-Logs.ps1 -SubscriptionId "YOUR-SUBSCRIPTION-ID"
```

### Starter Example 2: Check-Only Audit (`-CheckOnly`)

Review the current diagnostic settings status across all AVD resources **without making any changes**. Useful for auditing before a deployment or verifying after one:

```powershell
.\AVD-Enable-Diagnostic-Logs.ps1 `
    -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
    -CheckOnly
```

Output shows per-resource status: `Enabled (allLogs)`, `Enabled (not allLogs)`, `Not Configured`, or `Disabled`.

### Starter Example 3: Custom Workspace and Report Output

Point diagnostics to a specific Log Analytics workspace and write CSV output to a custom path:

```powershell
.\AVD-Enable-Diagnostic-Logs.ps1 `
    -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
    -WorkspaceName "AVD-LogAnalytics" `
    -WorkspaceResourceGroupName "rg-az-west2-avd-nonprod" `
    -CsvPath "C:\Reports\avd-diagnostics-status.csv"
```

## Script Reference, Access Impact, and Parameters

| Script | Purpose | What It Does | Starter Command | Additional Modes | Minimum Access | Azure Resources Changed | Identity Impact | Runtime Calls and Local Output |
| ------ | ------- | ------------ | --------------- | ---------------- | -------------- | ----------------------- | --------------- | ------------------------------ |
| `AVD-Enable-Diagnostic-Logs.ps1` | Enable AVD diagnostic logs to Log Analytics | Discovers all host pools, application groups, and workspaces in a subscription. Configures `allLogs` diagnostic settings to route telemetry to a Log Analytics workspace. Verifies settings after applying and exports results to CSV. | `.\AVD-Enable-Diagnostic-Logs.ps1 -SubscriptionId "YOUR-SUB-ID" -WorkspaceName "YOUR-LAW" -WorkspaceResourceGroupName "YOUR-LAW-RG"` | Check-only audit: `.\AVD-Enable-Diagnostic-Logs.ps1 -SubscriptionId "YOUR-SUB-ID" -CheckOnly`; Custom CSV: `.\AVD-Enable-Diagnostic-Logs.ps1 -SubscriptionId "YOUR-SUB-ID" -CsvPath "C:\Reports\diag-status.csv"`; Custom setting name: `.\AVD-Enable-Diagnostic-Logs.ps1 -SubscriptionId "YOUR-SUB-ID" -DiagnosticSettingName "AVD-Prod-Diagnostics"` | `Monitoring Contributor` on AVD resources and workspace scope | Creates or updates diagnostic settings on host pools, application groups, and workspaces | None | Azure control-plane calls via CLI; writes CSV report (`avd-diagnostics-minimal.csv` by default) |

### Parameters

| Parameter | Required | Type | Default | Description |
| --------- | -------- | ---- | ------- | ----------- |
| `-SubscriptionId` | **Yes** | `string` | - | Azure subscription ID (GUID format) |
| `-WorkspaceName` | No | `string` | `AVD-LAW` | Log Analytics workspace name |
| `-WorkspaceResourceGroupName` | No | `string` | `rg-avd-monitoring` | Resource group containing the workspace. Alias: `-WorkspaceResourceGroup` |
| `-DiagnosticSettingName` | No | `string` | `AVD-Diagnostics` | Name for diagnostic settings created on each resource |
| `-CsvPath` | No | `string` | `avd-diagnostics-minimal.csv` (script directory) | Output path for CSV status report |
| `-CheckOnly` | No | `switch` | Off | Read-only mode - displays current diagnostic settings status without making any changes |

## What Are AVD Diagnostic Logs?

Azure Virtual Desktop diagnostic logs capture telemetry about operations, performance, and user activity. Logs are stored in Log Analytics workspaces where they can be queried, analyzed, and used for alerting.

### Critical Log Categories

| Resource Type | Log Category | Description |
| --- | --- | --- |
| Host Pool | `HostRegistration` | Session host registration events and health status changes |
| Host Pool | `Connection` | User connection attempts, successes, and failures |
| Host Pool | `Error` | Errors occurring at the host pool level |
| Host Pool | `Checkpoint` | Lifecycle events and state transitions |
| Host Pool | `Management` | Administrative operations and configuration changes |
| Host Pool | `AgentHealthStatus` | AVD agent health monitoring |
| Application Group | `Checkpoint` | Application group lifecycle events |
| Application Group | `Error` | Application-specific errors |
| Application Group | `Management` | Application group configuration changes |
| Workspace | `Checkpoint` | Workspace lifecycle events |
| Workspace | `Error` | Workspace-level errors |
| Workspace | `Management` | Workspace configuration changes |
| Workspace | `Feed` | User feed subscription activities |

## Status Indicators

| Status | Meaning |
| ------ | ------- |
| `Enabled (allLogs)` | Configured with comprehensive logging |
| `Enabled (not allLogs)` | Configured but not using allLogs category |
| `Not Configured` | No diagnostic settings exist |
| `Disabled` | Diagnostic settings exist but are disabled |

## Troubleshooting

| Error / Issue | Resolution |
| ------------- | ---------- |
| `Failed to set subscription` | Run `az login` to authenticate before executing the script |
| `Log Analytics Workspace not found` | Verify `-WorkspaceName` and `-WorkspaceResourceGroupName` parameter values |
| `Conflict detected` | A duplicate diagnostic setting exists for the same workspace - remove it or use a different `-DiagnosticSettingName` |
| Permission errors | Ensure your account has **Monitoring Contributor** on the AVD resources and the Log Analytics workspace |

## Additional Resources

| Category | Resource | Description |
| -------- | -------- | ----------- |
| Microsoft Docs | [AVD Diagnostics Overview](https://learn.microsoft.com/en-us/azure/virtual-desktop/diagnostics-log-analytics) | Official diagnostics & Log Analytics guide |
| Microsoft Docs | [Azure Monitor Diagnostic Settings](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings) | Diagnostic settings reference |
| Microsoft Docs | [AVD Required URLs](https://learn.microsoft.com/en-us/azure/virtual-desktop/safe-url-list) | Firewall & network requirements |
| This Repo | [AVD Alerts Script](../AVD-AzAlerts/) | Automated alerting for AVD error conditions |
| This Repo | [AVD Session Host Insights](../AVD-SessionHost-Insights/) | DCR-based performance counter collection |
| Azure | [AVD Insights Workbook](https://learn.microsoft.com/en-us/azure/virtual-desktop/insights) | Built-in Azure Monitor workbook for AVD |
| Community | [AVD Tech Community](https://techcommunity.microsoft.com/t5/azure-virtual-desktop/bd-p/AzureVirtualDesktopForum) | Microsoft Tech Community forum |
| Community | [AVD GitHub Samples](https://github.com/Azure/RDS-Templates/tree/master/wvd-templates) | Official ARM/Bicep deployment templates |

## Version

**Version:** 1.2  
**Last Updated:** March 2026

## License

See [LICENSE](../LICENSE) file for details.

## Disclaimer

**THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.**

This script is provided as-is under the MIT License. The authors and contributors:

- **Make no warranties or guarantees** about the functionality, reliability, or suitability of this script for any purpose
- **Accept no responsibility or liability** for any damages, data loss, service interruptions, or other issues arising from the use of this script
- **Provide no support or maintenance** obligations, though community contributions are welcome
- **Recommend thorough testing** in a non-production environment before deploying to production systems

### Important Notes

- **Test First**: Always test in a development/staging environment before running in production
- **Backup**: Ensure you have appropriate backups and rollback procedures
- **Permissions**: Review required Azure RBAC permissions before execution
- **Costs**: Understand Azure Monitor and Log Analytics pricing before enabling diagnostics at scale
- **Compliance**: Verify this solution meets your organization's security and compliance requirements

**By using this script, you acknowledge and accept these terms and assume all risks associated with its use.**
