---
applyTo: "Assessments/VMSKURetirementReport/**"
---

# Azure Tenant Read-Only Copilot Instructions

These rules apply whenever Copilot accesses, queries, assesses, inspects, or interacts with an **Azure tenant, Azure subscription, management group, resource group, or Azure resource**.

Copilot must operate in **strict read-only mode at all times** when accessing the Azure tenant.

## Mandatory Rules

- Do **not** create, modify, update, delete, rename, move, deploy, restart, stop, start, enable, disable, configure, patch, remediate, or otherwise change any Azure resource, setting, policy, service, account, permission, configuration, or environment.
- Do **not** execute any command, script, API call, Azure CLI command, PowerShell command, ARM/Bicep deployment, Terraform operation, REST request, or automation that can change Azure state.
- Use **read-only Azure commands, APIs, queries, and operations only**.
- Assume the identity being used has **Reader-level permissions only**.
- Never request, assign, activate, elevate, or escalate Azure privileges.
- Never activate or request PIM roles.
- Never create or modify Azure RBAC role assignments.
- Never use Owner, Contributor, User Access Administrator, Privileged Role Administrator, or similar elevated permissions.
- Never use alternate identities, service principals, managed identities, credentials, tokens, or impersonation to obtain additional access.
- Never attempt to bypass, weaken, or work around Azure RBAC, Microsoft Entra ID, Azure Policy, Conditional Access, PIM, or other security controls.
- Never request the user to grant higher permissions merely to complete an assessment.

## Allowed Azure Actions

Copilot may only:

- Read Azure resource inventory.
- Inspect existing Azure configurations.
- Run Azure Resource Graph queries.
- Run read-only KQL queries.
- Retrieve Azure Monitor logs and metrics.
- Review activity logs.
- Review diagnostic settings without changing them.
- Review Azure Policy assignments and compliance state.
- Review RBAC assignments and permissions.
- Review Microsoft Entra configuration when accessible with read-only permissions.
- Review subscription, resource group, and resource metadata.
- Review networking, compute, storage, security, governance, and monitoring configurations.
- Analyze collected information.
- Identify risks, gaps, misconfigurations, retirement exposure, or recommended changes.
- Produce reports, assessments, findings, and recommendations.

## Required Behavior

If an Azure operation requires write, modify, Contributor, Owner, Administrator, PIM activation, or any elevated permission:

1. **Do not perform the action.**
2. Stop that portion of the task.
3. Clearly state that the operation exceeds the permitted read-only scope.
4. Explain what change would normally be required.
5. Provide the recommended remediation or implementation steps **without executing them**.

## Default-Deny Rule

If there is any uncertainty whether an Azure command, API, script, or operation could modify tenant or resource state:

**Treat it as a write operation and do not execute it.**

## Non-Negotiable Azure Safety Rule

**Under no circumstances may Copilot make changes to the Azure tenant, Azure subscriptions, Microsoft Entra ID, Azure resources, permissions, policies, or configurations, nor may it escalate its own privileges.**
