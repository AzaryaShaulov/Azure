#requires -Version 5.1
<#
==============================================================================
SCRIPT VERSION: 1.2
LAST UPDATED: March 12, 2026
REPOSITORY: https://github.com/AzaryaShaulov/AVD
DISCLAIMER: This script is provided AS IS, without warranties or support guarantees.
==============================================================================
QUICK START:
1. Update the default parameter values in the script with your values:
   - ResourceGroup: Your Azure resource group name
   - WorkspaceName (or LawName): Your Log Analytics workspace name
   - Location: Your Azure region (e.g., eastus, westus2)
   - DetailedResultsWebhookUrl: HTTPS webhook URL (e.g., Logic App callback URL)
   - SubscriptionId: (Optional) Specify if you want to target a specific subscription

2. Run the script:
   .\AVD-Category-Alerts.ps1 -DetailedResultsWebhookUrl "https://..."

3. Or override any parameter:
   .\AVD-Category-Alerts.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012" `
     -ResourceGroup "rg-avd" -WorkspaceName "law-avd" -Location "eastus2" `
     -DetailedResultsWebhookUrl "https://contoso.logic.azure.com/workflows/..."
==============================================================================
.SYNOPSIS
  Deploys and maintains Azure Monitor scheduled query alerts for Azure Virtual Desktop (AVD).

.DESCRIPTION
  Creates and updates Log Analytics-based AVD category alerts and configures the
  webhook action group for detailed alert delivery via Logic App.

  The script requires Azure CLI and sufficient Azure RBAC permissions.
  
  REQUIRED: Update default parameter values (ResourceGroup, WorkspaceName, Location)
  in the script, or pass them as arguments when running the script.
  Note: -LawName and -WorkspaceResourceGroup are accepted as backward-compatible aliases.

.PARAMETER SubscriptionId
  Azure subscription ID. If not provided, uses the current subscription context.

.PARAMETER DetailedResultsWebhookUrl
  Optional HTTPS webhook URL for detailed alert payload delivery (for example, a Logic App
  or Automation endpoint that can email query results).

.PARAMETER DetailedActionGroupName
  Name of the optional webhook action group used for detailed notifications.
  Default: "AVD-Alerts-Detailed"

.PARAMETER DetailedWebhookReceiverName
  Receiver name for the webhook action in the detailed action group.
  Default: "AVDAlertsDetailedWebhook"

.PARAMETER UseCommonAlertSchemaForWebhook
  When true, webhook receiver uses Azure Monitor common alert schema.

.PARAMETER ResourceGroup
  Resource group containing the Log Analytics workspace and action group.

.PARAMETER WorkspaceName
  Name of the Log Analytics workspace. Alias: -LawName (backward compatible).

.PARAMETER WorkspaceResourceGroup
  Optional resource group containing the Log Analytics workspace. If not specified,
  ResourceGroup is used.

.PARAMETER Location
  Azure region for scheduled query rules.

.PARAMETER Severity
  Alert severity level (0=Critical, 1=Error, 2=Warning, 3=Informational, 4=Verbose).

.PARAMETER CsvPath
  Path for CSV export of created alerts.

.PARAMETER CreateOnly
  Controls behavior for existing alerts. Default: $true (existing alerts are skipped and unchanged).

.PARAMETER WhatIf
  Preview changes without creating or modifying alerts.

.EXAMPLE
  # Deploy alerts with webhook action group (after updating defaults in script)
  .\AVD-Category-Alerts.ps1 -DetailedResultsWebhookUrl "https://contoso.logic.azure.com/workflows/..."

.EXAMPLE
  # Specify subscription and resource group
  .\AVD-Category-Alerts.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012" `
    -ResourceGroup "rg-avd-prod" -WorkspaceName "law-avd-prod" -Location "eastus2" `
    -DetailedResultsWebhookUrl "https://contoso.logic.azure.com/workflows/..."

.EXAMPLE
  # Preview changes without creating alerts
  .\AVD-Category-Alerts.ps1 -Severity 0 -WhatIf

.EXAMPLE
  # Use existing pre-created action group (no webhook URL needed)
  .\AVD-Category-Alerts.ps1 -ResourceGroup "rg-avd-prod" -WorkspaceName "law-avd-prod" -Location "eastus2"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $false)]
  [ValidatePattern('^$|^https?://.+')]
  [string]$DetailedResultsWebhookUrl,

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$DetailedActionGroupName = "AVD-Alerts-Detailed",

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$DetailedWebhookReceiverName = "AVDAlertsDetailedWebhook",

  [Parameter(Mandatory = $false)]
  [bool]$UseCommonAlertSchemaForWebhook = $true,

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
  [ValidateRange(0, 4)]
  [int]$Severity = 1,

  [Parameter(Mandatory = $false)]
  [bool]$CreateOnly = $true,

  [Parameter(Mandatory = $false)]
  [string]$CsvPath,

  # G6: when set, every alert's KQL is dry-run via `az monitor log-analytics query`
  # before the scheduled-query rule is created. Failed queries are skipped instead of
  # producing a rule that will silently 0-row forever. Adds runtime cost and requires
  # 'Log Analytics Reader' on the workspace for the caller.
  [Parameter(Mandatory = $false)]
  [switch]$ValidateKql
)

$ErrorActionPreference = "Stop"

# Track execution time
$ScriptStartTime = Get-Date

# Load shared constants and helpers (G10). Loaded early so all downstream call sites
# (action-group creation, KQL builders) can reference $Script:Avd* values.
$commonPath = Join-Path -Path $PSScriptRoot -ChildPath 'AVD-AzAlerts-Common.ps1'
if (-not (Test-Path -Path $commonPath)) {
    throw "Required helper file not found: $commonPath"
}
. $commonPath

# ----------------------------
# Trace log (always-on diagnostic file with millisecond timestamps)
# ----------------------------
# B4(b): write trace log to a per-user private directory rather than the shared OS temp dir,
# so the workspace/subscription identifiers it contains are not exposed to other users on
# multi-tenant hosts (e.g. Cloud Shell containers).
$traceSubTag = if ($SubscriptionId) { $SubscriptionId.Substring(0,8) } else { 'nosub' }
$isWindowsHost = ($IsWindows) -or ($null -eq $IsWindows -and $env:OS -eq 'Windows_NT')
if ($isWindowsHost) {
    $traceDirRoot = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [System.IO.Path]::GetTempPath() }
    $traceDir = Join-Path -Path $traceDirRoot -ChildPath 'AVD-Trace'
} else {
    $traceDirRoot = if ($env:HOME) { $env:HOME } else { [System.IO.Path]::GetTempPath() }
    $traceDir = Join-Path -Path $traceDirRoot -ChildPath '.avd-trace'
}
if (-not (Test-Path -LiteralPath $traceDir)) {
    try { New-Item -ItemType Directory -Path $traceDir -Force | Out-Null } catch {
        # Fall back to OS temp if the preferred dir cannot be created (e.g. read-only HOME).
        $traceDir = [System.IO.Path]::GetTempPath()
    }
}
$script:TraceLogPath = Join-Path -Path $traceDir `
  -ChildPath ("avd-alerts-trace-{0}-{1}.log" -f $traceSubTag, (Get-Date -Format 'yyyyMMdd-HHmmss'))
function Write-Trace {
  param([string]$Message, [string]$Tag = 'INFO')
  $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Tag, $Message
  try { Add-Content -Path $script:TraceLogPath -Value $line -Encoding utf8 -ErrorAction SilentlyContinue } catch {}
}
Write-Host "[Trace] Diagnostic log: $script:TraceLogPath" -ForegroundColor DarkGray
Write-Trace "Script start. PSVersion=$($PSVersionTable.PSVersion) OS=$([System.Environment]::OSVersion.VersionString) User=$env:USER$env:USERNAME"

# Set CSV path default (include subscription ID if specified)
if (-not $CsvPath) {
  if ($SubscriptionId) {
    $CsvPath = ".\avd-alerts-report-$($SubscriptionId.Substring(0,8)).csv"
  } else {
    $CsvPath = ".\avd-alerts-report.csv"
  }
}

# ----------------------------
# Pre-flight Checks
# ----------------------------

# Check 1: Verify Azure CLI is installed
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw "Azure CLI not found. Please install from https://learn.microsoft.com/cli/azure/install-azure-cli"
}

# Check 1b: Verify required Azure CLI extension is available
Write-Host "[Pre-flight] Checking required Azure CLI extension: scheduled-query..." -ForegroundColor Cyan
az extension show --name scheduled-query -o none 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host "[Pre-flight] 'scheduled-query' extension not found. Installing..." -ForegroundColor Yellow
  az extension add --name scheduled-query --yes -o none 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw "Required Azure CLI extension 'scheduled-query' is not available and could not be installed."
  }
  Write-Host "[Pre-flight] 'scheduled-query' extension installed." -ForegroundColor Green
}

# Check 2: Verify Azure login
Write-Host "[Pre-flight] Checking Azure authentication..." -ForegroundColor Cyan
$accountInfo = az account show 2>$null | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $null -eq $accountInfo) {
  throw "Not logged in to Azure. Please run 'az login' first."
}
Write-Host "[Pre-flight] Logged in as: $($accountInfo.user.name)" -ForegroundColor Gray

# Check 3: Set subscription context if specified
if ($SubscriptionId) {
  Write-Host "[Pre-flight] Setting subscription context: $SubscriptionId" -ForegroundColor Cyan
  az account set --subscription $SubscriptionId 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to set subscription context to '$SubscriptionId'. Verify the subscription ID and your access."
  }
  # Refresh account info after setting subscription
  $accountInfo = az account show 2>$null | ConvertFrom-Json
}
Write-Host "[Pre-flight] Subscription: $($accountInfo.name) ($($accountInfo.id))" -ForegroundColor Gray

# Check 4: Validate placeholder parameters have been updated
$placeholderParams = @()
if ($ResourceGroup -eq "your-resource-group") { $placeholderParams += "ResourceGroup" }
if ($WorkspaceName -eq "your-log-analytics-workspace") { $placeholderParams += "WorkspaceName" }
if ($Location -eq "your-azure-region") { $placeholderParams += "Location" }

if ($placeholderParams.Count -gt 0) {
  $paramList = $placeholderParams -join ", "
  throw "Please update the following parameter(s) with actual values: $paramList`nYou can either edit the default values in the script or pass them as arguments."
}

# Check 5: Verify RBAC permissions
# Required operations:
#   - Microsoft.Insights/scheduledQueryRules/*        (create/update/list alerts)
#   - Microsoft.Insights/actionGroups/*               (create/update action group)
#   - Microsoft.OperationalInsights/workspaces/read   (resolve LAW resource ID)
#
# Roles that satisfy all of the above:
#   Fully sufficient  : Owner | Contributor
#   Partially sufficient (both needed together): Monitoring Contributor + Log Analytics Contributor/Reader
Write-Host "[Pre-flight] Checking RBAC permissions..." -ForegroundColor Cyan

$rgScope = "/subscriptions/$($accountInfo.id)/resourceGroups/$ResourceGroup"

# Determine the signed-in principal's object ID (works for user and service principal)
$principalId = az ad signed-in-user show --query id -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($principalId)) {
  # Fallback: service principal / managed identity path
  $principalId = $accountInfo.user.name
}

# Fetch all role assignments at RG scope (inherited from sub/MG included)
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "SilentlyContinue"
$roleAssignmentsJson = az role assignment list `
  --assignee $principalId `
  --scope $rgScope `
  --include-inherited `
  --include-groups `
  --output json 2>&1
$roleExitCode = $LASTEXITCODE
$ErrorActionPreference = $prevEAP

if ($roleExitCode -ne 0 -or [string]::IsNullOrWhiteSpace(($roleAssignmentsJson | Out-String))) {
  Write-Host "[Pre-flight] WARNING: Could not retrieve role assignments. Continuing, but ensure you have:" -ForegroundColor Yellow
  Write-Host "  - Microsoft.Insights/scheduledQueryRules/* on RG '$ResourceGroup'" -ForegroundColor Yellow
  Write-Host "  - Microsoft.Insights/actionGroups/* on RG '$ResourceGroup'" -ForegroundColor Yellow
  Write-Host "  - Microsoft.OperationalInsights/workspaces/read on RG '$ResourceGroup'" -ForegroundColor Yellow
} else {
  $roleAssignments = ($roleAssignmentsJson | Out-String) | ConvertFrom-Json
  $assignedRoleNames = $roleAssignments | Select-Object -ExpandProperty roleDefinitionName

  # Built-in role IDs for programmatic matching (display names can be localised)
  $fullyQualifiedRoleIds = @(
    '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'  # Owner
    'b24988ac-6180-42a0-ab88-20f7382dd24c'  # Contributor
  )
  $monitoringContributorId   = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
  $logAnalyticsContribId     = '92aaf0da-9dab-42b6-94a3-d43ce8d16293'
  $logAnalyticsReaderId      = '73c42c96-874c-492b-b04d-ab87d138a893'

  # Extract just the GUID portion from each roleDefinitionId
  $assignedRoleIds = $roleAssignments | ForEach-Object {
    ($_.roleDefinitionId -split '/')[-1]
  }

  $hasFullRole            = ($assignedRoleIds | Where-Object { $fullyQualifiedRoleIds -contains $_ }).Count -gt 0
  $hasMonitoringContrib   = $assignedRoleIds -contains $monitoringContributorId
  $hasLAWContribOrReader  = ($assignedRoleIds -contains $logAnalyticsContribId) -or
                             ($assignedRoleIds -contains $logAnalyticsReaderId)

  # ---- Evaluate coverage ----
  if ($hasFullRole) {
    $matchedRole = ($assignedRoleNames | Where-Object { $_ -in @('Owner','Contributor') } | Select-Object -First 1)
    Write-Host "[Pre-flight] RBAC OK - '$matchedRole' covers all required permissions." -ForegroundColor Green
  } elseif ($hasMonitoringContrib -and $hasLAWContribOrReader) {
    Write-Host "[Pre-flight] RBAC OK - 'Monitoring Contributor' + Log Analytics role cover all required permissions." -ForegroundColor Green
  } else {
    # Partial coverage - report exactly what is missing
    Write-Host "[Pre-flight] WARNING: Insufficient RBAC permissions detected." -ForegroundColor Yellow
    Write-Host ""  -ForegroundColor Yellow
    Write-Host "  Assigned roles on scope '$rgScope':" -ForegroundColor Yellow
    if ($assignedRoleNames.Count -gt 0) {
      $assignedRoleNames | ForEach-Object { Write-Host "    - $_" -ForegroundColor Gray }
    } else {
      Write-Host "    (none found)" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  Required permissions and recommended roles:" -ForegroundColor Yellow
    if (-not $hasMonitoringContrib) {
      Write-Host "  [MISSING] Microsoft.Insights/scheduledQueryRules/* and Microsoft.Insights/actionGroups/*" -ForegroundColor Red
      Write-Host "            -> Assign 'Monitoring Contributor' on RG '$ResourceGroup'" -ForegroundColor Red
    }
    if (-not $hasLAWContribOrReader) {
      Write-Host "  [MISSING] Microsoft.OperationalInsights/workspaces/read" -ForegroundColor Red
      Write-Host "            -> Assign 'Log Analytics Reader' on RG '$ResourceGroup'" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  Quick fix - run these Azure CLI commands:" -ForegroundColor Cyan
    Write-Host "    az role assignment create --assignee '$principalId' --role 'Monitoring Contributor' --scope '$rgScope'" -ForegroundColor Cyan
    Write-Host "    az role assignment create --assignee '$principalId' --role 'Log Analytics Reader'   --scope '$rgScope'" -ForegroundColor Cyan
    Write-Host ""
    throw "Insufficient RBAC permissions. Please assign the roles listed above and re-run the script."
  }
}

# Alert cadence
$EvalFrequency = "PT10M"  # every 10 minutes
$WindowSize    = "PT15M"  # evaluation window (15 minutes)

# Track created alerts for CSV export
$AlertResults = @()
$ExistingAlerts = @()
$NewlyCreatedAlerts = @()

# Performance optimization: Get all existing alerts once
# Run in a background job with a timeout so a slow or hanging API call does not block the script.
Write-Host "[Pre-flight] Checking for existing alerts (timeout: 25s)..." -ForegroundColor Cyan
$script:existingAlertNamesList = $null  # Default: fall back to individual checks
try {
  $_listJobRg    = $ResourceGroup
  $_listJobSubId = $accountInfo.id
  $listJob = Start-Job -ScriptBlock {
    az monitor scheduled-query list -g ${using:_listJobRg} --subscription ${using:_listJobSubId} --query "[?starts_with(name, 'AVD-')].name" -o tsv 2>$null
  }

  $completed = Wait-Job $listJob -Timeout 25

  if ($null -ne $completed) {
    $existingAlertsOutput = Receive-Job $listJob -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($existingAlertsOutput)) {
      $script:existingAlertNamesList = $existingAlertsOutput -split "[\r\n]+" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() }
      Write-Host "[Pre-flight] Found $($script:existingAlertNamesList.Count) existing AVD alert(s)" -ForegroundColor Gray
    } else {
      Write-Host "[Pre-flight] No existing AVD alerts found - all will be created" -ForegroundColor Gray
      $script:existingAlertNamesList = @()  # Empty list (not null) = confirmed zero alerts exist
    }
  } else {
    Stop-Job $listJob -ErrorAction SilentlyContinue
    Write-Host "[Pre-flight] Alert list query timed out - will check each alert individually" -ForegroundColor Yellow
    $script:existingAlertNamesList = $null  # Trigger individual API calls for each alert
  }
  Remove-Job $listJob -Force -ErrorAction SilentlyContinue
} catch {
  Write-Host "[Pre-flight] Could not query existing alerts - will check individually" -ForegroundColor Yellow
  $script:existingAlertNamesList = $null
}

# ----------------------------
# Helper Functions
# ----------------------------
function Write-Log {
  param($Message, $Color = "White")
  $timestamp = Get-Date -Format "HH:mm:ss"
  Write-Host "[$timestamp] $Message" -ForegroundColor $Color
  Write-Trace -Message $Message -Tag 'LOG'
}

function Test-AlertExists {
  param([string]$AlertName)

  # Priority 1: Pre-built definitive map (built in main scope - most reliable)
  if ($null -ne $script:alertExistenceMap -and $script:alertExistenceMap.ContainsKey($AlertName)) {
    return $script:alertExistenceMap[$AlertName]
  }

  # Priority 2: Bulk-query cache from pre-flight (fast string compare)
  if ($null -ne $script:existingAlertNamesList) {
    return ($script:existingAlertNamesList -contains $AlertName)
  }

  # Priority 3: Individual API query (fallback when both cache sources are unavailable)
  az monitor scheduled-query show -g $ResourceGroup -n $AlertName --subscription $accountInfo.id -o none 2>$null
  return ($LASTEXITCODE -eq 0)
}

function Test-LawTableAvailable {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceResourceId,

    [Parameter(Mandatory = $true)]
    [string]$TableName,

    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [int]$TimeoutSeconds = 30
  )

  $probeQuery = "$TableName | take 1"

  # Run the probe in a background job with a timeout to prevent hanging on slow API responses.
  try {
    $_probeWsId  = $WorkspaceResourceId
    $_probeQuery = $probeQuery
    $_probeSubId = $SubscriptionId
    $probeJob = Start-Job -ScriptBlock {
      $output = az monitor log-analytics query `
        --workspace ${using:_probeWsId} `
        --analytics-query ${using:_probeQuery} `
        --timespan "PT1H" `
        --subscription ${using:_probeSubId} `
        -o none 2>&1
      [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
    }

    $completed = Wait-Job $probeJob -Timeout $TimeoutSeconds

    if ($null -eq $completed) {
      Stop-Job $probeJob -ErrorAction SilentlyContinue
      Remove-Job $probeJob -Force -ErrorAction SilentlyContinue
      Write-Log "Warning: Table probe for '$TableName' timed out after ${TimeoutSeconds}s. Skipping preview alert." "Yellow"
      return $false
    }

    $result = Receive-Job $probeJob -ErrorAction SilentlyContinue
    Remove-Job $probeJob -Force -ErrorAction SilentlyContinue

    if ($null -eq $result) {
      Write-Log "Warning: Could not verify table '$TableName'. Skipping preview alert." "Yellow"
      return $false
    }

    if ($result.ExitCode -eq 0) {
      return $true
    }

    $probeError = $result.Output
    if ($probeError -match "Failed to resolve table or column expression named|Semantic error") {
      return $false
    }

    # Conservative behavior: if probe fails for unknown reasons, skip preview alert to avoid hard failure.
    Write-Log "Warning: Could not verify table '$TableName'. Skipping preview alert. Details: $probeError" "Yellow"
    return $false
  } catch {
    Write-Log "Warning: Table probe for '$TableName' failed: $($_.Exception.Message). Skipping preview alert." "Yellow"
    return $false
  }
}

# ----------------------------
# Resolve Log Analytics Workspace Resource ID
# ----------------------------
Write-Log "Resolving Log Analytics Workspace: $WorkspaceName" "Cyan"

$ResolvedWorkspaceResourceGroup = if ([string]::IsNullOrWhiteSpace($WorkspaceResourceGroupName)) {
  $ResourceGroup
} else {
  $WorkspaceResourceGroupName
}

$LawId = az monitor log-analytics workspace show `
  -g $ResolvedWorkspaceResourceGroup `
  -n $WorkspaceName `
  --subscription $accountInfo.id `
  --query id -o tsv 2>$null

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($LawId)) {
  throw "Could not resolve Log Analytics workspace id for '$WorkspaceName' in RG '$ResolvedWorkspaceResourceGroup'."
}

Write-Log "Log Analytics Workspace ID: $LawId" "Gray"

# ----------------------------
# Create / ensure Webhook Action Group
# ----------------------------
$DetailedAgId = $null
Write-Log "Detailed Webhook URL: $DetailedResultsWebhookUrl" "Cyan"
  Write-Log "Detailed Action Group: $DetailedActionGroupName" "Cyan"

  if ($PSCmdlet.ShouldProcess($DetailedActionGroupName, "Create or update detailed webhook action group")) {
    $detailedAgJson = az monitor action-group show -g $ResourceGroup -n $DetailedActionGroupName --subscription $accountInfo.id -o json 2>$null
    $detailedAgExists = ($LASTEXITCODE -eq 0)

    if (-not $detailedAgExists) {
      if ([string]::IsNullOrWhiteSpace($DetailedResultsWebhookUrl)) {
        throw "Detailed action group '$DetailedActionGroupName' was not found and -DetailedResultsWebhookUrl was not provided. Provide a webhook URL or pre-create the detailed action group."
      }
      Write-Log "Detailed action group '$DetailedActionGroupName' not found - creating..." "Yellow"
      $createArgs = @(
        'monitor', 'action-group', 'create',
        '-g', $ResourceGroup, '-n', $DetailedActionGroupName,
        '--subscription', $accountInfo.id,
        '--short-name', $Script:AvdActionGroupShortName,
        '--action', 'webhook', $DetailedWebhookReceiverName, ('"' + $DetailedResultsWebhookUrl + '"')
      )
      if ($UseCommonAlertSchemaForWebhook) {
        $createArgs += 'usecommonalertschema'
      }
      $detailedAgCreateOutput = az @createArgs 2>&1
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to create detailed webhook action group: $detailedAgCreateOutput"
      }
      Write-Log "Detailed action group '$DetailedActionGroupName' created." "Green"
      $detailedAgJson = az monitor action-group show -g $ResourceGroup -n $DetailedActionGroupName --subscription $accountInfo.id -o json 2>$null
    } else {
      Write-Log "Detailed action group '$DetailedActionGroupName' already exists - validating webhook receiver..." "Gray"
      $detailedAg = $detailedAgJson | ConvertFrom-Json
      $webhookReceivers = @($detailedAg.webhookReceivers)
      $receiverByName = $webhookReceivers | Where-Object { $_.name -eq $DetailedWebhookReceiverName } | Select-Object -First 1
      $receiverWithUrl = $webhookReceivers | Where-Object { $_.serviceUri -eq $DetailedResultsWebhookUrl } | Select-Object -First 1

      if ([string]::IsNullOrWhiteSpace($DetailedResultsWebhookUrl)) {
        Write-Log "Detailed webhook URL not provided - using existing detailed action group as-is." "Gray"
      }

      # Self-heal: remove legacy receiver name to prevent duplicate webhook notifications.
      $legacyDetailedWebhookReceiverName = 'AVDAlertDetails'
      if ($DetailedWebhookReceiverName -ne $legacyDetailedWebhookReceiverName) {
        $legacyReceiver = $webhookReceivers | Where-Object { $_.name -eq $legacyDetailedWebhookReceiverName } | Select-Object -First 1
        if ($null -ne $legacyReceiver) {
          Write-Log "Legacy detailed webhook receiver '$legacyDetailedWebhookReceiverName' found - removing to avoid duplicates." "Yellow"
          az monitor action-group update -g $ResourceGroup -n $DetailedActionGroupName --subscription $accountInfo.id --remove-action $legacyDetailedWebhookReceiverName 2>&1 | Out-Null
        }
      }

      if (-not [string]::IsNullOrWhiteSpace($DetailedResultsWebhookUrl) -and $null -eq $receiverWithUrl) {
        if ($null -ne $receiverByName) {
          Write-Log "Webhook receiver name exists with different URL - replacing receiver '$DetailedWebhookReceiverName'." "Yellow"
          az monitor action-group update -g $ResourceGroup -n $DetailedActionGroupName --subscription $accountInfo.id --remove-action $DetailedWebhookReceiverName 2>&1 | Out-Null
        }

        $updateArgs = @(
          'monitor', 'action-group', 'update',
          '-g', $ResourceGroup, '-n', $DetailedActionGroupName,
          '--subscription', $accountInfo.id,
          '--add-action', 'webhook', $DetailedWebhookReceiverName, ('"' + $DetailedResultsWebhookUrl + '"')
        )
        if ($UseCommonAlertSchemaForWebhook) {
          $updateArgs += 'usecommonalertschema'
        }
        $detailedAgUpdateOutput = az @updateArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
          Write-Log "Warning: Failed to add/update webhook receiver: $detailedAgUpdateOutput" "Yellow"
        } else {
          Write-Log "Webhook receiver ensured on '$DetailedActionGroupName'." "Green"
        }
      } else {
        Write-Log "Webhook URL already present on detailed action group - no change needed." "Gray"
      }
    }

    $DetailedAgId = az monitor action-group show `
      -g $ResourceGroup `
      -n $DetailedActionGroupName `
      --subscription $accountInfo.id `
      --query id -o tsv 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($DetailedAgId)) {
      throw "Failed to retrieve detailed action group ID"
    }

    Write-Log "Detailed Action Group ID: $DetailedAgId" "Gray"
  } else {
    Write-Log "[WhatIf] Would create/update detailed action group: $DetailedActionGroupName" "Yellow"
    $subId = $accountInfo.id
    $DetailedAgId = "/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/microsoft.insights/actionGroups/$DetailedActionGroupName"
    Write-Log "Detailed Action Group ID (simulated): $DetailedAgId" "Gray"
  }

if ([string]::IsNullOrWhiteSpace($DetailedAgId)) {
  throw "A valid detailed action group is required. Provide -DetailedResultsWebhookUrl or pre-create '$DetailedActionGroupName'."
}
$ActionGroupIds = @($DetailedAgId)
Write-Log "Using detailed webhook action group routing." "Cyan"

# ----------------------------
# Helper: create scheduled query alert only (skip if exists)
# ----------------------------
function New-AvdScheduledQueryAlert {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)][string]$AlertName,
    [Parameter(Mandatory)][string]$Kql,
    [Parameter(Mandatory)][string]$Description
  )

  # B7: source severity label from the shared helper to avoid drift across scripts.
  $severityText = Get-AvdSeverityText -Severity $Severity

  # Check if alert already exists
  $alertExists = Test-AlertExists -AlertName $AlertName
  
  if ($alertExists) {
    $script:ExistingAlerts += $AlertName
  }

  if ($alertExists -and $CreateOnly) {
    Write-Log "Create-only mode: skipping existing alert: $AlertName" "Gray"
    $status = "Skipped"
    $action  = "Skipped"
  } elseif ($PSCmdlet.ShouldProcess($AlertName, "Create scheduled query alert")) {    # G6: optional KQL dry-run before rule creation.
    if ($ValidateKql) {
      $validateQuery = $Kql -replace "`r", "" -replace "`n", " "
      Write-Trace "Validating KQL for $AlertName via az monitor log-analytics query" 'VALIDATE'
      $prevEAP = $ErrorActionPreference
      $ErrorActionPreference = "SilentlyContinue"
      $validateOutput = az monitor log-analytics query `
        --workspace $LawId `
        --analytics-query $validateQuery `
        --timespan "PT15M" `
        --subscription $accountInfo.id `
        -o none 2>&1
      $validateExit = $LASTEXITCODE
      $ErrorActionPreference = $prevEAP
      if ($validateExit -ne 0) {
        Write-Log "  [SKIP] KQL validation failed for $AlertName; not creating rule. Output: $($validateOutput | Out-String)" "Yellow"
        $script:AlertResults += [pscustomobject]@{
          AlertName   = $AlertName
          Description = $Description
          Severity    = "$Severity ($severityText)"
          Action      = "Skipped"
          Status      = "KqlValidationFailed"
        }
        return
      }
    }
    Write-Log "Creating new alert: $AlertName (Severity: $severityText)" "Cyan"

    try {
      # Convert multi-line query to single line for Azure CLI
      $queryEscaped = $Kql -replace "`r", "" -replace "`n", " "
      
      $azCmdArgs = @(
        'monitor', 'scheduled-query', 'create',
        '-g', $ResourceGroup, '-n', $AlertName, '-l', $Location,
        '--subscription', $accountInfo.id, '--scopes', $LawId,
        '--evaluation-frequency', $EvalFrequency, '--window-size', $WindowSize,
        '--severity', "$Severity", '--description', $Description,
        '--condition', "count 'Query1' > 0", '--condition-query', "Query1=$queryEscaped"
      )
      $azCmdArgs += '--action-groups'
      $azCmdArgs += $ActionGroupIds
      $prevEAP = $ErrorActionPreference
      $ErrorActionPreference = "SilentlyContinue"
      $output = az @azCmdArgs 2>&1
      $azExitCode = $LASTEXITCODE
      $ErrorActionPreference = $prevEAP
      
      if ($azExitCode -eq 0) {
        Write-Log "  [OK] Success" "Green"
        $status = "Success"
        $action  = "Created"
        $script:NewlyCreatedAlerts += $AlertName
      } else {
        $errStr = ($output | Out-String).ToLower()
        if ($errStr -match "conflict|already exists") {
          Write-Log "  ~ Already exists (skipped)" "Gray"
          $status = "Skipped"
          $action  = "Skipped"
          $script:ExistingAlerts += $AlertName
        } else {
          Write-Log "  [FAIL] Failed: $output" "Red"
          $status = "Failed"
          $action  = "Failed"
        }
      }
    }
    catch {
      Write-Log "  [FAIL] Error: $($_.Exception.Message)" "Red"
      $status = "Error"
      $action  = "Error"
    }
  } else {
    Write-Log "[WhatIf] Would create alert: $AlertName" "Yellow"
    $status = "WhatIf"
    $action  = "WouldCreate"
  }

  # Track for CSV export
  $script:AlertResults += [pscustomobject]@{
    AlertName   = $AlertName
    Description = $Description
    Severity    = "$Severity ($severityText)"
    Action      = $action
    Status      = $status
  }
}

# ----------------------------
# Alerts
# ----------------------------
Write-Log "" 
Write-Log "Processing AVD Alerts..." "Cyan"
Write-Log "" 

# Start timer for WhatIf status reporting
$alertProcessingStart = Get-Date
$lastStatusReport = $alertProcessingStart

# ----------------------------
# Client / connection enrichment fragments (shared across user-facing alert KQL)
# ----------------------------
# Common module is dot-sourced near the top of the script (G10).
$MinSupportedClientVersion = $Script:AvdMinSupportedClientVersion

# KQL `let` block, single-line form for embedding in scheduled-query rule bodies.
# Uses ago(15m) instead of {0}/{1} placeholders.
$ConnEnrichmentLet = (Get-AvdConnEnrichmentLet -UseAgo15m) -replace "`r?`n", ' '

# Tail used by all WVDErrors-based alerts to enrich rows with client/gateway/geo context.
# B1 fix: cast CorrelationId to string on the WVDErrors side.
$ErrorEnrichTail = "| extend CorrelationId = tostring(column_ifexists('CorrelationId', '')) | lookup kind=leftouter ConnEnrichment on CorrelationId | project UserName, Source, CodeSymbolic, Message, Operation, HostPool, ClientIPAddress, GatewayRegion, ClientCity, ClientState, ClientCountry, ClientOS, ClientType, ClientVersion"

# Alert definitions
$alertDefinitions = @(
  @{ Name = "AVD-Category-AuthenticationIdentity"; Description = "Consolidated authentication and identity failures in AVD."; Kql = "$ConnEnrichmentLet WVDErrors`n| where TimeGenerated > ago(15m)`n| where CodeSymbolic in ('PasswordMustChange', 'PasswordExpired', 'InvalidAuthToken', 'InvalidCredentials', 'AccountLockedOut', 'AccountDisabled', 'LogonFailed', 'AuthenticationLogonFailed', 'NoAuthenticatingAuthority', 'LocalSecurityAuthorityError')`n| extend HostPool = tostring(split(_ResourceId, '/')[-1])`n$ErrorEnrichTail" },
  @{ Name = "AVD-Category-AuthorizationPolicy"; Description = "Consolidated authorization and logon rights failures in AVD."; Kql = "$ConnEnrichmentLet WVDErrors`n| where TimeGenerated > ago(15m)`n| where CodeSymbolic in ('ConnectionFailedUserNotAuthorized', 'LogonTypeNotGranted', 'NotAuthorizedForLogon')`n| extend HostPool = tostring(split(_ResourceId, '/')[-1])`n$ErrorEnrichTail" },
  @{ Name = "AVD-Category-ConnectionNetworkGateway"; Description = "Consolidated AVD client, DNS, reverse connect, and gateway transport failures."; Kql = "$ConnEnrichmentLet WVDErrors`n| where TimeGenerated > ago(15m)`n| where CodeSymbolic in ('Client', 'DnsLookupFailed', 'GatewayServerNotFound', 'ReverseConnectDnsLookupFailed', 'ConnectionFailedClientConnectedTooLateReverseConnectionAlreadyClosed')`n| extend HostPool = tostring(split(_ResourceId, '/')[-1])`n$ErrorEnrichTail" },
  @{ Name = "AVD-Category-SessionHostHealthCapacity"; Description = "Consolidated session host availability and capacity issues."; Kql = "$ConnEnrichmentLet WVDErrors`n| where TimeGenerated > ago(15m)`n| where CodeSymbolic in ('ConnectionFailedNoHealthyRdshAvailable', 'SessionHostResourceNotAvailable', 'OutOfMemory')`n| extend HostPool = tostring(split(_ResourceId, '/')[-1])`n$ErrorEnrichTail" },
  @{ Name = "AVD-Category-PersonalDesktopAssignment"; Description = "Consolidated personal desktop assignment and startup failures."; Kql = "$ConnEnrichmentLet WVDErrors`n| where TimeGenerated > ago(15m)`n| where CodeSymbolic in ('ConnectionFailedPersonalDesktopFailedToBeStarted', 'ConnectionFailedNoPreAssignedPersonalDesktopForUser')`n| extend HostPool = tostring(split(_ResourceId, '/')[-1])`n$ErrorEnrichTail" },
  @{ Name = "AVD-Category-DeviceGraphicsInput"; Description = "Consolidated input and graphics subsystem failures."; Kql = "$ConnEnrichmentLet WVDErrors`n| where TimeGenerated > ago(15m)`n| where CodeSymbolic in ('GetInputDeviceHandlesError', 'GraphicsCapsNotReceived', 'GraphicsSubsystemFailed', 'DWMProcessAccessFailure')`n| extend HostPool = tostring(split(_ResourceId, '/')[-1])`n$ErrorEnrichTail" },
  @{ Name = "AVD-Category-FSLogixProfileStorage"; Description = "Consolidated FSLogix profile and storage attach/detach/access issues."; Kql = "$ConnEnrichmentLet WVDErrors`n| where TimeGenerated > ago(15m)`n| where CodeSymbolic in ('ERROR_SHARING_VIOLATION', 'UnloadWaitingForUserAction', 'ERROR_ACCESS_DENIED', 'ERROR_PATH_NOT_FOUND', 'ERROR_FILE_NOT_FOUND', 'ERROR_BAD_NETPATH', 'ERROR_BAD_NET_NAME', 'ERROR_NETNAME_DELETED', 'ERROR_DISK_FULL', 'ERROR_LOCK_VIOLATION') or Source has 'fslogix' or Message has_any ('frxsvc', 'frxshell', 'temporary profile', 'default profile', 'profile failed', 'vhd attach', 'vhdx attach', 'container attach', 'container detach', 'odfc')`n| extend HostPool = tostring(split(_ResourceId, '/')[-1])`n$ErrorEnrichTail" },
  @{ Name = "AVD-Category-UnknownUnclassified"; Description = "Consolidated unknown or unclassified AVD error symbols for triage."; Kql = "$ConnEnrichmentLet WVDErrors`n| where TimeGenerated > ago(15m)`n| where CodeSymbolic == 'Unknown CodeSymbolic - review Message for details.'`n| extend HostPool = tostring(split(_ResourceId, '/')[-1])`n$ErrorEnrichTail" },
  # --- WVD Diagnostic Log alerts (require host pool diagnostic settings) ---
  @{ Name = "AVD-Category-ConnectionFailureRate"; Description = "Spike in failed connections per host pool from WVDConnections."; Kql = "let MinSupportedClient = '$MinSupportedClientVersion'; WVDConnections`n| where TimeGenerated > ago(15m)`n| where State == 'Failed'`n| extend HostPool = tostring(split(_ResourceId, '/')[-1])`n| extend Geo = geo_info_from_ip_address(ClientIPAddress)`n| extend ClientCity = tostring(Geo.city), ClientState = tostring(Geo.state), ClientCountry = tostring(Geo.country)`n| extend ClientVersionDisplay = case(isempty(ClientVersion), '(unknown)', isnull(parse_version(ClientVersion)), ClientVersion, parse_version(ClientVersion) < parse_version(MinSupportedClient), strcat(ClientVersion, ' (outdated)'), ClientVersion)`n| summarize FailedCount = count(), ClientIPAddress = any(ClientIPAddress), GatewayRegion = any(GatewayRegion), ClientCity = any(ClientCity), ClientState = any(ClientState), ClientCountry = any(ClientCountry), ClientOS = any(ClientOS), ClientType = any(ClientType), ClientVersion = any(ClientVersionDisplay) by HostPool, UserName`n| where FailedCount > 5`n| project HostPool, UserName, FailedCount, ClientIPAddress, GatewayRegion, ClientCity, ClientState, ClientCountry, ClientOS, ClientType, ClientVersion" },
  @{ Name = "AVD-Category-DisconnectionSpike"; Description = "Abnormal disconnection rate across session hosts indicating infrastructure or network instability."; Kql = "let MinSupportedClient = '$MinSupportedClientVersion'; WVDConnections`n| where TimeGenerated > ago(15m)`n| where State == 'Completed'`n| where column_ifexists('ConnectionType', '') == 'Disconnected' or column_ifexists('IsReconnect', false) == true`n| extend HostPool = tostring(split(_ResourceId, '/')[-1])`n| extend Geo = geo_info_from_ip_address(ClientIPAddress)`n| extend ClientCity = tostring(Geo.city), ClientState = tostring(Geo.state), ClientCountry = tostring(Geo.country)`n| extend ClientVersionDisplay = case(isempty(ClientVersion), '(unknown)', isnull(parse_version(ClientVersion)), ClientVersion, parse_version(ClientVersion) < parse_version(MinSupportedClient), strcat(ClientVersion, ' (outdated)'), ClientVersion)`n| summarize DisconnectCount = count(), UserName = any(UserName), ClientIPAddress = any(ClientIPAddress), GatewayRegion = any(GatewayRegion), ClientCity = any(ClientCity), ClientState = any(ClientState), ClientCountry = any(ClientCountry), ClientOS = any(ClientOS), ClientType = any(ClientType), ClientVersion = any(ClientVersionDisplay) by HostPool, SessionHostName`n| where DisconnectCount > 10`n| project HostPool, SessionHostName, DisconnectCount, UserName, ClientIPAddress, GatewayRegion, ClientCity, ClientState, ClientCountry, ClientOS, ClientType, ClientVersion" },
  @{ Name = "AVD-Category-UnhealthyHosts"; Description = "Session hosts reporting non-Available status from WVDAgentHealthStatus."; Kql = "WVDAgentHealthStatus`n| where TimeGenerated > ago(15m)`n| summarize arg_max(TimeGenerated, *) by SessionHostName`n| where Status != 'Available'`n| extend HostPool = tostring(split(_ResourceId, '/')[-1])`n| project HostPool, SessionHostName, Status, LastHeartBeat = TimeGenerated" },
  @{ Name = "AVD-Category-StaleHeartbeat"; Description = "Session hosts with stale agent heartbeat indicating communication failure or zombie hosts."; Kql = "WVDAgentHealthStatus`n| where TimeGenerated > ago(15m)`n| summarize arg_max(TimeGenerated, *) by SessionHostName`n| where TimeGenerated < ago(5m)`n| extend HostPool = tostring(split(_ResourceId, '/')[-1])`n| extend StaleSinceMin = datetime_diff('minute', now(), TimeGenerated)`n| project HostPool, SessionHostName, Status, StaleSinceMin" },
  @{ Name = "AVD-Category-BandwidthDrop"; Description = "Per-connection estimated bandwidth drops below threshold from WVDConnectionNetworkData."; Kql = "$ConnEnrichmentLet WVDConnectionNetworkData`n| where TimeGenerated > ago(15m)`n| summarize P10BW = percentile(EstAvailableBandwidthKBps, 10) by CorrelationId`n| where P10BW < 500`n| join kind=inner (WVDConnections | where TimeGenerated > ago(15m) | project CorrelationId, UserName, _ResourceId) on CorrelationId`n| extend HostPool = tostring(split(_ResourceId, '/')[-1])`n| lookup kind=leftouter ConnEnrichment on CorrelationId`n| project HostPool, UserName, SessionHostName = ClientSessionHost, P10BW_KBps = round(P10BW, 0), ClientIPAddress, GatewayRegion, ClientCity, ClientState, ClientCountry, ClientOS, ClientType, ClientVersion" },
  @{ Name = "AVD-Category-RTTPerUser"; Description = "Per-user P95 round-trip time exceeds threshold from WVDConnectionNetworkData."; Kql = "$ConnEnrichmentLet WVDConnectionNetworkData`n| where TimeGenerated > ago(15m)`n| summarize P95RTT = percentile(EstRoundTripTimeInMs, 95) by CorrelationId`n| where P95RTT > 200`n| join kind=inner (WVDConnections | where TimeGenerated > ago(15m) | project CorrelationId, UserName, _ResourceId) on CorrelationId`n| extend HostPool = tostring(split(_ResourceId, '/')[-1])`n| lookup kind=leftouter ConnEnrichment on CorrelationId`n| project HostPool, UserName, SessionHostName = ClientSessionHost, P95RTT_ms = round(P95RTT, 0), ClientIPAddress, GatewayRegion, ClientCity, ClientState, ClientCountry, ClientOS, ClientType, ClientVersion" },
  @{ Name = "AVD-Category-SignInPhaseDelay"; Description = "Prolonged sign-in phases detected from WVDCheckpoints (profile load, GPO, shell start)."; Kql = "$ConnEnrichmentLet WVDCheckpoints`n| where TimeGenerated > ago(15m)`n| where Source == 'WVDConnections'`n| where Name in ('OnConnected', 'ShellReady', 'LoadProfile', 'ApplyGroupPolicy')`n| extend HostPool = tostring(split(_ResourceId, '/')[-1])`n| extend DurationSec = datetime_diff('second', TimeGenerated, todatetime(tostring(Parameters.StartTime)))`n| where DurationSec > 15`n| extend CorrelationId = tostring(column_ifexists('CorrelationId', ''))`n| lookup kind=leftouter ConnEnrichment on CorrelationId`n| project HostPool, UserName, Name, DurationSec, SessionHostName = coalesce(tostring(Parameters.SessionHostName), ClientSessionHost), ClientIPAddress, GatewayRegion, ClientCity, ClientState, ClientCountry, ClientOS, ClientType, ClientVersion" },
  @{ Name = "AVD-Category-FrameQualityDegradation"; Description = "[Preview] End-to-end frame delay or dropped frames exceeding threshold from ConnectionGraphicsData."; Kql = "$ConnEnrichmentLet ConnectionGraphicsData`n| where TimeGenerated > ago(15m)`n| summarize AvgFrameDelay = avg(EstEndToEndDelayInMs), DropPct = avg(FramesSkippedPercentage) by CorrelationId`n| where AvgFrameDelay > 300 or DropPct > 15`n| join kind=inner (WVDConnections | where TimeGenerated > ago(15m) | project CorrelationId, UserName, _ResourceId) on CorrelationId`n| extend HostPool = tostring(split(_ResourceId, '/')[-1])`n| lookup kind=leftouter ConnEnrichment on CorrelationId`n| project HostPool, UserName, SessionHostName = ClientSessionHost, AvgFrameDelay_ms = round(AvgFrameDelay, 0), DroppedFramesPct = round(DropPct, 1), ClientIPAddress, GatewayRegion, ClientCity, ClientState, ClientCountry, ClientOS, ClientType, ClientVersion" }
)

# ConnectionGraphicsData is preview and may not exist in every workspace.
# Skip this single alert gracefully so core deployment can still complete.
$frameQualityAlertName = "AVD-Category-FrameQualityDegradation"
Write-Trace "About to probe LAW table 'ConnectionGraphicsData' on workspace '$LawId' (subscription=$($accountInfo.id))" 'PROBE'
$probeStart = Get-Date
$hasConnectionGraphicsData = Test-LawTableAvailable -WorkspaceResourceId $LawId -TableName "ConnectionGraphicsData" -SubscriptionId $accountInfo.id
Write-Trace ("LAW table probe finished. Result={0}, Elapsed={1:N1}s" -f $hasConnectionGraphicsData, ((Get-Date) - $probeStart).TotalSeconds) 'PROBE'
if (-not $hasConnectionGraphicsData) {
  Write-Log "ConnectionGraphicsData table not found in workspace '$WorkspaceName'. Skipping preview alert '$frameQualityAlertName'." "Yellow"
  $alertDefinitions = @($alertDefinitions | Where-Object { $_.Name -ne $frameQualityAlertName })

  $script:AlertResults += [pscustomobject]@{
    AlertName   = $frameQualityAlertName
    Description = "[Preview] End-to-end frame delay or dropped frames exceeding threshold from ConnectionGraphicsData."
    # A1: $severityText is function-local in New-AvdScheduledQueryAlert; here in script
    # scope use the shared helper directly to avoid emitting an empty parenthesis.
    Severity    = "$Severity ($(Get-AvdSeverityText -Severity $Severity))"
    Action      = "Skipped"
    Status      = "Skipped"
  }
}

# Build a definitive per-alert existence map in the main scope before any parallelism.
# This is the authoritative source - built with reliable $LASTEXITCODE using Test-AlertExists,
# which itself uses the bulk-query cache or individual API calls as needed.
$script:alertExistenceMap = @{}
Write-Log "Verifying existence of all $($alertDefinitions.Count) alerts..." "Cyan"
Write-Trace "BEGIN existence verification loop. Count=$($alertDefinitions.Count) RG=$ResourceGroup Sub=$($accountInfo.id)" 'VERIFY'
foreach ($alertDef in $alertDefinitions) {
  Write-Trace "Checking alert '$($alertDef.Name)'" 'VERIFY'
  $tCheck = Get-Date
  $script:alertExistenceMap[$alertDef.Name] = Test-AlertExists -AlertName $alertDef.Name
  Write-Trace ("Checked '{0}' Exists={1} Elapsed={2:N1}s" -f $alertDef.Name, $script:alertExistenceMap[$alertDef.Name], ((Get-Date) - $tCheck).TotalSeconds) 'VERIFY'
}
Write-Trace "END existence verification loop." 'VERIFY'
$existingCount = ($script:alertExistenceMap.Values | Where-Object { $_ -eq $true }).Count
$newCount = $alertDefinitions.Count - $existingCount
Write-Log "Verification complete: $existingCount alert(s) already exist, $newCount will be created." "Gray"
Write-Log "" 

# If detailed webhook mode is enabled, ensure existing alerts also include the configured action groups.
# This prevents drift where alerts created earlier have a different action group attached.
if (-not [string]::IsNullOrWhiteSpace($DetailedAgId) -and $existingCount -gt 0) {
  Write-Log "Ensuring existing alerts include the configured webhook action group..." "Cyan"
  Write-Trace "BEGIN action-group sync loop for $existingCount existing alert(s)." 'AGSYNC'
  foreach ($alertDef in $alertDefinitions) {
    if (-not $script:alertExistenceMap[$alertDef.Name]) {
      continue
    }

    if (-not $PSCmdlet.ShouldProcess($alertDef.Name, "Ensure action groups on existing scheduled query alert")) {
      Write-Log "[WhatIf] Would ensure action groups for existing alert: $($alertDef.Name)" "Yellow"
      continue
    }

    Write-Trace "AGSYNC.show '$($alertDef.Name)'" 'AGSYNC'
    $tAg = Get-Date
    $currentAgOutput = az monitor scheduled-query show `
      -g $ResourceGroup `
      -n $alertDef.Name `
      --subscription $accountInfo.id `
      --query "actions.actionGroups[].actionGroupId" -o tsv 2>$null
    Write-Trace ("AGSYNC.show '{0}' Elapsed={1:N1}s" -f $alertDef.Name, ((Get-Date) - $tAg).TotalSeconds) 'AGSYNC'

    $currentActionGroupIds = @()
    if (-not [string]::IsNullOrWhiteSpace($currentAgOutput)) {
      $currentActionGroupIds = $currentAgOutput -split "[\r\n]+" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim().ToLowerInvariant() }
    }

    $desiredActionGroupIds = $ActionGroupIds | ForEach-Object { $_.ToLowerInvariant() }
    $missingActionGroupIds = $desiredActionGroupIds | Where-Object { $currentActionGroupIds -notcontains $_ }

    if ($missingActionGroupIds.Count -eq 0) {
      Write-Log "Action groups already correct on existing alert: $($alertDef.Name)" "Gray"
      continue
    }

    $updateArgs = @(
      'monitor', 'scheduled-query', 'update',
      '-g', $ResourceGroup,
      '-n', $alertDef.Name,
      '--subscription', $accountInfo.id,
      '--action-groups'
    )
    $updateArgs += $ActionGroupIds

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $updateOutput = az @updateArgs 2>&1
    $updateExitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    if ($updateExitCode -eq 0) {
      Write-Log "Updated action groups on existing alert: $($alertDef.Name)" "Green"
    } else {
      Write-Log "Warning: Failed to update action groups on '$($alertDef.Name)': $updateOutput" "Yellow"
    }
  }
  Write-Log "" 
}

# Alert processing (sequential for deterministic and parser-safe behavior)
Write-Log "Using sequential processing" "Cyan"

$alertCount = 0
foreach ($alert in $alertDefinitions) {
  $alertCount++
  $percentComplete = [Math]::Round(($alertCount / $alertDefinitions.Count) * 100)
  $progressStatus = ('Processing alert {0} of {1}: {2}' -f $alertCount, $alertDefinitions.Count, $alert.Name)
  Write-Progress -Activity 'Creating AVD Alerts (create-only)' -Status $progressStatus -PercentComplete $percentComplete
  Write-Log ('[{0}/{1}] {2}' -f $alertCount, $alertDefinitions.Count, $alert.Name) "Cyan"

  # Status report for WhatIf mode if running longer than 30 seconds
  if ($PSBoundParameters.ContainsKey('WhatIf')) {
    $elapsed = (Get-Date) - $alertProcessingStart
    $timeSinceLastReport = (Get-Date) - $lastStatusReport

    if ($elapsed.TotalSeconds -ge 30 -and $timeSinceLastReport.TotalSeconds -ge 30) {
      Write-Log ""
      Write-Log "=== WhatIf Status Report ===" "Yellow"
      Write-Log "Elapsed Time: $([Math]::Round($elapsed.TotalSeconds, 1))s" "Yellow"
      $whatIfProgress = ('Progress: {0} of {1} alerts processed ({2} percent)' -f $alertCount, $alertDefinitions.Count, $percentComplete)
      Write-Log $whatIfProgress "Yellow"
      Write-Log "Current: $($alert.Name)" "Yellow"
      Write-Log ""
      $lastStatusReport = Get-Date
    }
  }

  if ($alert.ContainsKey('Kql')) {
    $kql = $alert.Kql
  }
  else {
    $kql = "WVDErrors`n| where TimeGenerated > ago(15m)`n| where CodeSymbolic == '$($alert.CodeSymbolic)'`n| extend HostPool = tostring(split(_ResourceId, '/')[-1])`n| project UserName, Source, CodeSymbolic, Message, Operation, HostPool"
  }

  New-AvdScheduledQueryAlert -AlertName $alert.Name -Description $alert.Description -Kql $kql
}

Write-Progress -Activity 'Creating AVD Alerts (create-only)' -Completed

# ----------------------------
# Export Results to CSV
# ----------------------------
if ($AlertResults.Count -gt 0) {
  try {
    # Validate CSV path
    $csvDirectory = Split-Path $CsvPath -Parent
    if ($csvDirectory -and -not (Test-Path $csvDirectory)) {
      New-Item -ItemType Directory -Path $csvDirectory -Force | Out-Null
    }
    
    $AlertResults | Export-Csv -NoTypeInformation -Path $CsvPath -Force -ErrorAction Stop
    Write-Log "" 
    Write-Log "Results exported to: $CsvPath" "Green"
  }
  catch {
    Write-Log "Warning: Failed to export results to CSV: $($_.Exception.Message)" "Yellow"
    Write-Log "CSV Path attempted: $CsvPath" "Gray"
  }
}

# ----------------------------
# Summary
# ----------------------------
Write-Log "" 
Write-Log "=== Summary ===" "Cyan"
Write-Log "Action Group: $DetailedActionGroupName" "White"
if (-not [string]::IsNullOrWhiteSpace($DetailedResultsWebhookUrl)) {
  Write-Log "Webhook URL: configured" "White"
} else {
  Write-Log "Webhook URL: using existing action group" "White"
}
Write-Log "Total Alerts Processed: $($AlertResults.Count)" "White"
Write-Log "" 

$failedCount = ($AlertResults | Where-Object Status -eq "Failed").Count
$whatIfCount = ($AlertResults | Where-Object Status -eq "WhatIf").Count

if ($whatIfCount -gt 0) {
  $whatIfSummary = ('WhatIf Mode: {0} alert(s) would be created; {1} would be skipped (already exist)' -f $whatIfCount, $ExistingAlerts.Count)
  Write-Log $whatIfSummary "Yellow"
} else {
  Write-Log "=== Alert Statistics ===" "Cyan"
  Write-Log "Alerts Newly Created: $($NewlyCreatedAlerts.Count)" "Green"
  Write-Log "Alerts Skipped (already existed): $($ExistingAlerts.Count)" "Yellow"
  if ($failedCount -gt 0) {
    Write-Log "Failed: $failedCount" "Red"
  }
  
  if ($NewlyCreatedAlerts.Count -gt 0) {
    Write-Log "" 
    Write-Log "=== Newly Created Alerts ===" "Green"
    Write-Log "The following $($NewlyCreatedAlerts.Count) alert(s) were created:" "Green"
    foreach ($alert in $NewlyCreatedAlerts) {
      Write-Log "  - $alert" "Gray"
    }
  }
  
  if ($ExistingAlerts.Count -gt 0) {
    Write-Log "" 
    Write-Log "=== Existing Alerts Detected ===" "Yellow"
    Write-Log "The following $($ExistingAlerts.Count) alert(s) were skipped (already exist):" "Yellow"
    foreach ($alert in $ExistingAlerts) {
      Write-Log "  - $alert" "Gray"
    }
    Write-Log "" 
    Write-Log "NOTE: If you want to recreate these alerts from scratch, you can:" "Yellow"
    Write-Log "1. Delete existing alerts using Azure Portal or Azure CLI" "Yellow"
    Write-Log "2. Run this PowerShell command to delete all AVD alerts:" "Yellow"
    Write-Log "" 
    $deleteCmd = '$alerts = az monitor scheduled-query list -g ' + $ResourceGroup + ' --query "[?starts_with(name,''AVD-'')].name" -o tsv' + "`n" +
      '$alerts | ForEach-Object {' + "`n" +
      '  if ($_){ az monitor scheduled-query delete -g ' + $ResourceGroup + ' -n $_ -y }' + "`n" +
      '}'
    Write-Log $deleteCmd "Gray"
    Write-Log "" 
    Write-Log "3. Re-run this script to create fresh alerts" "Yellow"
  }
}

$duration = (Get-Date) - $ScriptStartTime
Write-Log "" 
Write-Log "Execution time: $($duration.TotalSeconds.ToString('F1')) seconds" "Gray"
Write-Log "Done." "Green"
