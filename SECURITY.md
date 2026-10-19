# Security Policy

This policy covers every folder of this repository. The VM SKU Retirement Report also has its own
[security policy](Assessments/VMSKURetirementReport/SECURITY.md), which describes how that tool is built to be read-only
and to keep personal data out of its reports.

## Reporting a vulnerability

**Do not open a public issue for security problems.**

Report privately through GitHub's
[private vulnerability reporting](https://docs.github.com/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability):
open the **Security** tab and choose **Report a vulnerability**, or go straight to
<https://github.com/AzaryaShaulov/Azure/security/advisories/new>.

Please include:

- the folder and file that are affected and, for the VM SKU Retirement Report, its version (the report footer, or
  `toolVersion` in `assessment.json`);
- steps to reproduce, using sanitized data: no tenant, subscription or user identifiers, tokens or keys;
- the impact you observed or expect.

You should receive an acknowledgement within 5 business days. Coordinated disclosure timelines are agreed case by case.

## Scope

| Folder | What it contains | Supported versions |
|---|---|---|
| [`Assessments/VMSKURetirementReport`](Assessments/VMSKURetirementReport/) | The assessment scripts and modules, report templates, release package and CI workflows | The latest minor release (1.2.x) |
| [`AVD`](AVD/) | PowerShell scripts, KQL queries and a template that configure diagnostics, Data Collection Rules, alerts and a Logic App email workflow | No versioned releases |
| [`azure-arc`](azure-arc/) | An Azure Portal dashboard definition | No versioned releases |
| [`AzureDashboards`](AzureDashboards/) | Azure Portal dashboard definitions | No versioned releases |
| [`AzureWorkbooks`](AzureWorkbooks/) | An Azure Workbook definition | No versioned releases |

Examples of what to report: a credential, key or token in a file; a script or template that grants or requests more access
than its README says; a deployment that changes Azure configuration in a way its README does not describe; a report that
exposes personal data the project says it masks.

## Not in scope

- Vulnerabilities in Azure services, the Azure CLI or PowerShell themselves. Report those to the
  [Microsoft Security Response Center](https://msrc.microsoft.com/create-report).
- A recommendation that turns out to be wrong (for example a retirement date or a target size). That is a normal bug: open an
  issue. These tools are independent community tools, provided as is; see the disclaimer in the [readme](readme.md).
