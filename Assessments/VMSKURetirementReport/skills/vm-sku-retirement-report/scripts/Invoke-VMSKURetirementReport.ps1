<#
.SYNOPSIS
    VMSKURetirementReport (read-only).
.DESCRIPTION
    Scans accessible Azure subscriptions, classifies every VM size against Microsoft Learn retirement evidence,
    recommends the closest current-generation same-CPU-vendor replacement, validates regional availability,
    subscription restrictions and VM-family quota, scores compatibility (0-100) and plans migration waves.

    Nothing is changed in Azure. Only Resource Graph, Resource SKUs, compute usage, (optionally) Azure Monitor
    metrics and the public Retail Prices API are read.

    Outputs (per run folder): assessment.json, vm-assessment.csv, candidates.csv, quota-impact.csv,
    retirement-evidence.json, executive-summary.md, detailed-report.md, index.html + per-subscription HTML, run.log
    (minimal header; account masked unless -IncludeOperatorAccount) and, with -KeepRawData, raw data under data/.
.PARAMETER TenantId
    Tenant to assess. Default: the Azure CLI default tenant. A different signed-in tenant is assessed with tenant-scoped
    tokens (Resource Graph REST), so the Azure CLI default subscription is never changed.
.PARAMETER SubscriptionId
    Limit the scan to these subscription IDs. Default: all enabled subscriptions of the signed-in tenant.
.PARAMETER Region
    Limit the scan to these Azure regions (e.g. eastus2).
.PARAMETER OutputPath
    Output folder. Default: reports\<tenant>\<UTC yyyy-MM-dd_HHmmss>-<run-id>-VMSKURetirementReport, two folders above
    the skill folder.
.PARAMETER HorizonMonths
    Planning horizon in months (12-120, default 36). Dated retirements this many months away or more are placed in the
    'Beyond Horizon' wave; Wave 1 (retired or under 12 months) is never deferred.
.PARAMETER OfflineCatalog
    Use the cached Microsoft retirement catalog (data/retirement-catalog.json) instead of fetching Microsoft Learn.
.PARAMETER QuotaSafetyPct
    Extra headroom added to the minimum quota increase, as % of the migration requirement (default 20).
.PARAMETER MaxCandidates
    Number of ranked recommendations per VM (1-3, default 3).
.PARAMETER IncludeRightsizing
    Pull Azure Monitor CPU / memory metrics for VMs with an action and flag potential rightsizing (separate column only).
.PARAMETER IncludePricing
    Kept for compatibility: retail pricing is now on by default. Informational pay-as-you-go monthly prices (public
    Retail Prices API, USD, 730 h); never used for ranking.
.PARAMETER SkipPricing
    Do not add pay-as-you-go monthly prices. Use this when https://prices.azure.com is not reachable or for a fully
    offline -FromSnapshot replay.
.PARAMETER CheckModernization
    Evaluate every VM for a suitable v7 or v6 SKU. The exact CLI spelling --check-modernization is also accepted.
    This is assessment-only and never changes Azure resources.
.PARAMETER AuthTimeoutSec
    Seconds to wait for an Azure CLI token before failing with sign-in guidance (default 60). Prevents hangs when a
    cached token has expired and az waits for interactive sign-in.
.PARAMETER AsOfDate
    Date used to compute months remaining (default: today).
.PARAMETER IncludeOperatorAccount
    Record the full signed-in account (UPN) in the console, run.log and assessment.json. By default it is masked
    (e.g. j****@contoso.com) because these outputs are shared.
.PARAMETER KeepRawData
    Also write the raw VM inventory and Resource SKU responses to <OutputPath>/data for audit. Off by default: they are
    the most detailed copy of the estate and are not needed to read the report.
.PARAMETER SaveSnapshot
    Record every Azure read of this run (subscriptions, inventory, Resource SKUs, quota for every subscription/region,
    Advisor / Service Health and, with -IncludeRightsizing, metrics) to <OutputPath>/snapshot so the run can be replayed
    later with -FromSnapshot. Access tokens are never written and the signed-in account is masked. The snapshot is a full
    copy of the estate inventory: treat it as confidential.
.PARAMETER FromSnapshot
    Replay a run folder (or its snapshot folder) captured with -SaveSnapshot instead of calling Azure. Every other option
    can change (for example --check-modernization, -HorizonMonths, -QuotaSafetyPct, -MaxCandidates); tenant, subscription
    and region scope come from the snapshot. -AsOfDate defaults to the capture's as-of date and the Microsoft retirement
    evidence captured with the snapshot is reused, so a replay reproduces the capture. A warning is shown when the
    snapshot is more than 7 days old. No Azure CLI sign-in is needed; only retail pricing (public Retail Prices API) goes
    online. Add -SkipPricing for a fully offline replay.
.PARAMETER HtmlIncludeOptionalModernization
    Also list VMs whose action is 'Modernization Optional' (older generations without an announced retirement) in the HTML
    VM tables, details and modernization view. By default the HTML lists only VMs with an announced retirement date and a
    required action. CSV, JSON and Markdown always include every VM.
.PARAMETER HtmlMaxVmDetails
    Maximum number of expandable per-VM detail blocks per subscription page (default 250, 0 = no limit), in wave order.
    Every VM stays in the summary tables, vm-assessment.csv, detailed-report.md and assessment.json; this only keeps very
    large subscription pages fast to open.
.EXAMPLE
    pwsh ./Invoke-VMSKURetirementReport.ps1
.EXAMPLE
    pwsh ./Invoke-VMSKURetirementReport.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000     -Region eastus2 -IncludeRightsizing
.EXAMPLE
    pwsh ./Invoke-VMSKURetirementReport.ps1 -SaveSnapshot -OutputPath C:\Reports\vm-sku\capture
    pwsh ./Invoke-VMSKURetirementReport.ps1 -FromSnapshot C:\Reports\vm-sku\capture --check-modernization -OfflineCatalog -OutputPath C:\Reports\vm-sku\replay
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$TenantId,
    [string[]]$SubscriptionId,
    [string[]]$Region,
    [string]$OutputPath,
    [ValidateRange(12, 120)][int]$HorizonMonths = 36,
    [switch]$OfflineCatalog,
    [ValidateRange(0, 200)][int]$QuotaSafetyPct = 20,
    [ValidateRange(1, 3)][int]$MaxCandidates = 3,
    [switch]$IncludeRightsizing,
    [ValidateRange(7, 93)][int]$RightsizingLookbackDays = 30,
    [switch]$IncludePricing,
    [switch]$SkipPricing,
    [Alias('check-modernization')][switch]$CheckModernization,
    [switch]$SkipHtml,
    [ValidateRange(1, 16)][int]$ThrottleLimit = 6,
    [ValidateRange(10, 600)][int]$AuthTimeoutSec = 60,
    [datetime]$AsOfDate = (Get-Date).Date,
    [switch]$IncludeOperatorAccount,
    [switch]$KeepRawData,
    [switch]$SaveSnapshot,
    [string]$FromSnapshot,
    [switch]$HtmlIncludeOptionalModernization,
    [ValidateRange(0, 100000)][int]$HtmlMaxVmDetails = 250,
    [Parameter(ValueFromRemainingArguments = $true, DontShow = $true)][string[]]$RemainingArguments
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Snapshot mode is passed to modules through process environment variables; always restore the caller's values.
$priorSnapshotEnv = @($env:VMSKU_SNAPSHOT_MODE, $env:VMSKU_SNAPSHOT_DIR)
$restoreSnapshotEnv = { $env:VMSKU_SNAPSHOT_MODE = $priorSnapshotEnv[0]; $env:VMSKU_SNAPSHOT_DIR = $priorSnapshotEnv[1] }
trap { & $restoreSnapshotEnv; break }
if ($PSVersionTable.PSVersion -lt [version]'7.2') { throw 'PowerShell 7.2 or later is required.' }
foreach ($arg in @($RemainingArguments)) {
    if ([string]::IsNullOrWhiteSpace($arg)) { continue }
    if ($arg -ceq '--check-modernization') { $CheckModernization = $true }
    else {
        $name = ($arg -replace '^-+', '') -replace '[:=].*$', ''
        $known = @($MyInvocation.MyCommand.Parameters.Keys | Where-Object { $_ -ieq $name } | Select-Object -First 1)
        if ($arg -like '--*' -and $known.Count) { throw "Unknown argument '$arg'. PowerShell parameters use a single dash: use -$($known[0]) instead." }
        throw "Unknown argument '$arg'."
    }
}
if ($IncludePricing -and $SkipPricing) { throw '-IncludePricing and -SkipPricing cannot be used together. Retail pricing is on by default; use -SkipPricing to turn it off.' }
$pricingEnabled = -not $SkipPricing
$pricingStatus = if ($pricingEnabled) { 'Done' } else { 'Skipped' }

$skillRoot = Split-Path $PSScriptRoot -Parent
foreach ($m in 'Common', 'Retirement', 'SkuCatalog', 'Inventory', 'Scoring', 'Candidates', 'Quota', 'Rightsizing', 'Assessment', 'Output') {
    Import-Module (Join-Path $PSScriptRoot "modules/$m.psm1") -Force -DisableNameChecking
}
$startTime = Get-Date

# -- Snapshot: record this run's Azure reads (-SaveSnapshot) or replay a previous capture (-FromSnapshot) --
if ($SaveSnapshot -and $FromSnapshot) { throw '-SaveSnapshot and -FromSnapshot cannot be used together.' }
$snapshot = $null; $snapshotDir = $null
if ($FromSnapshot) {
    $snapshotDir = @((Join-Path $FromSnapshot 'snapshot'), $FromSnapshot) | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'snapshot.json') -PathType Leaf } | Select-Object -First 1
    if (-not $snapshotDir) { throw "No snapshot found at '$FromSnapshot'. Point -FromSnapshot to a run folder created with -SaveSnapshot, or to its 'snapshot' subfolder." }
    $snapshotDir = (Resolve-Path -LiteralPath $snapshotDir).ProviderPath
    $snapshot = Get-Content -LiteralPath (Join-Path $snapshotDir 'snapshot.json') -Raw | ConvertFrom-Json
    $scopeText = { param($v) (@($v | Where-Object { $_ } | ForEach-Object { "$_".ToLowerInvariant() } | Sort-Object -Unique)) -join ', ' }
    foreach ($s in @(@{ N = 'TenantId'; V = $TenantId; C = $snapshot.TenantId }, @{ N = 'SubscriptionId'; V = $SubscriptionId; C = $snapshot.SubscriptionId }, @{ N = 'Region'; V = $Region; C = $snapshot.Region })) {
        if ($PSBoundParameters.ContainsKey($s.N) -and (& $scopeText $s.V) -ne (& $scopeText $s.C)) {
            throw "-$($s.N) does not match the snapshot scope ($(if (& $scopeText $s.C) { & $scopeText $s.C } else { 'all' })). Omit it to reuse the captured scope, or capture a new snapshot."
        }
    }
    $TenantId = $snapshot.TenantId
    $capturedSubs = @($snapshot.SubscriptionId | Where-Object { $_ })
    $capturedRegions = @($snapshot.Region | Where-Object { $_ })
    $SubscriptionId = if ($capturedSubs.Count) { $capturedSubs } else { $null }
    $Region = if ($capturedRegions.Count) { $capturedRegions } else { $null }
    if (-not $PSBoundParameters.ContainsKey('AsOfDate')) {
        $AsOfDate = if ($snapshot.AsOfDate -is [datetime]) { $snapshot.AsOfDate.Date } else { [datetime]::ParseExact("$($snapshot.AsOfDate)", 'yyyy-MM-dd', [cultureinfo]::InvariantCulture) }
    }
    $snapshotCaptured = ([datetime]$snapshot.CapturedUtc).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC'
    $snapshotAgeDays = [int][math]::Floor(((Get-Date).ToUniversalTime() - ([datetime]$snapshot.CapturedUtc).ToUniversalTime()).TotalDays)
    $env:VMSKU_SNAPSHOT_DIR = $snapshotDir; $env:VMSKU_SNAPSHOT_MODE = 'Replay'
}
elseif ($SaveSnapshot) {
    # Recorded to a temporary folder until the output folder (named after the tenant) exists.
    $snapshotDir = Join-Path ([System.IO.Path]::GetTempPath()) ('vmskuretirementreport-snapshot-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null
    $env:VMSKU_SNAPSHOT_DIR = $snapshotDir; $env:VMSKU_SNAPSHOT_MODE = 'Record'
}

# -- Preflight --
if (-not $FromSnapshot -and -not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) not found.' }
$acct = Invoke-AzJson -Arguments @('account', 'show') -AllowFailure
if (-not $acct) { throw "Not signed in. Run 'az login --tenant <tenant-id>' first." }
$ext = Invoke-AzJson -Arguments @('extension', 'show', '--name', 'resource-graph') -AllowFailure
if (-not $ext) { throw "Azure CLI extension 'resource-graph' is required: az extension add --name resource-graph" }

# Target tenant: -TenantId, else the Azure CLI default. A non-default tenant is reached with tenant-scoped tokens,
# so the user's default subscription is never changed.
$tenantId = if ($TenantId) { $TenantId.ToLowerInvariant() } else { $acct.tenantId.ToLowerInvariant() }
$crossTenant = $tenantId -ne $acct.tenantId.ToLowerInvariant()
$auth = Test-AzAuthentication -TenantId $(if ($crossTenant) { $tenantId } else { $null }) -TimeoutSec $AuthTimeoutSec
if (-not $auth.Ok) { throw "Azure CLI cannot get a token for tenant ${tenantId}: $($auth.Reason) Run: az login --tenant $tenantId" }

$allSubs = @(Invoke-AzJson -Arguments @('account', 'list', '--query', "[?tenantId=='$tenantId' && state=='Enabled'].{id:id,name:name,tenantDisplayName:tenantDisplayName,user:user.name}"))
$tenantName = @($allSubs | ForEach-Object { if ($_.PSObject.Properties.Name -contains 'tenantDisplayName') { $_.tenantDisplayName } } | Where-Object { $_ } | Select-Object -First 1)
$tenantName = if ($tenantName) { $tenantName[0] } elseif (-not $crossTenant -and $acct.PSObject.Properties.Name -contains 'tenantDisplayName' -and $acct.tenantDisplayName) { $acct.tenantDisplayName } else { $null }
if (-not $tenantName) {
    $tl = Invoke-AzJson -Arguments @('rest', '--method', 'get', '--url', 'https://management.azure.com/tenants?api-version=2022-12-01') -AllowFailure
    $te = if ($tl) { @($tl.value) | Where-Object { $_.tenantId -eq $tenantId } | Select-Object -First 1 } else { $null }
    $tenantName = if ($te -and $te.PSObject.Properties.Name -contains 'defaultDomain' -and $te.defaultDomain) { if ($te.displayName -and $te.displayName -notmatch [regex]::Escape($te.defaultDomain)) { "$($te.displayName) ($($te.defaultDomain))" } elseif ($te.displayName) { $te.displayName } else { $te.defaultDomain } } elseif ($te -and $te.displayName) { $te.displayName } else { $tenantId }
}
$accountName = if ($crossTenant -and $allSubs.Count -and $allSubs[0].user) { $allSubs[0].user } else { $acct.user.name }
# Outputs (console, run.log, assessment.json) are shared, so the operator's account is masked unless requested.
$accountDisplay = if ($IncludeOperatorAccount) { $accountName } else { Get-MaskedAccount $accountName }
if ($SubscriptionId) {
    $want = @($SubscriptionId | ForEach-Object { $_.ToLowerInvariant() })
    $subs = @($allSubs | Where-Object { $want -contains $_.id.ToLowerInvariant() })
    $missing = @($want | Where-Object { $_ -notin @($subs | ForEach-Object { $_.id.ToLowerInvariant() }) })
    if ($missing.Count) { Write-Warning "Subscriptions not accessible/enabled in tenant ${tenantName}: $($missing -join ', ')" }
}
else { $subs = $allSubs }
if ($subs.Count -eq 0) { throw "No enabled subscriptions in scope for tenant $tenantName. Sign in with: az login --tenant $tenantId" }
$subName = @{}; foreach ($s in $subs) { $subName[$s.id.ToLowerInvariant()] = $s.name }
$argTenant = if ($crossTenant) { $tenantId } else { $null }

$runStamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd_HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
if (-not $OutputPath) {
    $repositoryRoot = Split-Path (Split-Path $skillRoot -Parent) -Parent
    $OutputPath = Get-DefaultAssessmentOutputPath -RepositoryRoot $repositoryRoot -TenantName $tenantName -RunStamp $runStamp
}
elseif ((Test-Path -LiteralPath $OutputPath) -and @(Get-ChildItem -LiteralPath $OutputPath -Force -ErrorAction Stop).Count -gt 0) {
    throw "OutputPath '$OutputPath' already exists and is not empty. Choose a new directory to avoid mixing assessment runs."
}
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
if ($SaveSnapshot) {
    $finalSnapshotDir = Join-Path $OutputPath 'snapshot'
    Move-Item -LiteralPath $snapshotDir -Destination $finalSnapshotDir
    $snapshotDir = (Resolve-Path -LiteralPath $finalSnapshotDir).ProviderPath
    $env:VMSKU_SNAPSHOT_DIR = $snapshotDir
}
$rawDir = if ($KeepRawData) { Join-Path $OutputPath 'data' } else { $null }
if ($rawDir) { New-Item -ItemType Directory -Path $rawDir -Force | Out-Null }
# Minimal header: the default transcript header records the local user name, machine name and host command line.
Start-Transcript -Path (Join-Path $OutputPath 'run.log') -UseMinimalHeader -Force | Out-Null
try {
    Write-Host "Tenant: $tenantName ($tenantId)  Account: $accountDisplay$(if ($crossTenant) { '  [tenant-scoped; Azure CLI default unchanged]' })"
    Write-Host "Scope: $($subs.Count) subscription(s)$(if ($Region) { ", regions $($Region -join ',')" })  As of: $($AsOfDate.ToString('yyyy-MM-dd'))  Output: $(ConvertTo-DisplayPath $OutputPath)"
    Write-Host "VMSKURetirementReport v$(Get-ToolVersion)  Mode: READ-ONLY (no Azure resources are modified)" -ForegroundColor Green
    if ($FromSnapshot) {
        Write-Host "Data: replaying snapshot captured $snapshotCaptured, $snapshotAgeDays day(s) ago (no Azure calls; quota and availability are as of the capture)" -ForegroundColor Yellow
        if ($snapshotAgeDays -gt 7) { Write-Warning "The snapshot is $snapshotAgeDays days old. Quota, availability and inventory may have changed; capture a new snapshot before acting on quota or resize decisions." }
    }
    elseif ($SaveSnapshot) { Write-Host "Data: live; recording a snapshot to $(ConvertTo-DisplayPath $snapshotDir)" -ForegroundColor DarkGray }

    # -- Microsoft evidence --
    Write-Phase 'Retirement evidence (Microsoft Learn)'
    $snapshotCatalogPath = if ($snapshotDir) { Join-Path $snapshotDir 'retirement-catalog.json' } else { $null }
    if ($FromSnapshot -and (Test-Path -LiteralPath $snapshotCatalogPath) -and $snapshot.PSObject.Properties.Name -contains 'CatalogSource') {
        # Replay the Microsoft evidence captured with the snapshot, labelled as it was at capture, so results are reproducible.
        $catalogResult = Get-RetirementCatalog -SeriesMapPath (Join-Path $skillRoot 'data/series-map.json') -CachePath $snapshotCatalogPath -Offline
        $catalogResult.Source = $snapshot.CatalogSource
        $catalogResult.Warning = $null
    }
    else {
        $catalogResult = Get-RetirementCatalog -SeriesMapPath (Join-Path $skillRoot 'data/series-map.json') -CachePath (Join-Path $skillRoot 'data/retirement-catalog.json') -Offline:$OfflineCatalog
    }
    if ($SaveSnapshot) { $catalogResult.Catalog | ConvertTo-Json -Depth 20 | Out-File -LiteralPath $snapshotCatalogPath -Encoding utf8 }
    $retCatalog = $catalogResult.Catalog
    Write-PhaseDone "$($catalogResult.Source); $(@($retCatalog.series).Count) series, $(@(Get-UnmappedSeriesNames -Catalog $retCatalog).Count) unmapped"
    foreach ($u in @(Get-UnmappedSeriesNames -Catalog $retCatalog)) { Write-Warning "Unmapped Microsoft series '$u' - VMs of this series will be 'Unable to Confirm'." }
    foreach ($n in @(Get-NonVmSizeEntries -Catalog $retCatalog)) { Write-Host "    note: Microsoft lifecycle entry that is not a VM size ($($n.Category)): $($n.Name) - $($n.Status) $($n.PlannedRetirementDate)" -ForegroundColor DarkGray }
    $procPath = Join-Path $skillRoot 'data/processor-catalog.json'
    $procCatalog = if (Test-Path $procPath) { Get-Content $procPath -Raw | ConvertFrom-Json -Depth 10 } else { Write-Warning 'processor-catalog.json missing; CPU vendor will be Partially Verified.'; $null }
    $weights = Get-Content (Join-Path $skillRoot 'data/scoring-weights.json') -Raw | ConvertFrom-Json

    # -- Inventory --
    $inventory = Get-EstateInventory -SubscriptionIds @($subs | ForEach-Object id) -Regions $Region -TenantId $argTenant
    $vms = @($inventory.Vms)
    if ($rawDir) { $vms | ConvertTo-Json -Depth 8 -Compress | Out-File (Join-Path $rawDir 'vm-inventory.json') -Encoding utf8 }

    # -- Lifecycle classification --
    Write-Phase 'Lifecycle classification'
    $lifecycleCache = @{}
    foreach ($sku in ($vms | ForEach-Object SkuName | Sort-Object -Unique)) {
        $lifecycleCache[$sku] = Resolve-SkuLifecycle -SkuName $sku -Catalog $retCatalog -AsOf $AsOfDate -CatalogSource $catalogResult.Source
    }
    $needs = @(if ($CheckModernization) { $vms } else { $vms | Where-Object { Test-NeedsCandidates -Lifecycle $lifecycleCache[$_.SkuName] } })
    Write-PhaseDone "$($lifecycleCache.Count) distinct sizes; $($needs.Count) VMs need replacement$(if ($CheckModernization) { ' / modernization' }) analysis"

    # -- SKU catalogs + quota (subscription-scoped where recommendations are needed) --
    $needPairs = @($needs | ForEach-Object { [pscustomobject]@{ SubscriptionId = $_.SubscriptionId; Region = $_.Region } } | Sort-Object SubscriptionId, Region -Unique)
    $allPairs = @($vms | ForEach-Object { [pscustomobject]@{ SubscriptionId = $_.SubscriptionId; Region = $_.Region } } | Sort-Object SubscriptionId, Region -Unique)
    Write-Phase "Resource SKUs (capabilities + restrictions): $($allPairs.Count) subscription/region pair(s)"
    $skuCatalogs = if ($allPairs.Count) { Get-SkuCatalogs -Pairs $allPairs -RawCacheDir $rawDir -ThrottleLimit $ThrottleLimit } else { @{} }
    $emptyCats = @($skuCatalogs.Keys | Where-Object { $skuCatalogs[$_].Count -eq 0 })
    foreach ($k in $emptyCats) { Write-Warning "No SKU data returned for $k (permissions or provider registration)." }
    Write-PhaseDone "$($skuCatalogs.Count) catalogs"
    # A snapshot records quota for every subscription/region so a replay can enable --check-modernization later.
    $quotaPairs = @(if ($SaveSnapshot) { $allPairs } else { $needPairs })
    Write-Phase "Compute quota usage: $($quotaPairs.Count) subscription/region pair(s)"
    $usage = if ($quotaPairs.Count) { Get-QuotaUsages -Pairs $quotaPairs -ThrottleLimit $ThrottleLimit } else { @{} }
    Write-PhaseDone "$(@($usage.Keys | Where-Object { $usage[$_] }).Count) with data"

    # -- Per-VM assessment --
    Write-Phase "Assessing $($vms.Count) VMs"
    $candidateCache = @{}
    $assessments = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($vm in $vms) {
        $i++
        if ($i % 100 -eq 0) { Write-Progress -Activity 'Assessing VMs' -Status "$i / $($vms.Count)" -PercentComplete ($i * 100 / $vms.Count) }
        $key = "$($vm.SubscriptionId)|$($vm.Region)".ToLowerInvariant()
        $cat = if ($skuCatalogs.ContainsKey($key) -and $skuCatalogs[$key].Count -gt 0) { $skuCatalogs[$key] } else { $null }
        $sn = $subName[$vm.SubscriptionId.ToLowerInvariant()]
        $assessments.Add((New-VmAssessment -Vm $vm -Lifecycle $lifecycleCache[$vm.SkuName] -RegionCatalog $cat -ProcessorCatalog $procCatalog -RetirementCatalog $retCatalog `
                    -LifecycleCache $lifecycleCache -CandidateCache $candidateCache -Weights $weights -AsOf $AsOfDate -SubscriptionName $(if ($sn) { $sn } else { $vm.SubscriptionId }) `
                    -MaxCandidates $MaxCandidates -CheckModernization:$CheckModernization))
    }
    Write-Progress -Activity 'Assessing VMs' -Completed
    Write-PhaseDone "$($candidateCache.Count) distinct candidate evaluations"

    # -- Aggregated quota impact --
    # Scopes, so optional work never inflates the quota needed for mandatory retirement migrations:
    #   Retirement               : retirement-affected + unconfirmed VMs, moving to their retirement target
    #   Retirement+Modernization : all VMs with an action, moving to Candidates.Primary (also drives QuotaStatus of non-affected VMs)
    #   Modernization            : -CheckModernization only; strategic v6/v7 target, steady-state and peak (side-by-side) demand
    Write-Phase 'Quota impact (aggregated per subscription / region / family)'
    foreach ($a in $assessments) { [void](Update-VmAction -Assessment $a -HorizonMonths $HorizonMonths) }
    if ($CheckModernization) {
        [void](Resolve-ModernizationQuotaChoices -Assessments $assessments.ToArray() -Usage $usage -SafetyPct $QuotaSafetyPct)
    }
    $toMoves = { param([object[]]$Set, [scriptblock]$Pick) @($Set | ForEach-Object {
                $chosen = & $Pick $_
                if (-not $chosen -or -not $chosen.Target) { return }
                [pscustomobject]@{
                    SubscriptionId = $_.Vm.SubscriptionId; Region = $_.Vm.Region; VmId = $_.Vm.Id
                    CurrentFamily = $_.Current.Family; CurrentVcpu = [int]$_.Current.vCPUs
                    TargetSku = $chosen.Target.SkuName; TargetFamily = $chosen.Target.Family; TargetVcpu = [int]$chosen.Target.vCPUs
                    IsAllocated = $_.Vm.IsAllocated; MigrationQuotaModel = $chosen.Model
                }
            }) }
    $pickPrimary = { param($a) @{ Target = $a.Candidates.Primary; Model = 'InPlace' } }
    $pickRetirement = { param($a)
        $existing = if ($a.Candidates.Modernization) { $a.Candidates.Modernization.ExistingRecommendation } else { $null }
        @{ Target = if ($existing) { $existing } else { $a.Candidates.Primary }; Model = 'InPlace' } }
    $pickModernization = { param($a) $i = Get-ModernizationTargetInfo -Assessment $a; @{ Target = $i.Target; Model = $i.MigrationQuotaModel } }

    $withPrimary = @($assessments | Where-Object { $_.Candidates -and $_.Candidates.Primary -and $_.Action -ne 'No Action Required' })
    $mandatory = @($withPrimary | Where-Object { $_.AffectedByRetirement -in 'Yes', 'Unknown' })
    $quotaRetirement = Measure-QuotaImpact -Moves @(& $toMoves $mandatory $pickRetirement) -Usage $usage -SafetyPct $QuotaSafetyPct -Scope 'Retirement'
    $quotaAll = Measure-QuotaImpact -Moves @(& $toMoves $withPrimary $pickPrimary) -Usage $usage -SafetyPct $QuotaSafetyPct -Scope 'Retirement+Modernization'
    # QuotaStatus / Readiness follow Candidates.Primary. When modernization promoted Primary away from the retirement
    # target, measure the mandatory set against Primary separately (not exported; Retirement rows stay lifecycle targets).
    $promoted = @($mandatory | Where-Object { $r = & $pickRetirement $_; $r.Target -and $r.Target.SkuName -ne $_.Candidates.Primary.SkuName })
    $quotaPrimaryMandatory = if ($promoted.Count -gt 0) { Measure-QuotaImpact -Moves @(& $toMoves $mandatory $pickPrimary) -Usage $usage -SafetyPct $QuotaSafetyPct } else { $quotaRetirement }
    $quotaModern = $null
    if ($CheckModernization) {
        $modernSet = @($assessments | Where-Object { $_.Candidates })
        $quotaModern = Measure-QuotaImpact -Moves @(& $toMoves $modernSet $pickModernization) -Usage $usage -SafetyPct $QuotaSafetyPct -Scope 'Modernization'
    }
    $scopes = @($quotaRetirement, $quotaAll) + @(if ($quotaModern) { $quotaModern })
    $quotaImpact = [pscustomobject]@{
        FamilyRows = @($scopes | ForEach-Object { $_.FamilyRows })
        RegionalRows = @($scopes | ForEach-Object { $_.RegionalRows })
    }
    $byVm = { param($result, $id) if ($result -and $result.ByVm.ContainsKey($id)) { $result.ByVm[$id] } else { $null } }
    foreach ($a in $assessments) {
        $id = $a.Vm.Id
        $q = if ($a.AffectedByRetirement -in 'Yes', 'Unknown') { & $byVm $quotaPrimaryMandatory $id } else { & $byVm $quotaAll $id }
        [void](Complete-VmAssessment -Assessment $a -QuotaResult $q -RetirementQuotaResult (& $byVm $quotaRetirement $id) `
                -ModernizationQuotaResult (& $byVm $quotaModern $id) -Usage $usage -HorizonMonths $HorizonMonths)
    }
    $increase = { param($result) if ($result) { @($result.FamilyRows + $result.RegionalRows | Where-Object Status -eq 'Quota Increase Required').Count } else { 0 } }
    $phase = "$(& $increase $quotaRetirement) retirement-scope quota(s) need an increase; $(& $increase $quotaAll) incl. modernization"
    if ($quotaModern) { $phase += "; $(& $increase $quotaModern) for v6/v7 targets ($(@($quotaModern.FamilyRows + $quotaModern.RegionalRows | Where-Object PeakStatus -eq 'Quota Increase Required').Count) at peak)" }
    Write-PhaseDone $phase
    # -- Optional: rightsizing --
    if ($IncludeRightsizing) {
        $targets = @($assessments | Where-Object { $_.Candidates -and $_.Candidates.Primary -and $_.Action -ne 'No Action Required' -and $_.Vm.PowerState -eq 'Running' })
        Write-Phase "Rightsizing telemetry (Azure Monitor, $RightsizingLookbackDays days): $($targets.Count) VMs"
        if ($targets.Count -eq 0) { Write-PhaseDone 'no running VMs with an action' }
        else { try {
            $util = Get-VmUtilization -Vms @($targets | ForEach-Object Vm) -LookbackDays $RightsizingLookbackDays -TenantId $argTenant
            foreach ($a in $targets) {
                $key = "$($a.Vm.SubscriptionId)|$($a.Vm.Region)".ToLowerInvariant()
                $a.Rightsizing = Get-RightsizingOpportunity -Utilization $util[$a.Vm.Id] -Primary $a.Candidates.Primary -RegionCatalog $skuCatalogs[$key] -MemoryGB $a.Current.MemoryGB
            }
            Write-PhaseDone "$(@($targets | Where-Object { $_.Rightsizing -and $_.Rightsizing.Status -eq 'Potential Rightsizing Opportunity' }).Count) potential opportunities"
        }
        catch { Write-Warning "Rightsizing telemetry unavailable: $($_.Exception.Message)" } }
    }

    # -- Optional: pricing --
    if ($pricingEnabled) {
        Write-Phase 'Retail pricing (informational, PAYGO USD)'
        foreach ($rg in ($assessments | Group-Object { $_.Vm.Region })) {
            $skuSet = @($rg.Group | ForEach-Object { $_.Vm.SkuName; if ($_.Candidates -and $_.Candidates.Primary) { $_.Candidates.Primary.SkuName; if ($_.Candidates.Secondary) { $_.Candidates.Secondary.SkuName } } } | Sort-Object -Unique)
            try { $prices = Get-RetailPrices -Region $rg.Name -SkuNames $skuSet }
            catch {
                # One unreachable-API warning instead of retrying every region; the report completes without prices.
                Write-Warning "Retail pricing unavailable, PAYGO columns left blank: $($_.Exception.Message) Use -SkipPricing to skip this step."
                $pricingStatus = 'Unavailable'
                break
            }
            foreach ($a in $rg.Group) {
                $os = if ($a.Vm.OsType -eq 'Windows') { 'Windows' } else { 'Linux' }
                $cur = $prices["$($a.Vm.SkuName.ToLowerInvariant())|$os"]
                $tgt = if ($a.Candidates -and $a.Candidates.Primary) { $prices["$($a.Candidates.Primary.SkuName.ToLowerInvariant())|$os"] } else { $null }
                $a.Pricing = [pscustomobject]@{
                    Os = $os; CurrentMonthly = if ($cur) { [math]::Round($cur * 730, 2) } else { $null }; TargetMonthly = if ($tgt) { [math]::Round($tgt * 730, 2) } else { $null }
                    Basis = 'Retail pay-as-you-go list price x 730 h; excludes EA/MCA discounts, reservations, savings plans, Azure Hybrid Benefit'
                }
            }
        }
        Write-PhaseDone $(if ($pricingStatus -eq 'Done') { '' } else { 'unavailable' })
    }
    Write-Phase 'Writing outputs'
    $summary = New-AssessmentSummary -Assessments $assessments.ToArray() -SubscriptionsScanned $subs.Count
    $run = [pscustomobject]@{
        GeneratedUtc = (Get-Date).ToUniversalTime().ToString('o'); AsOf = $AsOfDate; ToolVersion = (Get-ToolVersion)
        Tenant = [pscustomobject]@{ Id = $tenantId; Name = $tenantName }; Account = $accountDisplay
        DataSource = if ($snapshot) { "Snapshot captured $snapshotCaptured" } else { 'Live' }
        SnapshotAgeDays = if ($snapshot) { $snapshotAgeDays } else { $null }
        PricingStatus = $pricingStatus
        Parameters = [ordered]@{
            TenantId = $tenantId; SubscriptionId = $SubscriptionId; Region = $Region; HorizonMonths = $HorizonMonths; OfflineCatalog = [bool]$OfflineCatalog; QuotaSafetyPct = $QuotaSafetyPct
            MaxCandidates = $MaxCandidates; IncludeRightsizing = [bool]$IncludeRightsizing; RightsizingLookbackDays = $RightsizingLookbackDays; IncludePricing = $pricingEnabled; SkipPricing = [bool]$SkipPricing
            CheckModernization = [bool]$CheckModernization; IncludeOperatorAccount = [bool]$IncludeOperatorAccount; KeepRawData = [bool]$KeepRawData
            SaveSnapshot = [bool]$SaveSnapshot; FromSnapshot = [bool]$FromSnapshot
            HtmlIncludeOptionalModernization = [bool]$HtmlIncludeOptionalModernization; HtmlMaxVmDetails = $HtmlMaxVmDetails
        }
        Counts = $inventory.Counts
    }
    $rows = @(Export-AssessmentData -OutDir $OutputPath -Run $run -Assessments $assessments.ToArray() -Summary $summary -QuotaImpact $quotaImpact -CatalogResult $catalogResult -Inventory $inventory)
    Export-ExecutiveSummaryMarkdown -Path (Join-Path $OutputPath 'executive-summary.md') -Run $run -Summary $summary -Rows $rows -QuotaImpact $quotaImpact -CatalogResult $catalogResult
    Export-DetailedReportMarkdown -Path (Join-Path $OutputPath 'detailed-report.md') -Assessments $assessments.ToArray() -Run $run
    if (-not $SkipHtml) { Export-HtmlReports -OutDir $OutputPath -CssPath (Join-Path $skillRoot 'templates/report.css') -Run $run -Summary $summary -Assessments $assessments.ToArray() -QuotaImpact $quotaImpact -CatalogResult $catalogResult -ProcessorCatalog $procCatalog }
    Write-PhaseDone

    if ($SaveSnapshot) {
        # The manifest is written last, so an interrupted capture is never mistaken for a complete snapshot.
        [ordered]@{
            SnapshotVersion = 1; Tool = 'VMSKURetirementReport'; ToolVersion = (Get-ToolVersion); CapturedUtc = $startTime.ToUniversalTime().ToString('o')
            AsOfDate = $AsOfDate.ToString('yyyy-MM-dd'); TenantId = $tenantId; TenantName = $tenantName; CatalogSource = $catalogResult.Source
            SubscriptionId = @(if ($SubscriptionId) { $SubscriptionId }); Region = @(if ($Region) { $Region })
            Subscriptions = $subs.Count; Vms = $vms.Count; IncludeRightsizing = [bool]$IncludeRightsizing; RightsizingLookbackDays = $RightsizingLookbackDays
            Note = 'Raw Azure read responses (inventory, Resource SKUs, quota, Advisor / Service Health) and the Microsoft retirement evidence used. No access tokens; the signed-in account is masked. Treat as confidential inventory data.'
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $snapshotDir 'snapshot.json') -Encoding utf8
        Write-Host "Snapshot: $(ConvertTo-DisplayPath $snapshotDir) (replay with -FromSnapshot)" -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '==== Summary ====' -ForegroundColor Cyan
    $summary | Select-Object TotalSubscriptionsScanned, TotalVmsScanned, AffectedVms, AlreadyRetired, RetirementWithin12Months, RetirementWithin24Months, RetirementWithin36Months, ModernizationRecommended, ModernizationOptional, UnableToDetermine, VmsRequiringQuotaIncrease, VmsWithRegionalRestrictions, VmsRequiringCpuVendorChange, VmsRequiringManualReview, HighConfidence, MediumConfidence, LowConfidence | Format-List | Out-String | Write-Host
    Write-Host "Outputs: $(ConvertTo-DisplayPath $OutputPath)" -ForegroundColor Green
    Write-Host ("Elapsed: {0:N0}s" -f ((Get-Date) - $startTime).TotalSeconds)
}
finally {
    Stop-Transcript | Out-Null
    & $restoreSnapshotEnv
}
