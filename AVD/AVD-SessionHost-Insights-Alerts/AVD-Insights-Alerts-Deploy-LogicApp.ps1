<#
==============================================================================
SCRIPT VERSION: 2.0
LAST UPDATED: March 16, 2026
REPOSITORY: https://github.com/AzaryaShaulov/AVD
DISCLAIMER: This script is provided AS IS, without warranties or support guarantees.
==============================================================================
.SYNOPSIS
    Deploys and configures the AVD Insights Logic App webhook notification pipeline.

.DESCRIPTION
    Creates or updates the Logic App workflow, ensures the AVD-Insights-Detailed
    webhook action group, validates and authorizes required API connections, and
    configures alert routing so Insights performance alerts send detailed
    notifications through the webhook path.

    Follows the same patterns as AVD-Deploy-Alert-LogicApp.ps1 from
    AVD-AzAlerts: bootstrap missing alerts, create/update action group, deploy
    Logic App with managed identity, assign RBAC, and route alerts.

.PARAMETER SubscriptionId
    Azure subscription ID to target. If omitted, uses the current Azure CLI context.

.PARAMETER ResourceGroupName
    Resource group where Logic App and related alert resources are deployed.

.PARAMETER LogicAppName
    Name of the Logic App workflow used for detailed AVD Insights notifications.

.PARAMETER Location
    Azure region for deployment (for example: eastus2).

.PARAMETER WorkspaceName
    Log Analytics workspace name used by the alert queries.

.PARAMETER WorkspaceResourceGroupName
    Resource group containing the Log Analytics workspace.

.PARAMETER SendToEmails
    One or more recipient email addresses for detailed notifications.

.PARAMETER SendToEmail
    Single recipient email address (legacy single-value option).

.PARAMETER SendFromEmail
    Sender mailbox address used by the Office 365 connection.

.PARAMETER Office365ConnectionName
    Existing API connection name for Office 365 (default: avd-alerts-office365).

.PARAMETER DetailedActionGroupName
    Azure Monitor action group name for webhook-based detailed Insights alerts.

.PARAMETER DetailedWebhookReceiverName
    Webhook receiver name created/updated inside the detailed action group.

.PARAMETER Tags
    Optional resource tags to apply to deployed resources.

.PARAMETER UseHardCodedDefaults
    Uses values from the internal $HardCoded map when provided.

.PARAMETER CsvPath
    Optional output path for post-run CSV summary report.

.EXAMPLE
    .\AVD-Insights-Alerts-Deploy-LogicApp.ps1 `
      -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
      -ResourceGroupName "rg-avd-monitoring" `
      -LogicAppName "AVD-Insights-Alert-Email" `
      -Location "eastus2" `
      -WorkspaceName "law-avd-prod" `
      -WorkspaceResourceGroupName "rg-avd-monitoring" `
      -SendToEmail "alerts@contoso.com" `
      -SendFromEmail "alerts@contoso.com" `
      -Office365ConnectionName "avd-alerts-office365"

.EXAMPLE
    .\AVD-Insights-Alerts-Deploy-LogicApp.ps1 `
      -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
      -ResourceGroupName "rg-avd-monitoring" `
      -LogicAppName "AVD-Insights-Alert-Email" `
      -Location "eastus2" `
      -WorkspaceName "law-avd-prod" `
      -SendToEmails "avdops@contoso.com","noc@contoso.com" `
      -SendFromEmail "alerts@contoso.com"

.NOTES
    Script function summary:
    - Deploys/updates Logic App workflow resources used for detailed Insights notifications.
    - Ensures AVD-Insights-Detailed action group webhook receiver is present and points to callback URL.
    - Assigns Log Analytics Reader to the Logic App managed identity for query access.
    - Verifies required AVD-Insights alerts exist and bootstraps them via AVD-Insights-Alerts-Category-Alerts.ps1 when missing.
    - Applies detailed-only routing for Insights alerts after webhook deployment.
    - Reuses existing 'avd-alerts-office365' Office 365 API connection when available.

    Operational notes:
    - Requires Azure CLI login and permissions for Logic App, Monitor, and IAM changes.
    - Office365 connection may require manual authorization in Azure Portal before emails flow.
    - Supports either -SendToEmail (single) or -SendToEmails (multiple recipients).
#>

[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [ValidateNotNullOrEmpty()]
    [string]$LogicAppName,

    [ValidateNotNullOrEmpty()]
    [string]$Location,

    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceName,

    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceResourceGroupName,

    [string[]]$SendToEmails = @(),
    [string]$SendToEmail = "",

    [ValidateNotNullOrEmpty()]
    [string]$SendFromEmail,

    [string]$Office365ConnectionName = "avd-alerts-office365",
    [string]$DetailedActionGroupName = "AVD-Insights-Detailed",
    [string]$DetailedWebhookReceiverName = "AVDInsightsDetailedWebhook",
    [string]$CsvPath = "",
    [hashtable]$Tags = @{},
    [switch]$UseHardCodedDefaults
)

$ErrorActionPreference = "Stop"
$ScriptStartTime = Get-Date

# =========================
# OPTIONAL HARDCODED DEFAULTS
# Set these if you want to run with -UseHardCodedDefaults
# =========================
$HardCoded = @{
    SubscriptionId              = ""
    ResourceGroupName           = ""
    LogicAppName                = ""
    Location                    = ""
    WorkspaceName               = ""
    WorkspaceResourceGroupName  = ""
    SendToEmails                = @()
    SendToEmail                 = ""
    SendFromEmail               = ""
    Office365ConnectionName     = "avd-alerts-office365"
    DetailedActionGroupName     = "AVD-Insights-Detailed"
    DetailedWebhookReceiverName = "AVDInsightsDetailedWebhook"
    Tags                        = @{
        Solution    = "AVD-Insights"
        Environment = "Prod"
    }
}

# =========================
# Helper Functions
# =========================

function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Resolve-Setting {
    param(
        [string]$Value,
        [string]$DefaultValue,
        [string]$Name
    )
    if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
    if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) { return $DefaultValue }
    throw "Missing required value for '$Name'. Provide it as a parameter or populate the hard-coded defaults and use -UseHardCodedDefaults."
}

function Invoke-AzCliJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    if ($Arguments -notcontains '-o' -and $Arguments -notcontains '--output') {
        $Arguments += @('-o', 'json')
    }
    $result = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI command failed: az $($Arguments -join ' ')`n$result" }
    if ([string]::IsNullOrWhiteSpace(($result | Out-String))) { return $null }
    return ($result | Out-String | ConvertFrom-Json)
}

function Invoke-AzCliText {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $result = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI command failed: az $($Arguments -join ' ')`n$result" }
    return ($result | Out-String).Trim()
}

function Get-AlertDefinitionMap {
    param([Parameter(Mandatory)][array]$Definitions)
    $map = @{}
    foreach ($def in $Definitions) {
        $map[$def.Name] = @{
            Description = $def.Description
            Kql         = $def.Kql
        }
    }
    return $map
}

function Set-DetailedActionGroupWebhook {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$ActionGroupName,
        [Parameter(Mandatory)][string]$ReceiverName,
        [Parameter(Mandatory)][string]$ServiceUri
    )
    $actionGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/microsoft.insights/actionGroups/$ActionGroupName"
    $actionGroupUri = "${actionGroupId}?api-version=2023-01-01"
    $actionGroupBody = @{
        location   = 'Global'
        properties = @{
            groupShortName   = 'AVDInsght'
            enabled          = $true
            webhookReceivers = @(
                @{
                    name                 = $ReceiverName
                    serviceUri           = $ServiceUri
                    useCommonAlertSchema = $true
                }
            )
        }
    }
    $tmpFile = Join-Path $env:TEMP ("action-group-{0}-{1}.json" -f $ActionGroupName, [guid]::NewGuid().ToString('N'))
    try {
        $actionGroupBody | ConvertTo-Json -Depth 20 | Set-Content -Path $tmpFile -Encoding utf8
        $result = & az rest --method put --uri $actionGroupUri --body "@$tmpFile" -o json 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Failed to create/update action group '$ActionGroupName'`n$result" }
    }
    finally {
        Remove-Item -Path $tmpFile -ErrorAction SilentlyContinue
    }
}

function Set-InsightsAlertsToDetailedOnly {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$DetailedActionGroupName
    )
    $detailedActionGroupId = Invoke-AzCliText -Arguments @(
        "monitor", "action-group", "show",
        "--resource-group", $ResourceGroupName,
        "--name", $DetailedActionGroupName,
        "--subscription", $SubscriptionId,
        "--query", "id", "-o", "tsv"
    )
    if ([string]::IsNullOrWhiteSpace($detailedActionGroupId)) {
        throw "Failed to resolve action group ID for '$DetailedActionGroupName'."
    }

    $alertNameOutput = Invoke-AzCliText -Arguments @(
        "monitor", "scheduled-query", "list",
        "--resource-group", $ResourceGroupName,
        "--subscription", $SubscriptionId,
        "--query", "[?starts_with(name, 'AVD-Insights-')].name",
        "-o", "tsv"
    )
    if ([string]::IsNullOrWhiteSpace($alertNameOutput)) {
        Write-Warning "No existing AVD-Insights alert rules were found in resource group '$ResourceGroupName'."
        return
    }

    $alertNames = $alertNameOutput -split "[\r\n]+" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() }

    $updated = 0
    $failed = @()
    foreach ($alertName in $alertNames) {
        $updateOutput = & az monitor scheduled-query update `
            --resource-group $ResourceGroupName `
            --name $alertName `
            --subscription $SubscriptionId `
            --action-groups $detailedActionGroupId 2>&1
        if ($LASTEXITCODE -eq 0) {
            $updated++
            Write-Host "Updated '$alertName' to detailed-only action group." -ForegroundColor Gray
        }
        else {
            $failed += $alertName
            Write-Warning "Failed to update alert '$alertName' to detailed-only action group. $updateOutput"
        }
    }

    if ($failed.Count -gt 0) {
        throw "Updated $updated alert(s), but failed to update $($failed.Count): $($failed -join ', ')"
    }
    Write-Host "All $updated AVD-Insights alert(s) now use detailed-only action group '$DetailedActionGroupName'." -ForegroundColor Green
}

function Set-InsightsAlertsIfMissing {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$WorkspaceResourceGroupName,
        [Parameter(Mandatory)][string]$WorkspaceName,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$DetailedActionGroupName,
        [Parameter(Mandatory)][string]$DetailedWebhookReceiverName,
        [Parameter(Mandatory)][string]$DetailedResultsWebhookUrl
    )

    # Guard: ensure scheduled-query extension is available
    & az extension show --name scheduled-query -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Installing 'scheduled-query' extension for bootstrap..." -ForegroundColor Yellow
        & az extension add --name scheduled-query --yes -o none 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Required Azure CLI extension 'scheduled-query' could not be installed." }
    }

    $existingAlertNamesOutput = Invoke-AzCliText -Arguments @(
        "monitor", "scheduled-query", "list",
        "--resource-group", $ResourceGroupName,
        "--subscription", $SubscriptionId,
        "--query", "[?starts_with(name, 'AVD-Insights-')].name",
        "-o", "tsv"
    )
    $existingAlertNames = @()
    if (-not [string]::IsNullOrWhiteSpace($existingAlertNamesOutput)) {
        $existingAlertNames = $existingAlertNamesOutput -split "[\r\n]+" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() }
    }

    # Load required alert names from alerts-config.insights.json
    $configPath = Join-Path $PSScriptRoot "alerts-config.insights.json"
    if (-not (Test-Path $configPath)) {
        throw "Could not find alerts-config.insights.json at '$configPath'."
    }
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $requiredAlertNames = @()
    foreach ($catName in ($config.categories | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)) {
        foreach ($alertDef in $config.categories.$catName.alerts) {
            $requiredAlertNames += $alertDef.name
        }
    }

    $missingAlertNames = $requiredAlertNames | Where-Object { $existingAlertNames -notcontains $_ }
    if ($missingAlertNames.Count -eq 0) {
        Write-Host "All required AVD-Insights alerts already exist; bootstrap creation is not required." -ForegroundColor Gray
        return
    }

    $deployAlertsScript = Join-Path $PSScriptRoot "AVD-Insights-Alerts-Category-Alerts.ps1"
    if (-not (Test-Path $deployAlertsScript)) {
        throw "Could not find AVD-Insights-Alerts-Category-Alerts.ps1 at '$deployAlertsScript'."
    }

    Write-Host "Detected $($missingAlertNames.Count) missing AVD-Insights alert(s). Bootstrapping via AVD-Insights-Alerts-Category-Alerts.ps1..." -ForegroundColor Yellow

    & $deployAlertsScript `
        -SubscriptionId $SubscriptionId `
        -ResourceGroup $ResourceGroupName `
        -WorkspaceName $WorkspaceName `
        -WorkspaceResourceGroupName $WorkspaceResourceGroupName `
        -Location $Location `
        -ActionGroupName $DetailedActionGroupName `
        -WebhookUrl $DetailedResultsWebhookUrl `
        -WebhookReceiverName $DetailedWebhookReceiverName `
        -CreateOnly $true

    if ($LASTEXITCODE -ne 0) {
        throw "Bootstrap alert creation via AVD-Insights-Alerts-Category-Alerts.ps1 failed."
    }

    # Verify bootstrap result
    $postBootstrapOutput = Invoke-AzCliText -Arguments @(
        "monitor", "scheduled-query", "list",
        "--resource-group", $ResourceGroupName,
        "--subscription", $SubscriptionId,
        "--query", "[?starts_with(name, 'AVD-Insights-')].name",
        "-o", "tsv"
    )
    $postBootstrapAlertNames = @()
    if (-not [string]::IsNullOrWhiteSpace($postBootstrapOutput)) {
        $postBootstrapAlertNames = $postBootstrapOutput -split "[\r\n]+" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() }
    }

    $stillMissing = $requiredAlertNames | Where-Object { $postBootstrapAlertNames -notcontains $_ }
    if ($stillMissing.Count -gt 0) {
        throw "Bootstrap completed but required alerts are still missing: $($stillMissing -join ', ')"
    }
    Write-Host "Bootstrap complete: required AVD-Insights alerts now exist." -ForegroundColor Green
}

# =========================
# Resolve runtime values
# =========================
if ($UseHardCodedDefaults) {
    $SubscriptionId             = Resolve-Setting -Value $SubscriptionId            -DefaultValue $HardCoded.SubscriptionId             -Name "SubscriptionId"
    $ResourceGroupName          = Resolve-Setting -Value $ResourceGroupName         -DefaultValue $HardCoded.ResourceGroupName          -Name "ResourceGroupName"
    $LogicAppName               = Resolve-Setting -Value $LogicAppName              -DefaultValue $HardCoded.LogicAppName               -Name "LogicAppName"
    $Location                   = Resolve-Setting -Value $Location                  -DefaultValue $HardCoded.Location                   -Name "Location"
    $WorkspaceName              = Resolve-Setting -Value $WorkspaceName             -DefaultValue $HardCoded.WorkspaceName              -Name "WorkspaceName"
    $WorkspaceResourceGroupName = Resolve-Setting -Value $WorkspaceResourceGroupName -DefaultValue $HardCoded.WorkspaceResourceGroupName -Name "WorkspaceResourceGroupName"
    $SendFromEmail              = Resolve-Setting -Value $SendFromEmail             -DefaultValue $HardCoded.SendFromEmail              -Name "SendFromEmail"

    if (($SendToEmails.Count -eq 0) -and [string]::IsNullOrWhiteSpace($SendToEmail)) {
        if ($HardCoded.SendToEmails -and $HardCoded.SendToEmails.Count -gt 0) {
            $SendToEmails = $HardCoded.SendToEmails
        }
        else {
            $SendToEmail = Resolve-Setting -Value $SendToEmail -DefaultValue $HardCoded.SendToEmail -Name "SendToEmail"
        }
    }

    if ([string]::IsNullOrWhiteSpace($Office365ConnectionName)) {
        $Office365ConnectionName = $HardCoded.Office365ConnectionName
    }
    if ([string]::IsNullOrWhiteSpace($DetailedActionGroupName)) {
        $DetailedActionGroupName = $HardCoded.DetailedActionGroupName
    }
    if ([string]::IsNullOrWhiteSpace($DetailedWebhookReceiverName)) {
        $DetailedWebhookReceiverName = $HardCoded.DetailedWebhookReceiverName
    }
    if (-not $Tags -or $Tags.Count -eq 0) {
        $Tags = $HardCoded.Tags
    }
}
else {
    $SubscriptionId             = Resolve-Setting -Value $SubscriptionId             -DefaultValue "" -Name "SubscriptionId"
    $ResourceGroupName          = Resolve-Setting -Value $ResourceGroupName          -DefaultValue "" -Name "ResourceGroupName"
    $LogicAppName               = Resolve-Setting -Value $LogicAppName               -DefaultValue "" -Name "LogicAppName"
    $Location                   = Resolve-Setting -Value $Location                   -DefaultValue "" -Name "Location"
    $WorkspaceName              = Resolve-Setting -Value $WorkspaceName              -DefaultValue "" -Name "WorkspaceName"
    $WorkspaceResourceGroupName = Resolve-Setting -Value $WorkspaceResourceGroupName -DefaultValue "" -Name "WorkspaceResourceGroupName"
    $SendFromEmail              = Resolve-Setting -Value $SendFromEmail              -DefaultValue "" -Name "SendFromEmail"

    if (($SendToEmails.Count -eq 0) -and [string]::IsNullOrWhiteSpace($SendToEmail)) {
        throw "Missing required value for 'SendToEmails' or 'SendToEmail'. Provide at least one recipient."
    }
}

# Normalize recipients
$ResolvedSendToEmails = @($SendToEmails)
if (-not [string]::IsNullOrWhiteSpace($SendToEmail)) {
    $ResolvedSendToEmails += $SendToEmail
}
$ResolvedSendToEmails = @(
    $ResolvedSendToEmails |
    ForEach-Object { $_ -split '[;,]' } |
    ForEach-Object { $_.Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique
)
if ($ResolvedSendToEmails.Count -eq 0) {
    throw "No valid recipients were resolved from 'SendToEmails' or 'SendToEmail'."
}
$SendToEmailValue = (($ResolvedSendToEmails | ForEach-Object { $_ -replace '\\', '\\' -replace '"', '\"' }) -join ';')
$SendFromEmail = $SendFromEmail -replace '\\', '\\' -replace '"', '\"'

if ([string]::IsNullOrWhiteSpace($Office365ConnectionName)) {
    $Office365ConnectionName = "avd-alerts-office365"
}
if ([string]::IsNullOrWhiteSpace($DetailedActionGroupName)) {
    $DetailedActionGroupName = "AVD-Insights-Detailed"
}
if ([string]::IsNullOrWhiteSpace($DetailedWebhookReceiverName)) {
    $DetailedWebhookReceiverName = "AVDInsightsDetailedWebhook"
}
if (-not $Tags) { $Tags = @{} }

if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    $subPrefix = if ($SubscriptionId.Length -ge 8) { $SubscriptionId.Substring(0, 8) } else { $SubscriptionId }
    $CsvPath = ".\avd-insights-logicapp-report-$subPrefix.csv"
}

$Office365ConnectionStatus = "Unknown"
$RoleAssignmentStatus = "Unknown"

# =========================
# Pre-flight Checks
# =========================
Write-Step "Checking Azure CLI login"
& az account show | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Azure CLI is not logged in. Run 'az login' first." }

Write-Step "Setting Azure subscription"
& az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { throw "Failed to set Azure subscription to $SubscriptionId" }

Write-Step "Ensuring required CLI extension: scheduled-query"
& az extension show --name scheduled-query -o none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Installing 'scheduled-query' extension..." -ForegroundColor Yellow
    & az extension add --name scheduled-query --yes -o none 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Required Azure CLI extension 'scheduled-query' could not be installed." }
    Write-Host "'scheduled-query' extension installed." -ForegroundColor Green
}
else {
    Write-Host "'scheduled-query' extension is available." -ForegroundColor Gray
}

Write-Step "Ensuring Logic App resource group exists"
$rgExists = Invoke-AzCliText -Arguments @("group", "exists", "--name", $ResourceGroupName)
if ($rgExists -eq "false") {
    $tagArgs = @()
    if ($Tags.Count -gt 0) {
        $flatTags = $Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
        $tagArgs = @("--tags") + $flatTags
    }
    & az group create --name $ResourceGroupName --location $Location @tagArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to create resource group $ResourceGroupName" }
}

# =========================
# Resolve Log Analytics Workspace
# =========================
Write-Step "Resolving Log Analytics workspace by workspace name"
$workspace = Invoke-AzCliJson -Arguments @(
    "monitor", "log-analytics", "workspace", "show",
    "--resource-group", $WorkspaceResourceGroupName,
    "--workspace-name", $WorkspaceName
)
if (-not $workspace) {
    throw "Workspace '$WorkspaceName' in resource group '$WorkspaceResourceGroupName' was not found."
}

$WorkspaceId         = $workspace.customerId
$WorkspaceResourceId = $workspace.id
if ([string]::IsNullOrWhiteSpace($WorkspaceId) -or [string]::IsNullOrWhiteSpace($WorkspaceResourceId)) {
    throw "Could not resolve WorkspaceId or WorkspaceResourceId from workspace '$WorkspaceName'."
}
Write-Host "Workspace Name: $WorkspaceName"
Write-Host "Workspace GUID: $WorkspaceId"
Write-Host "Workspace Resource ID: $WorkspaceResourceId"

# =========================
# Ensure Office 365 API connection
# =========================
Write-Step "Ensuring Office 365 API connection exists"

$Office365ConnectionResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/connections/$Office365ConnectionName"
$Office365ManagedApiId = "/subscriptions/$SubscriptionId/providers/Microsoft.Web/locations/$Location/managedApis/office365"

$existingConnectionJson = & az resource show --ids $Office365ConnectionResourceId -o json 2>&1
$existingConnectionExitCode = $LASTEXITCODE

if ($existingConnectionExitCode -ne 0 -or [string]::IsNullOrWhiteSpace(($existingConnectionJson | Out-String))) {
    Write-Host "Office 365 connection '$Office365ConnectionName' not found - creating..."
    $connBody = @{
        location   = $Location
        properties = @{
            displayName = $Office365ConnectionName
            api         = @{ id = $Office365ManagedApiId }
        }
    }
    $connTmpFile = Join-Path $env:TEMP ("office365-connection-{0}.json" -f [guid]::NewGuid().ToString('N'))
    try {
        $connBody | ConvertTo-Json -Depth 20 | Set-Content -Path $connTmpFile -Encoding utf8
        $connUri = "${Office365ConnectionResourceId}?api-version=2016-06-01"
        $connCreateOutput = & az rest --method put --uri $connUri --body "@$connTmpFile" -o json 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create Office 365 connection '$Office365ConnectionName'`n$connCreateOutput"
        }
    }
    finally {
        Remove-Item -Path $connTmpFile -ErrorAction SilentlyContinue
    }
    Write-Host "Office 365 connection '$Office365ConnectionName' created. Authorize it in Azure Portal if prompted."
    $Office365ConnectionStatus = "Created"
}
else {
    Write-Host "Office 365 connection '$Office365ConnectionName' already exists."
    $Office365ConnectionStatus = "Existing"
}

# =========================
# Build Insights Alert Definition Map
# =========================
# Each Insights alert name maps to a category-specific re-query KQL and description.
# When the Logic App receives a webhook, it looks up the alert rule name to run
# the appropriate Perf / WVDCheckpoints / Event query for the email body.

$defaultFallbackName = "AVD-Insights-DefaultFallback"

$alertDefinitions = @(
    # --- Category: SessionQuality ---
    @{
        Name        = "AVD-Insights-Category-SessionQuality"
        Description = "Session-quality category alert: InputDelay (Process/Session), RoundTripLatency, UDPBandwidth."
        Kql         = @"
Perf
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where ObjectName in ('User Input Delay per Process','User Input Delay per Session','RemoteFX Network')
| summarize AvgValue=round(avg(CounterValue),1), MaxValue=round(max(CounterValue),1), Samples=count() by Computer, ObjectName, CounterName
| extend Status = case(ObjectName has 'Input Delay' and AvgValue > 200, 'CRITICAL', CounterName has 'Round Trip' and AvgValue > 150, 'WARNING', CounterName has 'UDP' and AvgValue < 500, 'WARNING', 'OK')
| order by Status asc, MaxValue desc
| limit 50
"@
    }

    # --- Category: HostPerformance ---
    @{
        Name        = "AVD-Insights-Category-HostPerformance"
        Description = "Host-performance category alert: CPU, Memory, MemoryCommit, Pages, PageFaults-Baseline, DiskTiming."
        Kql         = @"
Perf
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where ObjectName in ('Processor Information','Memory','LogicalDisk','PhysicalDisk')
| where CounterName in ('% Processor Time','Available MBytes','% Committed Bytes In Use','Pages/sec','Page Faults/sec','Avg. Disk sec/Read','Avg. Disk sec/Write')
    or CounterName has 'Disk sec/'
| summarize AvgValue=round(avg(CounterValue),1), MaxValue=round(max(CounterValue),1), Samples=count() by Computer, ObjectName, CounterName
| extend Status = case(CounterName == '% Processor Time' and AvgValue > 90, 'CRITICAL', CounterName == 'Available MBytes' and AvgValue < 512, 'CRITICAL', CounterName == '% Committed Bytes In Use' and AvgValue > 80, 'WARNING', CounterName == 'Pages/sec' and AvgValue > 100, 'WARNING', CounterName has 'Disk sec/' and AvgValue > 0.025, 'WARNING', 'OK')
| order by Status asc, Computer asc
| limit 100
"@
    }

    # --- Category: DiskHealth ---
    @{
        Name        = "AVD-Insights-Category-DiskHealth"
        Description = "Disk-health category alert: DiskQueueLength, DiskFreeSpace."
        Kql         = @"
Perf
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where (ObjectName in ('LogicalDisk','PhysicalDisk') and CounterName has 'Queue Length')
    or (ObjectName == 'LogicalDisk' and CounterName in ('% Free Space','Free Megabytes'))
| summarize AvgValue=round(avg(CounterValue),1), MaxValue=round(max(CounterValue),1), MinValue=round(min(CounterValue),1), Samples=count() by Computer, ObjectName, CounterName, InstanceName
| extend Status = case(CounterName has 'Queue Length' and AvgValue > 5, 'WARNING', CounterName == '% Free Space' and MinValue < 10, 'CRITICAL', 'OK')
| order by Status asc, Computer asc
| limit 100
"@
    }

    # --- Category: SessionLifecycle ---
    @{
        Name        = "AVD-Insights-Category-SessionLifecycle"
        Description = "Session-lifecycle category alert: SignInDegradation, CapacityPressure, SessionImbalance."
        Kql         = @"
union isfuzzy=true
(WVDCheckpoints
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where Source == 'WVDConnections'
| summarize StartTime=min(TimeGenerated), EndTime=max(TimeGenerated) by CorrelationId, UserName, SessionHostName=tostring(Parameters.SessionHostName)
| extend DurationMs=datetime_diff('millisecond', EndTime, StartTime)
| where DurationMs > 0
| summarize AvgDurationSec=round(avg(DurationMs)/1000.0,1), MaxDurationSec=round(max(DurationMs)/1000.0,1), Sessions=count() by SessionHostName
| project Computer=SessionHostName, Signal='SignInDegradation', AvgDurationSec, MaxDurationSec, Sessions, Status=iff(AvgDurationSec > 30, 'CRITICAL', 'OK')),
(WVDAgentHealthStatus
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where Status == 'Available' and isnotempty(ActiveSessions)
| summarize LatestSessions=arg_max(TimeGenerated, ActiveSessions, AllowNewSessions) by SessionHostName
| project Computer=SessionHostName, Signal='CapacityPressure', ActiveSessions, AllowNewSessions, Status='WARNING'),
(Perf
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where ObjectName == 'Terminal Services' and CounterName in ('Active Sessions','Inactive Sessions','Total Sessions')
| summarize Value=round(avg(CounterValue),0) by Computer, CounterName
| evaluate pivot(CounterName, take_any(Value))
| project Computer, Signal='SessionImbalance', ActiveSessions=column_ifexists('Active Sessions',0), InactiveSessions=column_ifexists('Inactive Sessions',0), TotalSessions=column_ifexists('Total Sessions',0), Status=iff(column_ifexists('Inactive Sessions',0) * 2 > max_of(column_ifexists('Total Sessions',0), 1) and column_ifexists('Total Sessions',0) >= 2, 'WARNING', 'OK'))
| limit 100
"@
    }

    # --- Category: CorrelatedSignals ---
    @{
        Name        = "AVD-Insights-Category-CorrelatedSignals"
        Description = "Correlated-signals category alert: multi-signal host degradation and FSLogix correlation."
        Kql         = @"
union isfuzzy=true
(Perf
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where ObjectName in ('Processor Information','Memory','LogicalDisk','PhysicalDisk')
| summarize AvgValue=round(avg(CounterValue),1), MaxValue=round(max(CounterValue),1), Samples=count() by Computer, ObjectName, CounterName
| extend Status = case(CounterName == '% Processor Time' and AvgValue > 90, 'CRITICAL', CounterName == 'Available MBytes' and AvgValue < 512, 'CRITICAL', CounterName has 'Disk sec/' and AvgValue > 0.025, 'WARNING', 'OK')),
(Event
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where Source has 'FSLogix' or EventLog has 'FSLogix'
| summarize EventCount=count() by Computer, Source, EventID, RenderedDescription=strcat(take(RenderedDescription,200),'...')
| extend Status = 'WARNING')
| limit 100
"@
    }

    # --- Category: EventLogAlerts ---
    @{
        Name        = "AVD-Insights-Category-EventLogAlerts"
        Description = "Event-log category alert: FSLogix profile attach/detach failures or VHD errors."
        Kql         = @"
Event
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where Source has 'FSLogix' or EventLog has 'FSLogix'
| where EventLevelName in ('Error','Warning')
| project TimeGenerated, Computer, Source, EventLog, EventID, EventLevelName, RenderedDescription, Status = iff(EventLevelName == 'Error', 'CRITICAL', 'WARNING')
| order by Status asc, TimeGenerated desc
| limit 100
"@
    }

    # --- Category: GPUPerformance ---
    @{
        Name        = "AVD-Insights-Category-GPUPerformance"
        Description = "GPU-performance category alert: RemoteFX Graphics encoding time exceeds frame budget."
        Kql         = @"
Perf
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where ObjectName == 'RemoteFX Graphics' and CounterName has 'Encoding'
| summarize AvgValue=round(avg(CounterValue),1), MaxValue=round(max(CounterValue),1), Samples=count() by Computer, ObjectName, CounterName
| extend Status = iff(AvgValue > 33, 'CRITICAL', 'OK')
| order by Status asc, MaxValue desc
| limit 50
"@
    }

    # --- Default fallback ---
    @{
        Name        = $defaultFallbackName
        Description = "Fallback Perf counter query when alert rule name is not mapped."
        Kql         = @"
Perf
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where ObjectName in ('Processor Information','Memory','LogicalDisk','PhysicalDisk','User Input Delay per Process','RemoteFX Network')
| summarize AvgValue=round(avg(CounterValue),1), MaxValue=round(max(CounterValue),1), Samples=count() by Computer, ObjectName, CounterName
| order by Computer asc, ObjectName asc
| limit 50
"@
    }
)

$alertDefinitionMap = Get-AlertDefinitionMap -Definitions $alertDefinitions
$alertDefinitionMapJson = $alertDefinitionMap | ConvertTo-Json -Depth 20 -Compress

# =========================
# Build dynamic KQL re-query expression
# =========================
$kqlQueryExpr = @"
@{replace(
    replace(
        coalesce(
            variables('AlertDefinitionMap')?[coalesce(triggerBody()?['data']?['essentials']?['alertRule'], '$defaultFallbackName')]?['Kql'],
            variables('AlertDefinitionMap')?['$defaultFallbackName']?['Kql']
        ),
        '{0}',
        coalesce(
            triggerBody()?['data']?['alertContext']?['condition']?['windowStartTime'],
            triggerBody()?['data']?['alertContext']?['windowStartTime'],
            triggerBody()?['data']?['essentials']?['firedDateTime'],
            addMinutes(utcNow(), -15)
        )
    ),
    '{1}',
    coalesce(
        triggerBody()?['data']?['alertContext']?['condition']?['windowEndTime'],
        triggerBody()?['data']?['alertContext']?['windowEndTime'],
        triggerBody()?['data']?['essentials']?['firedDateTime'],
        utcNow()
    )
)}
"@

# =========================
# Build HTML email template
# =========================
$alertEmailHtmlExpr = @'
@{concat(
  '<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:13px;color:#242424;">',
  '<h2 style="margin-bottom:8px;">AVD Insights Alert</h2>',

  '<table border="0" cellpadding="6" cellspacing="0" style="border-collapse:collapse;">',
    '<tr><td><b>Rule</b></td><td>', coalesce(triggerBody()?['data']?['essentials']?['alertRule'], 'N/A'), '</td></tr>',
    '<tr><td><b>Description</b></td><td>', coalesce(variables('AlertDescriptionText'), 'N/A'), '</td></tr>',
    '<tr><td><b>Severity</b></td><td>', string(coalesce(triggerBody()?['data']?['essentials']?['severity'], 'N/A')), '</td></tr>',
    '<tr><td><b>Condition</b></td><td>', coalesce(triggerBody()?['data']?['essentials']?['monitorCondition'], 'N/A'), '</td></tr>',
    '<tr><td><b>Fired At</b></td><td>', if(equals(coalesce(triggerBody()?['data']?['essentials']?['firedDateTime'], ''), ''), 'N/A', concat(convertTimeZone(triggerBody()?['data']?['essentials']?['firedDateTime'], 'UTC', '$CustomerTimeZone', 'yyyy-MM-dd HH:mm:ss'), ' ($CustomerTzAbbrev)')), '</td></tr>',
    '<tr><td><b>Window Start</b></td><td>', if(equals(coalesce(triggerBody()?['data']?['alertContext']?['condition']?['windowStartTime'], triggerBody()?['data']?['alertContext']?['windowStartTime'], ''), ''), 'N/A', concat(convertTimeZone(coalesce(triggerBody()?['data']?['alertContext']?['condition']?['windowStartTime'], triggerBody()?['data']?['alertContext']?['windowStartTime']), 'UTC', '$CustomerTimeZone', 'yyyy-MM-dd HH:mm:ss'), ' ($CustomerTzAbbrev)')), '</td></tr>',
    '<tr><td><b>Window End</b></td><td>', if(equals(coalesce(triggerBody()?['data']?['alertContext']?['condition']?['windowEndTime'], triggerBody()?['data']?['alertContext']?['windowEndTime'], ''), ''), 'N/A', concat(convertTimeZone(coalesce(triggerBody()?['data']?['alertContext']?['condition']?['windowEndTime'], triggerBody()?['data']?['alertContext']?['windowEndTime']), 'UTC', '$CustomerTimeZone', 'yyyy-MM-dd HH:mm:ss'), ' ($CustomerTzAbbrev)')), '</td></tr>',
  '</table>',

  '<h3 style="margin:14px 0 6px 0;">Log Analytics Workspace</h3>',
  '<table border="0" cellpadding="6" cellspacing="0" style="border-collapse:collapse;">',
    '<tr><td><b>Name</b></td><td>$WorkspaceName</td></tr>',
    '<tr><td><b>Workspace GUID</b></td><td>$WorkspaceId</td></tr>',
  '</table>',

  '<h3 style="margin:14px 0 6px 0;">Insights Query Results</h3>',
  '<p style="margin:2px 0 8px 0;font-size:11px;color:#616161;">Rows highlighted in <span style="background:#FFC7CE;color:#9C0006;padding:1px 4px;">red</span> have breached critical thresholds. Rows in <span style="background:#FFEB9C;color:#9C6500;padding:1px 4px;">yellow</span> are warnings.</p>',
  variables('ResultsTableHtml'),

  '<h3 style="margin:18px 0 6px 0;">Troubleshooting Resources</h3>',
  '<p style="margin:4px 0;">&#128214; <a href="$AlertMatrixUrl" style="color:#0078D4;">Alert Matrix</a> &mdash; thresholds, counters, and tuning guide for all category signals</p>',
  '<p style="margin:4px 0;">&#128736; <a href="$RunbookUrl" style="color:#0078D4;">Operational Runbook</a> &mdash; triage steps and resolution procedures for each signal</p>',

  '</body></html>'
)}
'@

$repoBaseUrl     = "https://github.com/AzaryaShaulov/AVD/blob/main/AVD-SessionHost-Insights-Alerts"
$alertMatrixUrl  = "$repoBaseUrl/AVD-Insights-Alert-Matrix.md"
$runbookUrl      = "$repoBaseUrl/AVD-hosts-Insights-Alerts-Runbook.md"

# Map Azure region to Windows timezone ID for local-time display in emails
$regionTimeZoneMap = @{
    'eastus'             = @{ tz = 'Eastern Standard Time';           abbrev = 'ET' }
    'eastus2'            = @{ tz = 'Eastern Standard Time';           abbrev = 'ET' }
    'centralus'          = @{ tz = 'Central Standard Time';           abbrev = 'CT' }
    'northcentralus'     = @{ tz = 'Central Standard Time';           abbrev = 'CT' }
    'southcentralus'     = @{ tz = 'Central Standard Time';           abbrev = 'CT' }
    'westcentralus'      = @{ tz = 'Mountain Standard Time';          abbrev = 'MT' }
    'westus'             = @{ tz = 'Pacific Standard Time';           abbrev = 'PT' }
    'westus2'            = @{ tz = 'Pacific Standard Time';           abbrev = 'PT' }
    'westus3'            = @{ tz = 'Mountain Standard Time';          abbrev = 'MT' }
    'canadacentral'      = @{ tz = 'Eastern Standard Time';           abbrev = 'ET' }
    'canadaeast'         = @{ tz = 'Eastern Standard Time';           abbrev = 'ET' }
    'northeurope'        = @{ tz = 'GMT Standard Time';               abbrev = 'GMT' }
    'westeurope'         = @{ tz = 'W. Europe Standard Time';         abbrev = 'CET' }
    'uksouth'            = @{ tz = 'GMT Standard Time';               abbrev = 'GMT' }
    'ukwest'             = @{ tz = 'GMT Standard Time';               abbrev = 'GMT' }
    'francecentral'      = @{ tz = 'Romance Standard Time';           abbrev = 'CET' }
    'germanywestcentral' = @{ tz = 'W. Europe Standard Time';         abbrev = 'CET' }
    'switzerlandnorth'   = @{ tz = 'W. Europe Standard Time';         abbrev = 'CET' }
    'norwayeast'         = @{ tz = 'W. Europe Standard Time';         abbrev = 'CET' }
    'swedencentral'      = @{ tz = 'W. Europe Standard Time';         abbrev = 'CET' }
    'australiaeast'      = @{ tz = 'AUS Eastern Standard Time';       abbrev = 'AEST' }
    'australiasoutheast' = @{ tz = 'AUS Eastern Standard Time';       abbrev = 'AEST' }
    'japaneast'          = @{ tz = 'Tokyo Standard Time';             abbrev = 'JST' }
    'japanwest'          = @{ tz = 'Tokyo Standard Time';             abbrev = 'JST' }
    'southeastasia'      = @{ tz = 'Singapore Standard Time';         abbrev = 'SGT' }
    'eastasia'           = @{ tz = 'China Standard Time';             abbrev = 'HKT' }
    'koreacentral'       = @{ tz = 'Korea Standard Time';             abbrev = 'KST' }
    'centralindia'       = @{ tz = 'India Standard Time';             abbrev = 'IST' }
    'brazilsouth'        = @{ tz = 'E. South America Standard Time';  abbrev = 'BRT' }
    'southafricanorth'   = @{ tz = 'South Africa Standard Time';      abbrev = 'SAST' }
    'uaenorth'           = @{ tz = 'Arabian Standard Time';           abbrev = 'GST' }
}

$locationKey = $Location.ToLowerInvariant().Replace(' ', '')
if ($regionTimeZoneMap.ContainsKey($locationKey)) {
    $CustomerTimeZone = $regionTimeZoneMap[$locationKey].tz
    $CustomerTzAbbrev = $regionTimeZoneMap[$locationKey].abbrev
} else {
    Write-Warning "No timezone mapping for region '$Location'. Defaulting to UTC."
    $CustomerTimeZone = 'UTC'
    $CustomerTzAbbrev = 'UTC'
}
Write-Host "Timezone for region '$Location': $CustomerTimeZone ($CustomerTzAbbrev)"

$alertEmailHtmlExpr = $alertEmailHtmlExpr.Replace('$WorkspaceName', $WorkspaceName)
$alertEmailHtmlExpr = $alertEmailHtmlExpr.Replace('$WorkspaceId', $WorkspaceId)
$alertEmailHtmlExpr = $alertEmailHtmlExpr.Replace('$CustomerTimeZone', $CustomerTimeZone)
$alertEmailHtmlExpr = $alertEmailHtmlExpr.Replace('$CustomerTzAbbrev', $CustomerTzAbbrev)
$alertEmailHtmlExpr = $alertEmailHtmlExpr.Replace('$AlertMatrixUrl', $alertMatrixUrl)
$alertEmailHtmlExpr = $alertEmailHtmlExpr.Replace('$RunbookUrl', $runbookUrl)

# =========================
# Build and Deploy Logic App Workflow
# =========================
$sendEmailAction = @{
    type     = "ApiConnection"
    runAfter = @{
        Append_Table_End = @("Succeeded")
    }
    inputs   = @{
        method = "post"
        path   = "/v2/Mail"
        host   = @{
            connection = @{
                name = "@parameters('`$connections')['office365']['connectionId']"
            }
        }
        body   = @{
            To         = $SendToEmailValue
            Subject    = "@{concat('AVD Insights Alert - ', coalesce(triggerBody()?['data']?['essentials']?['alertRule'], 'Performance'))}"
            Body       = $alertEmailHtmlExpr
            From       = $SendFromEmail
            Importance = "High"
        }
    }
}

$workflowDefinition = @{
    '$schema'      = 'https://schema.management.azure.com/schemas/2016-06-01/Microsoft.Logic.json'
    contentVersion = '1.0.0.0'
    parameters     = @{
        '$connections' = @{
            type         = 'Object'
            defaultValue = @{}
        }
    }
    triggers = @{
        manual = @{
            type   = 'Request'
            kind   = 'Http'
            inputs = @{ method = 'POST' }
        }
    }
    actions = @{
        Initialize_ResultsTableHtml = @{
            type     = 'InitializeVariable'
            inputs   = @{
                variables = @(
                    @{
                        name  = 'ResultsTableHtml'
                        type  = 'string'
                        value = '<p>No Insights data rows were returned for this alert window.</p>'
                    }
                )
            }
            runAfter = @{}
        }

        Initialize_AlertDefinitionMap = @{
            type   = 'InitializeVariable'
            inputs = @{
                variables = @(
                    @{
                        name  = 'AlertDefinitionMap'
                        type  = 'object'
                        value = ($alertDefinitionMapJson | ConvertFrom-Json)
                    }
                )
            }
            runAfter = @{
                Initialize_ResultsTableHtml = @('Succeeded')
            }
        }

        Initialize_AlertDescription = @{
            type   = 'InitializeVariable'
            inputs = @{
                variables = @(
                    @{
                        name  = 'AlertDescriptionText'
                        type  = 'string'
                        value = ''
                    }
                )
            }
            runAfter = @{
                Initialize_AlertDefinitionMap = @('Succeeded')
            }
        }

        Set_AlertDescriptionText = @{
            type   = 'SetVariable'
            inputs = @{
                name  = 'AlertDescriptionText'
                value = "@{coalesce(
                    variables('AlertDefinitionMap')?[coalesce(triggerBody()?['data']?['essentials']?['alertRule'], '$defaultFallbackName')]?['Description'],
                    variables('AlertDefinitionMap')?['$defaultFallbackName']?['Description']
                )}"
            }
            runAfter = @{
                Initialize_AlertDescription = @('Succeeded')
            }
        }

        Query_InsightsData = @{
            type     = 'Http'
            runAfter = @{
                Set_AlertDescriptionText = @('Succeeded')
            }
            inputs   = @{
                method         = 'POST'
                uri            = "https://api.loganalytics.io/v1/workspaces/$WorkspaceId/query"
                headers        = @{
                    'Content-Type' = 'application/json'
                }
                body           = @{
                    query = $kqlQueryExpr
                }
                authentication = @{
                    type     = 'ManagedServiceIdentity'
                    audience = 'https://api.loganalytics.io/'
                }
            }
        }

        Start_Table = @{
            type     = 'SetVariable'
            runAfter = @{
                Query_InsightsData = @('Succeeded')
            }
            inputs   = @{
                name  = 'ResultsTableHtml'
                value = "<table border='1' cellpadding='6' cellspacing='0' style='border-collapse:collapse;font-size:12px;'><thead><tr style='background:#f3f2f1;'>"
            }
        }

        For_Each_Column = @{
            type             = 'Foreach'
            foreach          = "@body('Query_InsightsData')?['tables']?[0]?['columns']"
            operationOptions = 'Sequential'
            runAfter         = @{
                Start_Table = @('Succeeded')
            }
            actions          = @{
                Append_Column_Header = @{
                    type     = 'AppendToStringVariable'
                    inputs   = @{
                        name  = 'ResultsTableHtml'
                        value = "@{concat('<th>', item()?['name'], '</th>')}"
                    }
                    runAfter = @{}
                }
            }
        }

        Append_Header_Close = @{
            type     = 'AppendToStringVariable'
            runAfter = @{
                For_Each_Column = @('Succeeded')
            }
            inputs   = @{
                name  = 'ResultsTableHtml'
                value = "</tr></thead><tbody>"
            }
        }

        For_Each_Row = @{
            type             = 'Foreach'
            foreach          = "@body('Query_InsightsData')?['tables']?[0]?['rows']"
            operationOptions = 'Sequential'
            runAfter         = @{
                Append_Header_Close = @('Succeeded')
            }
            actions          = @{
                Start_Row = @{
                    type     = 'AppendToStringVariable'
                    inputs   = @{
                        name  = 'ResultsTableHtml'
                        value = "@{if(equals(last(items('For_Each_Row')), 'CRITICAL'), '<tr style=''background-color:#FFC7CE;color:#9C0006;''>', if(equals(last(items('For_Each_Row')), 'WARNING'), '<tr style=''background-color:#FFEB9C;color:#9C6500;''>', '<tr>'))}"
                    }
                    runAfter = @{}
                }
                For_Each_Cell = @{
                    type             = 'Foreach'
                    foreach          = "@item()"
                    operationOptions = 'Sequential'
                    runAfter         = @{ Start_Row = @('Succeeded') }
                    actions          = @{
                        Append_Cell = @{
                            type     = 'AppendToStringVariable'
                            inputs   = @{
                                name  = 'ResultsTableHtml'
                                value = "@{concat('<td>', if(and(not(equals(item(), null)), greater(length(string(item())), 19), startsWith(string(item()), '2'), contains(string(item()), 'T'), contains(string(item()), ':')), concat(convertTimeZone(string(item()), 'UTC', '$CustomerTimeZone', 'yyyy-MM-dd HH:mm:ss'), ' ($CustomerTzAbbrev)'), if(equals(item(), null), '', string(item()))), '</td>')}"
                            }
                            runAfter = @{}
                        }
                    }
                }
                End_Row = @{
                    type     = 'AppendToStringVariable'
                    runAfter = @{ For_Each_Cell = @('Succeeded') }
                    inputs   = @{ name = 'ResultsTableHtml'; value = "</tr>" }
                }
            }
        }

        Append_Table_End = @{
            type     = 'AppendToStringVariable'
            runAfter = @{
                For_Each_Row = @('Succeeded')
            }
            inputs   = @{
                name  = 'ResultsTableHtml'
                value = "</tbody></table>"
            }
        }

        Send_Detailed_Email = $sendEmailAction

        Response_Success = @{
            type     = 'Response'
            runAfter = @{
                Send_Detailed_Email = @('Succeeded')
            }
            inputs   = @{
                statusCode = 202
                body       = @{ status = 'accepted' }
            }
        }

        Response_Failure = @{
            type     = 'Response'
            runAfter = @{
                Send_Detailed_Email = @('Failed', 'TimedOut')
            }
            inputs   = @{
                statusCode = 500
                body       = @{ status = 'email_send_failed' }
            }
        }
    }
    outputs = @{}
}

$workflowProperties = @{
    definition = $workflowDefinition
    parameters = @{
        '$connections' = @{
            value = @{
                office365 = @{
                    connectionId   = $Office365ConnectionResourceId
                    connectionName = $Office365ConnectionName
                    id             = $Office365ManagedApiId
                }
            }
        }
    }
}

$body = @{
    identity   = @{ type = 'SystemAssigned' }
    location   = $Location
    tags       = $Tags
    properties = $workflowProperties
}

Write-Step "Deploying Logic App"
$workflowResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Logic/workflows/$LogicAppName"
$workflowTempFile = Join-Path $env:TEMP ("logicapp-{0}-{1}.json" -f $LogicAppName, [guid]::NewGuid().ToString('N'))
try {
    $body | ConvertTo-Json -Depth 100 | Set-Content -Path $workflowTempFile -Encoding utf8
    $deployResult = & az resource create `
        --id $workflowResourceId `
        --api-version 2019-05-01 `
        --is-full-object `
        --properties "@$workflowTempFile" `
        -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to deploy Logic App $LogicAppName`n$deployResult"
    }
}
finally {
    Remove-Item -Path $workflowTempFile -ErrorAction SilentlyContinue
}

# =========================
# Managed identity and RBAC
# =========================
Write-Step "Retrieving Logic App managed identity"
$logicApp = Invoke-AzCliJson -Arguments @(
    "resource", "show",
    "--resource-group", $ResourceGroupName,
    "--name", $LogicAppName,
    "--resource-type", "Microsoft.Logic/workflows"
)

if (-not $logicApp.identity -or -not $logicApp.identity.principalId) {
    throw "Managed identity was not found on Logic App $LogicAppName"
}
$principalId = $logicApp.identity.principalId
Write-Host "Logic App Managed Identity PrincipalId: $principalId"

Write-Step "Assigning Log Analytics Reader to Logic App managed identity"
& az role assignment create `
    --assignee-object-id $principalId `
    --assignee-principal-type ServicePrincipal `
    --role "Log Analytics Reader" `
    --scope $WorkspaceResourceId 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Warning "Role assignment may already exist or could not be created automatically. Verify that the Logic App managed identity has 'Log Analytics Reader' on: $WorkspaceResourceId"
    $RoleAssignmentStatus = "NeedsVerification"
}
else {
    Write-Host "Role assignment created successfully."
    $RoleAssignmentStatus = "CreatedOrExists"
}

# Verify role assignment
$verifyRoleJson = & az role assignment list `
    --assignee-object-id $principalId `
    --scope $WorkspaceResourceId `
    --role "Log Analytics Reader" `
    --query "[0].id" -o tsv 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($verifyRoleJson)) {
    throw "Role assignment verification failed. The Logic App managed identity does not have 'Log Analytics Reader' on: $WorkspaceResourceId. Assign this role manually before the Logic App can query Log Analytics."
}
if ($RoleAssignmentStatus -eq "NeedsVerification") {
    Write-Host "Role assignment verified (already existed)."
    $RoleAssignmentStatus = "AlreadyExists"
}

# =========================
# Webhook URL and Action Group
# =========================
Write-Step "Retrieving webhook URL"
$callbackValue = Invoke-AzCliText -Arguments @(
    "rest",
    "--method", "post",
    "--uri", "$workflowResourceId/triggers/manual/listCallbackUrl?api-version=2019-05-01",
    "--body", "{}",
    "--query", "value",
    "-o", "tsv"
)
if ([string]::IsNullOrWhiteSpace($callbackValue)) {
    throw "Failed to retrieve Logic App callback URL."
}

Write-Step "Ensuring detailed webhook action group"
Set-DetailedActionGroupWebhook `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ActionGroupName $DetailedActionGroupName `
    -ReceiverName $DetailedWebhookReceiverName `
    -ServiceUri $callbackValue
Write-Host "Detailed webhook action group '$DetailedActionGroupName' is configured."

# =========================
# Bootstrap Insights Alerts
# =========================
Write-Step "Ensuring AVD-Insights alerts exist (bootstrap if needed)"
Set-InsightsAlertsIfMissing `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -WorkspaceResourceGroupName $WorkspaceResourceGroupName `
    -WorkspaceName $WorkspaceName `
    -Location $Location `
    -DetailedActionGroupName $DetailedActionGroupName `
    -DetailedWebhookReceiverName $DetailedWebhookReceiverName `
    -DetailedResultsWebhookUrl $callbackValue

Write-Step "Switching AVD-Insights alerts to detailed-only action group"
Set-InsightsAlertsToDetailedOnly `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -DetailedActionGroupName $DetailedActionGroupName

# =========================
# Summary and CSV Report
# =========================
Write-Host ""
Write-Host "Deployment complete." -ForegroundColor Green
Write-Host ""
Write-Host "Webhook URL:"
Write-Host $callbackValue
Write-Host ""
Write-Host "Notes:"
Write-Host "1. The Office 365 API connection '$Office365ConnectionName' is auto-created if missing, but it must be authenticated in Azure Portal."
Write-Host "2. The Log Analytics workspace was resolved by name: $WorkspaceName"
Write-Host "3. Your Azure Monitor alert rule names should match one of the following definitions to use category-specific KQL:"
$alertDefinitions | ForEach-Object { Write-Host "   - $($_.Name)" }
Write-Host "4. If no rule name matches, the script uses the fallback Perf query."
Write-Host "5. Detailed webhook action group: $DetailedActionGroupName ($DetailedWebhookReceiverName)"
Write-Host "6. If AVD-Insights alerts were missing, they were auto-created via AVD-Insights-Alerts-Category-Alerts.ps1."
Write-Host "7. Existing AVD-Insights alerts were switched to detailed-only action group routing."

$ScriptEndTime = Get-Date
$ExecutionSeconds = [Math]::Round(($ScriptEndTime - $ScriptStartTime).TotalSeconds, 1)
$IdentityChange = if ([string]::IsNullOrWhiteSpace($principalId)) { "Unknown" } else { "LogicAppSystemAssignedManagedIdentity" }

$reportRows = @(
    [pscustomobject]@{
        TimestampUtc                = (Get-Date).ToUniversalTime().ToString("o")
        SubscriptionId              = $SubscriptionId
        ResourceGroupName           = $ResourceGroupName
        LogicAppName                = $LogicAppName
        Location                    = $Location
        WorkspaceName               = $WorkspaceName
        WorkspaceResourceGroupName  = $WorkspaceResourceGroupName
        DetailedActionGroupName     = $DetailedActionGroupName
        DetailedWebhookReceiverName = $DetailedWebhookReceiverName
        SendFromEmail               = $SendFromEmail
        SendToRecipients            = $SendToEmailValue
        WebhookUrl                  = $callbackValue
        LogicAppPrincipalId         = $principalId
        IdentityChange              = $IdentityChange
        Office365ConnectionStatus   = $Office365ConnectionStatus
        RoleAssignmentStatus        = $RoleAssignmentStatus
        ExecutionSeconds            = $ExecutionSeconds
        Result                      = "Success"
    }
)

try {
    $csvDirectory = Split-Path -Path $CsvPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($csvDirectory) -and -not (Test-Path -Path $csvDirectory)) {
        New-Item -Path $csvDirectory -ItemType Directory -Force | Out-Null
    }
    $reportRows | Export-Csv -Path $CsvPath -NoTypeInformation -Force
    Write-Host "CSV report written: $CsvPath" -ForegroundColor Green
}
catch {
    Write-Warning "Failed to write CSV report to '$CsvPath': $($_.Exception.Message)"
}


