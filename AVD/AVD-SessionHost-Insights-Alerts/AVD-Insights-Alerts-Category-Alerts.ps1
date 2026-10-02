#requires -Version 5.1
<#
==============================================================================
SCRIPT VERSION: 1.0
LAST UPDATED: March 16, 2026
DISCLAIMER: This script is provided AS IS, without warranties or support guarantees.
==============================================================================
QUICK START:
1. Update the default parameter values in the script with your values:
   - ResourceGroup: Your Azure resource group name
   - WorkspaceName: Your Log Analytics workspace name
   - Location: Your Azure region (e.g., eastus, westus2)

2. Run the script:
   .\AVD-Insights-Alerts-Category-Alerts.ps1

3. Or override any parameter:
   .\AVD-Insights-Alerts-Category-Alerts.ps1 -SubscriptionId "12345678-..." `
     -ResourceGroup "rg-avd" -WorkspaceName "law-avd" -Location "eastus2" `
     -WebhookUrl "https://contoso.logic.azure.com/workflows/..."
==============================================================================
.SYNOPSIS
  Deploys AVD Insights performance and session lifecycle alerts from a config file.

.DESCRIPTION
  Reads alert definitions from alerts-config.insights.json, loads the referenced
  KQL query files (thresholds are embedded as 'let' variables in the KQL), and
  creates Azure Monitor scheduled query rules via Azure CLI.

  Complements the existing AVD-Category (WVDErrors) alerts by adding
  Perf-counter and session lifecycle monitoring.

  REQUIRED: Azure CLI with the 'scheduled-query' extension installed.
  REQUIRED: A Log Analytics workspace receiving AVD Insights data (Perf, WVDCheckpoints,
            WVDAgentHealthStatus) via Data Collection Rule.

.PARAMETER SubscriptionId
  Azure subscription ID. If not provided, uses the current subscription context.

.PARAMETER ResourceGroup
  Resource group for the scheduled query rules and action group.

.PARAMETER WorkspaceName
  Name of the Log Analytics workspace. Alias: -LawName (backward compatible).

.PARAMETER WorkspaceResourceGroupName
  Resource group containing the LAW. Defaults to ResourceGroup if not specified.

.PARAMETER Location
  Azure region for scheduled query rules.

.PARAMETER ConfigPath
  Path to the alerts-config.insights.json file.

.PARAMETER WebhookUrl
  Optional HTTPS webhook URL for the action group (e.g., Logic App callback URL).

.PARAMETER ActionGroupName
  Name of the webhook action group for Insights alerts.

.PARAMETER WebhookReceiverName
  Receiver name for the webhook action.

.PARAMETER UseCommonAlertSchema
  When true, webhook receiver uses Azure Monitor common alert schema.

.PARAMETER CategoryFilter
  Optional. Deploy only alerts in the specified category (e.g., "SessionQuality").

.PARAMETER AlertFilter
  Optional. Deploy only the alert with this exact name.

.PARAMETER Severity
  Override severity for all alerts (0=Critical..4=Verbose). Uses config values when not specified.

.PARAMETER CreateOnly
  When true (default), existing alerts are skipped. Set to $false to update existing alerts.

.PARAMETER CsvPath
  Path for CSV export of alert deployment results.

.PARAMETER WhatIf
  Preview changes without creating or modifying resources.

.EXAMPLE
  .\AVD-Insights-Alerts-Category-Alerts.ps1 -ResourceGroup "rg-avd-prod" `
    -WorkspaceName "law-avd-prod" -Location "eastus2"

.EXAMPLE
  .\AVD-Insights-Alerts-Category-Alerts.ps1 -CategoryFilter "HostPerformance" -WhatIf

.EXAMPLE
  .\AVD-Insights-Alerts-Category-Alerts.ps1 -AlertFilter "AVD-Insights-Category-HostPerformance" -Severity 1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$ResourceGroup = "your-resource-group",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [Alias('LawName')]
  [string]$WorkspaceName = "your-log-analytics-workspace",

  [Parameter(Mandatory = $false)]
  [Alias('WorkspaceResourceGroup')]
  [string]$WorkspaceResourceGroupName,

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$Location = "your-azure-region",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$ConfigPath,

  [Parameter(Mandatory = $false)]
  [ValidatePattern('^$|^https?://.+')]
  [string]$WebhookUrl,

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$ActionGroupName = "AVD-Insights-Detailed",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$WebhookReceiverName = "AVDInsightsWebhook",

  [Parameter(Mandatory = $false)]
  [bool]$UseCommonAlertSchema = $true,

  [Parameter(Mandatory = $false)]
  [string]$CategoryFilter,

  [Parameter(Mandatory = $false)]
  [string]$AlertFilter,

  [Parameter(Mandatory = $false)]
  [ValidateRange(0, 4)]
  [int]$Severity = -1,

  [Parameter(Mandatory = $false)]
  [bool]$CreateOnly = $true,

  [Parameter(Mandatory = $false)]
  [string]$CsvPath
)

$ErrorActionPreference = "Stop"

$ScriptStartTime = Get-Date
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Default config path: alerts-config.insights.json in the same directory as the script
if (-not $ConfigPath) {
  $ConfigPath = Join-Path $ScriptDir "alerts-config.insights.json"
}

# Default CSV path
if (-not $CsvPath) {
  if ($SubscriptionId) {
    $CsvPath = ".\avd-insights-report-$($SubscriptionId.Substring(0,8)).csv"
  } else {
    $CsvPath = ".\avd-insights-report.csv"
  }
}

# ----------------------------
# Helper Functions
# ----------------------------
function Write-Log {
  param($Message, $Color = "White")
  $timestamp = Get-Date -Format "HH:mm:ss"
  Write-Host "[$timestamp] $Message" -ForegroundColor $Color
}

function Test-AlertExists {
  param([string]$AlertName)

  # Priority 1: Pre-built definitive map
  if ($null -ne $script:alertExistenceMap -and $script:alertExistenceMap.ContainsKey($AlertName)) {
    return $script:alertExistenceMap[$AlertName]
  }

  # Priority 2: Bulk-query cache from pre-flight
  if ($null -ne $script:existingAlertNamesList) {
    return ($script:existingAlertNamesList -contains $AlertName)
  }

  # Priority 3: Individual API query fallback
  az monitor scheduled-query show -g $ResourceGroup -n $AlertName --subscription $script:subscriptionId -o none 2>$null
  return ($LASTEXITCODE -eq 0)
}

function Read-KqlFile {
  param(
    [Parameter(Mandatory)][string]$QueryFilePath
  )

  if (-not (Test-Path $QueryFilePath)) {
    throw "KQL query file not found: $QueryFilePath"
  }

  # Strip // comment lines - they break when KQL is flattened to a single line
  $lines = Get-Content $QueryFilePath
  $filtered = $lines | Where-Object { $_ -notmatch '^\s*//' }
  return ($filtered -join "`n").Trim()
}

# ----------------------------
# Pre-flight Checks
# ----------------------------

# Check 1: Azure CLI
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw "Azure CLI not found. Please install from https://learn.microsoft.com/cli/azure/install-azure-cli"
}

# Check 1b: scheduled-query extension
Write-Host "[Pre-flight] Checking required Azure CLI extension: scheduled-query..." -ForegroundColor Cyan
az extension show --name scheduled-query -o none 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host "[Pre-flight] 'scheduled-query' extension not found. Installing..." -ForegroundColor Yellow
  az extension add --name scheduled-query --yes -o none 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw "Required Azure CLI extension 'scheduled-query' could not be installed."
  }
  Write-Host "[Pre-flight] 'scheduled-query' extension installed." -ForegroundColor Green
}

# Check 2: Azure login
Write-Host "[Pre-flight] Checking Azure authentication..." -ForegroundColor Cyan
$accountInfo = az account show 2>$null | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $null -eq $accountInfo) {
  throw "Not logged in to Azure. Please run 'az login' first."
}
Write-Host "[Pre-flight] Logged in as: $($accountInfo.user.name)" -ForegroundColor Gray

# Check 3: Subscription context
if ($SubscriptionId) {
  Write-Host "[Pre-flight] Setting subscription context: $SubscriptionId" -ForegroundColor Cyan
  az account set --subscription $SubscriptionId 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to set subscription context to '$SubscriptionId'."
  }
  $accountInfo = az account show 2>$null | ConvertFrom-Json
}
$script:subscriptionId = $accountInfo.id
Write-Host "[Pre-flight] Subscription: $($accountInfo.name) ($($accountInfo.id))" -ForegroundColor Gray

# Check 4: Placeholder detection
$placeholderParams = @()
if ($ResourceGroup -eq "your-resource-group") { $placeholderParams += "ResourceGroup" }
if ($WorkspaceName -eq "your-log-analytics-workspace") { $placeholderParams += "WorkspaceName" }
if ($Location -eq "your-azure-region") { $placeholderParams += "Location" }

if ($placeholderParams.Count -gt 0) {
  $paramList = $placeholderParams -join ", "
  throw "Please update the following parameter(s) with actual values: $paramList`nEdit the defaults in the script or pass them as arguments."
}

# Check 5: Config file exists
if (-not (Test-Path $ConfigPath)) {
  throw "Config file not found: $ConfigPath"
}
Write-Host "[Pre-flight] Config file: $ConfigPath" -ForegroundColor Gray

# Check 6: RBAC permissions
Write-Host "[Pre-flight] Checking RBAC permissions..." -ForegroundColor Cyan

$rgScope = "/subscriptions/$($accountInfo.id)/resourceGroups/$ResourceGroup"

$principalId = az ad signed-in-user show --query id -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($principalId)) {
  $principalId = $accountInfo.user.name
}

$roleAssignmentsJson = az role assignment list `
  --assignee $principalId `
  --scope $rgScope `
  --include-inherited `
  --include-groups `
  --output json 2>$null

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($roleAssignmentsJson)) {
  Write-Host "[Pre-flight] WARNING: Could not retrieve role assignments. Ensure you have:" -ForegroundColor Yellow
  Write-Host "  - Microsoft.Insights/scheduledQueryRules/* on RG '$ResourceGroup'" -ForegroundColor Yellow
  Write-Host "  - Microsoft.Insights/actionGroups/* on RG '$ResourceGroup'" -ForegroundColor Yellow
  Write-Host "  - Microsoft.OperationalInsights/workspaces/read" -ForegroundColor Yellow
} else {
  $roleAssignments = $roleAssignmentsJson | ConvertFrom-Json
  $fullyQualifiedRoleIds = @(
    '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'  # Owner
    'b24988ac-6180-42a0-ab88-20f7382dd24c'  # Contributor
  )
  $monitoringContributorId   = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
  $logAnalyticsContribId     = '92aaf0da-9dab-42b6-94a3-d43ce8d16293'
  $logAnalyticsReaderId      = '73c42c96-874c-492b-b04d-ab87d138a893'

  $assignedRoleIds = $roleAssignments | ForEach-Object { ($_.roleDefinitionId -split '/')[-1] }

  $hasFullRole          = ($assignedRoleIds | Where-Object { $fullyQualifiedRoleIds -contains $_ }).Count -gt 0
  $hasMonitoringContrib = $assignedRoleIds -contains $monitoringContributorId
  $hasLAWContribOrReader = ($assignedRoleIds -contains $logAnalyticsContribId) -or
                           ($assignedRoleIds -contains $logAnalyticsReaderId)

  if ($hasFullRole) {
    $assignedRoleNames = $roleAssignments | Select-Object -ExpandProperty roleDefinitionName
    $matchedRole = ($assignedRoleNames | Where-Object { $_ -in @('Owner','Contributor') } | Select-Object -First 1)
    Write-Host "[Pre-flight] RBAC OK - '$matchedRole' covers all required permissions." -ForegroundColor Green
  } elseif ($hasMonitoringContrib -and $hasLAWContribOrReader) {
    Write-Host "[Pre-flight] RBAC OK - 'Monitoring Contributor' + Log Analytics role cover permissions." -ForegroundColor Green
  } else {
    Write-Host "[Pre-flight] WARNING: Insufficient RBAC permissions detected." -ForegroundColor Yellow
    Write-Host "  Quick fix:" -ForegroundColor Cyan
    Write-Host "    az role assignment create --assignee '$principalId' --role 'Monitoring Contributor' --scope '$rgScope'" -ForegroundColor Cyan
    Write-Host "    az role assignment create --assignee '$principalId' --role 'Log Analytics Reader'   --scope '$rgScope'" -ForegroundColor Cyan
    throw "Insufficient RBAC permissions. Assign the roles listed above and re-run."
  }
}

# ----------------------------
# Load Config
# ----------------------------
Write-Log "Loading alert configuration..." "Cyan"
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$alertPrefix     = $config.alertPrefix
$defaultEvalFreq = $config.defaults.evaluationFrequency
$defaultWindow   = $config.defaults.windowSize

# Flatten all alert definitions from categories
$allAlerts = @()
foreach ($catName in ($config.categories | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)) {
  $category = $config.categories.$catName
  foreach ($alertDef in $category.alerts) {
    $allAlerts += [pscustomobject]@{
      Category            = $catName
      CategoryDescription = $category.description
      Name                = $alertDef.name
      Description         = $alertDef.description
      QueryFile           = $alertDef.queryFile
      Severity            = if ($Severity -ge 0) { $Severity } else { $alertDef.severity }
      EvaluationFrequency = if ($alertDef.evaluationFrequency) { $alertDef.evaluationFrequency } else { $defaultEvalFreq }
      WindowSize          = if ($alertDef.windowSize) { $alertDef.windowSize } else { $defaultWindow }
      Thresholds          = @{}
    }

    # Convert NoteProperty thresholds to hashtable
    if ($alertDef.thresholds) {
      $ht = @{}
      $alertDef.thresholds | Get-Member -MemberType NoteProperty | ForEach-Object {
        $ht[$_.Name] = $alertDef.thresholds.($_.Name)
      }
      $allAlerts[-1].Thresholds = $ht
    }
  }
}

Write-Log "Loaded $($allAlerts.Count) alert definitions across $(($config.categories | Get-Member -MemberType NoteProperty).Count) categories." "Gray"

# Apply category filter
if (-not [string]::IsNullOrWhiteSpace($CategoryFilter)) {
  $allAlerts = $allAlerts | Where-Object { $_.Category -eq $CategoryFilter }
  if ($allAlerts.Count -eq 0) {
    throw "No alerts found in category '$CategoryFilter'. Available: $(($config.categories | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name) -join ', ')"
  }
  Write-Log "Category filter applied: $CategoryFilter ($($allAlerts.Count) alerts)" "Gray"
}

# Apply alert name filter
if (-not [string]::IsNullOrWhiteSpace($AlertFilter)) {
  $allAlerts = $allAlerts | Where-Object { $_.Name -eq $AlertFilter }
  if ($allAlerts.Count -eq 0) {
    throw "Alert '$AlertFilter' not found in config."
  }
  Write-Log "Alert filter applied: $AlertFilter" "Gray"
}

# ----------------------------
# Resolve Log Analytics Workspace
# ----------------------------
Write-Log "Resolving Log Analytics Workspace: $WorkspaceName" "Cyan"

$ResolvedWorkspaceRG = if ([string]::IsNullOrWhiteSpace($WorkspaceResourceGroupName)) {
  $ResourceGroup
} else {
  $WorkspaceResourceGroupName
}

$LawId = az monitor log-analytics workspace show `
  -g $ResolvedWorkspaceRG `
  -n $WorkspaceName `
  --subscription $script:subscriptionId `
  --query id -o tsv 2>$null

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($LawId)) {
  throw "Could not resolve LAW id for '$WorkspaceName' in RG '$ResolvedWorkspaceRG'."
}
Write-Log "LAW ID: $LawId" "Gray"

# ----------------------------
# Create / Ensure Action Group
# ----------------------------
$ActionGroupId = $null
Write-Log "Action Group: $ActionGroupName" "Cyan"

if ($PSCmdlet.ShouldProcess($ActionGroupName, "Create or update Insights webhook action group")) {
  $agJson = $null
  $agExists = $false
  try {
    $agJson = az monitor action-group show -g $ResourceGroup -n $ActionGroupName --subscription $script:subscriptionId -o json 2>&1
    $agExists = ($LASTEXITCODE -eq 0)
  } catch {
    $agExists = $false
  }

  if (-not $agExists) {
    if ([string]::IsNullOrWhiteSpace($WebhookUrl)) {
      throw "Action group '$ActionGroupName' not found and -WebhookUrl was not provided."
    }
    Write-Log "Creating action group '$ActionGroupName'..." "Yellow"
    $createArgs = @(
      'monitor', 'action-group', 'create',
      '-g', $ResourceGroup, '-n', $ActionGroupName,
      '--subscription', $script:subscriptionId,
      '--short-name', 'AVDInsght',
      '--action', 'webhook', $WebhookReceiverName, ('"' + $WebhookUrl + '"')
    )
    if ($UseCommonAlertSchema) {
      $createArgs += 'usecommonalertschema'
    }
    $createOutput = az @createArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to create action group: $createOutput"
    }
    Write-Log "Action group '$ActionGroupName' created." "Green"
  } else {
    Write-Log "Action group '$ActionGroupName' already exists." "Gray"

    # Ensure webhook receiver if URL provided
    if (-not [string]::IsNullOrWhiteSpace($WebhookUrl)) {
      $ag = $agJson | ConvertFrom-Json
      $webhookReceivers = @($ag.webhookReceivers)
      $receiverWithUrl = $webhookReceivers | Where-Object { $_.serviceUri -eq $WebhookUrl } | Select-Object -First 1

      if ($null -eq $receiverWithUrl) {
        $receiverByName = $webhookReceivers | Where-Object { $_.name -eq $WebhookReceiverName } | Select-Object -First 1
        if ($null -ne $receiverByName) {
          Write-Log "Replacing webhook receiver '$WebhookReceiverName' with new URL." "Yellow"
          az monitor action-group update -g $ResourceGroup -n $ActionGroupName --subscription $script:subscriptionId --remove-action $WebhookReceiverName 2>&1 | Out-Null
        }

        $updateArgs = @(
          'monitor', 'action-group', 'update',
          '-g', $ResourceGroup, '-n', $ActionGroupName,
          '--subscription', $script:subscriptionId,
          '--add-action', 'webhook', $WebhookReceiverName, ('"' + $WebhookUrl + '"')
        )
        if ($UseCommonAlertSchema) {
          $updateArgs += 'usecommonalertschema'
        }
        $updateOutput = az @updateArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
          Write-Log "Warning: Failed to update webhook receiver: $updateOutput" "Yellow"
        } else {
          Write-Log "Webhook receiver ensured on '$ActionGroupName'." "Green"
        }
      } else {
        Write-Log "Webhook URL already present on action group." "Gray"
      }
    }
  }

  $ActionGroupId = az monitor action-group show `
    -g $ResourceGroup `
    -n $ActionGroupName `
    --subscription $script:subscriptionId `
    --query id -o tsv 2>$null

  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ActionGroupId)) {
    throw "Failed to retrieve action group ID for '$ActionGroupName'."
  }
  Write-Log "Action Group ID: $ActionGroupId" "Gray"
} else {
  Write-Log "[WhatIf] Would create/update action group: $ActionGroupName" "Yellow"
  $subId = $script:subscriptionId
  $ActionGroupId = "/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/microsoft.insights/actionGroups/$ActionGroupName"
}

if ([string]::IsNullOrWhiteSpace($ActionGroupId)) {
  throw "A valid action group is required. Provide -WebhookUrl or pre-create '$ActionGroupName'."
}

# ----------------------------
# Check Existing Alerts (bulk cache)
# ----------------------------
Write-Host "[Pre-flight] Checking for existing Insights alerts (timeout: 25s)..." -ForegroundColor Cyan
$script:existingAlertNamesList = $null
try {
  $_listJobRg    = $ResourceGroup
  $_listJobSubId = $script:subscriptionId
  $_listJobPrefix = $alertPrefix
  $listJob = Start-Job -ScriptBlock {
    az monitor scheduled-query list -g ${using:_listJobRg} --subscription ${using:_listJobSubId} --query "[?starts_with(name, '${using:_listJobPrefix}')].name" -o tsv 2>$null
  }

  $completed = Wait-Job $listJob -Timeout 25

  if ($null -ne $completed) {
    $existingAlertsOutput = Receive-Job $listJob -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($existingAlertsOutput)) {
      $script:existingAlertNamesList = $existingAlertsOutput -split "[\r\n]+" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() }
      Write-Host "[Pre-flight] Found $($script:existingAlertNamesList.Count) existing Insights alert(s)" -ForegroundColor Gray
    } else {
      Write-Host "[Pre-flight] No existing Insights alerts found" -ForegroundColor Gray
      $script:existingAlertNamesList = @()
    }
  } else {
    Stop-Job $listJob -ErrorAction SilentlyContinue
    Write-Host "[Pre-flight] Alert list query timed out - will check individually" -ForegroundColor Yellow
    $script:existingAlertNamesList = $null
  }
  Remove-Job $listJob -Force -ErrorAction SilentlyContinue
} catch {
  Write-Host "[Pre-flight] Could not query existing alerts - will check individually" -ForegroundColor Yellow
  $script:existingAlertNamesList = $null
}

# Build definitive existence map
$script:alertExistenceMap = @{}
Write-Log "Verifying existence of $($allAlerts.Count) alert(s)..." "Cyan"
foreach ($alert in $allAlerts) {
  $script:alertExistenceMap[$alert.Name] = Test-AlertExists -AlertName $alert.Name
}
$existingCount = ($script:alertExistenceMap.Values | Where-Object { $_ -eq $true }).Count
$newCount = $allAlerts.Count - $existingCount
Write-Log "Verified: $existingCount existing, $newCount to create." "Gray"

# ----------------------------
# Deploy Alerts
# ----------------------------
$AlertResults    = @()
$ExistingAlerts  = @()
$NewlyCreated    = @()
$FailedAlerts    = @()

Write-Log ""
Write-Log "Processing $($allAlerts.Count) Insights alerts..." "Cyan"
Write-Log ""

$alertCount = 0
foreach ($alert in $allAlerts) {
  $alertCount++
  $percentComplete = [Math]::Round(($alertCount / $allAlerts.Count) * 100)
  Write-Progress -Activity 'Deploying AVD Insights Alerts' `
    -Status "Alert $alertCount of $($allAlerts.Count): $($alert.Name)" `
    -PercentComplete $percentComplete

  $severityVal = $alert.Severity
  $severityText = switch ($severityVal) {
    0 { "Critical" }
    1 { "Error" }
    2 { "Warning" }
    3 { "Informational" }
    4 { "Verbose" }
  }

  # Check existence
  $alertExists = Test-AlertExists -AlertName $alert.Name

  if ($alertExists) {
    $ExistingAlerts += $alert.Name
  }

  if ($alertExists -and $CreateOnly) {
    Write-Log "Skipping existing alert: $($alert.Name)" "Gray"
    $AlertResults += [pscustomobject]@{
      AlertName   = $alert.Name
      Category    = $alert.Category
      Description = $alert.Description
      Severity    = "$severityVal ($severityText)"
      Action      = "Skipped"
      Status      = "Skipped"
    }
    continue
  }

  # Load and resolve KQL
  $queryFilePath = Join-Path $ScriptDir $alert.QueryFile
  try {
    $kql = Read-KqlFile -QueryFilePath $queryFilePath
  } catch {
    Write-Log "  [FAIL] KQL load error for $($alert.Name): $($_.Exception.Message)" "Red"
    $FailedAlerts += $alert.Name
    $AlertResults += [pscustomobject]@{
      AlertName   = $alert.Name
      Category    = $alert.Category
      Description = $alert.Description
      Severity    = "$severityVal ($severityText)"
      Action      = "Failed"
      Status      = "KQL Error: $($_.Exception.Message)"
    }
    continue
  }

  if ($PSCmdlet.ShouldProcess($alert.Name, "Create scheduled query alert")) {
    Write-Log "Creating: $($alert.Name) [$($alert.Category)] (Severity: $severityText)" "Cyan"

    try {
      $queryEscaped = $kql -replace "`r", "" -replace "`n", " "

      # Write condition-query to temp file to avoid CMD shell parsing issues
      # (az.cmd passes args through cmd.exe which breaks on KQL special chars)
      $condQueryFile = [System.IO.Path]::GetTempFileName()
      [System.IO.File]::WriteAllText($condQueryFile, "Query1=$queryEscaped")

      $azCmdArgs = @(
        'monitor', 'scheduled-query', 'create',
        '-g', $ResourceGroup, '-n', $alert.Name, '-l', $Location,
        '--subscription', $script:subscriptionId, '--scopes', $LawId,
        '--evaluation-frequency', $alert.EvaluationFrequency,
        '--window-size', $alert.WindowSize,
        '--severity', "$severityVal",
        '--description', $alert.Description,
        '--condition', "count 'Query1' > 0",
        '--condition-query', "@$condQueryFile",
        '--action-groups', $ActionGroupId
      )

      if ($config.defaults.autoMitigate -eq $true) {
        $azCmdArgs += @('--auto-mitigate', 'true')
      }

      $output = az @azCmdArgs 2>&1

      if ($LASTEXITCODE -eq 0) {
        Write-Log "  [OK] Created successfully." "Green"
        $NewlyCreated += $alert.Name
        $AlertResults += [pscustomobject]@{
          AlertName   = $alert.Name
          Category    = $alert.Category
          Description = $alert.Description
          Severity    = "$severityVal ($severityText)"
          Action      = "Created"
          Status      = "Success"
        }
      } else {
        $errStr = ($output | Out-String).ToLower()
        if ($errStr -match "conflict|already exists") {
          Write-Log "  ~ Already exists (skipped)" "Gray"
          $ExistingAlerts += $alert.Name
          $AlertResults += [pscustomobject]@{
            AlertName   = $alert.Name
            Category    = $alert.Category
            Description = $alert.Description
            Severity    = "$severityVal ($severityText)"
            Action      = "Skipped"
            Status      = "Skipped"
          }
        } else {
          Write-Log "  [FAIL] $output" "Red"
          $FailedAlerts += $alert.Name
          $AlertResults += [pscustomobject]@{
            AlertName   = $alert.Name
            Category    = $alert.Category
            Description = $alert.Description
            Severity    = "$severityVal ($severityText)"
            Action      = "Failed"
            Status      = "Failed"
          }
        }
      }
    } catch {
      Write-Log "  [FAIL] $($_.Exception.Message)" "Red"
      $FailedAlerts += $alert.Name
      $AlertResults += [pscustomobject]@{
        AlertName   = $alert.Name
        Category    = $alert.Category
        Description = $alert.Description
        Severity    = "$severityVal ($severityText)"
        Action      = "Error"
        Status      = "Error"
      }
    } finally {
      if ($condQueryFile -and (Test-Path $condQueryFile)) {
        Remove-Item $condQueryFile -ErrorAction SilentlyContinue
      }
    }
  } else {
    Write-Log "[WhatIf] Would create: $($alert.Name)" "Yellow"
    $AlertResults += [pscustomobject]@{
      AlertName   = $alert.Name
      Category    = $alert.Category
      Description = $alert.Description
      Severity    = "$severityVal ($severityText)"
      Action      = "WouldCreate"
      Status      = "WhatIf"
    }
  }
}

Write-Progress -Activity 'Deploying AVD Insights Alerts' -Completed

# ----------------------------
# Ensure Action Groups on Existing Alerts
# ----------------------------
if (-not [string]::IsNullOrWhiteSpace($ActionGroupId) -and $ExistingAlerts.Count -gt 0 -and -not $CreateOnly) {
  Write-Log "Ensuring action groups on existing alerts..." "Cyan"
  foreach ($alertName in ($ExistingAlerts | Select-Object -Unique)) {
    if (-not $PSCmdlet.ShouldProcess($alertName, "Ensure action groups")) {
      Write-Log "[WhatIf] Would ensure action groups for: $alertName" "Yellow"
      continue
    }

    $currentAgOutput = az monitor scheduled-query show `
      -g $ResourceGroup -n $alertName `
      --subscription $script:subscriptionId `
      --query "actions.actionGroups[].actionGroupId" -o tsv 2>$null

    $currentIds = @()
    if (-not [string]::IsNullOrWhiteSpace($currentAgOutput)) {
      $currentIds = $currentAgOutput -split "[\r\n]+" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim().ToLowerInvariant() }
    }

    if ($currentIds -contains $ActionGroupId.ToLowerInvariant()) {
      Write-Log "Action group already correct on: $alertName" "Gray"
      continue
    }

    $updateOutput = az monitor scheduled-query update `
      -g $ResourceGroup -n $alertName `
      --subscription $script:subscriptionId `
      --action-groups $ActionGroupId 2>&1

    if ($LASTEXITCODE -eq 0) {
      Write-Log "Updated action groups on: $alertName" "Green"
    } else {
      Write-Log "Warning: Failed to update action groups on '$alertName': $updateOutput" "Yellow"
    }
  }
}

# ----------------------------
# Export Results to CSV
# ----------------------------
if ($AlertResults.Count -gt 0) {
  try {
    $csvDirectory = Split-Path $CsvPath -Parent
    if ($csvDirectory -and -not (Test-Path $csvDirectory)) {
      New-Item -ItemType Directory -Path $csvDirectory -Force | Out-Null
    }
    $AlertResults | Export-Csv -NoTypeInformation -Path $CsvPath -Force -ErrorAction Stop
    Write-Log ""
    Write-Log "Results exported to: $CsvPath" "Green"
  } catch {
    Write-Log "Warning: Failed to export CSV: $($_.Exception.Message)" "Yellow"
  }
}

# ----------------------------
# Summary
# ----------------------------
Write-Log ""
Write-Log "=== AVD Insights Alerts Summary ===" "Cyan"
Write-Log "Action Group: $ActionGroupName" "White"
Write-Log "Total Alerts Processed: $($AlertResults.Count)" "White"
Write-Log ""

$whatIfCount = ($AlertResults | Where-Object Status -eq "WhatIf").Count

if ($whatIfCount -gt 0) {
  Write-Log "WhatIf Mode: $whatIfCount alert(s) would be created; $($ExistingAlerts.Count) would be skipped" "Yellow"
} else {
  Write-Log "=== Statistics ===" "Cyan"
  Write-Log "Created:  $($NewlyCreated.Count)" "Green"
  Write-Log "Skipped:  $(($ExistingAlerts | Select-Object -Unique).Count)" "Yellow"
  Write-Log "Failed:   $($FailedAlerts.Count)" $(if ($FailedAlerts.Count -gt 0) { "Red" } else { "Gray" })

  if ($NewlyCreated.Count -gt 0) {
    Write-Log ""
    Write-Log "=== Newly Created ===" "Green"
    foreach ($name in $NewlyCreated) {
      Write-Log "  - $name" "Gray"
    }
  }

  if ($FailedAlerts.Count -gt 0) {
    Write-Log ""
    Write-Log "=== Failed ===" "Red"
    foreach ($name in $FailedAlerts) {
      Write-Log "  - $name" "Gray"
    }
  }
}

# Category breakdown
Write-Log ""
Write-Log "=== By Category ===" "Cyan"
$AlertResults | Group-Object Category | ForEach-Object {
  $created = ($_.Group | Where-Object Action -eq "Created").Count
  $skipped = ($_.Group | Where-Object Action -eq "Skipped").Count
  $failed  = ($_.Group | Where-Object { $_.Action -in @("Failed","Error") }).Count
  Write-Log "  $($_.Name): $($_.Count) total ($created created, $skipped skipped, $failed failed)" "Gray"
}

$duration = (Get-Date) - $ScriptStartTime
Write-Log ""
Write-Log "Execution time: $($duration.TotalSeconds.ToString('F1')) seconds" "Gray"
Write-Log "Done." "Green"


