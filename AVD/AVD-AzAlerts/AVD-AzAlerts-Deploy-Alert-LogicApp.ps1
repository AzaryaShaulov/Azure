#requires -Version 5.1
<#
==============================================================================
SCRIPT VERSION: 1.2
LAST UPDATED: March 12, 2026
REPOSITORY: https://github.com/AzaryaShaulov/AVD
DISCLAIMER: This script is provided AS IS, without warranties or support guarantees.
==============================================================================
.SYNOPSIS
    Deploys and configures the AVD Logic App webhook notification pipeline.

.DESCRIPTION
    Creates or updates the Logic App workflow, ensures the detailed webhook action group,
    validates and authorizes required API connections, and configures alert routing so
    AVD category alerts send detailed notifications through the webhook path.

.PARAMETER SubscriptionId
    Azure subscription ID to target. If omitted, uses the current Azure CLI context.

.PARAMETER ResourceGroupName
    Resource group where Logic App and related alert resources are deployed.

.PARAMETER LogicAppName
    Name of the Logic App workflow used for detailed AVD alert notifications.

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
    Existing API connection name for Office 365 (default: office365).

.PARAMETER DetailedActionGroupName
    Azure Monitor action group name for webhook-based detailed alerts.

.PARAMETER DetailedWebhookReceiverName
    Webhook receiver name created/updated inside the detailed action group.

.PARAMETER Tags
    Optional resource tags to apply to deployed resources.

.PARAMETER UseHardCodedDefaults
    Uses values from the internal $HardCoded map when provided.

.PARAMETER CsvPath
    Optional output path for post-run CSV summary report.
    If omitted, defaults to .\avd-webhook-deploy-report-<subscriptionPrefix>.csv.

.EXAMPLE
    .\AVD-Deploy-Alert-LogicApp.ps1 `
      -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
      -ResourceGroupName "rg-avd-monitoring" `
      -LogicAppName "AVD-alert-details" `
      -Location "eastus2" `
      -WorkspaceName "law-avd-prod" `
      -WorkspaceResourceGroupName "rg-avd-monitoring" `
      -SendToEmail "alerts@contoso.com" `
      -SendFromEmail "alerts@contoso.com" `
      -Office365ConnectionName "avd-alerts-office365"

    Deploy webhook-based detailed notifications using a single recipient.

.EXAMPLE
    .\AVD-Deploy-Alert-LogicApp.ps1 `
      -SubscriptionId "YOUR-SUBSCRIPTION-ID" `
      -ResourceGroupName "rg-avd-monitoring" `
      -LogicAppName "AVD-alert-details" `
      -Location "eastus2" `
      -WorkspaceName "law-avd-prod" `
      -WorkspaceResourceGroupName "rg-avd-monitoring" `
      -SendToEmails "avdops@contoso.com","noc@contoso.com" `
      -SendFromEmail "alerts@contoso.com" `
      -Office365ConnectionName "avd-alerts-office365"

    Deploy with multiple recipients using -SendToEmails.

.NOTES
    Script function summary:
    - Deploys/updates Logic App workflow resources used for detailed alert notifications.
    - Ensures AVD detailed action group webhook receiver is present and points to callback URL.
    - Assigns Log Analytics Reader to the Logic App managed identity for query access.
    - Verifies required AVD-Category alerts exist and bootstraps them when missing.
    - Applies detailed-only routing for AVD category alerts after webhook deployment.

    Operational notes:
    - Requires Azure CLI login and permissions for Logic App, Monitor, and IAM changes.
    - Office365 connection may require manual authorization in Azure Portal before emails flow.
    - Supports either -SendToEmail (single) or -SendToEmails (multiple recipients).
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId,

    [string]$ResourceGroupName,

    [string]$LogicAppName,

    [string]$Location,

    [string]$WorkspaceName,

    [string]$WorkspaceResourceGroupName,

    [string[]]$SendToEmails = @(),
    [string]$SendToEmail = "",

    [string]$SendFromEmail,

    [string]$Office365ConnectionName = "office365",
    [string]$DetailedActionGroupName = "AVD-Alerts-Detailed",
    [string]$DetailedWebhookReceiverName = "AVDAlertsDetailedWebhook",
    [string]$CsvPath = "",
    [hashtable]$Tags = @{},
    [switch]$UseHardCodedDefaults,

    # S1: by default the CSV report stores a masked Logic App webhook URL (signature redacted).
    # Set this switch to record the full URL including the SAS signature (treat the CSV as a secret).
    [switch]$IncludeFullCallbackUrl
)

$ErrorActionPreference = "Stop"
$ScriptStartTime = Get-Date

# B3(c): script-scope tracker for temp files plus a trap that removes any pending
# files if an unhandled error escapes a try/finally. Does NOT protect against
# SIGKILL/process abort (intentionally accepted residual risk).
$script:TempFilesToCleanup = New-Object System.Collections.Generic.List[string]
trap {
    foreach ($_pendingFile in $script:TempFilesToCleanup) {
        if ($_pendingFile -and (Test-Path -LiteralPath $_pendingFile)) {
            Remove-Item -LiteralPath $_pendingFile -Force -ErrorAction SilentlyContinue
        }
    }
    continue
}

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
    Office365ConnectionName     = "office365"
    DetailedActionGroupName     = "AVD-Alerts-Detailed"
    DetailedWebhookReceiverName = "AVDAlertsDetailedWebhook"
    Tags                        = @{
        Solution    = "AVD"
        Environment = "Prod"
    }
}

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

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return $Value.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
        return $DefaultValue.Trim()
    }

    throw "Missing required value for '$Name'. Provide it as a parameter or populate the hard-coded defaults and use -UseHardCodedDefaults."
}

function Get-AlertDefinitionMap {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Definitions
    )

    $map = @{}
    foreach ($definition in $Definitions) {
        $map[$definition.Name] = @{
            Description = $definition.Description
            Kql         = $definition.Kql
        }
    }

    return $map
}

function Invoke-AzCliJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $result = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP

    if ($exitCode -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')`n$($result | Out-String)"
    }

    if ([string]::IsNullOrWhiteSpace(($result | Out-String))) {
        return $null
    }

    return ($result | Out-String | ConvertFrom-Json)
}

function Invoke-AzCliText {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $result = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP

    if ($exitCode -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')`n$($result | Out-String)"
    }

    return ($result | Out-String).Trim()
}

function Set-DetailedActionGroupWebhook {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$ActionGroupName,
        [Parameter(Mandatory = $true)]
        [string]$ReceiverName,
        [Parameter(Mandatory = $true)]
        [string]$ServiceUri
    )

    $actionGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/microsoft.insights/actionGroups/$ActionGroupName"
    $actionGroupUri = "${actionGroupId}?api-version=2023-01-01"
    $actionGroupBody = @{
        location = 'Global'
        properties = @{
            groupShortName = 'AVDDetl'
            enabled = $true
            webhookReceivers = @(
                @{
                    name = $ReceiverName
                    serviceUri = $ServiceUri
                    useCommonAlertSchema = $true
                }
            )
        }
    }

    $tmpFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("action-group-{0}-{1}.json" -f $ActionGroupName, [guid]::NewGuid().ToString('N'))
    $script:TempFilesToCleanup.Add($tmpFile) | Out-Null
    try {
        $actionGroupBody | ConvertTo-Json -Depth 30 | Set-Content -Path $tmpFile -Encoding utf8
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
        $result = & az rest --method put --uri $actionGroupUri --body "@$tmpFile" -o json 2>&1
        $azExitCode = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
        if ($azExitCode -ne 0) {
            throw "Failed to create/update action group '$ActionGroupName'`n$($result | Out-String)"
        }
    }
    finally {
        Remove-Item -Path $tmpFile -ErrorAction SilentlyContinue
    }
}

function Set-AVDCategoryAlertsToDetailedOnly {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$DetailedActionGroupName
    )

    $detailedActionGroupId = Invoke-AzCliText -Arguments @(
        "monitor", "action-group", "show",
        "--resource-group", $ResourceGroupName,
        "--name", $DetailedActionGroupName,
        "--subscription", $SubscriptionId,
        "--query", "id",
        "-o", "tsv"
    )

    if ([string]::IsNullOrWhiteSpace($detailedActionGroupId)) {
        throw "Failed to resolve action group ID for '$DetailedActionGroupName'."
    }

    $alertNameOutput = Invoke-AzCliText -Arguments @(
        "monitor", "scheduled-query", "list",
        "--resource-group", $ResourceGroupName,
        "--subscription", $SubscriptionId,
        "--query", "[?starts_with(name, 'AVD-Category-')].name",
        "-o", "tsv"
    )

    if ([string]::IsNullOrWhiteSpace($alertNameOutput)) {
        Write-Warning "No existing AVD-Category alert rules were found in resource group '$ResourceGroupName'."
        return
    }

    $alertNames = $alertNameOutput -split "[\r\n]+" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() }

    $updated = 0
    $failed = @()
    foreach ($alertName in $alertNames) {
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
        $updateOutput = & az monitor scheduled-query update `
            --resource-group $ResourceGroupName `
            --name $alertName `
            --subscription $SubscriptionId `
            --action-groups $detailedActionGroupId 2>&1
        $updateExitCode = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP

        if ($updateExitCode -eq 0) {
            $updated++
            Write-Host "Updated '$alertName' to detailed-only action group." -ForegroundColor Gray
        }
        else {
            $failed += $alertName
            Write-Warning "Failed to update alert '$alertName' to detailed-only action group. $($updateOutput | Out-String)"
        }
    }

    if ($failed.Count -gt 0) {
        throw "Updated $updated alert(s), but failed to update $($failed.Count): $($failed -join ', ')"
    }

    Write-Host "All $updated AVD-Category alert(s) now use detailed-only action group '$DetailedActionGroupName'." -ForegroundColor Green
}

function Confirm-AVDCategoryAlertsExist {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceName,
        [Parameter(Mandatory = $true)]
        [string]$Location,
        [Parameter(Mandatory = $true)]
        [string]$DetailedActionGroupName,
        [Parameter(Mandatory = $true)]
        [string]$DetailedWebhookReceiverName,
        [Parameter(Mandatory = $true)]
        [string]$DetailedResultsWebhookUrl
    )

    # Guard: ensure scheduled-query extension is available before any az monitor scheduled-query calls
    & az extension show --name scheduled-query -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Installing 'scheduled-query' extension for bootstrap..." -ForegroundColor Yellow
        & az extension add --name scheduled-query --yes -o none 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Required Azure CLI extension 'scheduled-query' could not be installed."
        }
    }

    $existingAlertNamesOutput = Invoke-AzCliText -Arguments @(
        "monitor", "scheduled-query", "list",
        "--resource-group", $ResourceGroupName,
        "--subscription", $SubscriptionId,
        "--query", "[?starts_with(name, 'AVD-Category-')].name",
        "-o", "tsv"
    )

    $existingAlertNames = @()
    if (-not [string]::IsNullOrWhiteSpace($existingAlertNamesOutput)) {
        $existingAlertNames = $existingAlertNamesOutput -split "[\r\n]+" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() }
    }

    $requiredAlertNames = @(
        'AVD-Category-AuthenticationIdentity',
        'AVD-Category-AuthorizationPolicy',
        'AVD-Category-ConnectionNetworkGateway',
        'AVD-Category-SessionHostHealthCapacity',
        'AVD-Category-PersonalDesktopAssignment',
        'AVD-Category-DeviceGraphicsInput',
        'AVD-Category-FSLogixProfileStorage',
        'AVD-Category-UnknownUnclassified',
        'AVD-Category-ConnectionFailureRate',
        'AVD-Category-DisconnectionSpike',
        'AVD-Category-UnhealthyHosts',
        'AVD-Category-StaleHeartbeat',
        'AVD-Category-BandwidthDrop',
        'AVD-Category-RTTPerUser',
        'AVD-Category-SignInPhaseDelay',
        'AVD-Category-FrameQualityDegradation'
    )

    $missingAlertNames = $requiredAlertNames | Where-Object { $existingAlertNames -notcontains $_ }
    # B1(a): always invoke the Category script - it is the single owner of the action group
    # and idempotently skips existing alerts when -CreateOnly $true. Doing so removes the
    # double-write race vs. a separate Set-DetailedActionGroupWebhook PUT.
    if ($missingAlertNames.Count -eq 0) {
        Write-Host "All required AVD-Category alerts already exist; still invoking Category script idempotently to ensure action group + webhook are configured." -ForegroundColor Gray
    } else {
        Write-Host "Detected $($missingAlertNames.Count) missing AVD-Category alert(s). Bootstrapping core alerts via AVD-AzAlerts-Category-Alerts.ps1..." -ForegroundColor Yellow
    }

    $coreAlertsScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "AVD-AzAlerts-Category-Alerts.ps1"
    if (-not (Test-Path -Path $coreAlertsScriptPath)) {
        throw "Could not find AVD-AzAlerts-Category-Alerts.ps1 at '$coreAlertsScriptPath'."
    }

    # B4: $ErrorActionPreference is 'Stop' globally, so a child-script terminating error
    # will jump out before $LASTEXITCODE is read. Wrap in try/catch so we surface a clear
    # bootstrap-context message.
    try {
        & $coreAlertsScriptPath `
            -SubscriptionId $SubscriptionId `
            -ResourceGroup $ResourceGroupName `
            -WorkspaceResourceGroupName $WorkspaceResourceGroupName `
            -WorkspaceName $WorkspaceName `
            -Location $Location `
            -DetailedActionGroupName $DetailedActionGroupName `
            -DetailedWebhookReceiverName $DetailedWebhookReceiverName `
            -DetailedResultsWebhookUrl $DetailedResultsWebhookUrl `
            -CreateOnly $true
    }
    catch {
        throw "Bootstrap alert creation via AVD-AzAlerts-Category-Alerts.ps1 failed: $($_.Exception.Message)"
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Bootstrap alert creation via AVD-AzAlerts-Category-Alerts.ps1 returned exit code $LASTEXITCODE."
    }

    $postBootstrapOutput = Invoke-AzCliText -Arguments @(
        "monitor", "scheduled-query", "list",
        "--resource-group", $ResourceGroupName,
        "--subscription", $SubscriptionId,
        "--query", "[?starts_with(name, 'AVD-Category-')].name",
        "-o", "tsv"
    )

    $postBootstrapAlertNames = @()
    if (-not [string]::IsNullOrWhiteSpace($postBootstrapOutput)) {
        $postBootstrapAlertNames = $postBootstrapOutput -split "[\r\n]+" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() }
    }

    # FrameQualityDegradation is a preview alert that may be skipped if the table doesn't exist
    $optionalAlerts = @('AVD-Category-FrameQualityDegradation')
    $stillMissing = $requiredAlertNames | Where-Object {
        $postBootstrapAlertNames -notcontains $_ -and $optionalAlerts -notcontains $_
    }
    if ($stillMissing.Count -gt 0) {
        throw "Bootstrap completed but required alerts are still missing: $($stillMissing -join ', ')"
    }

    Write-Host "Bootstrap complete: required AVD-Category alerts now exist." -ForegroundColor Green
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

# Normalize recipients from both parameters. Supports either array input or ';' / ',' delimited strings.
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

# S3: validate every recipient against a strict regex and cap the list size to prevent abuse
# (e.g. a tampered config flooding email infrastructure). Limits come from the shared module.
$invalidRecipients = @($ResolvedSendToEmails | Where-Object { $_ -notmatch $Script:AvdEmailRegex })
if ($invalidRecipients.Count -gt 0) {
    throw "One or more recipients are not valid email addresses: $($invalidRecipients -join ', ')"
}
if ($ResolvedSendToEmails.Count -gt $Script:AvdMaxRecipients) {
    throw "Recipient count $($ResolvedSendToEmails.Count) exceeds the maximum allowed ($($Script:AvdMaxRecipients)). Reduce 'SendToEmails' or raise AvdMaxRecipients in AVD-AzAlerts-Common.ps1."
}

# A5 / S-3 follow-up: validate the sender address with the same regex applied to recipients.
if ($SendFromEmail -notmatch $Script:AvdEmailRegex) {
    throw "Invalid SendFromEmail address: '$SendFromEmail'. Provide a valid RFC 5321 mailbox."
}

# JSON-escape email values to prevent special characters from breaking workflow definition
$SendToEmailValue = (($ResolvedSendToEmails | ForEach-Object { $_ -replace '\\', '\\' -replace '"', '\"' }) -join ';')
$SendFromEmail = $SendFromEmail -replace '\\', '\\' -replace '"', '\"'

if ([string]::IsNullOrWhiteSpace($Office365ConnectionName)) {
    $Office365ConnectionName = "office365"
}
if ([string]::IsNullOrWhiteSpace($DetailedActionGroupName)) {
    $DetailedActionGroupName = "AVD-Alerts-Detailed"
}
if ([string]::IsNullOrWhiteSpace($DetailedWebhookReceiverName)) {
    $DetailedWebhookReceiverName = "AVDAlertsDetailedWebhook"
}
if (-not $Tags) {
    $Tags = @{}
}

if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    $subPrefix = if ($SubscriptionId.Length -ge 8) { $SubscriptionId.Substring(0, 8) } else { $SubscriptionId }
    # C7: build the path explicitly under the current working directory; the previous
    # ".\file.csv" form broke when the script was run from a different CWD on Linux/Cloud Shell.
    $CsvPath = Join-Path -Path (Get-Location).Path -ChildPath "avd-webhook-deploy-report-$subPrefix.csv"
}

$Office365ConnectionStatus = "Unknown"
$RoleAssignmentStatus = "Unknown"

# G1: trap unhandled errors anywhere in the deployment flow and persist a Failed row to the
# CSV report before re-throwing, so operators always have an audit trail even on partial failure.
try {

Write-Step "Checking Azure CLI login"
& az account show -o none 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Azure CLI is not logged in. Run 'az login' first."
}

Write-Step "Setting Azure subscription"
& az account set --subscription $SubscriptionId 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to set Azure subscription to $SubscriptionId"
}

Write-Step "Ensuring required CLI extension: scheduled-query"
& az extension show --name scheduled-query -o none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Installing 'scheduled-query' extension..." -ForegroundColor Yellow
    & az extension add --name scheduled-query --yes -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Required Azure CLI extension 'scheduled-query' could not be installed."
    }
    Write-Host "'scheduled-query' extension installed." -ForegroundColor Green
} else {
    Write-Host "'scheduled-query' extension is available." -ForegroundColor Gray
}

Write-Step "Ensuring Logic App resource group exists"
$rgExists = Invoke-AzCliText -Arguments @("group","exists","--name",$ResourceGroupName)
if ($rgExists -eq "false") {
    $tagArgs = @()
    if ($Tags.Count -gt 0) {
        $flatTags = $Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
        $tagArgs = @("--tags") + $flatTags
    }

    & az group create --name $ResourceGroupName --location $Location @tagArgs -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create resource group $ResourceGroupName"
    }
}

Write-Step "Resolving Log Analytics workspace by workspace name"
Write-Host "DEBUG: ResourceGroupName='$ResourceGroupName' WorkspaceResourceGroupName='$WorkspaceResourceGroupName' WorkspaceName='$WorkspaceName'" -ForegroundColor DarkGray

$workspace = $null
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "SilentlyContinue"
$workspaceShowJson = & az monitor log-analytics workspace show `
    --resource-group $WorkspaceResourceGroupName `
    --workspace-name $WorkspaceName `
    -o json 2>$null
$workspaceShowExit = $LASTEXITCODE
$ErrorActionPreference = $prevEAP

if ($workspaceShowExit -eq 0 -and -not [string]::IsNullOrWhiteSpace(($workspaceShowJson | Out-String))) {
    $workspace = $workspaceShowJson | Out-String | ConvertFrom-Json
}
else {
    Write-Warning "Workspace '$WorkspaceName' was not found in resource group '$WorkspaceResourceGroupName'. Searching the entire subscription by name..."

    $candidatesJson = & az resource list `
        --resource-type "Microsoft.OperationalInsights/workspaces" `
        --name $WorkspaceName `
        -o json 2>$null

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace(($candidatesJson | Out-String))) {
        $candidates = @($candidatesJson | Out-String | ConvertFrom-Json)
    }

    if ($candidates.Count -eq 0) {
        throw "Workspace '$WorkspaceName' was not found in subscription '$SubscriptionId'. Verify -WorkspaceName and that you are signed in to the correct tenant/subscription."
    }
    elseif ($candidates.Count -gt 1) {
        $candidateRgs = ($candidates | ForEach-Object { $_.resourceGroup }) -join ', '
        throw "Workspace name '$WorkspaceName' is ambiguous - found in multiple resource groups: $candidateRgs. Pass the correct -WorkspaceResourceGroupName explicitly."
    }
    else {
        $resolvedRg = $candidates[0].resourceGroup
        Write-Warning "Auto-resolved workspace '$WorkspaceName' to resource group '$resolvedRg' (you provided '$WorkspaceResourceGroupName'). Continuing with the resolved RG."
        $WorkspaceResourceGroupName = $resolvedRg

        $workspaceShowJson = & az monitor log-analytics workspace show `
            --resource-group $WorkspaceResourceGroupName `
            --workspace-name $WorkspaceName `
            -o json 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($workspaceShowJson | Out-String))) {
            throw "Failed to read workspace '$WorkspaceName' even after auto-resolving its resource group to '$WorkspaceResourceGroupName'."
        }
        $workspace = $workspaceShowJson | Out-String | ConvertFrom-Json
    }
}

if (-not $workspace) {
    throw "Workspace '$WorkspaceName' in resource group '$WorkspaceResourceGroupName' was not found."
}

$WorkspaceId = $workspace.customerId
$WorkspaceResourceId = $workspace.id

if ([string]::IsNullOrWhiteSpace($WorkspaceId) -or [string]::IsNullOrWhiteSpace($WorkspaceResourceId)) {
    throw "Could not resolve WorkspaceId or WorkspaceResourceId from workspace '$WorkspaceName'."
}

Write-Host "Workspace Name: $WorkspaceName"
Write-Host "Workspace GUID: $WorkspaceId"
Write-Host "Workspace Resource ID: $WorkspaceResourceId"

$Office365ConnectionResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/connections/$Office365ConnectionName"
$Office365ManagedApiId = "/subscriptions/$SubscriptionId/providers/Microsoft.Web/locations/$Location/managedApis/office365"

Write-Step "Ensuring Office 365 API connection exists"
$existingConnectionJson = $null
$existingConnectionExitCode = 1
try {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $existingConnectionJson = & az resource show --ids $Office365ConnectionResourceId -o json 2>&1
    $existingConnectionExitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
} catch {
    $existingConnectionExitCode = 1
    $ErrorActionPreference = $prevEAP
}

if ($existingConnectionExitCode -ne 0 -or [string]::IsNullOrWhiteSpace(($existingConnectionJson | Out-String))) {
    Write-Host "Office 365 connection '$Office365ConnectionName' not found - creating..."
    $connBody = @{
        location = $Location
        properties = @{
            displayName = $Office365ConnectionName
            api = @{ id = $Office365ManagedApiId }
        }
    }

    $connTmpFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("office365-connection-{0}.json" -f [guid]::NewGuid().ToString('N'))
    $script:TempFilesToCleanup.Add($connTmpFile) | Out-Null
    try {
        $connBody | ConvertTo-Json -Depth 30 | Set-Content -Path $connTmpFile -Encoding utf8
        $connUri = "${Office365ConnectionResourceId}?api-version=2016-06-01"
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
        $connCreateOutput = & az rest --method put --uri $connUri --body "@$connTmpFile" -o json 2>&1
        $connCreateExitCode = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
        if ($connCreateExitCode -ne 0) {
            throw "Failed to create Office 365 connection '$Office365ConnectionName'`n$($connCreateOutput | Out-String)"
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

$defaultAlertDefinitionName = "AVD-Category-DefaultFallback"

# Load shared constants and helpers (G10).
$commonPath = Join-Path -Path $PSScriptRoot -ChildPath 'AVD-AzAlerts-Common.ps1'
if (-not (Test-Path -Path $commonPath)) {
    throw "Required helper file not found: $commonPath"
}
. $commonPath

# Reusable KQL fragment that builds a per-CorrelationId enrichment table from WVDConnections.
# Provides: ClientIPAddress, GatewayRegion, ClientOS/Type/Version (annotated), ClientCity/State/Country.
# Time placeholders {0}/{1} are substituted by the Logic App at runtime from the alert payload.
$connectionEnrichmentLet = Get-AvdConnEnrichmentLet
$MinSupportedClientVersion = $Script:AvdMinSupportedClientVersion
$ResultRowLimit = $Script:AvdMaxResultRows

# A2 (B-2): pick Log Analytics REST audience for the active Azure cloud (sovereign-cloud aware).
$logAnalyticsAudience = Get-AvdLogAnalyticsAudience
$logAnalyticsHost = ([uri]$logAnalyticsAudience).Host
Write-Host "Log Analytics audience: $logAnalyticsAudience (host=$logAnalyticsHost)" -ForegroundColor DarkGray

# Common projection for WVDErrors-based queries: keeps CorrelationId, joins enrichment, then projects
# the final column set including client geo + gateway + annotated client version.
# B1 fix: cast CorrelationId to string on the WVDErrors side so the lookup join key types match
# ConnEnrichment.CorrelationId (also string).
$commonProjection = @"
| extend ResourceName = tostring(split(column_ifexists('_ResourceId', ''), '/')[-1])
| extend CorrelationId = tostring(column_ifexists('CorrelationId', ''))
| lookup kind=leftouter ConnEnrichment on CorrelationId
| project
    TimeGenerated = column_ifexists('TimeGenerated', datetime(null)),
    UserName = column_ifexists('UserName', ''),
    Source = column_ifexists('Source', ''),
    Code = column_ifexists('Code', ''),
    CodeSymbolic = column_ifexists('CodeSymbolic', ''),
    Message = column_ifexists('Message', ''),
    Operation = column_ifexists('Operation', ''),
    ResourceName,
    ClientIPAddress,
    GatewayRegion,
    ClientCity,
    ClientState,
    ClientCountry,
    ClientOS,
    ClientType,
    ClientVersion
"@

$alertDefinitions = @(
    @{
        Name        = "AVD-Category-AuthenticationIdentity"
        Description = "Consolidated authentication and identity failures in AVD."
        Kql         = @"
$connectionEnrichmentLet
WVDErrors
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where CodeSymbolic in (
    'PasswordMustChange',
    'PasswordExpired',
    'InvalidAuthToken',
    'InvalidCredentials',
    'AccountLockedOut',
    'AccountDisabled',
    'LogonFailed',
    'AuthenticationLogonFailed',
    'NoAuthenticatingAuthority',
    'LocalSecurityAuthorityError'
)
$commonProjection
| order by TimeGenerated desc
| limit $ResultRowLimit
"@
    }

    @{
        Name        = "AVD-Category-AuthorizationPolicy"
        Description = "Consolidated authorization and logon rights failures in AVD."
        Kql         = @"
$connectionEnrichmentLet
WVDErrors
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where CodeSymbolic in (
    'ConnectionFailedUserNotAuthorized',
    'LogonTypeNotGranted',
    'NotAuthorizedForLogon'
)
$commonProjection
| order by TimeGenerated desc
| limit $ResultRowLimit
"@
    }

    @{
        Name        = "AVD-Category-ConnectionNetworkGateway"
        Description = "Consolidated AVD client, DNS, reverse connect, and gateway transport failures."
        Kql         = @"
$connectionEnrichmentLet
WVDErrors
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where CodeSymbolic in (
    'Client',
    'DnsLookupFailed',
    'GatewayServerNotFound',
    'ReverseConnectDnsLookupFailed',
    'ConnectionFailedClientConnectedTooLateReverseConnectionAlreadyClosed',
    'ConnectionFailedServerDisconnect',
    'ConnectionFailedClientDisconnect',
    'ReverseConnectSChannelFailure'
)
$commonProjection
| order by TimeGenerated desc
| limit $ResultRowLimit
"@
    }

    @{
        Name        = "AVD-Category-SessionHostHealthCapacity"
        Description = "Consolidated session host availability and capacity issues."
        Kql         = @"
$connectionEnrichmentLet
WVDErrors
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where CodeSymbolic in (
    'ConnectionFailedNoHealthyRdshAvailable',
    'SessionHostResourceNotAvailable',
    'OutOfMemory'
)
$commonProjection
| order by TimeGenerated desc
| limit $ResultRowLimit
"@
    }

    @{
        Name        = "AVD-Category-PersonalDesktopAssignment"
        Description = "Consolidated personal desktop assignment and startup failures."
        Kql         = @"
$connectionEnrichmentLet
WVDErrors
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where CodeSymbolic in (
    'ConnectionFailedPersonalDesktopFailedToBeStarted',
    'ConnectionFailedNoPreAssignedPersonalDesktopForUser'
)
$commonProjection
| order by TimeGenerated desc
| limit $ResultRowLimit
"@
    }

    @{
        Name        = "AVD-Category-DeviceGraphicsInput"
        Description = "Consolidated input and graphics subsystem failures."
        Kql         = @"
$connectionEnrichmentLet
WVDErrors
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where CodeSymbolic in (
    'GetInputDeviceHandlesError',
    'GraphicsCapsNotReceived',
    'GraphicsSubsystemFailed',
    'DWMProcessAccessFailure'
)
$commonProjection
| order by TimeGenerated desc
| limit $ResultRowLimit
"@
    }

    @{
        Name        = "AVD-Category-FSLogixProfileStorage"
        Description = "Consolidated FSLogix profile and storage attach/detach/access issues."
        Kql         = @"
$connectionEnrichmentLet
WVDErrors
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where
    CodeSymbolic in (
        'ERROR_SHARING_VIOLATION',
        'UnloadWaitingForUserAction',
        'ERROR_ACCESS_DENIED',
        'ERROR_PATH_NOT_FOUND',
        'ERROR_FILE_NOT_FOUND',
        'ERROR_BAD_NETPATH',
        'ERROR_BAD_NET_NAME',
        'ERROR_NETNAME_DELETED',
        'ERROR_DISK_FULL',
        'ERROR_LOCK_VIOLATION'
    )
    or Source contains 'fslogix'
    or Message has_any (
        'frxsvc',
        'frxshell',
        'temporary profile',
        'default profile',
        'profile failed',
        'vhd attach',
        'vhdx attach',
        'container attach',
        'container detach',
        'odfc'
    )
$commonProjection
| order by TimeGenerated desc
| limit $ResultRowLimit
"@
    }

    @{
        Name        = "AVD-Category-UnknownUnclassified"
        Description = "Consolidated unknown or unclassified AVD error symbols for triage."
        Kql         = @"
$connectionEnrichmentLet
WVDErrors
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where CodeSymbolic == 'Unknown CodeSymbolic - review Message for details.'
$commonProjection
| order by TimeGenerated desc
| limit $ResultRowLimit
"@
    }

    # --- WVD Diagnostic Log alerts (non-WVDErrors tables) ---

    @{
        Name        = "AVD-Category-ConnectionFailureRate"
        Description = "Spike in failed connections per host pool from WVDConnections."
        Kql         = @"
let MinSupportedClient = '$MinSupportedClientVersion';
WVDConnections
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where State == 'Failed'
| extend HostPool = tostring(split(_ResourceId, '/')[-1])
| extend Geo = geo_info_from_ip_address(ClientIPAddress)
| extend ClientCity = tostring(Geo.city), ClientState = tostring(Geo.state), ClientCountry = tostring(Geo.country)
| extend ClientVersionDisplay = case(
    isempty(ClientVersion), '(unknown)',
    isnull(parse_version(ClientVersion)), ClientVersion,
    parse_version(ClientVersion) < parse_version(MinSupportedClient), strcat(ClientVersion, ' (outdated)'),
    ClientVersion)
| summarize FailedCount = count(),
            ClientIPAddress = any(ClientIPAddress),
            GatewayRegion = any(GatewayRegion),
            ClientCity = any(ClientCity),
            ClientState = any(ClientState),
            ClientCountry = any(ClientCountry),
            ClientOS = any(ClientOS),
            ClientType = any(ClientType),
            ClientVersion = any(ClientVersionDisplay)
        by HostPool, UserName
| where FailedCount > 5
| project HostPool, UserName, FailedCount,
          ClientIPAddress, GatewayRegion, ClientCity, ClientState, ClientCountry,
          ClientOS, ClientType, ClientVersion
| order by FailedCount desc
| limit $ResultRowLimit
"@
    }

    @{
        Name        = "AVD-Category-DisconnectionSpike"
        Description = "Abnormal disconnection rate across session hosts indicating infrastructure or network instability."
        Kql         = @"
let MinSupportedClient = '$MinSupportedClientVersion';
WVDConnections
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where State == 'Completed'
| where column_ifexists('ConnectionType', '') == 'Disconnected' or column_ifexists('IsReconnect', false) == true
| extend HostPool = tostring(split(_ResourceId, '/')[-1])
| extend Geo = geo_info_from_ip_address(ClientIPAddress)
| extend ClientCity = tostring(Geo.city), ClientState = tostring(Geo.state), ClientCountry = tostring(Geo.country)
| extend ClientVersionDisplay = case(
    isempty(ClientVersion), '(unknown)',
    isnull(parse_version(ClientVersion)), ClientVersion,
    parse_version(ClientVersion) < parse_version(MinSupportedClient), strcat(ClientVersion, ' (outdated)'),
    ClientVersion)
| summarize DisconnectCount = count(),
            UserName = any(UserName),
            ClientIPAddress = any(ClientIPAddress),
            GatewayRegion = any(GatewayRegion),
            ClientCity = any(ClientCity),
            ClientState = any(ClientState),
            ClientCountry = any(ClientCountry),
            ClientOS = any(ClientOS),
            ClientType = any(ClientType),
            ClientVersion = any(ClientVersionDisplay)
        by HostPool, SessionHostName
| where DisconnectCount > 10
| project HostPool, SessionHostName, DisconnectCount, UserName,
          ClientIPAddress, GatewayRegion, ClientCity, ClientState, ClientCountry,
          ClientOS, ClientType, ClientVersion
| order by DisconnectCount desc
| limit $ResultRowLimit
"@
    }

    @{
        Name        = "AVD-Category-UnhealthyHosts"
        Description = "Session hosts reporting non-Available status from WVDAgentHealthStatus."
        Kql         = @"
WVDAgentHealthStatus
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| summarize arg_max(TimeGenerated, *) by SessionHostName
| where Status != 'Available'
| extend HostPool = tostring(split(_ResourceId, '/')[-1])
| project HostPool, SessionHostName, Status, LastHeartBeat = TimeGenerated
| order by LastHeartBeat asc
| limit $ResultRowLimit
"@
    }

    @{
        Name        = "AVD-Category-StaleHeartbeat"
        Description = "Session hosts with stale agent heartbeat indicating communication failure or zombie hosts."
        Kql         = @"
WVDAgentHealthStatus
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| summarize arg_max(TimeGenerated, *) by SessionHostName
| where TimeGenerated < ago(5m)
| extend HostPool = tostring(split(_ResourceId, '/')[-1])
| extend StaleSinceMin = datetime_diff('minute', now(), TimeGenerated)
| project HostPool, SessionHostName, Status, StaleSinceMin
| order by StaleSinceMin desc
| limit $ResultRowLimit
"@
    }

    @{
        Name        = "AVD-Category-BandwidthDrop"
        Description = "Per-connection estimated bandwidth drops below threshold from WVDConnectionNetworkData."
        Kql         = @"
$connectionEnrichmentLet
WVDConnectionNetworkData
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| summarize P10BW = percentile(EstAvailableBandwidthKBps, 10) by CorrelationId
| where P10BW < 500
| join kind=inner (
    WVDConnections
    | where TimeGenerated between (datetime({0}) .. datetime({1}))
    | project CorrelationId, UserName, _ResourceId
) on CorrelationId
| extend HostPool = tostring(split(_ResourceId, '/')[-1])
| lookup kind=leftouter ConnEnrichment on CorrelationId
| project HostPool, UserName, SessionHostName = ClientSessionHost, P10BW_KBps = round(P10BW, 0),
          ClientIPAddress, GatewayRegion, ClientCity, ClientState, ClientCountry,
          ClientOS, ClientType, ClientVersion
| order by P10BW_KBps asc
| limit $ResultRowLimit
"@
    }

    @{
        Name        = "AVD-Category-RTTPerUser"
        Description = "Per-user P95 round-trip time exceeds threshold from WVDConnectionNetworkData."
        Kql         = @"
$connectionEnrichmentLet
WVDConnectionNetworkData
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| summarize P95RTT = percentile(EstRoundTripTimeInMs, 95) by CorrelationId
| where P95RTT > 200
| join kind=inner (
    WVDConnections
    | where TimeGenerated between (datetime({0}) .. datetime({1}))
    | project CorrelationId, UserName, _ResourceId
) on CorrelationId
| extend HostPool = tostring(split(_ResourceId, '/')[-1])
| lookup kind=leftouter ConnEnrichment on CorrelationId
| project HostPool, UserName, SessionHostName = ClientSessionHost, P95RTT_ms = round(P95RTT, 0),
          ClientIPAddress, GatewayRegion, ClientCity, ClientState, ClientCountry,
          ClientOS, ClientType, ClientVersion
| order by P95RTT_ms desc
| limit $ResultRowLimit
"@
    }

    @{
        Name        = "AVD-Category-SignInPhaseDelay"
        Description = "Prolonged sign-in phases detected from WVDCheckpoints (profile load, GPO, shell start)."
        Kql         = @"
$connectionEnrichmentLet
WVDCheckpoints
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| where Source == 'WVDConnections'
| where Name in ('OnConnected', 'ShellReady', 'LoadProfile', 'ApplyGroupPolicy')
| extend HostPool = tostring(split(_ResourceId, '/')[-1])
| extend DurationSec = datetime_diff('second', TimeGenerated, todatetime(tostring(Parameters.StartTime)))
| where DurationSec > 15
| extend CorrelationId = tostring(column_ifexists('CorrelationId', ''))
| lookup kind=leftouter ConnEnrichment on CorrelationId
| project HostPool, UserName, Name, DurationSec,
          SessionHostName = coalesce(tostring(Parameters.SessionHostName), ClientSessionHost),
          ClientIPAddress, GatewayRegion, ClientCity, ClientState, ClientCountry,
          ClientOS, ClientType, ClientVersion
| order by DurationSec desc
| limit $ResultRowLimit
"@
    }

    @{
        Name        = "AVD-Category-FrameQualityDegradation"
        Description = "[Preview] End-to-end frame delay or dropped frames exceeding threshold from ConnectionGraphicsData."
        Kql         = @"
$connectionEnrichmentLet
ConnectionGraphicsData
| where TimeGenerated between (datetime({0}) .. datetime({1}))
| summarize AvgFrameDelay = avg(EstEndToEndDelayInMs), DropPct = avg(FramesSkippedPercentage) by CorrelationId
| where AvgFrameDelay > 300 or DropPct > 15
| join kind=inner (
    WVDConnections
    | where TimeGenerated between (datetime({0}) .. datetime({1}))
    | project CorrelationId, UserName, _ResourceId
) on CorrelationId
| extend HostPool = tostring(split(_ResourceId, '/')[-1])
| lookup kind=leftouter ConnEnrichment on CorrelationId
| project HostPool, UserName, SessionHostName = ClientSessionHost,
          AvgFrameDelay_ms = round(AvgFrameDelay, 0), DroppedFramesPct = round(DropPct, 1),
          ClientIPAddress, GatewayRegion, ClientCity, ClientState, ClientCountry,
          ClientOS, ClientType, ClientVersion
| order by AvgFrameDelay_ms desc
| limit $ResultRowLimit
"@
    }

    # --- Fallback ---

    @{
        Name        = "AVD-Category-DefaultFallback"
        Description = "Fallback WVDErrors query when alert rule name is not mapped."
        Kql         = @"
$connectionEnrichmentLet
WVDErrors
| where TimeGenerated between (datetime({0}) .. datetime({1}))
$commonProjection
| order by TimeGenerated desc
| limit $ResultRowLimit
"@
    }
)

$alertDefinitionMap = Get-AlertDefinitionMap -Definitions $alertDefinitions
$alertDefinitionMapJson = $alertDefinitionMap | ConvertTo-Json -Depth 20 -Compress

$kqlQueryExpr = @"
@{replace(
    replace(
        coalesce(
            variables('AlertDefinitionMap')?[coalesce(triggerBody()?['data']?['essentials']?['alertRule'], '$defaultAlertDefinitionName')]?['Kql'],
            variables('AlertDefinitionMap')?['$defaultAlertDefinitionName']?['Kql']
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

$alertEmailHtmlExpr = @'
@{concat(
  '<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:13px;color:#242424;">',
  '<h2 style="margin-bottom:8px;">Azure Virtual Desktop Alert</h2>',

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

  '<h3 style="margin:14px 0 6px 0;">', coalesce(triggerBody()?['data']?['essentials']?['alertRule'], 'Query'), ' Results</h3>',
  variables('ResultsTableHtml'),

  '<h3 style="margin:18px 0 6px 0;">Troubleshooting Resources</h3>',
  '<p style="margin:4px 0;">&#128214; <a href="$AlertMatrixUrl" style="color:#0078D4;">Alert Matrix</a> &mdash; thresholds, categories, and tuning guide for all AVD alert signals</p>',
  '<p style="margin:4px 0;">&#128736; <a href="$RunbookUrl" style="color:#0078D4;">Operational Runbook</a> &mdash; triage steps and resolution procedures for each alert category</p>',

  '</body></html>'
)}
'@

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
    'italynorth'         = @{ tz = 'W. Europe Standard Time';         abbrev = 'CET' }
    'polandcentral'      = @{ tz = 'Central European Standard Time';  abbrev = 'CET' }
    'spaincentral'       = @{ tz = 'Romance Standard Time';           abbrev = 'CET' }
    'israelcentral'      = @{ tz = 'Israel Standard Time';            abbrev = 'IST' }
    'qatarcentral'       = @{ tz = 'Arabian Standard Time';           abbrev = 'GST' }
    'mexicocentral'      = @{ tz = 'Central Standard Time (Mexico)';  abbrev = 'CT' }
    'newzealandnorth'    = @{ tz = 'New Zealand Standard Time';       abbrev = 'NZST' }
    'australiacentral'   = @{ tz = 'AUS Eastern Standard Time';       abbrev = 'AEST' }
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

# S4: HTML-encode every value substituted into the email template body to prevent
# stored-XSS via a malicious workspace/region name showing up in operator inboxes.
$alertEmailHtmlExpr = $alertEmailHtmlExpr.Replace('$WorkspaceName', (ConvertTo-AvdHtmlEncoded $WorkspaceName))
$alertEmailHtmlExpr = $alertEmailHtmlExpr.Replace('$WorkspaceId', (ConvertTo-AvdHtmlEncoded $WorkspaceId))
$alertEmailHtmlExpr = $alertEmailHtmlExpr.Replace('$CustomerTimeZone', (ConvertTo-AvdHtmlEncoded $CustomerTimeZone))
$alertEmailHtmlExpr = $alertEmailHtmlExpr.Replace('$CustomerTzAbbrev', (ConvertTo-AvdHtmlEncoded $CustomerTzAbbrev))

$repoBaseUrl     = "https://github.com/AzaryaShaulov/AVD/blob/main/AVD-AzAlerts"
$alertMatrixUrl  = "$repoBaseUrl/AVD-AzAlerts-Alerts-Matrix.md"
$runbookUrl      = "$repoBaseUrl/AVD-AzAlerts-Runbook.md"
$alertEmailHtmlExpr = $alertEmailHtmlExpr.Replace('$AlertMatrixUrl', $alertMatrixUrl)
$alertEmailHtmlExpr = $alertEmailHtmlExpr.Replace('$RunbookUrl', $runbookUrl)

$sendEmailAction = @{
    type = "ApiConnection"
    runAfter = @{
        Append_Table_End = @("Succeeded")
    }
    inputs = @{
        method = "post"
        path   = "/v2/Mail"
        host   = @{
            connection = @{
                name = "@parameters('`$connections')['office365']['connectionId']"
            }
        }
        body   = @{
            To         = $SendToEmailValue
            Subject    = "@{concat('AVD Alert - ', coalesce(triggerBody()?['data']?['essentials']?['alertRule'], 'WVDErrors'))}"
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
            inputs = @{
                method = 'POST'
            }
        }
    }

    actions = @{
        Initialize_ResultsTableHtml = @{
            type   = 'InitializeVariable'
            inputs = @{
                variables = @(
                    @{
                        name  = 'ResultsTableHtml'
                        type  = 'string'
                        value = '<p>No WVDErrors rows were returned for this alert window.</p>'
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
                    variables('AlertDefinitionMap')?[coalesce(triggerBody()?['data']?['essentials']?['alertRule'], '$defaultAlertDefinitionName')]?['Description'],
                    variables('AlertDefinitionMap')?['$defaultAlertDefinitionName']?['Description']
                )}"
            }
            runAfter = @{
                Initialize_AlertDescription = @('Succeeded')
            }
        }

        Query_WVDErrors = @{
            type     = 'Http'
            runAfter = @{
                Set_AlertDescriptionText = @('Succeeded')
            }
            inputs   = @{
                method         = 'POST'
                uri            = "https://$logAnalyticsHost/v1/workspaces/$WorkspaceId/query"
                headers        = @{
                    'Content-Type' = 'application/json'
                }
                body           = @{
                    query = $kqlQueryExpr
                }
                authentication = @{
                    type     = 'ManagedServiceIdentity'
                    audience = $logAnalyticsAudience
                }
            }
            limit   = @{
                timeout = 'PT2M'
            }
        }

        Start_Table = @{
            type     = 'SetVariable'
            runAfter = @{
                Query_WVDErrors = @('Succeeded')
            }
            inputs   = @{
                name  = 'ResultsTableHtml'
                value = "<table border='1' cellpadding='6' cellspacing='0' style='border-collapse:collapse;font-size:12px;'><thead><tr style='background:#f3f2f1;'>"
            }
        }

        For_Each_Column = @{
            type     = 'Foreach'
            foreach  = "@body('Query_WVDErrors')?['tables']?[0]?['columns']"
            operationOptions = 'Sequential'
            runAfter = @{
                Start_Table = @('Succeeded')
            }
            actions  = @{
                Append_Column_Header = @{
                    type   = 'AppendToStringVariable'
                    inputs = @{
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
            type     = 'Foreach'
            foreach  = "@body('Query_WVDErrors')?['tables']?[0]?['rows']"
            operationOptions = 'Sequential'
            runAfter = @{
                Append_Header_Close = @('Succeeded')
            }
            actions  = @{
                Start_Row = @{
                    type   = 'AppendToStringVariable'
                    inputs = @{
                        name  = 'ResultsTableHtml'
                        value = "<tr>"
                    }
                    runAfter = @{}
                }

                For_Each_Cell = @{
                    type     = 'Foreach'
                    foreach  = "@item()"
                    operationOptions = 'Sequential'
                    runAfter = @{
                        Start_Row = @('Succeeded')
                    }
                    actions  = @{
                        Append_Cell = @{
                            type   = 'AppendToStringVariable'
                            inputs = @{
                                name  = 'ResultsTableHtml'
                                value = "@{concat('<td>', if(and(not(equals(item(), null)), greater(length(string(item())), 19), startsWith(string(item()), '2'), contains(string(item()), 'T'), contains(string(item()), ':')), concat(convertTimeZone(string(item()), 'UTC', '$CustomerTimeZone', 'yyyy-MM-dd HH:mm:ss'), ' ($CustomerTzAbbrev)'), if(equals(item(), null), '', string(item()))), '</td>')}"
                            }
                            runAfter = @{}
                        }
                    }
                }

                End_Row = @{
                    type     = 'AppendToStringVariable'
                    runAfter = @{
                        For_Each_Cell = @('Succeeded')
                    }
                    inputs   = @{
                        name  = 'ResultsTableHtml'
                        value = "</tr>"
                    }
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
                body       = @{
                    status = 'accepted'
                }
            }
        }

        Response_Failure = @{
            type     = 'Response'
            runAfter = @{
                Send_Detailed_Email = @('Failed', 'TimedOut')
            }
            inputs   = @{
                statusCode = 500
                body       = @{
                    status = 'email_send_failed'
                }
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
    identity   = @{
        type = 'SystemAssigned'
    }
    location   = $Location
    tags       = $Tags
    properties = $workflowProperties
}

Write-Step "Deploying Logic App"
$workflowResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Logic/workflows/$LogicAppName"
$workflowTempFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("logicapp-{0}-{1}.json" -f $LogicAppName, [guid]::NewGuid().ToString('N'))
$script:TempFilesToCleanup.Add($workflowTempFile) | Out-Null
try {
    $body | ConvertTo-Json -Depth 100 | Set-Content -Path $workflowTempFile -Encoding utf8

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $deployResult = & az resource create `
        --id $workflowResourceId `
        --api-version 2019-05-01 `
        --is-full-object `
        --properties "@$workflowTempFile" `
        -o json 2>&1
    $deployExitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP

    if ($deployExitCode -ne 0) {
        throw "Failed to deploy Logic App $LogicAppName`n$($deployResult | Out-String)"
    }
}
finally {
    Remove-Item -Path $workflowTempFile -ErrorAction SilentlyContinue
}

Write-Step "Retrieving Logic App managed identity"
$logicApp = Invoke-AzCliJson -Arguments @(
    "resource","show",
    "--resource-group",$ResourceGroupName,
    "--name",$LogicAppName,
    "--resource-type","Microsoft.Logic/workflows"
)

if (-not $logicApp.identity -or -not $logicApp.identity.principalId) {
    throw "Managed identity was not found on Logic App $LogicAppName"
}

$principalId = $logicApp.identity.principalId
Write-Host "Logic App Managed Identity PrincipalId: $principalId"

Write-Step "Assigning Log Analytics Reader to Logic App managed identity"
# S9: managed-identity object IDs can take 30-60s to propagate to Microsoft Graph and ARM
# after the Logic App is first created. Retry the role creation a few times before giving up.
$roleCreateOutput = $null
$roleCreateExitCode = 1
$roleAttempts = 3
for ($attempt = 1; $attempt -le $roleAttempts; $attempt++) {
    try {
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
        $roleCreateOutput = & az role assignment create `
            --assignee-object-id $principalId `
            --assignee-principal-type ServicePrincipal `
            --role "Log Analytics Reader" `
            --scope $WorkspaceResourceId 2>&1
        $roleCreateExitCode = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
    } catch {
        $ErrorActionPreference = $prevEAP
    }
    if ($roleCreateExitCode -eq 0) { break }
    $stderrText = ($roleCreateOutput | Out-String)
    # Retry on transient propagation errors only.
    if ($stderrText -notmatch 'PrincipalNotFound|does not exist in the directory|cannot find the .* with id|Unknown user|UnknownPrincipal') {
        break
    }
    if ($attempt -lt $roleAttempts) {
        Write-Host "Role assignment attempt $attempt failed with transient propagation error; retrying in 10s..." -ForegroundColor Yellow
        Start-Sleep -Seconds 10
    }
}

if ($roleCreateExitCode -ne 0) {
    $roleCreateStr = ($roleCreateOutput | Out-String)
    # Only treat as fatal auth failure when az clearly says re-login is required.
    # Cloud Shell can emit transient Graph token warnings (e.g. "Timeout waiting
    # for token from portal. Audience: https://graph.microsoft.com/") even when
    # the role assignment actually succeeded, so we defer to the verification
    # step below instead of throwing on any 'authentication' substring.
    if ($roleCreateStr -match 'AADSTS\d+|InteractionRequired|Please run ''az login''|run `az login`|az login --scope') {
        throw "Azure CLI session has expired or requires interactive login. Run 'az login' and retry.`n$roleCreateStr"
    }
    Write-Warning "Role assignment command returned a non-zero exit code; will verify whether the assignment exists. Output:`n$roleCreateStr"
    $RoleAssignmentStatus = "NeedsVerification"
}
else {
    Write-Host "Role assignment created successfully."
    $RoleAssignmentStatus = "CreatedOrExists"
}

# Verify role assignment was actually applied. ARM cache propagation can take 5-30s
# after a successful create, so retry the verify a few times before declaring failure (A4).
$verifyRoleJson = $null
$verifyAttempts = 3
$verifySucceeded = $false
for ($vAttempt = 1; $vAttempt -le $verifyAttempts; $vAttempt++) {
    try {
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
        $verifyRoleJson = & az role assignment list `
            --assignee-object-id $principalId `
            --scope $WorkspaceResourceId `
            --role "Log Analytics Reader" `
            --query "[0].id" -o tsv 2>&1
        $verifyExitCode = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
    } catch {
        $verifyExitCode = 1
        $ErrorActionPreference = $prevEAP
    }
    if ($verifyExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace(($verifyRoleJson | Out-String))) {
        $verifySucceeded = $true
        break
    }
    if ($vAttempt -lt $verifyAttempts) {
        Write-Host "Role assignment verification attempt $vAttempt returned empty/error; retrying in 5s (ARM cache propagation)..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 5
    }
}
if (-not $verifySucceeded) {
    throw "Role assignment verification failed after $verifyAttempts attempts. The Logic App managed identity does not have 'Log Analytics Reader' on: $WorkspaceResourceId. Assign this role manually before the Logic App can query Log Analytics."
}
if ($RoleAssignmentStatus -eq "NeedsVerification") {
    Write-Host "Role assignment verified (already existed)."
    $RoleAssignmentStatus = "AlreadyExists"
}

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

# B1(a): action group is now managed exclusively by AVD-AzAlerts-Category-Alerts.ps1
# (invoked below via Confirm-AVDCategoryAlertsExist). The previous direct PUT via
# Set-DetailedActionGroupWebhook is removed to eliminate the double-write race.

Write-Step "Ensuring AVD-Category alerts exist (bootstrap if needed)"
Confirm-AVDCategoryAlertsExist `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -WorkspaceResourceGroupName $WorkspaceResourceGroupName `
    -WorkspaceName $WorkspaceName `
    -Location $Location `
    -DetailedActionGroupName $DetailedActionGroupName `
    -DetailedWebhookReceiverName $DetailedWebhookReceiverName `
    -DetailedResultsWebhookUrl $callbackValue

Write-Step "Switching AVD-Category alerts to detailed-only action group"
Set-AVDCategoryAlertsToDetailedOnly `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -DetailedActionGroupName $DetailedActionGroupName

Write-Host ""
Write-Host "Deployment complete." -ForegroundColor Green
Write-Host ""
$maskedCallbackUrl = if ($callbackValue -match '(https://[^?]+)') { $Matches[1] + '?sig=***' } else { '***' }
Write-Host "Webhook URL: $maskedCallbackUrl"
Write-Host "(Full URL stored in CSV report: $CsvPath)"
Write-Host ""
Write-Host "Notes:"
Write-Host "1. The Office 365 API connection '$Office365ConnectionName' is auto-created if missing, but it must be authenticated in Azure Portal."
Write-Host "2. The Log Analytics workspace was resolved by name: $WorkspaceName"
Write-Host "3. Your Azure Monitor alert rule names should match one of the following definitions to use category-specific KQL:"
$alertDefinitions | ForEach-Object { Write-Host "   - $($_.Name)" }
Write-Host "4. If no rule name matches, the script uses the fallback WVDErrors query."
Write-Host "5. Detailed webhook action group: $DetailedActionGroupName ($DetailedWebhookReceiverName)"
Write-Host "6. If AVD-Category alerts were missing, they were auto-created via AVD-AzAlerts-Category-Alerts.ps1."
Write-Host "7. Existing AVD-Category alerts were switched to detailed-only action group routing."

$ScriptEndTime = Get-Date
$ExecutionSeconds = [Math]::Round(($ScriptEndTime - $ScriptStartTime).TotalSeconds, 1)
$IdentityChange = if ([string]::IsNullOrWhiteSpace($principalId)) {
    "Unknown"
}
else {
    "LogicAppSystemAssignedManagedIdentity"
}

$reportRows = @(
    [pscustomobject]@{
        TimestampUtc = (Get-Date).ToUniversalTime().ToString("o")
        SubscriptionId = $SubscriptionId
        ResourceGroupName = $ResourceGroupName
        LogicAppName = $LogicAppName
        Location = $Location
        WorkspaceName = $WorkspaceName
        WorkspaceResourceGroupName = $WorkspaceResourceGroupName
        DetailedActionGroupName = $DetailedActionGroupName
        DetailedWebhookReceiverName = $DetailedWebhookReceiverName
        SendFromEmail = $SendFromEmail
        SendToRecipients = $SendToEmailValue
        # S1: persist the masked URL by default; only include the SAS-bearing URL when the
        # operator explicitly asks for it via -IncludeFullCallbackUrl (treat CSV as secret).
        WebhookUrl = if ($IncludeFullCallbackUrl) { $callbackValue } else { $maskedCallbackUrl }
        LogicAppPrincipalId = $principalId
        IdentityChange = $IdentityChange
        Office365ConnectionStatus = $Office365ConnectionStatus
        RoleAssignmentStatus = $RoleAssignmentStatus
        ExecutionSeconds = $ExecutionSeconds
        Result = "Success"
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

} # end G1 outer try
catch {
    $g1ErrorMessage = $_.Exception.Message
    Write-Host ""
    Write-Host "Deployment FAILED: $g1ErrorMessage" -ForegroundColor Red
    try {
        $failureCallback = if ($null -ne $callbackValue -and -not [string]::IsNullOrWhiteSpace($callbackValue)) {
            if ($IncludeFullCallbackUrl) { $callbackValue } else { ($callbackValue -replace '\?.*$', '?sig=***') }
        } else { "" }
        $failureExecSec = [Math]::Round(((Get-Date) - $ScriptStartTime).TotalSeconds, 1)
        $failureRow = [pscustomobject]@{
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
            WebhookUrl                  = $failureCallback
            LogicAppPrincipalId         = $principalId
            IdentityChange              = "Unknown"
            Office365ConnectionStatus   = $Office365ConnectionStatus
            RoleAssignmentStatus        = $RoleAssignmentStatus
            ExecutionSeconds            = $failureExecSec
            Result                      = "Failed: $g1ErrorMessage"
        }
        $csvDirectory = Split-Path -Path $CsvPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($csvDirectory) -and -not (Test-Path -Path $csvDirectory)) {
            New-Item -Path $csvDirectory -ItemType Directory -Force | Out-Null
        }
        $failureRow | Export-Csv -Path $CsvPath -NoTypeInformation -Force
        Write-Host "Failure CSV report written: $CsvPath" -ForegroundColor Yellow
    }
    catch {
        Write-Warning "Additionally failed to write failure CSV: $($_.Exception.Message)"
    }
    throw
}