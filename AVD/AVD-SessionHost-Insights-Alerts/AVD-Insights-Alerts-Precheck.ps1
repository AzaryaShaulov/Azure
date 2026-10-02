#requires -Version 5.1
<#
.SYNOPSIS
    Validates prerequisites for AVD Insights alert deployment.

.DESCRIPTION
    Checks RBAC permissions, Azure CLI extensions, Log Analytics workspace
    connectivity, and verifies that expected Perf counter data is flowing
    to the workspace before running AVD-Insights-Alerts-Category-Alerts.ps1.

    This is a safe, read-only script that makes no changes.

.PARAMETER SubscriptionId
    Target Azure subscription ID.

.PARAMETER ResourceGroupName
    Resource group where alert resources will be deployed.

.PARAMETER WorkspaceName
    Log Analytics workspace name.

.PARAMETER WorkspaceResourceGroupName
    Resource group containing the LAW. Defaults to ResourceGroupName.

.PARAMETER Assignee
    Optional UPN or service principal appId to evaluate instead of the signed-in user.

.PARAMETER AssigneeObjectId
    Optional Entra ID object ID of the principal to evaluate.

.PARAMETER CsvPath
    Output path for the precheck report CSV.

.PARAMETER CheckDataFlow
    When specified, queries the LAW for recent Perf counter data to verify
    that the DCR is delivering data. Default: $true.

.EXAMPLE
    .\AVD-Insights-Alerts-Precheck.ps1 `
      -SubscriptionId "YOUR-SUB-ID" `
      -ResourceGroupName "rg-avd-prod" `
      -WorkspaceName "law-avd-prod"

.EXAMPLE
    .\AVD-Insights-Alerts-Precheck.ps1 `
      -SubscriptionId "YOUR-SUB-ID" `
      -ResourceGroupName "rg-avd-prod" `
      -WorkspaceName "law-avd-prod" `
      -Assignee "deployer@contoso.com"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceName,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$Assignee,

    [Parameter(Mandatory = $false)]
    [string]$AssigneeObjectId,

    [Parameter(Mandatory = $false)]
    [string]$CsvPath,

    [Parameter(Mandatory = $false)]
    [bool]$CheckDataFlow = $true
)

$ErrorActionPreference = "Stop"

if (-not $CsvPath) {
    $CsvPath = ".\avd-insights-precheck-$($SubscriptionId.Substring(0,8)).csv"
}

if ([string]::IsNullOrWhiteSpace($WorkspaceResourceGroupName)) {
    $WorkspaceResourceGroupName = $ResourceGroupName
}

# ----------------------------
# Helper
# ----------------------------
function Write-Log {
    param($Message, $Color = "White")
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
}

$results = @()
$passCount = 0
$warnCount = 0
$failCount = 0

function Add-CheckResult {
    param(
        [string]$Check,
        [string]$Scope,
        [ValidateSet("PASS","WARN","FAIL")][string]$Result,
        [string]$Detail
    )
    $script:results += [pscustomobject]@{
        Check  = $Check
        Scope  = $Scope
        Result = $Result
        Detail = $Detail
    }
    $color = switch ($Result) { "PASS" { "Green" } "WARN" { "Yellow" } "FAIL" { "Red" } }
    Write-Log "  [$Result] $Check - $Detail" $color

    switch ($Result) {
        "PASS" { $script:passCount++ }
        "WARN" { $script:warnCount++ }
        "FAIL" { $script:failCount++ }
    }
}

# ----------------------------
# Check 1: Azure CLI
# ----------------------------
Write-Log "=== Pre-flight Checks ===" "Cyan"

if (Get-Command az -ErrorAction SilentlyContinue) {
    $azVer = az version 2>$null | ConvertFrom-Json
    Add-CheckResult -Check "Azure CLI" -Scope "Local" -Result "PASS" -Detail "Installed ($($azVer.'azure-cli'))"
} else {
    Add-CheckResult -Check "Azure CLI" -Scope "Local" -Result "FAIL" -Detail "Not installed"
}

# Check 1b: scheduled-query extension
az extension show --name scheduled-query -o none 2>$null
if ($LASTEXITCODE -eq 0) {
    Add-CheckResult -Check "scheduled-query extension" -Scope "Local" -Result "PASS" -Detail "Installed"
} else {
    Add-CheckResult -Check "scheduled-query extension" -Scope "Local" -Result "FAIL" -Detail "Not installed. Run: az extension add --name scheduled-query"
}

# ----------------------------
# Check 2: Azure Login
# ----------------------------
$accountInfo = az account show 2>$null | ConvertFrom-Json
if ($LASTEXITCODE -eq 0 -and $null -ne $accountInfo) {
    Add-CheckResult -Check "Azure Login" -Scope "Local" -Result "PASS" -Detail "Logged in as $($accountInfo.user.name)"
} else {
    Add-CheckResult -Check "Azure Login" -Scope "Local" -Result "FAIL" -Detail "Not authenticated. Run: az login"
    Write-Log ""
    Write-Log "Cannot proceed without Azure authentication." "Red"
    $results | Export-Csv -NoTypeInformation -Path $CsvPath -Force
    exit 1
}

# Set subscription
az account set --subscription $SubscriptionId 2>$null
if ($LASTEXITCODE -ne 0) {
    Add-CheckResult -Check "Subscription Access" -Scope $SubscriptionId -Result "FAIL" -Detail "Cannot access subscription"
    $results | Export-Csv -NoTypeInformation -Path $CsvPath -Force
    exit 1
} else {
    $accountInfo = az account show 2>$null | ConvertFrom-Json
    Add-CheckResult -Check "Subscription Access" -Scope $SubscriptionId -Result "PASS" -Detail "$($accountInfo.name)"
}

# ----------------------------
# Check 3: Resource Group
# ----------------------------
az group show -n $ResourceGroupName --subscription $SubscriptionId -o none 2>$null
if ($LASTEXITCODE -eq 0) {
    Add-CheckResult -Check "Resource Group" -Scope $ResourceGroupName -Result "PASS" -Detail "Exists"
} else {
    Add-CheckResult -Check "Resource Group" -Scope $ResourceGroupName -Result "FAIL" -Detail "Not found"
}

# ----------------------------
# Check 4: Log Analytics Workspace
# ----------------------------
$lawJson = az monitor log-analytics workspace show `
    -g $WorkspaceResourceGroupName `
    -n $WorkspaceName `
    --subscription $SubscriptionId `
    -o json 2>$null

if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($lawJson)) {
    $law = $lawJson | ConvertFrom-Json
    Add-CheckResult -Check "Log Analytics Workspace" -Scope $WorkspaceName -Result "PASS" -Detail "ID: $($law.customerId)"
} else {
    Add-CheckResult -Check "Log Analytics Workspace" -Scope $WorkspaceName -Result "FAIL" -Detail "Not found in RG '$WorkspaceResourceGroupName'"
    $CheckDataFlow = $false
}

# ----------------------------
# Check 5: RBAC Permissions
# ----------------------------
Write-Log ""
Write-Log "=== RBAC Permission Checks ===" "Cyan"

# Resolve principal
$principalId = $null
if (-not [string]::IsNullOrWhiteSpace($AssigneeObjectId)) {
    $principalId = $AssigneeObjectId
} elseif (-not [string]::IsNullOrWhiteSpace($Assignee)) {
    $principalId = $Assignee
} else {
    $principalId = az ad signed-in-user show --query id -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($principalId)) {
        $principalId = $accountInfo.user.name
    }
}

$rgScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"

$roleAssignmentsJson = az role assignment list `
    --assignee $principalId `
    --scope $rgScope `
    --include-inherited `
    --include-groups `
    --output json 2>$null

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($roleAssignmentsJson)) {
    Add-CheckResult -Check "RBAC Query" -Scope $rgScope -Result "WARN" -Detail "Could not retrieve role assignments for '$principalId'"
} else {
    $roleAssignments = $roleAssignmentsJson | ConvertFrom-Json
    $assignedRoleIds = $roleAssignments | ForEach-Object { ($_.roleDefinitionId -split '/')[-1] }
    $assignedRoleNames = $roleAssignments | Select-Object -ExpandProperty roleDefinitionName

    # Required roles for insights alerts deployment
    # Note: RBAC validation uses role-based checks (Owner/Contributor/Monitoring Contributor + LAW role)
    # rather than per-action matching, because role definition action parsing is complex and fragile.
    $requiredActions = @(
        @{ Action = "Microsoft.Insights/scheduledQueryRules/*"; Description = "Create/manage scheduled query alerts" }
        @{ Action = "Microsoft.Insights/actionGroups/*"; Description = "Create/manage action groups" }
        @{ Action = "Microsoft.OperationalInsights/workspaces/read"; Description = "Resolve LAW resource ID" }
    )

    $fullyQualifiedRoleIds = @(
        '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'  # Owner
        'b24988ac-6180-42a0-ab88-20f7382dd24c'  # Contributor
    )
    $monitoringContributorId = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
    $logAnalyticsContribId   = '92aaf0da-9dab-42b6-94a3-d43ce8d16293'
    $logAnalyticsReaderId    = '73c42c96-874c-492b-b04d-ab87d138a893'

    $hasFullRole          = ($assignedRoleIds | Where-Object { $fullyQualifiedRoleIds -contains $_ }).Count -gt 0
    $hasMonitoringContrib = $assignedRoleIds -contains $monitoringContributorId
    $hasLAWRole           = ($assignedRoleIds -contains $logAnalyticsContribId) -or
                            ($assignedRoleIds -contains $logAnalyticsReaderId)

    if ($hasFullRole) {
        $matchedRole = ($assignedRoleNames | Where-Object { $_ -in @('Owner','Contributor') } | Select-Object -First 1)
        foreach ($req in $requiredActions) {
            Add-CheckResult -Check $req.Action -Scope $rgScope -Result "PASS" -Detail "Covered by '$matchedRole'"
        }
    } elseif ($hasMonitoringContrib -and $hasLAWRole) {
        foreach ($req in $requiredActions) {
            Add-CheckResult -Check $req.Action -Scope $rgScope -Result "PASS" -Detail "Covered by Monitoring Contributor + LAW role"
        }
    } else {
        if (-not $hasMonitoringContrib) {
            Add-CheckResult -Check "Microsoft.Insights/scheduledQueryRules/*" -Scope $rgScope -Result "FAIL" -Detail "Missing. Assign 'Monitoring Contributor'"
            Add-CheckResult -Check "Microsoft.Insights/actionGroups/*" -Scope $rgScope -Result "FAIL" -Detail "Missing. Assign 'Monitoring Contributor'"
        } else {
            Add-CheckResult -Check "Microsoft.Insights/scheduledQueryRules/*" -Scope $rgScope -Result "PASS" -Detail "Covered by Monitoring Contributor"
            Add-CheckResult -Check "Microsoft.Insights/actionGroups/*" -Scope $rgScope -Result "PASS" -Detail "Covered by Monitoring Contributor"
        }
        if (-not $hasLAWRole) {
            Add-CheckResult -Check "Microsoft.OperationalInsights/workspaces/read" -Scope $rgScope -Result "FAIL" -Detail "Missing. Assign 'Log Analytics Reader'"
        } else {
            Add-CheckResult -Check "Microsoft.OperationalInsights/workspaces/read" -Scope $rgScope -Result "PASS" -Detail "Covered by LAW role"
        }
    }

    Write-Log ""
    Write-Log "  Assigned roles on scope:" "Gray"
    if ($assignedRoleNames.Count -gt 0) {
        $assignedRoleNames | Sort-Object -Unique | ForEach-Object { Write-Log "    - $_" "Gray" }
    } else {
        Write-Log "    (none found)" "Gray"
    }
}

# ----------------------------
# Check 6: Data Flow Validation
# ----------------------------
if ($CheckDataFlow -and $null -ne $law) {
    Write-Log ""
    Write-Log "=== Data Flow Checks ===" "Cyan"

    $customerId = $law.customerId

    # Check Perf counter data
    $perfQuery = "Perf | where TimeGenerated > ago(1h) | where ObjectName in ('Processor Information','Memory','LogicalDisk','PhysicalDisk','User Input Delay per Process','RemoteFX Network') | summarize Count=count(), DistinctCounters=dcount(CounterName), DistinctHosts=dcount(Computer) by ObjectName | order by ObjectName asc"

    $perfResult = az monitor log-analytics query `
        -w $customerId `
        --analytics-query $perfQuery `
        -o json 2>$null

    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($perfResult)) {
        $perfData = $perfResult | ConvertFrom-Json
        if ($perfData.Count -gt 0) {
            $totalRows = ($perfData | Measure-Object -Property Count -Sum).Sum
            Add-CheckResult -Check "Perf Data (last 1h)" -Scope $WorkspaceName -Result "PASS" -Detail "$totalRows rows across $($perfData.Count) object names"

            # Check specific counters
            $expectedObjects = @('Processor Information', 'Memory', 'LogicalDisk')
            foreach ($obj in $expectedObjects) {
                $match = $perfData | Where-Object { $_.ObjectName -eq $obj }
                if ($match) {
                    Add-CheckResult -Check "Perf: $obj" -Scope $WorkspaceName -Result "PASS" -Detail "$($match.Count) rows, $($match.DistinctCounters) counters, $($match.DistinctHosts) hosts"
                } else {
                    Add-CheckResult -Check "Perf: $obj" -Scope $WorkspaceName -Result "WARN" -Detail "No data in last 1h. Verify DCR includes this counter."
                }
            }

            # Optional counters
            $optionalObjects = @('User Input Delay per Process', 'RemoteFX Network')
            foreach ($obj in $optionalObjects) {
                $match = $perfData | Where-Object { $_.ObjectName -eq $obj }
                if ($match) {
                    Add-CheckResult -Check "Perf: $obj" -Scope $WorkspaceName -Result "PASS" -Detail "$($match.Count) rows, $($match.DistinctHosts) hosts"
                } else {
                    Add-CheckResult -Check "Perf: $obj" -Scope $WorkspaceName -Result "WARN" -Detail "No data. InputDelay/RTT alerts will not fire without this counter."
                }
            }
        } else {
            Add-CheckResult -Check "Perf Data (last 1h)" -Scope $WorkspaceName -Result "FAIL" -Detail "No Perf data found. Verify DCR and AMA agent deployment."
        }
    } else {
        Add-CheckResult -Check "Perf Data Query" -Scope $WorkspaceName -Result "WARN" -Detail "Could not query LAW. Verify permissions."
    }

    # Check WVDCheckpoints
    $wvdQuery = "union isfuzzy=true (WVDCheckpoints | where TimeGenerated > ago(1h) | summarize Count=count() | extend Table='WVDCheckpoints'), (WVDAgentHealthStatus | where TimeGenerated > ago(1h) | summarize Count=count() | extend Table='WVDAgentHealthStatus')"

    $wvdResult = az monitor log-analytics query `
        -w $customerId `
        --analytics-query $wvdQuery `
        -o json 2>$null

    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($wvdResult)) {
        $wvdData = $wvdResult | ConvertFrom-Json
        foreach ($table in @('WVDCheckpoints', 'WVDAgentHealthStatus')) {
            $match = $wvdData | Where-Object { $_.Table -eq $table }
            if ($match -and [int]$match.Count -gt 0) {
                Add-CheckResult -Check "Table: $table" -Scope $WorkspaceName -Result "PASS" -Detail "$($match.Count) rows in last 1h"
            } else {
                Add-CheckResult -Check "Table: $table" -Scope $WorkspaceName -Result "WARN" -Detail "No data. Enable AVD diagnostics for SignIn/Capacity alerts."
            }
        }
    } else {
        Add-CheckResult -Check "WVD Tables Query" -Scope $WorkspaceName -Result "WARN" -Detail "Could not query WVD diagnostic tables."
    }
}

# ----------------------------
# Export Results
# ----------------------------
try {
    $csvDirectory = Split-Path $CsvPath -Parent
    if ($csvDirectory -and -not (Test-Path $csvDirectory)) {
        New-Item -ItemType Directory -Path $csvDirectory -Force | Out-Null
    }
    $results | Export-Csv -NoTypeInformation -Path $CsvPath -Force
    Write-Log ""
    Write-Log "Report exported to: $CsvPath" "Green"
} catch {
    Write-Log "Warning: Failed to export CSV: $($_.Exception.Message)" "Yellow"
}

# ----------------------------
# Summary
# ----------------------------
Write-Log ""
Write-Log "=== Precheck Summary ===" "Cyan"
Write-Log "PASS: $passCount  |  WARN: $warnCount  |  FAIL: $failCount" $(if ($failCount -gt 0) { "Red" } elseif ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($failCount -gt 0) {
    Write-Log ""
    Write-Log "One or more checks failed. Resolve the issues above before running AVD-Insights-Alerts-Category-Alerts.ps1" "Red"
    exit 1
} elseif ($warnCount -gt 0) {
    Write-Log ""
    Write-Log "Warnings detected. Deployment may succeed but some alerts may not fire until data flows." "Yellow"
    exit 0
} else {
    Write-Log ""
    Write-Log "All checks passed. Ready to deploy." "Green"
    exit 0
}

