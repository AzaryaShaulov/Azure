# AVD Session Host Insights LogicApp Alerts

## Overview

TThis script deploys and configures a Logic App webhook notification pipeline for AVD Insights performance alerts—it creates or updates the Logic App workflow with managed identity, ensures the AVD-Insights-Detailed webhook action group exists, and validates/authorizes the Office 365 API connection for sending email notifications. It then routes Insights performance alerts through the webhook so operators receive detailed email notifications when session host metrics cross alert thresholds.

Signals are sourced from AVD Insights data, including Perf counters, `WVDCheckpoints`, and `WVDAgentHealthStatus`.

## Purpose

This solution complements the existing [AVD-AzAlerts](../AVD-AzAlerts/) WVDErrors-category alerts by adding deep session host performance and session lifecycle coverage.

**Key goals:**

- Provide category-based alerting across AVD session quality, host performance, disk health, lifecycle, correlation, event logs, and GPU performance.
- Deliver actionable email context through Logic App enrichment instead of basic alert notifications.
- Keep deployment repeatable through script-driven precheck and idempotent deployment steps.
- Support threshold tuning with KQL-backed category query files.

**Why this is a best practice:**

| Best Practice | Benefits |
| --- | --- |
| **Proactive Monitoring and Alerting** | Detect performance degradation and session issues before user-impact escalates. |
| **Troubleshooting and Root Cause Analysis** | Correlate Perf, checkpoint, and agent health signals in one workflow. |
| **Operational Consistency** | Use the same deployment pattern across environments with precheck and scripted rollout. |
| **Performance Optimization** | Track capacity pressure, latency, and host bottlenecks for tuning decisions. |
| **Cost Management** | Focus alerting on meaningful categories and thresholds to reduce noisy operations overhead. |
| **Microsoft Support Readiness** | Retain alert and telemetry evidence for faster incident triage. |

## Prerequisites

- Azure CLI installed ([Install guide](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli))
- Azure account with **Monitoring Contributor** and **Log Analytics Reader** (or Owner/Contributor)
- PowerShell 5.1 or later
- Active Azure subscription with AVD session hosts
- Azure Monitor Agent (AMA) deployed on session hosts
- Data Collection Rule sending required Perf counters to the target Log Analytics workspace
- AVD diagnostics enabled for lifecycle/agent tables (`WVDCheckpoints`, `WVDAgentHealthStatus`)

### Best Practice Checklist

Before running this solution, ensure:

- [ ] AMA is healthy on all session hosts
- [ ] DCR is collecting required Perf counters into the target workspace
- [ ] AVD diagnostics tables (`WVDCheckpoints`, `WVDAgentHealthStatus`) are populated
- [ ] You have required RBAC on resource group, workspace, and alert resources
- [ ] Office 365 connection authorization ownership is assigned for post-deploy validation
- [ ] Threshold expectations are reviewed in `alerts-config.insights.json` and `queries/category-*.kql`

## Runbook and Alert Matrix

Use the runbook for operational response steps, validation checks, and day-2 maintenance guidance after deployment. Use the alert matrix to quickly understand each alert category, the monitored signals, and intended operator actions.

- [Insights Runbook](AVD-hosts-Insights-Alerts-Runbook.md)
- [Insights Alert Matrix](AVD-Insights-Alert-Matrix.md)

## Run Order

1. Authenticate with Azure (`az login`) and confirm the target subscription.
2. Run precheck to validate permissions, extension readiness, and data flow.
3. Run Logic App deployment to create/update the webhook email pipeline and bootstrap missing category alerts.
4. Validate deployment outputs and confirm alerts are connected to the detailed action group.

### Quick Start

1. Login to Azure:

  ```powershell
  az login
  ```

1. Run precheck:

  ```powershell
  .\AVD-Insights-Alerts-Precheck.ps1 -SubscriptionId "YOUR-SUB-ID" -ResourceGroupName "YOUR-RG" -WorkspaceName "YOUR-LAW"
  ```

### Starter Example 1: Deploy Full Solution

1. Deploy the detailed email pipeline and bootstrap category alerts:

```powershell
.\AVD-Insights-Alerts-Deploy-LogicApp.ps1 `
  -SubscriptionId "YOUR-SUB-ID" `
  -ResourceGroupName "YOUR-RG" `
  -LogicAppName "AVD-Insights-Alert-Email" `
  -Location "eastus2" `
  -WorkspaceName "YOUR-LAW" `
  -WorkspaceResourceGroupName "YOUR-LAW-RG" `
  -SendFromEmail "alerts@contoso.com" `
  -SendToEmail "team@contoso.com"
```

### Starter Example 2: Deploy Alerts Only (No Logic App)

Create or update category rules directly:

```powershell
.\AVD-Insights-Alerts-Category-Alerts.ps1 `
  -ResourceGroup "YOUR-RG" `
  -WorkspaceName "YOUR-LAW" `
  -Location "eastus2" `
  -CategoryFilter "HostPerformance"
```

## Post-Run Validation

After deployment, validate that the Logic App, action group, and all category alerts are present and connected.

Recommended validation command:

```powershell
.\AVD-Insights-Alerts-Precheck.ps1 -SubscriptionId "YOUR-SUB-ID" -ResourceGroupName "YOUR-RG" -WorkspaceName "YOUR-LAW"
```

Script steps diagram:

[![AVD Insights Alerts Script Steps](AVD-Insights-Alerts-Steps.svg)](AVD-Insights-Alerts-Steps.svg)

## Script Reference, Access Impact, and Parameters

| Script | Purpose | What It Does | Starter Command | Additional Modes | Minimum Access | Azure Resources Changed | Identity Impact | Runtime Calls and Local Output |
| ------ | ------- | ------------ | --------------- | ---------------- | -------------- | ----------------------- | --------------- | ------------------------------ |
| `AVD-Insights-Alerts-Precheck.ps1` | Validate prerequisites | Checks RBAC permissions, Azure CLI extension readiness, workspace connectivity, and Perf data availability. Read-only. | `.\AVD-Insights-Alerts-Precheck.ps1 -SubscriptionId "YOUR-SUB-ID" -ResourceGroupName "YOUR-RG" -WorkspaceName "YOUR-LAW"` | Re-run after deployment for verification. | Read permissions on target resource group and Log Analytics workspace | None | None | Azure read operations and console validation output |
| `AVD-Insights-Alerts-Deploy-LogicApp.ps1` | Primary deploy for pipeline and bootstrap | Creates/updates Logic App, API connection, webhook action group, and RBAC assignment for managed identity. Bootstraps missing category alerts. | `.\AVD-Insights-Alerts-Deploy-LogicApp.ps1 -SubscriptionId "YOUR-SUB-ID" -ResourceGroupName "YOUR-RG" -LogicAppName "AVD-Insights-Alert-Email" -Location "eastus2" -WorkspaceName "YOUR-LAW" -WorkspaceResourceGroupName "YOUR-LAW-RG" -SendFromEmail "alerts@contoso.com" -SendToEmail "team@contoso.com"` | Re-run safely for updates in place. | `Monitoring Contributor` and `Log Analytics Reader` at required scopes | Logic App, API connection, action group, RBAC assignment, and alert links | Uses system-assigned managed identity for query execution | Azure control-plane calls, deployment status messages |
| `AVD-Insights-Alerts-Category-Alerts.ps1` | Deploy category alert rules only | Loads `alerts-config.insights.json` and `queries/category-*.kql`, then creates or updates category scheduled query rules. | `.\AVD-Insights-Alerts-Category-Alerts.ps1 -ResourceGroup "YOUR-RG" -WorkspaceName "YOUR-LAW" -Location "eastus2"` | WhatIf: `-WhatIf`; single category: `-CategoryFilter "HostPerformance"`; severity override: `-Severity 1` | `Monitoring Contributor` on target resource group/workspace | Scheduled query alert rules and action group bindings | None | Azure control-plane calls and rule deployment output |

### Parameters

| Script | Required Parameters | Optional Parameters |
| ------ | ------------------- | ------------------- |
| `AVD-Insights-Alerts-Precheck.ps1` | `-SubscriptionId`, `-ResourceGroupName`, `-WorkspaceName` | `-WorkspaceResourceGroupName` (if supported in your version) |
| `AVD-Insights-Alerts-Deploy-LogicApp.ps1` | `-SubscriptionId`, `-ResourceGroupName`, `-LogicAppName`, `-Location`, `-WorkspaceName`, `-WorkspaceResourceGroupName`, `-SendFromEmail`, `-SendToEmail` | Environment-specific naming overrides where available |
| `AVD-Insights-Alerts-Category-Alerts.ps1` | `-ResourceGroup`, `-WorkspaceName`, `-Location` | `-WhatIf`, `-CategoryFilter`, `-AlertFilter`, `-Severity`, `-WebhookUrl`, `-CreateOnly` |

## What Are AVD Session Host Insights Alerts?

These are category-consolidated scheduled query alerts built on AVD Insights telemetry and related AVD operational tables.

### Alert Categories

| Category | Alert Rule | Signals | Data Source |
| -------- | ---------- | ------- | ----------- |
| Session Quality | `AVD-Insights-Category-SessionQuality` | InputDelay (Process/Session), RTT latency, UDP bandwidth | Perf (User Input Delay, RemoteFX Network) |
| Host Performance | `AVD-Insights-Category-HostPerformance` | CPU, memory, commit ratio, pages/sec, page faults, disk timing | Perf (Processor, Memory, LogicalDisk) |
| Disk Health | `AVD-Insights-Category-DiskHealth` | Queue length, free space | Perf (PhysicalDisk, LogicalDisk) |
| Session Lifecycle | `AVD-Insights-Category-SessionLifecycle` | Sign-in duration, capacity pressure, session imbalance | `WVDCheckpoints`, `WVDAgentHealthStatus`, Perf |
| Correlated Signals | `AVD-Insights-Category-CorrelatedSignals` | Multi-signal hosts, FSLogix plus Perf correlation | Perf plus `WVDCheckpoints` plus Event |
| Event Log Alerts | `AVD-Insights-Category-EventLogAlerts` | FSLogix profile error | Event (FSLogix operational/admin logs) |
| GPU Performance | `AVD-Insights-Category-GPUPerformance` | GPU encoding time | Perf (RemoteFX Graphics) |

## Status Indicators

| Status | Meaning |
| ------ | ------- |
| Precheck Passed | Required dependencies, permissions, and data flow checks succeeded |
| Precheck Warning | One or more non-blocking gaps were detected and should be reviewed |
| Deployment Succeeded | Logic App pipeline and alert resources were created or updated successfully |
| Bootstrap Skipped | Category alerts already existed and did not require creation |
| Alert Rule Enabled | Scheduled query rule is active and bound to action group |

## Troubleshooting

| Error / Issue | Resolution |
| ------------- | ---------- |
| Office 365 connection not sending emails | Re-authorize the API connection in Azure Portal and verify sender mailbox permissions |
| Alerts created but no detailed email content | Confirm Logic App callback URL/action group binding and Log Analytics Reader role assignment |
| Precheck reports missing Perf data | Validate AMA health and DCR scope, then wait for fresh ingestion |
| Permission or RBAC failures | Confirm `Monitoring Contributor` and `Log Analytics Reader` at required scopes |
| Category deploy not updating thresholds | Verify edits in `queries/category-*.kql` and redeploy with update mode |

## Additional Resources

| Category | Resource | Description |
| -------- | -------- | ----------- |
| This Repo | [AVD Diagnostics](../AVD-Diagnostics/) | Enable and validate AVD diagnostics required for lifecycle signals |
| This Repo | [AVD Az Alerts](../AVD-AzAlerts/) | WVDErrors-category alerts for connection/authentication failures |
| This Repo | [AVD Session Host Insights](../AVD-SessionHost-Insights/) | AMA and DCR setup for Perf metrics collection |
| This Repo | [Perf Metrics Script](../AVD-SessionHost-Insights/AVD-Insights-Enable-PerfMetricsDCR.ps1) | Deploys session host Perf metric collection prerequisites |
| This Repo | [Insights Alert Matrix](AVD-Insights-Alert-Matrix.md) | Alert category and signal reference |
| This Repo | [Insights Runbook](AVD-hosts-Insights-Alerts-Runbook.md) | Operational response and maintenance guidance |
| Microsoft Docs | [AVD Insights](https://learn.microsoft.com/en-us/azure/virtual-desktop/insights) | Official AVD Insights documentation |
| Microsoft Docs | [Azure Monitor Scheduled Query Alerts](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-types#log-search-alerts) | Alert rule behavior and configuration details |

## Version

**Version:** 1.0  
**Last Updated:** March 2026

## License

See [LICENSE](../LICENSE) file for details.

## Disclaimer

**THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.**

This solution is provided as-is under the MIT License. The authors and contributors:

- Make no warranties or guarantees about functionality, reliability, or suitability for any purpose
- Accept no responsibility or liability for damages, data loss, service interruptions, or other impacts from use
- Provide no support or maintenance obligations, though community contributions are welcome
- Recommend thorough testing in non-production environments before production rollout

### Important Notes

- Test first in a development or staging environment before production rollout
- Validate Logic App and Office 365 connection authorization after deployment
- Confirm required RBAC assignments before execution
- Review Azure Monitor and Log Analytics ingestion costs before broad enablement
- Ensure organizational security and compliance requirements are met

By using this solution, you acknowledge and accept these terms and assume all associated risks.
