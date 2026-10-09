# Azure

Azure assessment tools, monitoring automation, dashboards and workbooks. Each project has its own documentation,
prerequisites and usage instructions.

## Projects at a glance

| Area | Subproject | Summary |
|---|---|---|
| Assessments | [VM SKU Retirement Report](Assessments/VMSKURetirementReport/README.md) | Read-only assessment of Azure VMs affected by Microsoft SKU retirement announcements. Recommends retirement targets and optional v6/v7 modernization paths, checks availability and quota, and generates HTML, Markdown, CSV and JSON reports with PAYGO price estimates. |
| Azure Virtual Desktop | [Diagnostics](AVD/AVD-Diagnostics/README.md) | Configures diagnostic logging for AVD host pools, application groups and workspaces to provide telemetry for troubleshooting and alerting. |
| Azure Virtual Desktop | [Azure Monitor Alerts](AVD/AVD-AzAlerts/README.md) | Deploys WVDErrors-based alert categories and a Logic App email workflow with affected hosts, errors and troubleshooting context. |
| Azure Virtual Desktop | [Session Host Insights](AVD/AVD-SessionHost-Insights/README.md) | Sets up Data Collection Rules and session-host performance telemetry for CPU, memory, disk, networking, GPU and session quality. |
| Azure Virtual Desktop | [Session Host Insights Alerts](AVD/AVD-SessionHost-Insights-Alerts/README.md) | Deploys performance and session-health alerts with detailed email notifications, including disk pressure and FSLogix signals. |
| Azure Arc | [Arc-enabled Servers Dashboard](azure-arc/README.md) | Azure Portal dashboard showing server inventory, operating systems, connection and agent status, plus Windows Server 2012/R2 Extended Security Update licensing and assignments. |
| Azure Dashboards | [Azure Update Manager Operations Dashboard](AzureDashboards/AUM-UpdateStatus-Dashboard/README.md) | Resource Graph-backed Azure Portal dashboard for maintenance progress, patch compliance, failures, pending updates and restart requirements across Azure VMs and Arc-enabled servers. Includes 7-, 14- and 30-day reporting artifacts. |
| Azure Workbooks | [Arc SQL Migration Assessment](<AzureWorkbooks/Arc - SQL Migration Assessment/README.md>) | Consolidates existing Azure Arc SQL migration assessments into an estate-wide view of readiness, blockers, recommended Azure SQL targets and estimated costs, with Excel export for planning. |

See the [AVD overview](AVD/README.md) for the monitoring decision guide and deployment sequence.

## Repository structure

```text
Azure
|-- Assessments/
|   `-- VMSKURetirementReport/
|-- AVD/
|   |-- AVD-Diagnostics/
|   |-- AVD-AzAlerts/
|   |-- AVD-SessionHost-Insights/
|   `-- AVD-SessionHost-Insights-Alerts/
|-- azure-arc/
|-- AzureDashboards/
|   `-- AUM-UpdateStatus-Dashboard/
`-- AzureWorkbooks/
    `-- Arc - SQL Migration Assessment/
```

## Usage and safety

- Start with the linked project README for supported scenarios, permissions and download/import instructions.
- The VM SKU Retirement Report is read-only. AVD setup and dashboard/workbook deployment may change Azure
  configuration; review the relevant scripts and validate in a non-production environment before deployment.
- Treat real assessment exports and monitoring results as confidential: they may contain tenant, resource or user
  identifiers.
- For vulnerability reporting, see [SECURITY.md](SECURITY.md). Licensing is documented by the individual projects.

### Disclaimer – Independent Community Tools

**These tools are provided "AS IS," without warranties or guarantees of any kind.**

These independently developed tools, scripts, dashboards and workbooks are **not an official Microsoft product or Microsoft-supported solution**. Microsoft does not provide support, maintenance, warranties, or guarantees for these tools or their outputs.

Monitoring results, deployment guidance and any assessment or migration recommendations are provided for informational and planning purposes only. Findings may not reflect the latest Azure capabilities, regional availability, pricing, retirement announcements, or Microsoft documentation.

**Before making production changes, users must independently validate, as applicable:**

- VM SKU compatibility and supported migration paths.
- Regional SKU availability and subscription quotas.
- Pricing and capacity requirements.
- VM generation, disk controller, NVMe, and storage compatibility.
- Redeployment, downtime, and migration requirements.
- Official Azure retirement dates and Microsoft documentation.

Users are solely responsible for validating assessment findings, evaluating potential operational impacts, and planning and executing changes within their environments.

**Use of these tools and reliance on its outputs are at the user's own risk.**
