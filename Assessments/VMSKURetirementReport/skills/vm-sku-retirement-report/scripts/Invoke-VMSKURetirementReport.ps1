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
    Add informational pay-as-you-go monthly prices (retail API, USD, 730 h). Never used for ranking.
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
.EXAMPLE
    pwsh ./Invoke-VMSKURetirementReport.ps1
.EXAMPLE
    pwsh ./Invoke-VMSKURetirementReport.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -Region eastus2 -IncludeRightsizing -IncludePricing
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
    [Alias('check-modernization')][switch]$CheckModernization,
    [switch]$SkipHtml,
    [ValidateRange(1, 16)][int]$ThrottleLimit = 6,
    [ValidateRange(10, 600)][int]$AuthTimeoutSec = 60,
    [datetime]$AsOfDate = (Get-Date).Date,
    [switch]$IncludeOperatorAccount,
    [switch]$KeepRawData,
    [Parameter(ValueFromRemainingArguments = $true, DontShow = $true)][string[]]$RemainingArguments
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
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

$skillRoot = Split-Path $PSScriptRoot -Parent
foreach ($m in 'Common', 'Retirement', 'SkuCatalog', 'Inventory', 'Scoring', 'Candidates', 'Quota', 'Rightsizing', 'Assessment', 'Output') {
    Import-Module (Join-Path $PSScriptRoot "modules/$m.psm1") -Force -DisableNameChecking
}
$startTime = Get-Date

# -- Preflight --
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) not found.' }
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
$rawDir = if ($KeepRawData) { Join-Path $OutputPath 'data' } else { $null }
if ($rawDir) { New-Item -ItemType Directory -Path $rawDir -Force | Out-Null }
# Minimal header: the default transcript header records the local user name, machine name and host command line.
Start-Transcript -Path (Join-Path $OutputPath 'run.log') -UseMinimalHeader -Force | Out-Null
try {
    Write-Host "Tenant: $tenantName ($tenantId)  Account: $accountDisplay$(if ($crossTenant) { '  [tenant-scoped; Azure CLI default unchanged]' })"
    Write-Host "Scope: $($subs.Count) subscription(s)$(if ($Region) { ", regions $($Region -join ',')" })  As of: $($AsOfDate.ToString('yyyy-MM-dd'))  Output: $(ConvertTo-DisplayPath $OutputPath)"
    Write-Host "VMSKURetirementReport v$(Get-ToolVersion)  Mode: READ-ONLY (no Azure resources are modified)" -ForegroundColor Green

    # -- Microsoft evidence --
    Write-Phase 'Retirement evidence (Microsoft Learn)'
    $catalogResult = Get-RetirementCatalog -SeriesMapPath (Join-Path $skillRoot 'data/series-map.json') -CachePath (Join-Path $skillRoot 'data/retirement-catalog.json') -Offline:$OfflineCatalog
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
    Write-Phase "Compute quota usage: $($needPairs.Count) subscription/region pair(s)"
    $usage = if ($needPairs.Count) { Get-QuotaUsages -Pairs $needPairs -ThrottleLimit $ThrottleLimit } else { @{} }
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
    # Two scopes so optional modernization never inflates the quota needed for mandatory retirement migrations:
    #   Retirement               : retirement-affected + unconfirmed VMs (used for their quota status)
    #   Retirement+Modernization : all VMs with an action (used for modernization VMs' quota status)
    Write-Phase 'Quota impact (aggregated per subscription / region / family)'
    foreach ($a in $assessments) { [void](Update-VmAction -Assessment $a -HorizonMonths $HorizonMonths) }
    if ($CheckModernization) {
        [void](Resolve-ModernizationQuotaChoices -Assessments $assessments.ToArray() -Usage $usage -SafetyPct $QuotaSafetyPct)
    }
    $toMove = { param($set) @($set | ForEach-Object {
                [pscustomobject]@{ SubscriptionId = $_.Vm.SubscriptionId; Region = $_.Vm.Region; VmId = $_.Vm.Id; CurrentFamily = $_.Current.Family; CurrentVcpu = [int]$_.Current.vCPUs
                    TargetSku = $_.Candidates.Primary.SkuName; TargetFamily = $_.Candidates.Primary.Family; TargetVcpu = [int]$_.Candidates.Primary.vCPUs; IsAllocated = $_.Vm.IsAllocated }
            }) }
    $withPrimary = @($assessments | Where-Object { $_.Candidates -and $_.Candidates.Primary -and $_.Action -ne 'No Action Required' })
    $mandatory = @($withPrimary | Where-Object { $_.AffectedByRetirement -in 'Yes', 'Unknown' })
    $quotaRequired = Measure-QuotaImpact -Moves @(& $toMove $mandatory) -Usage $usage -SafetyPct $QuotaSafetyPct
    $quotaAll = Measure-QuotaImpact -Moves @(& $toMove $withPrimary) -Usage $usage -SafetyPct $QuotaSafetyPct
    foreach ($r in @($quotaRequired.FamilyRows + $quotaRequired.RegionalRows)) { $r | Add-Member -NotePropertyName Scope -NotePropertyValue 'Retirement' -Force }
    foreach ($r in @($quotaAll.FamilyRows + $quotaAll.RegionalRows)) { $r | Add-Member -NotePropertyName Scope -NotePropertyValue 'Retirement+Modernization' -Force }
    $quotaImpact = [pscustomobject]@{
        FamilyRows = @($quotaRequired.FamilyRows) + @($quotaAll.FamilyRows)
        RegionalRows = @($quotaRequired.RegionalRows) + @($quotaAll.RegionalRows)
    }
    foreach ($a in $assessments) {
        $src = if ($a.AffectedByRetirement -in 'Yes', 'Unknown') { $quotaRequired } else { $quotaAll }
        $q = if ($src.ByVm.ContainsKey($a.Vm.Id)) { $src.ByVm[$a.Vm.Id] } else { $null }
        [void](Complete-VmAssessment -Assessment $a -QuotaResult $q -Usage $usage -HorizonMonths $HorizonMonths)
    }
    Write-PhaseDone "$(@($quotaRequired.FamilyRows + $quotaRequired.RegionalRows | Where-Object Status -eq 'Quota Increase Required').Count) retirement-scope quota(s) need an increase; $(@($quotaAll.FamilyRows + $quotaAll.RegionalRows | Where-Object Status -eq 'Quota Increase Required').Count) incl. modernization"

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
    if ($IncludePricing) {
        Write-Phase 'Retail pricing (informational, PAYGO USD)'
        foreach ($rg in ($assessments | Group-Object { $_.Vm.Region })) {
            $skuSet = @($rg.Group | ForEach-Object { $_.Vm.SkuName; if ($_.Candidates -and $_.Candidates.Primary) { $_.Candidates.Primary.SkuName; if ($_.Candidates.Secondary) { $_.Candidates.Secondary.SkuName } } } | Sort-Object -Unique)
            $prices = Get-RetailPrices -Region $rg.Name -SkuNames $skuSet
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
        Write-PhaseDone
    }

    # -- Outputs --
    Write-Phase 'Writing outputs'
    $summary = New-AssessmentSummary -Assessments $assessments.ToArray() -SubscriptionsScanned $subs.Count
    $run = [pscustomobject]@{
        GeneratedUtc = (Get-Date).ToUniversalTime().ToString('o'); AsOf = $AsOfDate; ToolVersion = (Get-ToolVersion)
        Tenant = [pscustomobject]@{ Id = $tenantId; Name = $tenantName }; Account = $accountDisplay
        Parameters = [ordered]@{
            TenantId = $tenantId; SubscriptionId = $SubscriptionId; Region = $Region; HorizonMonths = $HorizonMonths; OfflineCatalog = [bool]$OfflineCatalog; QuotaSafetyPct = $QuotaSafetyPct
            MaxCandidates = $MaxCandidates; IncludeRightsizing = [bool]$IncludeRightsizing; RightsizingLookbackDays = $RightsizingLookbackDays; IncludePricing = [bool]$IncludePricing
            CheckModernization = [bool]$CheckModernization; IncludeOperatorAccount = [bool]$IncludeOperatorAccount; KeepRawData = [bool]$KeepRawData
        }
        Counts = $inventory.Counts
    }
    $rows = @(Export-AssessmentData -OutDir $OutputPath -Run $run -Assessments $assessments.ToArray() -Summary $summary -QuotaImpact $quotaImpact -CatalogResult $catalogResult -Inventory $inventory)
    Export-ExecutiveSummaryMarkdown -Path (Join-Path $OutputPath 'executive-summary.md') -Run $run -Summary $summary -Rows $rows -QuotaImpact $quotaImpact -CatalogResult $catalogResult
    Export-DetailedReportMarkdown -Path (Join-Path $OutputPath 'detailed-report.md') -Assessments $assessments.ToArray() -Run $run
    if (-not $SkipHtml) { Export-HtmlReports -OutDir $OutputPath -CssPath (Join-Path $skillRoot 'templates/report.css') -Run $run -Summary $summary -Assessments $assessments.ToArray() -QuotaImpact $quotaImpact -CatalogResult $catalogResult -ProcessorCatalog $procCatalog }
    Write-PhaseDone

    Write-Host ''
    Write-Host '==== Summary ====' -ForegroundColor Cyan
    $summary | Select-Object TotalSubscriptionsScanned, TotalVmsScanned, AffectedVms, AlreadyRetired, RetirementWithin12Months, RetirementWithin24Months, RetirementWithin36Months, ModernizationRecommended, ModernizationOptional, UnableToDetermine, VmsRequiringQuotaIncrease, VmsWithRegionalRestrictions, VmsRequiringCpuVendorChange, VmsRequiringManualReview, HighConfidence, MediumConfidence, LowConfidence | Format-List | Out-String | Write-Host
    Write-Host "Outputs: $(ConvertTo-DisplayPath $OutputPath)" -ForegroundColor Green
    Write-Host ("Elapsed: {0:N0}s" -f ((Get-Date) - $startTime).TotalSeconds)
}
finally {
    Stop-Transcript | Out-Null
}
