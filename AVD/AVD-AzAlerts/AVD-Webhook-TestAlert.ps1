#requires -Version 5.1
<#
==============================================================================
SCRIPT VERSION: 1.2
LAST UPDATED: March 12, 2026
REPOSITORY: https://github.com/AzaryaShaulov/AVD
DISCLAIMER: This script is provided AS IS, without warranties or support guarantees.
==============================================================================
.SYNOPSIS
  Sends a sample Azure Monitor common alert schema payload to an AVD Logic App webhook.

.DESCRIPTION
  Retrieves the callback URL for the target Logic App trigger and posts a test payload
  that mimics an AVD alert. Useful for validating end-to-end detailed email notifications.

.NOTES
  Repository: https://github.com/AzaryaShaulov/AVD
  Support: This script is provided AS IS, without warranties or support guarantees.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ResourceGroup,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$LogicAppName,

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$TriggerName = 'manual'
)

$ErrorActionPreference = 'Stop'

function Write-Log {
  param([string]$Message, [string]$Color = 'White')
  $ts = Get-Date -Format 'HH:mm:ss'
  Write-Host "[$ts] $Message" -ForegroundColor $Color
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw 'Azure CLI not found. Install Azure CLI first.'
}

$account = az account show -o json 2>$null | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $null -eq $account) {
  throw "Not logged in to Azure. Run 'az login' first."
}

if ($SubscriptionId) {
  az account set --subscription $SubscriptionId -o none 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to set subscription '$SubscriptionId'."
  }
  $account = az account show -o json 2>$null | ConvertFrom-Json
}

$workflowResourceId = "/subscriptions/$($account.id)/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$LogicAppName"
$callbackEndpoint = "${workflowResourceId}/triggers/$TriggerName/listCallbackUrl?api-version=2019-05-01"

Write-Log "Resolving callback URL for $LogicAppName/$TriggerName..." 'Cyan'
$callbackUrl = az rest --method post --uri $callbackEndpoint --query value -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($callbackUrl)) {
  throw 'Failed to resolve callback URL.'
}

$payload = @{
  schemaId = 'azureMonitorCommonAlertSchema'
  data = @{
    essentials = @{
      alertRule = 'AVD-Test-SampleAlert'
      severity = 'Sev3'
      monitorCondition = 'Fired'
      firedDateTime = (Get-Date).ToString('o')
      description = 'Manual test sample alert from AVD-Webhook-TestAlert.ps1'
    }
    alertContext = @{
      SearchResults = @{
        tables = @(
          @{
            name = 'PrimaryResult'
            columns = @(
              @{ name = 'UserName'; type = 'string' },
              @{ name = 'CodeSymbolic'; type = 'string' },
              @{ name = 'Message'; type = 'string' }
            )
            rows = @(
              @('test.user@contoso.com', 'AccountLockedOut', 'Synthetic sample alert payload')
            )
          }
        )
      }
    }
  }
} | ConvertTo-Json -Depth 12

Write-Log 'Posting sample alert payload...' 'Cyan'
try {
  $resp = Invoke-WebRequest -Method Post -Uri $callbackUrl -ContentType 'application/json' -Body $payload -UseBasicParsing
  Write-Log "Sample alert accepted. HTTP status: $($resp.StatusCode)" 'Green'
  Write-Log "Callback URL used: $callbackUrl" 'Gray'
} catch {
  $msg = $_.Exception.Message
  throw "Sample alert post failed: $msg"
}
