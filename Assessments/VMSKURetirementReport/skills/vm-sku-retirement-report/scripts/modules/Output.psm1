Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Retirement.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Assessment.psm1') -DisableNameChecking

$script:DisclaimerWarranty = 'This assessment and its recommendations are provided "AS IS," without warranties or guarantees.'
$script:DisclaimerIndependence = 'This independently developed tool is not an official Microsoft product and is not supported or endorsed by Microsoft.'
$script:DisclaimerValidation = 'Findings, retirement timelines, SKU compatibility, and modernization recommendations are informational only. Users must verify all recommendations, regional availability, quotas, pricing, VM generation, storage compatibility, and migration requirements against current official Microsoft documentation before implementing production changes.'
$script:Disclaimer = "$script:DisclaimerWarranty $script:DisclaimerIndependence`n`n$script:DisclaimerValidation"
$script:RepositoryUrl = 'https://github.com/AzaryaShaulov/Azure'
# The name shown in the headers, titles and footers of the reports (the tool and its files keep the name VMSKURetirementReport).
$script:ReportName = 'Azure VM SKU Retirement Report'

# Export-Csv writes a zero-byte file, with no header, when there are no rows; typed consumers such as Power BI then fail on
# refresh. These lists give those files their header row. A test compares them with the row builders.
$script:CsvColumns = @{
    'vm-assessment' = @(
        'Subscription', 'SubscriptionId', 'ResourceGroup', 'VM', 'VmResourceId', 'Region', 'Zone', 'PowerState', 'OsType', 'HyperVGeneration', 'CurrentSku',
        'CurrentSkuGeneration', 'VmFamily', 'CpuVendor', 'CpuArchitecture', 'vCPU', 'MemoryGB', 'AffectedByRetirement', 'EvidenceClass', 'RetirementStatus',
        'RetirementDate', 'TimeRemaining', 'Urgency', 'RecommendedSku', 'RecommendedSkuGeneration', 'TargetCpuVendor', 'TargetCpuArchitecture', 'TargetvCPU',
        'TargetMemoryGB', 'CompatibilityScore', 'ScoreBand', 'CpuVendorPreserved', 'CpuVendorChangeRequired', 'RegionAvailable', 'CurrentVcpu',
        'CurrentMemoryGB', 'RecommendedVcpu', 'RecommendedMemoryGB', 'SkuRegionalAvailability', 'QuotaStatus', 'ModernizationStatus', 'RecommendationReason',
        'QuotaFamily', 'QuotaMinIncreaseFamily', 'QuotaMinIncreaseRegional', 'DeploymentReadiness', 'Confidence', 'Action', 'NextStep', 'Wave',
        'AlternativeSku', 'AlternativeScore', 'AlternativeReason', 'ThirdCandidateSku', 'NewerGenerationIfConverted', 'NoCandidateReason',
        'VendorChangeReason', 'MaterialDifferences', 'ValidationItems', 'RightsizingStatus', 'RightsizingSuggestedSku', 'CurrentMonthlyUSD',
        'TargetMonthlyUSD', 'MicrosoftSource', 'AnnouncementUrl', 'MigrationGuideUrl', 'DQ_RetirementDate', 'DQ_CpuVendor', 'DQ_RegionalAvailability',
        'DQ_Quota', 'DQ_PhysicalCapacity', 'LifecycleNotes', 'RetirementTargetSku', 'RetirementTargetGeneration', 'RetirementQuotaStatus',
        'ModernizationTargetSku', 'ModernizationTargetGeneration', 'ModernizationTargetSource', 'ModernizationPath', 'ModernizationComplexity',
        'ModernizationReadiness', 'ModernizationQuotaStatus', 'ModernizationPeakQuotaStatus', 'MigrationQuotaModel', 'RecommendedMigrationPath',
        'ModernizationValidationItems', 'LifecycleStage', 'ModernizationMaterialDifferences')
    'candidates'    = @(
        'Subscription', 'SubscriptionId', 'ResourceGroup', 'VM', 'Region', 'CurrentSku', 'Role', 'Variant', 'CandidateSku', 'QuotaFamily', 'Generation',
        'CpuVendor', 'CpuArchitecture', 'vCPU', 'MemoryGB', 'TempDiskGB', 'Availability', 'Score', 'Band', 'Rejected', 'RejectionReason', 'ReviewGates',
        'VendorPreserved', 'FamilyMatch', 'CapacityHeadroomPct', 'ExistingRecommendationCandidate', 'ModernizationCandidate', 'S_CpuVendor', 'S_Architecture',
        'S_Family', 'S_vCpu', 'S_Memory', 'S_MemPerVcpu', 'S_Storage', 'S_DiskThroughput', 'S_Network', 'S_NicDiskLimits', 'S_ZoneRegion', 'S_Other')
    'quota-impact'  = @(
        'SubscriptionId', 'Region', 'QuotaName', 'QuotaDisplayName', 'VmCount', 'TargetSkus', 'Limit', 'CurrentUsage', 'Remaining', 'RequiredVcpu',
        'RequiredVcpuAllocatedOnly', 'PostMigrationUsage', 'MinimumIncrease', 'RecommendedIncrease', 'RecommendedNewLimit', 'Status', 'DataQuality', 'Scope',
        'MigrationQuotaModel', 'SideBySideVmCount', 'SteadyStateRequiredVcpu', 'PeakMigrationRequiredVcpu', 'PeakPostMigrationUsage', 'PeakMinimumIncrease',
        'PeakRecommendedIncrease', 'PeakRecommendedNewLimit', 'PeakStatus')
}

function Export-CsvFile {
    param([AllowEmptyCollection()][object[]]$Rows, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$OutDir)
    $path = Join-Path $OutDir "$Name.csv"
    if (@($Rows).Count -gt 0) { @($Rows) | Export-Csv -Path $path -NoTypeInformation -Encoding utf8; return }
    ('"' + ($script:CsvColumns[$Name] -join '","') + '"') | Out-File -FilePath $path -Encoding utf8
}

function Add-ReportDisclaimerMarkdown {
    param([Parameter(Mandatory)][System.Text.StringBuilder]$Builder)
    [void]$Builder.AppendLine()
    [void]$Builder.AppendLine('## Disclaimer')
    [void]$Builder.AppendLine()
    [void]$Builder.AppendLine("**$script:DisclaimerWarranty** $script:DisclaimerIndependence")
    [void]$Builder.AppendLine()
    [void]$Builder.AppendLine($script:DisclaimerValidation)
}

function ConvertTo-SafeCsvValue {
    param([AllowNull()][object]$Value)
    if ($Value -isnot [string]) { return $Value }
    if ($Value -match '^[=\-+@\t\r]') { return "'" + $Value }
    return $Value
}

function ConvertTo-SafeCsvRows {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows)
    foreach ($row in $Rows) {
        $safe = [ordered]@{}
        foreach ($prop in $row.PSObject.Properties) { $safe[$prop.Name] = ConvertTo-SafeCsvValue $prop.Value }
        [pscustomobject]$safe
    }
}

function ConvertTo-MarkdownText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return (([string]$Value).Replace('\', '\\')) -replace '([`*_\[\]<>#|])', '\$1' -replace "`r?`n", ' '
}

function ConvertTo-CandidateSummary {
    param($C)
    if (-not $C) { return $null }
    [ordered]@{
        role = $C.Role; variant = $C.Variant; sku = $C.SkuName; quotaFamily = $C.Family; seriesKey = $C.SeriesKey; generation = $C.Generation
        cpuVendor = $C.CpuVendor; cpuArchitecture = $C.CpuArchitecture; cpuGeneration = $C.CpuGeneration; processors = @($C.Processors); vendorDataQuality = $C.VendorQuality
        vCpu = $C.vCPUs; memoryGB = $C.MemoryGB; tempDiskGB = $C.TempDiskGB; regionAvailability = $C.Availability; zoneAvailable = $C.ZoneAvailable
        compatibilityScore = $C.Score; scoreBand = $C.Band; scoreBreakdown = $C.ScoreBreakdown; capacityHeadroomPct = $C.CapacityHeadroomPct
        vendorPreserved = $C.VendorPreserved; familyMatch = $C.FamilyMatch; rejected = $C.Rejected; rejectionReason = $C.RejectionReason
        gates = @($C.Gates); materialDifferences = @($C.Differences | Where-Object { $_ })
    }
}

function ConvertTo-AssessmentJsonObject {
    param([Parameter(Mandatory)]$A)
    $vm = $A.Vm; $c = $A.Candidates
    [ordered]@{
        row            = ConvertTo-AssessmentRow $A
        vm             = $vm
        lifecycle      = $A.Lifecycle
        current        = [ordered]@{
            sku = $A.Current.SkuName; quotaFamily = $A.Current.Family; seriesKey = $A.Current.NameInfo.SeriesKey; generation = $A.Current.NameInfo.Version
            cpuVendor = $A.Current.Vendor; cpuArchitecture = $A.Current.Architecture; processors = @($A.Current.Processors)
            vCpu = $A.Current.vCPUs; memoryGB = $A.Current.MemoryGB; memoryPerVcpu = if ($A.Current.vCPUs -and $A.Current.MemoryGB) { [math]::Round($A.Current.MemoryGB / $A.Current.vCPUs, 2) } else { $null }
            tempDiskGB = $A.Current.TempDiskGB; premiumIO = $A.Current.PremiumIO; acceleratedNetworking = $A.Current.AcceleratedNetworking
            maxNics = $A.Current.MaxNICs; maxDataDisks = $A.Current.MaxDataDisks; uncachedDiskIops = $A.Current.UncachedDiskIOPS; uncachedDiskMBps = $A.Current.UncachedDiskMBps
            hyperVGenerations = @($A.Current.HyperVGenerations); diskControllerTypes = @($A.Current.DiskControllerTypes); zones = @($A.Current.Zones)
            capabilitiesSource = $A.Current.CapsSource
        }
        recommendation = if ($c) {
            [ordered]@{
                permittedSeries = $c.PermittedSeries; candidatesEvaluated = @($c.Candidates).Count
                vendorChangeRequired = $c.VendorChangeRequired; vendorChangeReason = $c.VendorChangeReason; noCandidateReason = $c.NoCandidateReason
                primary = ConvertTo-CandidateSummary $c.Primary; secondary = ConvertTo-CandidateSummary $c.Secondary; third = ConvertTo-CandidateSummary $c.Third
                secondaryReason = $A.SecondaryReason
                newerGenerationIfConverted = ConvertTo-CandidateSummary $c.FutureGeneration
            }
        } else { $null }
        modernization  = if ($A.Modernization) {
            [ordered]@{
                enabled = $A.Modernization.Enabled
                currentGeneration = $A.Modernization.CurrentGeneration
                recommendedSku = $A.Modernization.RecommendedSku
                recommendedGeneration = $A.Modernization.RecommendedGeneration
                cpuVendor = $A.Current.Vendor
                cpuArchitecture = $A.Current.Architecture
                region = $A.Vm.Region
                regionAvailability = $A.Modernization.Availability
                quotaStatus = $A.QuotaStatus
                status = $A.Modernization.Status
                reason = $A.Modernization.Reason
                candidate = ConvertTo-CandidateSummary $A.Modernization.Candidate
            }
        } else { $null }
        quota          = $A.Quota
        retirementQuota = $A.RetirementQuota
        modernizationQuota = $A.ModernizationQuota
        strategy       = if ($A.Strategy) {
            $st = [ordered]@{}
            foreach ($prop in $A.Strategy.PSObject.Properties) {
                # Assigned inside each branch (not as the value of an if expression) so an empty or one-item array is not unrolled.
                if ($prop.Name -in 'RetirementTarget', 'ModernizationTarget') { $st[$prop.Name] = ConvertTo-CandidateSummary $prop.Value }
                elseif ($prop.Name -in 'ValidationItems', 'TargetComparison') { $st[$prop.Name] = @($prop.Value) }
                else { $st[$prop.Name] = $prop.Value }
            }
            $st
        } else { $null }
        readiness      = $A.Readiness
        confidence     = $A.Confidence
        action         = $A.Action
        nextStep       = $A.NextStep
        wave           = $A.Wave
        dataQuality    = $A.DataQuality
        rightsizing    = $A.Rightsizing
        pricing        = $A.Pricing
    }
}

function Export-AssessmentData {
    <#
    .SYNOPSIS
        Writes assessment.json, vm-assessment.csv, candidates.csv, quota-impact.csv and retirement-evidence.json.
    #>
    param(
        [Parameter(Mandatory)][string]$OutDir,
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Assessments,
        [Parameter(Mandatory)]$Summary,
        $QuotaImpact,
        [Parameter(Mandatory)]$CatalogResult,
        $Inventory,
        [object[]]$CollectionIssues = @()
    )
    $rows = @($Assessments | ForEach-Object { ConvertTo-AssessmentRow $_ })
    Export-CsvFile -Rows @(ConvertTo-SafeCsvRows -Rows $rows) -Name 'vm-assessment' -OutDir $OutDir

    $candRows = foreach ($a in $Assessments) {
        if (-not $a.Candidates) { continue }
        foreach ($c in @($a.Candidates.Candidates)) {
            $bd = $c.ScoreBreakdown
            [pscustomobject][ordered]@{
                Subscription = $a.SubscriptionName; SubscriptionId = $a.Vm.SubscriptionId; ResourceGroup = $a.Vm.ResourceGroup; VM = $a.Vm.Name; Region = $a.Vm.Region
                CurrentSku = $a.Vm.SkuName; Role = $c.Role; Variant = $c.Variant; CandidateSku = $c.SkuName; QuotaFamily = $c.Family; Generation = $c.Generation
                CpuVendor = $c.CpuVendor; CpuArchitecture = $c.CpuArchitecture; vCPU = $c.vCPUs; MemoryGB = $c.MemoryGB; TempDiskGB = $c.TempDiskGB
                Availability = $c.Availability; Score = $c.Score; Band = $c.Band; Rejected = $c.Rejected; RejectionReason = $c.RejectionReason
                ReviewGates = ($c.ReviewGates -join ', '); VendorPreserved = $c.VendorPreserved; FamilyMatch = $c.FamilyMatch; CapacityHeadroomPct = $c.CapacityHeadroomPct
                ExistingRecommendationCandidate = $c.ExistingEligible; ModernizationCandidate = $c.ModernizationEligible
                S_CpuVendor = $bd.cpuVendor; S_Architecture = $bd.cpuArchitecture; S_Family = $bd.workloadFamily; S_vCpu = $bd.vCpu; S_Memory = $bd.memory
                S_MemPerVcpu = $bd.memoryPerVcpu; S_Storage = $bd.storageCapability; S_DiskThroughput = $bd.diskThroughput; S_Network = $bd.network
                S_NicDiskLimits = $bd.nicDiskLimits; S_ZoneRegion = $bd.zoneRegion; S_Other = $bd.otherFeatures
            }
        }
    }
    Export-CsvFile -Rows @(ConvertTo-SafeCsvRows -Rows @($candRows)) -Name 'candidates' -OutDir $OutDir

    $qRows = @()
    if ($QuotaImpact) { $qRows = @($QuotaImpact.FamilyRows) + @($QuotaImpact.RegionalRows) }
    Export-CsvFile -Rows @(ConvertTo-SafeCsvRows -Rows @($qRows)) -Name 'quota-impact' -OutDir $OutDir

    $evidence = [ordered]@{
        schemaVersion = '1.0'; generatedUtc = $Run.GeneratedUtc; catalogSource = $CatalogResult.Source; catalogWarning = $CatalogResult.Warning
        disclaimer = $script:Disclaimer
        microsoftSources = $CatalogResult.Catalog.sources; unmappedSeries = $CatalogResult.Catalog.unmappedSeries
        nonVmSizeEntries = @(Get-NonVmSizeEntries -Catalog $CatalogResult.Catalog)
        seriesEvidence = $CatalogResult.Catalog.series
        corroboration = [ordered]@{
            advisorServiceUpgradeAndRetirement = if ($Inventory) { @($Inventory.AdvisorSignals) } else { @() }
            serviceHealthRetirementEvents = if ($Inventory) { @($Inventory.ServiceHealthEvents) } else { @() }
        }
    }
    $evidence | ConvertTo-Json -Depth 20 | Out-File (Join-Path $OutDir 'retirement-evidence.json') -Encoding utf8

    $doc = [ordered]@{
        schemaVersion = '1.0'
        tool = 'VMSKURetirementReport'
        toolVersion = (Get-ToolVersion)
        generatedUtc = $Run.GeneratedUtc
        asOfDate = $Run.AsOf.ToString('yyyy-MM-dd')
        dataSource = if ($Run.PSObject.Properties.Name -contains 'DataSource' -and $Run.DataSource) { $Run.DataSource } else { 'Live' }
        pricingStatus = if ($Run.PSObject.Properties.Name -contains 'PricingStatus' -and $Run.PricingStatus) { $Run.PricingStatus } elseif ($Run.Parameters -is [System.Collections.IDictionary] -and $Run.Parameters['IncludePricing']) { 'Done' } else { 'Skipped' }
        tenant = $Run.Tenant
        signedInAccount = $Run.Account
        parameters = $Run.Parameters
        disclaimer = $script:Disclaimer
        catalog = [ordered]@{ source = $CatalogResult.Source; warning = $CatalogResult.Warning; sources = $CatalogResult.Catalog.sources; unmappedSeries = $CatalogResult.Catalog.unmappedSeries; nonVmSizeEntries = @(Get-NonVmSizeEntries -Catalog $CatalogResult.Catalog) }
        counts = $Run.Counts
        summary = $Summary
        quota = [ordered]@{ family = @(if ($QuotaImpact) { $QuotaImpact.FamilyRows }); regional = @(if ($QuotaImpact) { $QuotaImpact.RegionalRows }) }
        collectionIssues = @($CollectionIssues | ForEach-Object { [ordered]@{ subscriptionId = $_.SubscriptionId; region = $_.Region; api = $_.Api; message = $_.Message; effect = $_.Effect } })
        vms = @($Assessments | ForEach-Object { ConvertTo-AssessmentJsonObject $_ })
    }
    $doc | ConvertTo-Json -Depth 14 | Out-File (Join-Path $OutDir 'assessment.json') -Encoding utf8
    return $rows
}

function Format-MdCell { param($v) if ($null -eq $v -or "$v" -eq '') { '-' } else { ConvertTo-MarkdownText $v } }

function Format-MdTable {
    param([object[]]$Rows, [string[]]$Columns)
    if (-not $Rows -or $Rows.Count -eq 0) { return "_None._`n" }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('| ' + ($Columns -join ' | ') + ' |')
    [void]$sb.AppendLine('|' + (($Columns | ForEach-Object { '---' }) -join '|') + '|')
    foreach ($r in $Rows) { [void]$sb.AppendLine('| ' + (($Columns | ForEach-Object { Format-MdCell $r.$_ }) -join ' | ') + ' |') }
    return $sb.ToString()
}

function Export-ExecutiveSummaryMarkdown {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Run, [Parameter(Mandatory)]$Summary, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows, $QuotaImpact, $CatalogResult, [object[]]$CollectionIssues = @())
    $s = $Summary
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# $script:ReportName - Executive Summary")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("[Source repository]($script:RepositoryUrl) | $script:ReportName v$(Get-ToolVersion)")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("| Item | Value |`n|---|---|")
    [void]$sb.AppendLine("| Tenant | $(ConvertTo-MarkdownText $Run.Tenant.Name) (``$(ConvertTo-MarkdownText $Run.Tenant.Id)``) |")
    [void]$sb.AppendLine("| Assessment date (as of) | $($Run.AsOf.ToString('yyyy-MM-dd')) |")
    [void]$sb.AppendLine("| Generated (UTC) | $($Run.GeneratedUtc) |")
    [void]$sb.AppendLine("| Retirement evidence | $($CatalogResult.Source) - Microsoft Learn |")
    foreach ($src in @($CatalogResult.Catalog.sources)) { [void]$sb.AppendLine("| Source: $($src.Name) | [$($src.Url)]($($src.Url)) (updated $($src.UpdatedAt), retrieved $($src.RetrievedUtc)) |") }
    [void]$sb.AppendLine("| Horizon | $($Run.Parameters.HorizonMonths) months |")
    [void]$sb.AppendLine()
    if ($CatalogResult.Warning) { [void]$sb.AppendLine("> **Warning:** $($CatalogResult.Warning)`n") }
    $unmappedNames = @(Get-UnmappedSeriesNames -Catalog $CatalogResult.Catalog)
    if ($unmappedNames.Count -gt 0) { [void]$sb.AppendLine("> **Unmapped Microsoft series (not classified):** $($unmappedNames -join ', ')`n") }
    $nonVm = @(Get-NonVmSizeEntries -Catalog $CatalogResult.Catalog)
    if ($nonVm.Count -gt 0) { [void]$sb.AppendLine("> **Microsoft lifecycle entries that are not VM sizes (validate separately):** $((@($nonVm) | ForEach-Object { "$($_.Name) ($($_.Category), $($_.Status))" }) -join '; ')`n") }
    if (@($CollectionIssues).Count -gt 0) {
        [void]$sb.AppendLine('## Data collection issues')
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('Some data could not be collected, so the results for the affected scopes are incomplete. Fix the cause and run the assessment again. The same list is in `assessment.json` (`collectionIssues`).')
        [void]$sb.AppendLine()
        $issueRows = @($CollectionIssues | ForEach-Object { [pscustomobject]@{ Data = $_.Api; Subscription = $_.SubscriptionId; Region = $_.Region; Problem = $_.Message; Effect = $_.Effect } })
        [void]$sb.AppendLine((Format-MdTable -Rows $issueRows -Columns 'Data', 'Subscription', 'Region', 'Problem', 'Effect'))
    }

    [void]$sb.AppendLine('## Estate summary')
    [void]$sb.AppendLine()
    # The v6/v7 counters exist only when the modernization check ran; without it a 0 would read as "nothing to modernize".
    $modernizationRan = [bool](Get-RunParameter -Run $Run -Name 'CheckModernization' -Default $false)
    $ifChecked = { param($Value) if ($modernizationRan) { $Value } else { 'not evaluated' } }
    $kv = [ordered]@{
        'Total Subscriptions Scanned' = $s.TotalSubscriptionsScanned; 'Total VMs Scanned' = $s.TotalVmsScanned; 'Affected VMs (confirmed/announced retirement)' = $s.AffectedVms
        'VMs With an Action' = $s.ActionableVms
        'Already Retired' = $s.AlreadyRetired; 'Retirement Within 12 Months' = $s.RetirementWithin12Months; 'Retirement Within 12-24 Months' = $s.RetirementWithin24Months
        'Retirement Within 24-36 Months' = $s.RetirementWithin36Months; 'Retirement Beyond 36 Months' = $s.RetirementBeyond36Months
        'Modernization Recommended (Microsoft previous-gen)' = $s.ModernizationRecommended; 'Modernization Optional (action)' = $s.ModernizationOptional
        'v7 modernization target, any path' = (& $ifChecked $s.ModernizationTargetV7); 'v6 modernization target, any path' = (& $ifChecked $s.ModernizationTargetV6)
        'of which need Gen1 / NVMe conversion first: v7' = (& $ifChecked $s.ConvertibleToV7); 'of which need Gen1 / NVMe conversion first: v6' = (& $ifChecked $s.ConvertibleToV6)
        'Direct resize to v7 (every check passes)' = (& $ifChecked $s.ModernizeToV7); 'Direct resize to v6 (every check passes)' = (& $ifChecked $s.ModernizeToV6)
        'Already on v6/v7' = (& $ifChecked $s.AlreadyOnModernGeneration)
        'No Retirement Announced' = $s.NoRetirementAnnounced; 'Unable to Determine' = $s.UnableToDetermine
        'VMs Requiring Quota Increase' = $s.VmsRequiringQuotaIncrease; 'VMs With Regional Restrictions' = $s.VmsWithRegionalRestrictions
        'VMs Requiring CPU Vendor Change' = $s.VmsRequiringCpuVendorChange; 'VMs Requiring Manual Review' = $s.VmsRequiringManualReview
        'High Confidence Recommendations' = $s.HighConfidence; 'Medium Confidence Recommendations' = $s.MediumConfidence; 'Low Confidence Recommendations' = $s.LowConfidence
    }
    [void]$sb.AppendLine("| Metric | Count |`n|---|---:|")
    foreach ($k in $kv.Keys) { [void]$sb.AppendLine("| $k | $($kv[$k]) |") }
    [void]$sb.AppendLine()

    [void]$sb.AppendLine('## Migration waves')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('Waves 1-3 contain only VMs with Microsoft-confirmed or announced retirement dates. Wave 4 is optional modernization and is never mixed with retirement requirements.')
    [void]$sb.AppendLine()
    foreach ($wave in 'Wave 1 - Urgent', 'Wave 2 - Near Term', 'Wave 3 - Planned', 'Beyond Horizon', 'Review - Unconfirmed', 'Wave 4 - Modernization') {
        $wr = @($Rows | Where-Object Wave -eq $wave)
        if ($wr.Count -eq 0) { continue }
        [void]$sb.AppendLine("### $wave ($($wr.Count) VMs)")
        [void]$sb.AppendLine()
        $bySku = @($wr | Group-Object CurrentSku, RecommendedSku | Sort-Object Count -Descending | ForEach-Object {
                $f = $_.Group[0]
                [pscustomobject]@{ CurrentSku = $f.CurrentSku; LifecycleStage = $f.LifecycleStage; EvidenceClass = $f.EvidenceClass; RecommendedSku = $f.RecommendedSku; VMs = $_.Count
                    Ready = @($_.Group | Where-Object DeploymentReadiness -eq 'Ready').Count; QuotaIncrease = @($_.Group | Where-Object QuotaStatus -eq 'Quota Increase Required').Count
                    ManualReview = @($_.Group | Where-Object DeploymentReadiness -eq 'Manual Review Required').Count }
            })
        [void]$sb.AppendLine((Format-MdTable -Rows $bySku -Columns 'CurrentSku', 'LifecycleStage', 'EvidenceClass', 'RecommendedSku', 'VMs', 'Ready', 'QuotaIncrease', 'ManualReview'))
    }

    $groups = [ordered]@{
        'By subscription' = $s.BySubscription; 'By region' = $s.ByRegion; 'By current SKU' = $s.ByCurrentSku; 'By current SKU family' = $s.ByCurrentSkuFamily
        'By recommended SKU' = $s.ByRecommendedSku; 'By recommended SKU family' = $s.ByRecommendedSkuFamily; 'By CPU vendor' = $s.ByCpuVendor
        'By migration priority (action)' = $s.ByMigrationPriority; 'By deployment readiness' = $s.ByDeploymentReadiness
    }
    [void]$sb.AppendLine('## Groupings')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("Unless a heading says otherwise, each table counts only the VMs that have an action ($($s.ActionableVms) of $($s.TotalVmsScanned) VMs); VMs with no action required are not in it.")
    [void]$sb.AppendLine()
    $groupScope = @{ 'By migration priority (action)' = "all $($s.TotalVmsScanned) VMs" }
    foreach ($g in $groups.Keys) {
        $scopeNote = if ($groupScope.ContainsKey($g)) { " - $($groupScope[$g])" } else { '' }
        [void]$sb.AppendLine("### $g$scopeNote")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine((Format-MdTable -Rows @($groups[$g] | Select-Object -First 25) -Columns 'Key', 'Count'))
    }

    if ($QuotaImpact) {
        $need = @($QuotaImpact.FamilyRows + $QuotaImpact.RegionalRows | Where-Object Status -ne 'Quota OK')
        [void]$sb.AppendLine('## Quota actions')
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('Demand is aggregated for all VMs moving into the same subscription / region / family. Minimum increase = (current usage + required) - limit. Recommended increase adds the safety margin. Scope ''Retirement'' covers mandatory migrations to their retirement target; ''Retirement+Modernization'' also includes optional Wave 4 moves; ''Modernization'' (only with --check-modernization) covers the strategic v6/v7 targets with steady-state and peak demand.')
        [void]$sb.AppendLine()
        [void]$sb.AppendLine((Format-MdTable -Rows $need -Columns 'Scope', 'SubscriptionId', 'Region', 'QuotaDisplayName', 'QuotaName', 'Limit', 'CurrentUsage', 'RequiredVcpu', 'PostMigrationUsage', 'MinimumIncrease', 'RecommendedIncrease', 'Status'))
    }
    [void]$sb.AppendLine('## Data quality')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('- Retirement dates come only from Microsoft Learn (retired sizes list, previous-gen list, migration guide). No date is inferred. The dates are kept in the JSON and CSV outputs and are not shown in this report.')
    [void]$sb.AppendLine('- CPU vendor: Microsoft Learn size-series processor tables (Verified) or the Azure VM naming convention (Partially Verified).')
    [void]$sb.AppendLine('- Regional availability and restrictions: subscription-scoped Azure Resource SKUs API (Verified).')
    [void]$sb.AppendLine('- Physical regional capacity, nested virtualization use and temp-disk usage cannot be verified from the control plane (Unable to Verify).')
    Add-ReportDisclaimerMarkdown -Builder $sb
    Set-Content -Path $Path -Value $sb.ToString() -Encoding utf8
}

function Export-DetailedReportMarkdown {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Assessments, [Parameter(Mandatory)]$Run)
    $sb = New-Object System.Text.StringBuilder
    $checkModernization = [bool](Get-RunParameter -Run $Run -Name 'CheckModernization' -Default $false)
    [void]$sb.AppendLine($(if ($checkModernization) { '# Detailed VM Reports - Retirement and Modernization Assessment' } else { '# Detailed VM Reports - Retirement-Affected and Unconfirmed VMs' }))
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("[Source repository]($script:RepositoryUrl)")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("Tenant: **$(ConvertTo-MarkdownText $Run.Tenant.Name)** (``$(ConvertTo-MarkdownText $Run.Tenant.Id)``) | As of: **$($Run.AsOf.ToString('yyyy-MM-dd'))** | Tool: $script:ReportName v$(Get-ToolVersion)")
    [void]$sb.AppendLine()
    $affected = @(if ($checkModernization) {
        $Assessments | Sort-Object { $_.SubscriptionName }, { $_.Lifecycle.RetirementDate }, { $_.Vm.Name }
    }
    else {
        $Assessments | Where-Object { $_.AffectedByRetirement -in 'Yes', 'Unknown' } | Sort-Object { $_.SubscriptionName }, { $_.Lifecycle.RetirementDate }, { $_.Vm.Name }
    })
    if ($affected.Count -eq 0) {
        [void]$sb.AppendLine('_No retirement-affected VMs were found._')
        Add-ReportDisclaimerMarkdown -Builder $sb
        Set-Content -Path $Path -Value $sb.ToString() -Encoding utf8
        return
    }
    $v = { param($x) if ($null -eq $x -or "$x" -eq '') { 'Unknown' } elseif ($x -is [bool]) { if ($x) { 'Yes' } else { 'No' } } else { "$x" } }
    foreach ($sub in ($affected | Group-Object SubscriptionName)) {
        [void]$sb.AppendLine("## Subscription: $(ConvertTo-MarkdownText $sub.Name)")
        [void]$sb.AppendLine()
        foreach ($a in $sub.Group) {
            $vm = $a.Vm; $cur = $a.Current; $lc = $a.Lifecycle; $p = if ($a.Candidates) { $a.Candidates.Primary } else { $null }; $s = if ($a.Candidates) { $a.Candidates.Secondary } else { $null }
            $st = if ($a.Strategy) { $a.Strategy } else { Get-TargetStrategy -Assessment $a }
            $comparison = New-TargetComparisonMarkdown -Strategy $st -CheckModernization:$checkModernization
            [void]$sb.AppendLine("### VM: $(ConvertTo-MarkdownText $vm.Name)")
            [void]$sb.AppendLine()
            [void]$sb.AppendLine("- **Subscription:** $(ConvertTo-MarkdownText $a.SubscriptionName) (``$(ConvertTo-MarkdownText $vm.SubscriptionId)``)")
            [void]$sb.AppendLine("- **Resource Group:** $(ConvertTo-MarkdownText $vm.ResourceGroup)")
            [void]$sb.AppendLine("- **Region:** $(ConvertTo-MarkdownText $vm.Region)$(if ($vm.Zone) { " (zone $(ConvertTo-MarkdownText $vm.Zone))" })")
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('**CURRENT CONFIGURATION**')
            [void]$sb.AppendLine()
            [void]$sb.AppendLine("| Attribute | Value |`n|---|---|")
            $curRows = [ordered]@{
                'Current SKU' = $vm.SkuName; 'Current SKU Generation' = "v$($cur.NameInfo.Version)"; 'VM Family' = (& $v $cur.Family); 'CPU Vendor' = "$($cur.Vendor) ($($cur.VendorQuality))"; 'CPU Architecture' = $cur.Architecture
                'Processors' = (($cur.Processors | Select-Object -First 3) -join '; '); 'vCPU' = (& $v $cur.vCPUs); 'Memory (GB)' = (& $v $cur.MemoryGB)
                'Premium Storage (in use)' = (& $v $vm.UsesPremiumStorage); 'Accelerated Networking (in use)' = (& $v $vm.AcceleratedNetworking)
                'Temp Disk' = $(if ($null -eq $cur.HasTempDisk) { 'Unknown' } elseif ($cur.HasTempDisk) { "$($cur.TempDiskGB) GB" } else { 'None' })
                'Data Disks' = $vm.DataDiskCount; 'Disk SKUs' = ($vm.DiskSkus -join ', '); 'NIC Count' = $vm.NicCount; 'Availability Zone' = $(if ($vm.Zone) { $vm.Zone } else { 'None (regional deployment)' })
                'Hyper-V Generation' = (& $v $vm.HyperVGeneration); 'Disk Controller' = "$($vm.DiskControllerType)$(if (-not $vm.DiskControllerReported) { ' (default, not reported)' })"
                'Security Type' = $vm.SecurityType; 'Power State' = $vm.PowerState
            }
            foreach ($k in $curRows.Keys) { [void]$sb.AppendLine("| $k | $(Format-MdCell $curRows[$k]) |") }
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('**RETIREMENT**')
            [void]$sb.AppendLine()
            [void]$sb.AppendLine("| Attribute | Value |`n|---|---|")
            $src = if ($lc.SourceUrl) { "[$($lc.SourceUrl)]($($lc.SourceUrl))" } else { '-' }
            $ann = if ($lc.AnnouncementUrl) { "[$($lc.AnnouncementDate)]($($lc.AnnouncementUrl))" } else { (& $v $lc.AnnouncementDate) }
            foreach ($pair in @(            @('Retirement Status', $lc.RetirementStatus),
                    @('Microsoft Series', (& $v $lc.LearnSeriesName)), @('Microsoft Retirement Source', $src), @('Announcement', $ann),
                    @('Migration Guide', $(if ($lc.MigrationGuideUrl) { "[link]($($lc.MigrationGuideUrl))" } else { '-' })), @('Microsoft Lifecycle Stage', (Get-LifecycleStage -Lifecycle $lc)), @('Evidence Classification', $lc.EvidenceClass), @('Data Quality', $lc.DataQuality))) {
                [void]$sb.AppendLine("| $($pair[0]) | $(Format-MdCell $pair[1]) |")
            }
            foreach ($n in @($lc.Notes)) { [void]$sb.AppendLine("`n> Note: $(ConvertTo-MarkdownText $n)") }
            [void]$sb.AppendLine()
            if ($a.Modernization) {
                [void]$sb.AppendLine('**MODERNIZATION ASSESSMENT**')
                [void]$sb.AppendLine()
                [void]$sb.AppendLine("| Attribute | Value |`n|---|---|")
                $modRows = New-Object System.Collections.Generic.List[object]
                if ($st.ModernizationEnabled) {
                    foreach ($pair in @(@('Modernization Target', (& $v $st.ModernizationTargetSku)), @('Modernization Target Generation', $(if ($st.ModernizationTargetGeneration) { "v$($st.ModernizationTargetGeneration)" } else { 'Unknown' })),
                            @('Modernization Readiness', (& $v $st.ModernizationReadiness)), @('Recommended Path', (& $v $st.ModernizationPath)), @('Migration Path', (& $v $st.RecommendedMigrationPath)),
                            @('Regional Availability', $a.Modernization.Availability), @('Retirement Target Quota', (& $v $st.RetirementQuotaStatus)), @('Modernization Target Quota', (& $v $st.ModernizationQuotaStatus)),
                            @('Modernization Peak Quota', (& $v $st.ModernizationPeakQuotaStatus)))) { $modRows.Add($pair) }
                    if (-not $st.ModernizationTargetSku -and -not $st.AlreadyModern) { $modRows.Add(@('Reason', $a.Modernization.Reason)) }
                }
                else {
                    foreach ($pair in @(@('Status', $a.Modernization.Status), @('Recommended SKU', (& $v $a.Modernization.RecommendedSku)),
                            @('Recommended SKU Generation', $(if ($a.Modernization.RecommendedGeneration) { "v$($a.Modernization.RecommendedGeneration)" } else { 'Unknown' })),
                            @('Regional Availability', $a.Modernization.Availability), @('Quota Status', $a.QuotaStatus), @('Reason', $a.Modernization.Reason))) { $modRows.Add($pair) }
                }
                foreach ($pair in $modRows) {
                    [void]$sb.AppendLine("| $($pair[0]) | $(Format-MdCell $pair[1]) |")
                }
                [void]$sb.AppendLine()
            }
            [void]$sb.AppendLine('**PRIMARY RECOMMENDATION**')
            [void]$sb.AppendLine()
            if ($p) {
                [void]$sb.AppendLine("| Attribute | Value |`n|---|---|")
                foreach ($pair in @(@('Recommended SKU', $p.SkuName), @('VM Family', $p.Family), @('CPU Vendor', "$($p.CpuVendor) ($($p.VendorQuality))"), @('CPU Generation', (& $v $p.CpuGeneration)),
                        @('vCPU', $p.vCPUs), @('Memory (GB)', $p.MemoryGB), @('Compatibility Score', "$($p.Score) ($($p.Band))"), @('Migration Confidence', $a.Confidence.Level),
                        @('CPU Vendor Preserved', (& $v $p.VendorPreserved)), @('CPU Architecture Preserved', (& $v ($p.CpuArchitecture -eq $cur.Architecture))),
                        @('Region Available', $p.Availability), @('Zone Available', $(if ($vm.Zone) { & $v $p.ZoneAvailable } else { 'N/A (regional VM)' })),
                        @('Quota Available', (& $v $a.QuotaStatus)), @('Quota Increase Required', $(if ($a.Quota) { "Family +$($a.Quota.Family.MinimumIncrease) / Regional +$($a.Quota.Regional.MinimumIncrease) vCPU (recommended request: family +$($a.Quota.Family.RecommendedIncrease))" } else { 'Unknown' })),
                        @('Feature Compatibility', $(if (@($p.ReviewGates).Count) { 'Review: ' + ($p.ReviewGates -join ', ') } else { 'All mandatory requirements met' })),
                        @('Deployment Readiness', $a.Readiness), @('Permitted series', $a.Candidates.PermittedSeries))) {
                    [void]$sb.AppendLine("| $($pair[0]) | $(Format-MdCell $pair[1]) |")
                }
                [void]$sb.AppendLine()
                [void]$sb.AppendLine('**ALTERNATIVE RECOMMENDATION**')
                [void]$sb.AppendLine()
                if ($s) { [void]$sb.AppendLine("- Alternative SKU: **$(ConvertTo-MarkdownText $s.SkuName)** ($(ConvertTo-MarkdownText $s.CpuVendor), $($s.vCPUs) vCPU / $($s.MemoryGB) GB)`n- Compatibility Score: $($s.Score) ($(ConvertTo-MarkdownText $s.Band))`n- Reason for Alternative: $(ConvertTo-MarkdownText $a.SecondaryReason)") }
                else { [void]$sb.AppendLine('- No valid alternative in the permitted series.') }
                if ($a.Candidates.Third) { [void]$sb.AppendLine("- Third candidate: $($a.Candidates.Third.SkuName) (score $($a.Candidates.Third.Score); $($a.Candidates.Third.Variant))") }
                if ($a.Candidates.FutureGeneration) { [void]$sb.AppendLine("- Newer generation if converted: $($a.Candidates.FutureGeneration.SkuName) - blocked by $($a.Candidates.FutureGeneration.FailedGates -join ', ')") }
                [void]$sb.AppendLine()
                [void]$sb.AppendLine($(if ($comparison) { '**CURRENT VS TARGET SIZE**' } else { '**MATERIAL DIFFERENCES**' }))
                [void]$sb.AppendLine()
                [void]$sb.AppendLine($(if ($comparison) { $comparison } else { Format-MdTable -Rows @($p.Differences) -Columns 'Attribute', 'Current', 'Target', 'Assessment', 'Note' }))
            }
            else {
                $noRecommendation = if ($a.Candidates) { $a.Candidates.NoCandidateReason } else { $cause = Get-NoRecommendationReason -Assessment $a; if ($cause) { ConvertTo-MarkdownText $cause } else { 'size characteristics or region catalog unavailable' } }
                [void]$sb.AppendLine("_No primary recommendation: ${noRecommendation}_")
                [void]$sb.AppendLine()
                if ($comparison) {
                    [void]$sb.AppendLine('**CURRENT VS TARGET SIZE**')
                    [void]$sb.AppendLine()
                    [void]$sb.AppendLine($comparison)
                }
            }
            if ($a.Candidates -and $a.Candidates.VendorChangeRequired) { [void]$sb.AppendLine("> **CPU Vendor Change Required:** $($a.Candidates.VendorChangeReason)`n") }
            [void]$sb.AppendLine('**MIGRATION CONSIDERATIONS**')
            [void]$sb.AppendLine()
            $cons = @($a.ValidationItems) + @($a.Confidence.LowReasons | ForEach-Object { "Low confidence: $_" })
            if ($p) { $cons += @($p.Gates | Where-Object { $_.Result -eq 'Info' } | ForEach-Object { "$($_.Gate): $($_.Detail)" }) }
            $cons += 'Nested virtualization / temp-disk usage / physical capacity: Unable to Verify from Azure control plane'
            foreach ($x in $cons | Where-Object { $_ }) { [void]$sb.AppendLine("- $(ConvertTo-MarkdownText $x)") }
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('**RECOMMENDED ACTION**')
            [void]$sb.AppendLine()
            $act = "$($a.Action). Next step: $($a.NextStep)."
            if ($p) { $act += " Resize $($vm.SkuName) -> $($p.SkuName) ($($a.Confidence.Level) confidence, $($a.Readiness))." }
            if ($a.Rightsizing -and $a.Rightsizing.Status -eq 'Potential Rightsizing Opportunity') { $act += " Separate from this migration: potential rightsizing ($($a.Rightsizing.Note))." }
            [void]$sb.AppendLine($act)
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('**DATA QUALITY**')
            [void]$sb.AppendLine()
            foreach ($prop in $a.DataQuality.PSObject.Properties) { [void]$sb.AppendLine("- $($prop.Name): $($prop.Value)") }
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('---')
            [void]$sb.AppendLine()
        }
    }
    Add-ReportDisclaimerMarkdown -Builder $sb
    Set-Content -Path $Path -Value $sb.ToString() -Encoding utf8
}

function Get-BadgeClass {
    param([string]$Value)
    switch -Regex ($Value) {
        '^(Already Retired|Retired|Immediate|Wave 1|LOW|SKU Restricted|Regional Limitation|Less than 12|Fail|Reduced|Redeploy Review)' { 'b-red'; break }
        '^(End of Life|Confirmed Retirement|Retirement Announced|Migration Required|Wave 2|Quota Increase|12-24)' { 'b-orange'; break }
        '^(Wave 3|24-36|MEDIUM|Capacity Validation|Manual Review|Manual Validation|Convertible|Unable|Unavailable|Review|Skipped|Partial|Changed|Not verifiable|Excluded|Not assessed)' { 'b-yellow'; break }
        '^(Modernization|Wave 4|Plan Migration)' { 'b-purple'; break }
        '^(HIGH|Ready|Current|Not End of Life|Quota OK|No Action|No Retirement|Pass|Done|Improved|Same|Available)' { 'b-green'; break }
        '^(Intel|AMD|ARM|Info)' { 'b-blue'; break }
        default { 'b-grey' }
    }
}

function New-Badge {
    param([string]$Value, [string]$Label, [string]$Title)
    if (-not $Value) { return "<span class='muted'>&ndash;</span>" }
    $tip = if ($Title) { " title='$(ConvertTo-HtmlEncoded $Title)'" } else { '' }
    "<span class='badge $(Get-BadgeClass $Value)'$tip>$(ConvertTo-HtmlEncoded $(if ($Label) { $Label } else { $Value }))</span>"
}

# Plain-language meaning of the DeploymentReadiness values (set by Get-DeploymentReadiness in Scoring.psm1): Short for
# the legend, Long for the badge hover text.
$script:ReadinessMeaning = [ordered]@{
    'Ready'                        = @{ Short = 'Checked platform and quota prerequisites pass; validation still required.'; Long = 'The target is listed as available in the region, is not restricted, and assessed vCPU quota covers it. This does not guarantee hardware allocation or a successful resize. Validate guest OS, workload, licensing and capacity before scheduling a change.' }
    'Quota Increase Required'      = @{ Short = 'Request a vCPU quota increase first.'; Long = 'Not enough family or regional vCPU quota for the target; request an increase first.' }
    'Capacity Validation Required' = @{ Short = 'Confirm the region can allocate the size.'; Long = 'Capacity-sensitive VM (placement group, Dedicated Host, capacity reservation, Ultra Disk, GPU or 64+ vCPUs); confirm the region can allocate the size.' }
    'Manual Review Required'       = @{ Short = 'No target, data unknown or special case.'; Long = 'No target, availability or quota unknown, CPU vendor change, or special hardware; review before planning.' }
    'SKU Restricted'               = @{ Short = 'Size restricted for this subscription.'; Long = 'The target size is restricted for this subscription.' }
    'Regional Limitation'          = @{ Short = 'Size not offered in the region or zone.'; Long = 'The target size is not available in the region or in the VM''s zone.' }
}

function Get-ConfidenceAssumption {
    <# What the assessment took for granted without lowering the confidence. Azure reports a VM's disk controller only for some VMs and the
       assessment then assumes SCSI (the Azure default); that is listed only where it matters, when a SCSI to NVMe conversion is part of the
       reported path. #>
    param([Parameter(Mandatory)]$Assessment, $Strategy)
    $a = $Assessment
    if ($a.Vm.DiskControllerReported) { return @() }
    $futureNeedsNvme = [bool]($a.Candidates -and $a.Candidates.FutureGeneration -and @($a.Candidates.FutureGeneration.FailedGates) -contains 'Disk Controller')
    if (($Strategy -and $Strategy.RequiresNvmeConversion) -or $futureNeedsNvme) {
        return @('The VM''s disk controller is not reported by Azure, so SCSI (the Azure default) was assumed and the SCSI to NVMe conversion is reported on that basis.')
    }
    @()
}

function Get-ConfidenceTooltip {
    <# Hover text for the confidence badge, rendered from the assessment's own confidence reasons and validation items. -Assumptions are
       things the assessment took for granted that do not change the level; they are listed after the items. #>
    param($Confidence, [string[]]$Assumptions = @())
    if (-not $Confidence) { return $null }
    $lines = @(@($Confidence.LowReasons | Where-Object { $_ } | ForEach-Object { "- Blocker: $_" }) + @($Confidence.ValidationItems | Where-Object { $_ } | ForEach-Object { "- $_" }))
    $head = "Confidence in the recommended size: $($Confidence.Level)."
    $assumed = @($Assumptions | Where-Object { $_ })
    $tail = if ($assumed.Count -gt 0) { "`nAssumed, without changing the level:`n$((@($assumed | ForEach-Object { "- $_" })) -join "`n")" } else { '' }
    if ($lines.Count -eq 0) { return "$head No outstanding items in the assessed evidence. Guest/workload compatibility and physical capacity still require validation.$tail" }
    return "$head Validate first:`n$($lines -join "`n")$tail"
}

function Get-VmAnchorId {
    <# Page-unique id for a VM's table row, detail row and toggle. Resource group and name are joined with '-', which both can contain
       ('app-prod'+'db' vs 'app'+'prod-db'), so a short hash of the unambiguous 'group|name' pair is appended. #>
    param([Parameter(Mandatory)]$Vm)
    $key = "$($Vm.ResourceGroup)|$($Vm.Name)".ToLowerInvariant()
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($key))
    $short = [System.BitConverter]::ToString($hash, 0, 3).Replace('-', '').ToLowerInvariant()
    return 'vm-' + (Get-SafeFileName "$($Vm.ResourceGroup)-$($Vm.Name)").ToLowerInvariant() + '-' + $short
}

function New-HtmlPage {
    <# -Warnings is the number of warnings the page shows at its top; the footer states it instead of claiming success. #>
    param([string]$Title, [string]$Eyebrow, [string]$Heading, [string]$Subtitle, [string[]]$Meta, [string]$Body, [string]$Css, [string]$BackLink, [object[]]$Nav, [int]$Warnings = 0)
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $back = if ($BackLink) { "<a href='$BackLink' class='back'>&larr; Tenant summary</a>" } else { '' }
    $metaHtml = (@($Meta) | Where-Object { $_ } | ForEach-Object { "<span class='chip'>$_</span>" }) -join ''
    $navHtml = New-NavHtml -Nav $Nav
    $version = Get-ToolVersion
    $statusHtml = if ($Warnings -gt 0) { "<span class=""footer-status warn""><span aria-hidden=""true""></span>Report generated with $Warnings warning$(if ($Warnings -ne 1) { 's' })</span>" } else { '<span class="footer-status"><span aria-hidden="true"></span>Report generated</span>' }
    # Allow long VM size names to wrap only after the 'Standard_' prefix, never mid-name.
    $Body = $Body -replace '<code>Standard_', '<code>Standard_<wbr>'
    @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>$(& $e $Title)</title><style>$Css</style></head><body>
<header class="hero"><div class="wrap">
<div class="app-bar">
<div class="brand-lockup"><span class="brand-mark" aria-hidden="true">&#9729;</span><span><strong>$script:ReportName</strong><small>Assessment report v$version</small></span></div>
<span class="brand-divider" aria-hidden="true"></span>
<span class="report-context">$(& $e $Eyebrow)</span>
<span class="mode-pill">Read-only</span>
</div>
<div class="hero-content">
$back
<h1>$(& $e $Heading)</h1>
$(if ($Subtitle) { "<p class='subtitle'>$(& $e $Subtitle)</p>" })
<div class="chips">$metaHtml</div>
</div>
</div></header>
$(if ($navHtml) { "<nav class='toc'><div class='wrap'>$navHtml</div></nav>" })
<main class="wrap">
$Body
<section class="callout disclaimer" aria-label="Disclaimer"><h2>Disclaimer</h2><p><strong>$(& $e $script:DisclaimerWarranty)</strong> $(& $e $script:DisclaimerIndependence)</p><p>$(& $e $script:DisclaimerValidation)</p></section>
</main>
<footer><div class="wrap">$statusHtml<span>$script:ReportName v$version &middot; read-only assessment &middot; $(& $e $Title) &middot; <a href="$script:RepositoryUrl" target="_blank" rel="noopener noreferrer">Source repository</a></span></div></footer>
</body></html>
"@
}

function New-Section {
    param([string]$Id, [string]$Title, [string]$Body, [string]$Intro, [switch]$Collapsed)
    if ($Collapsed) {
        return "<details id='$Id' class='card collapsible-section'><summary><span class='section-heading' role='heading' aria-level='2'>$(ConvertTo-HtmlEncoded $Title)</span>$(if ($Intro) { "<span class='section-intro'>$Intro</span>" })</summary><div class='section-body'>$Body</div></details>"
    }
    "<section id='$Id' class='card'><h2>$(ConvertTo-HtmlEncoded $Title)</h2>$(if ($Intro) { "<p class='lead'>$Intro</p>" })$Body</section>"
}

function New-NavHtml {
    <# Navigation links; consecutive items with the same Group are wrapped in a labelled, colour-coded group. #>
    param([object[]]$Nav)
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $out = New-Object System.Collections.Generic.List[string]
    $group = $null; $buffer = New-Object System.Collections.Generic.List[string]; $tone = $null
    $flush = {
        if ($buffer.Count) { $out.Add("<span class='toc-group toc-$tone'><span class='toc-group-label'>$(& $e $group)</span>$($buffer -join '')</span>"); $buffer.Clear() }
    }
    foreach ($n in @($Nav)) {
        $g = if ($n -is [System.Collections.IDictionary] -and $n.Contains('Group')) { $n.Group } else { $null }
        if ($g -ne $group) { & $flush; $group = $g; $tone = if ($n -is [System.Collections.IDictionary] -and $n.Contains('Tone')) { $n.Tone } else { 'neutral' } }
        $link = "<a href='#$($n.Id)'>$(& $e $n.Label)</a>"
        if ($g) { $buffer.Add($link) } else { $out.Add($link) }
    }
    & $flush
    return ($out -join '')
}

function New-TrackHtml {
    <# Wraps the sections of the retirement remediation part of a subscription page in a labelled, colour-coded band. #>
    param([Parameter(Mandatory)][string]$Tone, [Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][string]$Title, [string]$Description, [string]$Body)
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    @"
<div class='track track-$Tone' id='track-$Tone' role='region' aria-labelledby='track-$Tone-title'>
<div class='track-banner'><span class='track-icon' aria-hidden='true'>&#9888;</span><div class='track-text'><span class='track-part'><strong>$(& $e $Label)</strong></span><div class='track-title' id='track-$Tone-title' role='heading' aria-level='2'>$(& $e $Title)</div>$(if ($Description) { "<p class='track-desc'>$Description</p>" })</div></div>
$Body
</div>
"@
}

function New-TrackTilesHtml {
    <# Overview tile that introduces and links to the retirement remediation part. #>
    param([int]$RetiringCount)
    $retHint = if ($RetiringCount) { 'Move them to the recommended size.' } else { 'No VMs on End of Life or retired sizes.' }
    "<div class='track-tiles'><a class='track-tile track-tile-retirement' href='#track-retirement'><span class='track-tile-part'>Required</span><span class='track-tile-value'>$RetiringCount</span><span class='track-tile-label'>VMs on End of Life or retired sizes</span><span class='track-tile-hint'>$retHint</span></a></div>"
}

# Microsoft Learn guidance for the upgrade path (URLs verified 2026-10-07).
$script:LearnDocs = [ordered]@{
    LifecycleOverview = @{ Title = 'VM lifecycle overview (Current, Extended, End of Life, Retired)'; Url = 'https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/lifecycle-overview'; Topic = 'Retirement' }
    EndOfLifeList    = @{ Title = 'End of Life Azure VM size series'; Url = 'https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/end-of-life-sizes-list'; Topic = 'Retirement' }
    RetiredSizes     = @{ Title = 'VM size series retirements and modernization guidance'; Url = 'https://learn.microsoft.com/azure/virtual-machines/sizes/retirement/retired-sizes-list'; Topic = 'Retirement' }
    ModernizationGuide = @{ Title = 'Retired VM sizes modernization guide'; Url = 'https://learn.microsoft.com/azure/virtual-machines/migration/sizes/d-ds-dv2-dsv2-ls-series-migration-guide'; Topic = 'Retirement' }
    SizesOverview    = @{ Title = 'Virtual machine sizes overview'; Url = 'https://learn.microsoft.com/azure/virtual-machines/sizes/overview'; Topic = 'Retirement' }
    Resize           = @{ Title = 'Resize a virtual machine'; Url = 'https://learn.microsoft.com/azure/virtual-machines/sizes/resize-vm'; Topic = 'Resize' }
    NvmeOverview     = @{ Title = 'NVMe overview'; Url = 'https://learn.microsoft.com/azure/virtual-machines/nvme-overview'; Topic = 'SCSI to NVMe' }
    NvmeConvert      = @{ Title = 'Convert SCSI to NVMe for Linux and Windows VMs'; Url = 'https://learn.microsoft.com/azure/virtual-machines/nvme-linux'; Topic = 'SCSI to NVMe' }
    NvmeInPlace      = @{ Title = 'Convert a VM from SCSI to NVMe in place'; Url = 'https://learn.microsoft.com/azure/virtual-machines/migration/scsi-to-nvme-migration'; Topic = 'SCSI to NVMe' }
    NvmeOsImages     = @{ Title = 'NVMe supported OS images'; Url = 'https://learn.microsoft.com/azure/virtual-machines/enable-nvme-interface'; Topic = 'SCSI to NVMe' }
    NvmeFaq          = @{ Title = 'NVMe general FAQ'; Url = 'https://learn.microsoft.com/azure/virtual-machines/enable-nvme-faqs'; Topic = 'SCSI to NVMe' }
    Gen1TrustedLaunch = @{ Title = 'Upgrade Gen1 VMs to Trusted launch'; Url = 'https://learn.microsoft.com/azure/virtual-machines/trusted-launch-existing-vm-gen-1'; Topic = 'Gen1 to Gen2' }
    Generation2      = @{ Title = 'Azure support for Generation 2 VMs'; Url = 'https://learn.microsoft.com/azure/virtual-machines/generation-2'; Topic = 'Gen1 to Gen2' }
    Mana             = @{ Title = 'Microsoft Azure Network Adapter (MANA) overview'; Url = 'https://learn.microsoft.com/azure/virtual-network/accelerated-networking-mana-overview'; Topic = 'Networking and temp disk' }
    NoTempDisk       = @{ Title = 'FAQ: Azure VM sizes with no local temporary disk'; Url = 'https://learn.microsoft.com/azure/virtual-machines/azure-vms-no-temp-disk'; Topic = 'Networking and temp disk' }
}

function New-LearnLink {
    param([Parameter(Mandatory)][string]$Key, [string]$Text)
    $d = $script:LearnDocs[$Key]
    "<a href='$(ConvertTo-HtmlEncoded $d.Url)' target='_blank'>$(ConvertTo-HtmlEncoded $(if ($Text) { $Text } else { $d.Title }))</a>"
}

function Test-RetiringVm {
    <# HTML scope: VMs on End of Life or retired sizes (Microsoft-announced retirement) that need action. #>
    param([Parameter(Mandatory)]$Assessment)
    $a = $Assessment
    return [bool]($a.AffectedByRetirement -eq 'Yes' -and (Get-LifecycleStage -Lifecycle $a.Lifecycle) -in 'End of Life', 'Retired' -and $a.Action -and $a.Action -ne 'No Action Required')
}

function Test-HtmlListedVm {
    <# VMs listed in the HTML: retiring VMs, plus optional-modernization VMs with -HtmlIncludeOptionalModernization. #>
    param([Parameter(Mandatory)]$Assessment, [switch]$IncludeOptional)
    if (Test-RetiringVm -Assessment $Assessment) { return $true }
    return [bool]($IncludeOptional -and $Assessment.Action -eq 'Modernization Optional')
}

function Get-RunParameter {
    param($Run, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if (-not $Run -or $Run.PSObject.Properties.Name -notcontains 'Parameters' -or -not $Run.Parameters) { return $Default }
    $p = $Run.Parameters
    if ($p -is [System.Collections.IDictionary]) { if ($p.Contains($Name)) { return $p[$Name] } else { return $Default } }
    if ($p.PSObject.Properties.Name -contains $Name) { return $p.$Name }
    return $Default
}

function New-UpgradeGuidanceHtml {
    <# One compact guide: the general upgrade sequence, recommended steps for each migration path with an example, and the Microsoft Learn links. #>
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $paths = @(
        @{ Name = 'Direct Resize'; When = 'The target already supports the VM''s hardware generation and disk controller.'; Example = @('Standard_D4s_v5', 'Standard_D4s_v6')
            Steps = @("Request target-family and regional vCPU quota ($(New-LearnLink 'SizesOverview' 'size list'))", 'Back up or snapshot the OS and data disks', "Resize in a change window; the VM restarts ($(New-LearnLink 'Resize' 'resize a VM'))", 'Validate the application, disks and networking') }
        @{ Name = 'SCSI to NVMe + Resize'; When = 'The target supports NVMe only and the VM uses SCSI.'; Example = @('Standard_D4ds_v5', 'Standard_D4ds_v6'); Note = 'SCSI to NVMe'
            Steps = @("Confirm the guest OS image supports NVMe ($(New-LearnLink 'NvmeOsImages' 'supported images'))", 'Test on a clone or snapshot first; reference Linux disks by UUID, not device name', "Convert the disk controller to NVMe and resize ($(New-LearnLink 'NvmeConvert' 'conversion steps'))", 'Check that every disk is visible, then validate the application') }
        @{ Name = 'Gen1 + NVMe + Resize'; When = 'A Gen1, SCSI VM must move to a Gen2, NVMe-only size.'; Example = @('Standard_DS3_v2', 'Standard_D4s_v6'); Note = 'Gen1 + SCSI to Gen2 + NVMe'
            Steps = @("Check the OS supports the Trusted launch upgrade ($(New-LearnLink 'Gen1TrustedLaunch' 'Gen1 upgrade')); if not, redeploy instead", 'Back up the VM; plan for a restart and MBR to GPT conversion', 'Upgrade to Gen2 (Trusted launch), then convert the disk controller to NVMe', 'Resize to the target and validate boot, disks and drivers (MANA networking)') }
        @{ Name = 'Gen1 Modernization + Resize'; When = 'A Gen1 VM must move to a Gen2-only size; the controller stays SCSI.'; Example = @('Gen1 VM', 'Gen2-only size')
            Steps = @('Check OS and size support for the Trusted launch upgrade', 'Back up the VM and plan the restart', "Upgrade Gen1 to Gen2 ($(New-LearnLink 'Generation2' 'Gen2 support'))", 'Resize to the target and validate') }
        @{ Name = 'Redeploy / Rebuild Review'; When = 'The guest OS cannot be upgraded in place (for example Windows Server 2016, Debian, Azure Linux).'; Example = @('Gen1 VM (unsupported OS)', 'New Gen2 VM')
            Steps = @('Build a new Gen2 VM on the target size from a supported image', 'Move data disks or restore from backup, then cut over', 'Keep the old VM until the workload is validated, then delete it') }
    )
    $rows = foreach ($p in $paths) {
        $steps = ($p.Steps | ForEach-Object { "<li>$_</li>" }) -join ''
        $note = if ($p.ContainsKey('Note')) { "<div class='sub'>$(& $e $p.Note)</div>" } else { '' }
        "<tr><td class='path-name'>$(& $e $p.Name)</td><td>$(& $e $p.When)</td><td class='example'><code>$(& $e $p.Example[0])</code> &rarr; <code>$(& $e $p.Example[1])</code>$note</td><td><ol class='steps'>$steps</ol></td></tr>"
    }
    $groups = @($script:LearnDocs.Values | Group-Object { $_.Topic })
    $order = 'Retirement', 'Resize', 'SCSI to NVMe', 'Gen1 to Gen2', 'Networking and temp disk'
    $docs = foreach ($t in $order) {
        $g = $groups | Where-Object Name -eq $t
        if (-not $g) { continue }
        $links = (@($g.Group) | ForEach-Object { "<a href='$(ConvertTo-HtmlEncoded $_.Url)' target='_blank'>$(ConvertTo-HtmlEncoded $_.Title)</a>" }) -join ' &middot; '
        "<div class='doc-row'><dt>$(& $e $t)</dt><dd>$links</dd></div>"
    }
    @"
<ol class='upgrade-steps'>
<li><strong>Confirm the retirement</strong> and the Microsoft-recommended target series for each retiring size.</li>
<li><strong>Check prerequisites</strong>: Gen1 VMs need the Trusted launch upgrade before a Gen2-only size; SCSI VMs need NVMe conversion before an NVMe-only size (validate guest OS support first).</li>
<li><strong>Request quota</strong> for the target family and regional vCPUs (see Quota Actions). Use peak demand when source and target must coexist.</li>
<li><strong>Resize in a change window</strong>, then validate disks, networking (MANA), temp-disk usage (keep a <code>d</code> size if the workload needs local scratch) and application health.</li>
</ol>
<h3>Recommended steps by migration path</h3>
<div class='table-wrap'><table class='ref steps-table'><thead><tr><th>Path</th><th>When it applies</th><th>Example</th><th>Recommended steps</th></tr></thead><tbody>
$($rows -join "`n")
</tbody></table></div>
<p class='note'>Examples are illustrative. The path, target and blockers for each VM are in the <em>VMs with Retiring SKUs</em> table and its details; guest readiness cannot be proven from Azure control-plane data, so always test before changing production.</p>
<h3>Microsoft Learn</h3>
<dl class='doc-links'>$($docs -join '')</dl>
"@
}

function Get-QuotaDisplayRows {
    <# Display only (quota-impact.csv keeps every scope): drops a Retirement+Modernization row that repeats its Retirement row, then keeps rows that need action in steady state or at peak plus every Modernization row. #>
    param([AllowEmptyCollection()][object[]]$Rows)
    $field = { param($r, $n) if ($r.PSObject.Properties.Name -contains $n) { $r.$n } else { $null } }
    $compare = 'CurrentUsage', 'Limit', 'RequiredVcpu', 'MinimumIncrease', 'RecommendedIncrease', 'Status', 'VmCount', 'SteadyStateRequiredVcpu', 'PeakMigrationRequiredVcpu', 'PeakMinimumIncrease', 'PeakRecommendedIncrease', 'PeakStatus'
    $keyOf = { param($r) (@('SubscriptionId', 'Region', 'QuotaName') | ForEach-Object { "$(& $field $r $_)" }) -join '|' }
    $signature = { param($r) ($compare | ForEach-Object { "$(& $field $r $_)" }) -join '|' }
    $all = @($Rows | Where-Object { $_ })
    $retirement = @{}
    foreach ($r in $all) { if ((& $field $r 'Scope') -eq 'Retirement') { $retirement[(& $keyOf $r)] = & $signature $r } }
    $rank = @{ 'Retirement' = 0; 'Retirement+Modernization' = 1; 'Modernization' = 2 }
    $kept = foreach ($r in $all) {
        $scope = "$(& $field $r 'Scope')"
        if ($scope -eq 'Retirement+Modernization' -and $retirement.ContainsKey((& $keyOf $r)) -and $retirement[(& $keyOf $r)] -eq (& $signature $r)) { continue }
        $peakStatus = & $field $r 'PeakStatus'
        if ($r.Status -ne 'Quota OK' -or ($peakStatus -and $peakStatus -ne 'Quota OK') -or $scope -eq 'Modernization') { $r }
    }
    @($kept | Sort-Object @{ e = { $s = "$(& $field $_ 'Scope')"; if ($rank.ContainsKey($s)) { $rank[$s] } else { 9 } } } -Stable)
}

function New-QuotaActionsHtml {
    <# One quota table for the retirement and modernization scopes, with steady-state and peak demand. -HideSubscription drops the column on per-subscription pages; otherwise it shows the subscription name (from -SubscriptionNames, keyed by lower-case ID) with the ID underneath. #>
    param([AllowEmptyCollection()][object[]]$Rows, [switch]$HideSubscription, [hashtable]$SubscriptionNames = @{})
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $field = { param($r, $n) if ($r.PSObject.Properties.Name -contains $n) { $r.$n } else { $null } }
    $has = { param($v) $null -ne $v -and "$v" -ne '' }
    $dash = "<span class='muted'>&ndash;</span>"
    $shown = @(Get-QuotaDisplayRows -Rows $Rows)
    if ($shown.Count -eq 0) { return "<div class='callout ok'>No quota increase is needed for the recommended moves. <span class='muted'>(Quota OK does not guarantee physical capacity.)</span></div>" }
    $needsAction = @($shown | Where-Object { $_.Status -ne 'Quota OK' -or ((& $field $_ 'PeakStatus') -and (& $field $_ 'PeakStatus') -ne 'Quota OK') }).Count
    $okNote = if ($needsAction -eq 0) { "<div class='callout ok'>No quota increase is needed for the recommended moves. <span class='muted'>(Quota OK does not guarantee physical capacity.)</span></div>" } else { '' }
    $showPeak = @($shown | Where-Object { $p = & $field $_ 'PeakMigrationRequiredVcpu'; (& $has $p) -and (& $has $_.RequiredVcpu) -and [int]$p -ne [int]$_.RequiredVcpu }).Count -gt 0
    $hasModernization = @($shown | Where-Object { (& $field $_ 'Scope') -eq 'Modernization' }).Count -gt 0
    $subHead = if ($HideSubscription) { '' } else { '<th>Subscription</th>' }
    $peakHead = if ($showPeak) { "<th class='num'>Peak needed</th>" } else { '' }
    # A peak figure is added under the steady-state one only when it differs.
    $withPeak = { param($value, $peak, [switch]$Strong)
        $main = if (& $has $value) { if ($Strong) { "<strong>$(& $e $value)</strong>" } else { & $e $value } } else { $dash }
        if ((& $has $peak) -and (& $has $value) -and [int]$peak -ne [int]$value) { "$main<div class='sub peak'>peak $(& $e $peak)</div>" } else { $main }
    }
    $rowsHtml = ($shown | ForEach-Object {
            $scope = "$(& $field $_ 'Scope')"
            $model = & $field $_ 'MigrationQuotaModel'
            $scopeSub = if ($scope -eq 'Modernization' -and $model -and $model -ne 'InPlace') { "<div class='sub'>$(& $e $model) ($(& $e (& $field $_ 'SideBySideVmCount')) side-by-side)</div>" } else { '' }
            $subName = if ($SubscriptionNames.ContainsKey("$($_.SubscriptionId)".ToLowerInvariant())) { $SubscriptionNames["$($_.SubscriptionId)".ToLowerInvariant()] } else { $null }
            $subCell = if ($HideSubscription) { '' } elseif ($subName) { "<td><span class='strong'>$(& $e $subName)</span><div class='sub'>$(& $e $_.SubscriptionId)</div></td>" } else { "<td class='sub'>$(& $e $_.SubscriptionId)</td>" }
            $usage = if ($null -eq $_.Limit -or "$($_.Limit)" -eq '') { $dash } else { "$(& $e $_.CurrentUsage) / $(& $e $_.Limit)" }
            $peakValue = & $field $_ 'PeakMigrationRequiredVcpu'
            $peakCell = if ($showPeak) { "<td class='num$(if ((& $has $peakValue) -and (& $has $_.RequiredVcpu) -and [int]$peakValue -ne [int]$_.RequiredVcpu) { ' peak' })'>$(if (& $has $peakValue) { & $e $peakValue } else { $dash })</td>" } else { '' }
            $peakStatus = & $field $_ 'PeakStatus'
            $statusCell = New-Badge $_.Status
            if ($peakStatus -and $peakStatus -ne $_.Status) { $statusCell += "<div class='sub'>Peak: $(New-Badge $peakStatus)</div>" }
            "<tr><td>$(& $e $scope)$scopeSub</td>$subCell<td>$(& $e $_.Region)</td><td>$(& $e $(if ($_.QuotaDisplayName) { $_.QuotaDisplayName } else { $_.QuotaName }))</td><td class='num quota-usage'>$usage</td><td class='num'>$(& $e $_.RequiredVcpu)</td>$peakCell<td class='num'>$(& $withPeak $_.MinimumIncrease (& $field $_ 'PeakMinimumIncrease') -Strong)</td><td class='num'>$(& $withPeak $_.RecommendedIncrease (& $field $_ 'PeakRecommendedIncrease'))</td><td>$statusCell</td></tr>"
        }) -join "`n"
    $planning = if ($showPeak -or $hasModernization) { "<p class='note quota-impact-note'><strong>Peak</strong> adds the target capacity while the source VM still exists: resizes and SCSI to NVMe conversions are modeled in place; Gen1 to Gen2 (Trusted launch upgrade) and redeploy paths are modeled side-by-side. These are planning estimates from <code>quota-impact.csv</code>; validate the final migration method and Azure capacity before execution.</p>" } else { '' }
    "$okNote<div class='table-wrap'><table class='quota-table'><thead><tr><th>Scope</th>$subHead<th>Region</th><th>Quota</th><th class='num quota-usage'>Used / limit</th><th class='num'>Needed</th>$peakHead<th class='num'>Min. increase</th><th class='num'>Recommended request</th><th>Status</th></tr></thead><tbody>$rowsHtml</tbody></table></div><p class='note'><em>Retirement</em> covers required migrations to their retirement target; <em>Retirement+Modernization</em> is listed only when it differs (it adds optional Wave 4 moves); <em>Modernization</em> (only with <code>--check-modernization</code>) covers the strategic v6/v7 targets. Identical scopes are shown once; <code>quota-impact.csv</code> keeps every scope.</p>$planning"
}

function New-Kpi {
    param([string]$Value, [string]$Label, [string]$Tone = 'neutral', [string]$Hint)
    "<div class='kpi kpi-$Tone'><div class='kpi-label'>$(ConvertTo-HtmlEncoded $Label)</div><div class='kpi-value'>$(ConvertTo-HtmlEncoded $Value)</div>$(if ($Hint) { "<div class='kpi-hint'>$(ConvertTo-HtmlEncoded $Hint)</div>" })</div>"
}

$script:Arrow = [string][char]0x2192

function Get-ToneClass {
    <# Text colour class for a status value, from the same mapping as the badges. Blue and grey values stay neutral. #>
    param([string]$Value)
    if (-not $Value) { return '' }
    $class = Get-BadgeClass $Value
    if ($class -in 'b-blue', 'b-grey') { return '' }
    return 'tone-' + $class.Substring(2)
}

function New-SpecLineHtml {
    <# One "Label: value" line shared by the size, change and next-step cells. -Value is already-encoded HTML; -Tone is a Get-ToneClass result. #>
    param([Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][AllowEmptyString()][string]$Value, [string]$Tone, [string]$Title)
    $shown = if ($Tone) { "<span class='$Tone'>$Value</span>" } else { $Value }
    $tip = if ($Title) { " title='$(ConvertTo-HtmlEncoded $Title)'" } else { '' }
    "<div class='spec'$tip><span class='spec-label'>${Label}:</span> $shown</div>"
}

function Get-MaterialChangeLinesHtml {
    <# One "Attribute: current -> target" line per material difference between the current size and the retirement target, coloured by severity. The full comparison is in the VM details. #>
    param([Parameter(Mandatory)]$Assessment, [int]$Max = 4)
    $s = $Assessment.Strategy
    if (-not $s -or -not $s.RetirementTarget) { return "<span class='muted'>&ndash;</span>" }
    $noteRequired = 'Temp / Local Disk', 'Disk Controller', 'Hyper-V Generation'
    $items = @(@($s.TargetComparison) | Where-Object {
            $_.Attribute -ne 'Processor' -and $_.RetirementChange -in 'Reduced', 'Changed' -and ($_.Attribute -notin $noteRequired -or $_.RetirementNote)
        })
    if ($items.Count -eq 0) { return "<span class='muted'>None</span>" }
    $labels = @{
        'Uncached Disk IOPS' = 'Disk IOPS'; 'Uncached Disk MBps' = 'Disk MBps'; 'Max Data Disks' = 'Data disks'; 'Max NICs' = 'NICs'
        'Accelerated Networking' = 'Accel. networking'; 'Temp / Local Disk' = 'Temp disk'; 'Disk Controller' = 'Disk controller'
        'Hyper-V Generation' = 'VM Gen'; 'Memory (GB)' = 'vRAM (GB)'; 'Premium Storage' = 'Premium storage'; 'Availability Zones' = 'Zones'
        'CPU Vendor' = 'Vendor'; 'CPU Architecture' = 'Architecture'
    }
    $show = { param($attribute, $value)
        if ($attribute -eq 'Hyper-V Generation') { Format-VmGeneration @("$value" -split ',') }
        elseif ($null -eq $value -or "$value" -eq '') { 'Unknown' }
        else { "$value" }
    }
    $lines = foreach ($i in ($items | Select-Object -First $Max)) {
        $attribute = [string]$i.Attribute
        $label = if ($labels.ContainsKey($attribute)) { $labels[$attribute] } else { $attribute }
        $value = ConvertTo-HtmlEncoded "$(& $show $attribute $i.Current) $script:Arrow $(& $show $attribute $i.RetirementTarget)"
        $tone = if ($i.RetirementChange -eq 'Reduced') { 'tone-red' } else { 'tone-yellow' }
        New-SpecLineHtml -Label $label -Value $value -Tone $tone -Title "${attribute}: $($i.Current) $script:Arrow $($i.RetirementTarget)$(if ($i.RetirementNote) { ' - ' + $i.RetirementNote })"
    }
    $more = if ($items.Count -gt $Max) { "<div class='spec muted'>+$($items.Count - $Max) more</div>" } else { '' }
    (@($lines) -join '') + $more
}

function Format-VmGeneration {
    <# 'V1' -> 'Gen1', 'V2' -> 'Gen2'; a list becomes 'Gen1, Gen2'; nothing reported -> 'Unknown'. #>
    param($Value)
    $items = @($Value | Where-Object { $_ } | ForEach-Object { if ("$_" -match '^V?(\d)$') { "Gen$($Matches[1])" } else { "$_" } })
    if ($items.Count -eq 0) { return 'Unknown' }
    return ($items -join ', ')
}

function New-SizeSpecHtml {
    <# A VM size with Vendor, vCPU, vRAM, VM Gen and Disk controller on separate lines. Used for the current size, the retirement target and the modernization target so the columns read the same way. #>
    param([Parameter(Mandatory)][string]$SkuName, $Vendor, $Vcpu, $MemoryGb, $Generation, $Controller)
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $text = { param($v, [string]$suffix = '') if ($null -eq $v -or "$v" -eq '') { 'Unknown' } else { "$(& $e $v)$suffix" } }
    $controllers = @($Controller | Where-Object { $_ }) -join ', '
    "<code>$(& $e $SkuName)</code>" +
    (New-SpecLineHtml -Label 'Vendor' -Value (& $text $Vendor)) +
    (New-SpecLineHtml -Label 'vCPU' -Value (& $text $Vcpu ' vCPU')) +
    (New-SpecLineHtml -Label 'vRAM' -Value (& $text $MemoryGb ' GB')) +
    (New-SpecLineHtml -Label 'VM Gen' -Value (& $text (Format-VmGeneration $Generation))) +
    (New-SpecLineHtml -Label 'Disk controller' -Value (& $text $controllers))
}

function Get-Gen1VmCount {
    <# Number of VMs on Hyper-V generation 1. VMs that do not report a generation are not counted. #>
    param([AllowEmptyCollection()][object[]]$Assessments)
    @($Assessments | Where-Object { $_ -and $_.Vm.HyperVGeneration -eq 'V1' }).Count
}

function New-VmSummaryRowHtml {
    <# One row of the VMs with Retiring SKUs table: current size, Microsoft status, retirement target and, with --check-modernization, the v6/v7 target and path. #>
    param([Parameter(Mandatory)]$Assessment, [switch]$CheckModernization, [switch]$HasDetails, [switch]$Alt)
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $a = $Assessment
    $r = ConvertTo-AssessmentRow $a
    $s = if ($a.Strategy) { $a.Strategy } else { Get-TargetStrategy -Assessment $a }
    $rt = $s.RetirementTarget
    $p = if ($a.Candidates) { $a.Candidates.Primary } else { $null }
    $anchor = Get-VmAnchorId $a.Vm
    # Pure-CSS expand/collapse (the report has no scripts): a hidden checkbox, its label, and the detail row that follows.
    $toggle = if ($HasDetails) { "<input type='checkbox' class='vm-toggle' id='tg-$anchor' aria-label='Show details for $(& $e $r.VM)'><label class='vm-toggle-label' for='tg-$anchor'>Details</label>" } else { '' }
    $link = "<span class='strong'>$(& $e $r.VM)</span>"
    $currentCell = New-SizeSpecHtml -SkuName $r.CurrentSku -Vendor $r.CpuVendor -Vcpu $r.vCPU -MemoryGb $r.MemoryGB -Generation $a.Vm.HyperVGeneration -Controller $a.Vm.DiskControllerType
    $retirementCell = if ($rt) {
        $record = if ($rt.PSObject.Properties.Name -contains 'Record') { $rt.Record } else { $null }
        $targetSpec = New-SizeSpecHtml -SkuName $rt.SkuName -Vendor $rt.CpuVendor -Vcpu $rt.vCPUs -MemoryGb $rt.MemoryGB `
            -Generation $(if ($record) { $record.HyperVGenerations }) -Controller $(if ($record) { $record.DiskControllerTypes })
        "$targetSpec$(New-SpecLineHtml -Label 'Score' -Value (& $e $rt.Score))"
    }
    elseif ($p -and -not $s.RetirementRequired -and -not $s.RetirementUnconfirmed) { "<span class='muted'>Not required</span><div class='sub'>Optional move: <code>$(& $e $p.SkuName)</code></div>" }
    elseif ($a.Action -eq 'No Action Required') { "<span class='muted'>Current generation</span>" }
    else { "<span class='muted'>None found</span>" }
    $cost = if ($a.Pricing -and $a.Pricing.CurrentMonthly) { "`$$([math]::Round($a.Pricing.CurrentMonthly))$(if ($a.Pricing.TargetMonthly) { " &rarr; `$$([math]::Round($a.Pricing.TargetMonthly))" })" } else { "<span class='muted'>&ndash;</span>" }
    $nextStep = "<span class='muted'>No action required</span>"
    if ($a.Action -ne 'No Action Required') {
        $nextStep = New-SpecLineHtml -Label 'Readiness' -Value (& $e $r.DeploymentReadiness) -Tone (Get-ToneClass $r.DeploymentReadiness)
        $nextStep += New-SpecLineHtml -Label 'Confidence' -Value (& $e $r.Confidence) -Tone (Get-ToneClass $r.Confidence)
    }
    $optional = ''
    if ($CheckModernization) {
        $mt = $s.ModernizationTarget
        $modernCell = if ($s.AlreadyModern) { "<span class='tone-green'>Already v6/v7</span>" }
        elseif ($s.ModernizationTargetSku -and $mt) {
            $mRecord = if ($mt.PSObject.Properties.Name -contains 'Record') { $mt.Record } else { $null }
            (New-SizeSpecHtml -SkuName $mt.SkuName -Vendor $mt.CpuVendor -Vcpu $mt.vCPUs -MemoryGb $mt.MemoryGB `
                -Generation $(if ($mRecord) { $mRecord.HyperVGenerations }) -Controller $(if ($mRecord) { $mRecord.DiskControllerTypes })) +
            (New-SpecLineHtml -Label 'Score' -Value (& $e $mt.Score))
        }
        else { "<span class='muted'>&ndash;</span>" }
        $modernStatus = if ($s.ModernizationReadiness) { New-SpecLineHtml -Label 'Status' -Value (& $e $s.ModernizationReadiness) -Tone (Get-ToneClass $s.ModernizationReadiness) } else { '' }
        $modernQuota = if ($s.ModernizationTargetSku -and $s.ModernizationQuotaStatus) { New-SpecLineHtml -Label 'Quota' -Value (& $e $s.ModernizationQuotaStatus) -Tone (Get-ToneClass $s.ModernizationQuotaStatus) } else { '' }
        $optional = "<td class='target-cell modernization-target-cell'>$modernCell$modernStatus$modernQuota</td><td class='path-cell'><div class='path-primary'>$(& $e $s.ModernizationPath)</div></td>"
    }
    "<tr class='vm-summary-row$(if ($Alt) { ' alt' })' id='$anchor'><td>$toggle$link<div class='sub'>$(& $e $r.ResourceGroup) &middot; $(& $e $r.Region)$(if ($r.Zone) { " &middot; zone $(& $e $r.Zone)" }) &middot; $(& $e $r.PowerState)</div></td><td>$currentCell</td><td>$(New-Badge $r.LifecycleStage)<div class='sub'>$(& $e $r.EvidenceClass)</div></td><td class='target-cell retirement-target-cell'>$retirementCell</td><td class='change-cell'>$(Get-MaterialChangeLinesHtml -Assessment $a)</td><td>$nextStep</td>$optional<td class='num nowrap'>$cost</td></tr>"
}

function New-VmTableHtml {
    <# The single per-VM table. Required retirement columns always; optional v6/v7 columns only with --check-modernization. -Details maps a VM anchor id to its detail block, rendered as a collapsed row under that VM. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Assessments, [switch]$CheckModernization, [hashtable]$Details = @{})
    if (@($Assessments).Count -eq 0) { return "<div class='callout ok'>No VMs in this subscription are on End of Life or retired sizes.</div>" }
    $columns = if ($CheckModernization) { 9 } else { 7 }
    $index = 0
    $rows = foreach ($a in $Assessments) {
        $anchor = Get-VmAnchorId $a.Vm
        $has = $Details.ContainsKey($anchor)
        New-VmSummaryRowHtml -Assessment $a -CheckModernization:$CheckModernization -HasDetails:$has -Alt:([bool]($index % 2))
        if ($has) { "<tr class='vm-detail-row' id='$anchor-details'><td colspan='$columns' class='vm-detail-cell'>$($Details[$anchor])</td></tr>" }
        $index++
    }
    $optionalGroup = if ($CheckModernization) { "<th colspan='2' class='group-head group-optional'>Optional &middot; v6/v7 modernization</th>" } else { '' }
    $optionalHead = if ($CheckModernization) { '<th>Modernization target</th><th>Migration path</th>' } else { '' }
    $tools = if ($Details.Count) { "<div class='vm-table-tools'><input type='checkbox' class='vm-toggle-all' id='vm-expand-all' aria-label='Show details for every VM'><label class='vm-toggle-all-label' for='vm-expand-all'><span class='off'>Expand all details</span><span class='on'>Collapse all details</span></label><span class='note'>Select Details on a VM, or the row itself, to see what to do, what changes and what to validate.</span></div>" } else { '' }
    "<div class='vm-table-block'>$tools<div class='table-wrap'><table class='vm-table'><thead><tr><th rowspan='2'>VM</th><th rowspan='2'>Current size</th><th colspan='4' class='group-head group-required'>Required &middot; retirement remediation</th>$optionalGroup<th rowspan='2' class='num'>PAYGO / month</th></tr><tr><th>Microsoft status</th><th>Retirement target</th><th>Material changes</th><th>Next step</th>$optionalHead</tr></thead><tbody>$($rows -join "`n")</tbody></table></div></div><p class='note'>Every VM is in <code>vm-assessment.csv</code>. Material changes list only differences that need attention; the full current-vs-target comparison is in each VM's details. Monthly cost is the public pay-as-you-go list price (730 h) for comparison only; your actual rates may differ.</p>"
}

function Get-ComparisonNote {
    <# Combined note for one comparison row, labelling which target it applies to when both are shown. #>
    param([Parameter(Mandatory)]$Row, [bool]$ShowRetirement, [bool]$ShowModernization)
    $rn = if ($ShowRetirement) { [string]$Row.RetirementNote } else { '' }
    $mn = if ($ShowModernization -or -not $ShowRetirement) { [string]$Row.ModernizationNote } else { '' }
    $parts = New-Object System.Collections.Generic.List[string]
    if ($ShowRetirement -and $ShowModernization) {
        if ($rn -and $rn -eq $mn) { $parts.Add("Both targets: $rn") }
        else {
            if ($rn) { $parts.Add("Retirement target: $rn") }
            if ($mn) { $parts.Add("Modernization target: $mn") }
        }
    }
    else { foreach ($n in @($rn, $mn)) { if ($n) { $parts.Add($n) } } }
    $parts -join '; '
}

function New-TargetComparisonMarkdown {
    <# Attribute | Current | Retirement target | Modernization target | Note, from the same Strategy.TargetComparison model as the HTML card. Returns $null when there is nothing to compare. #>
    param([Parameter(Mandatory)]$Strategy, [switch]$CheckModernization)
    $rt = $Strategy.RetirementTarget
    $mt = if ($CheckModernization -and -not $Strategy.AlreadyModern) { $Strategy.ModernizationTarget } else { $null }
    $rows = @($Strategy.TargetComparison)
    if ($rows.Count -eq 0 -or (-not $rt -and -not $mt)) { return $null }
    $same = [bool]($rt -and $mt -and $rt.SkuName -eq $mt.SkuName)
    $showRet = [bool]$rt
    $showMod = [bool]($mt -and -not $same)
    $retLabel = if ($same) { 'Retirement and modernization target' } else { 'Retirement target' }
    $columns = @('Attribute', 'Current') + $(if ($showRet) { $retLabel }) + $(if ($showMod) { 'Modernization target' }) + 'Note'
    $cell = { param($target, $change) if ($null -eq $target -or "$target" -eq '') { '' } elseif ($change) { "$target ($change)" } else { "$target" } }
    $table = foreach ($row in $rows) {
        $o = [ordered]@{ Attribute = $row.Attribute; Current = $row.Current }
        if ($showRet) { $o[$retLabel] = & $cell $row.RetirementTarget $row.RetirementChange }
        if ($showMod) { $o['Modernization target'] = & $cell $row.ModernizationTarget $row.ModernizationChange }
        $o['Note'] = Get-ComparisonNote -Row $row -ShowRetirement $showRet -ShowModernization $showMod
        [pscustomobject]$o
    }
    $targets = @(if ($showRet) { "${retLabel}: **$(ConvertTo-MarkdownText $rt.SkuName)**" }) + @(if ($showMod) { "Modernization target: **$(ConvertTo-MarkdownText $mt.SkuName)**" })
    "$($targets -join ' | ')`n`n$(Format-MdTable -Rows @($table) -Columns $columns)"
}

function New-TargetComparisonHtml {
    <# Attribute | Current | Retirement target | Modernization target, rendered from Strategy.TargetComparison. -ChangesOnly keeps the rows that differ. #>
    param([Parameter(Mandatory)]$Strategy, [switch]$CheckModernization, [switch]$ChangesOnly, [switch]$NoHeading)
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $rt = $Strategy.RetirementTarget
    $mt = if ($CheckModernization -and -not $Strategy.AlreadyModern) { $Strategy.ModernizationTarget } else { $null }
    $rows = @($Strategy.TargetComparison)
    if ($rows.Count -eq 0 -or (-not $rt -and -not $mt)) { return '' }
    $same = [bool]($rt -and $mt -and $rt.SkuName -eq $mt.SkuName)
    $showRet = [bool]$rt
    $showMod = [bool]($mt -and -not $same)
    if ($ChangesOnly) {
        $differs = 'Changed', 'Reduced', 'Improved'
        $rows = @($rows | Where-Object { $_.Attribute -ne 'Processor' -and (($showRet -and $_.RetirementChange -in $differs) -or ($showMod -and $_.ModernizationChange -in $differs)) })
        if ($rows.Count -eq 0) { return "<p class='note'>No material changes against the current size.</p>" }
    }
    $head = "<th>Attribute</th><th>Current</th>"
    if ($showRet) { $head += "<th>$(if ($same) { 'Retirement and modernization target' } else { 'Retirement target' }) <code>$(& $e $rt.SkuName)</code></th>" }
    if ($showMod) { $head += "<th>Modernization target <code>$(& $e $mt.SkuName)</code></th>" }
    $head += '<th>Note</th>'
    $body = foreach ($row in $rows) {
        $cells = "<td>$(& $e $row.Attribute)</td><td>$(& $e $row.Current)</td>"
        if ($showRet) { $cells += "<td>$(& $e $row.RetirementTarget) $(New-Badge $row.RetirementChange)</td>" }
        if ($showMod) { $cells += "<td>$(& $e $row.ModernizationTarget) $(New-Badge $row.ModernizationChange)</td>" }
        "<tr>$cells<td>$(& $e (Get-ComparisonNote -Row $row -ShowRetirement $showRet -ShowModernization $showMod))</td></tr>"
    }
    $heading = if ($NoHeading) { '' } else { '<h3>Current vs target size</h3>' }
    "$heading<div class='table-wrap compact'><table class='comparison-table'><thead><tr>$head</tr></thead><tbody>$($body -join '')</tbody></table></div>"
}

function New-GateComparisonHtml {
    <# One compatibility-gate table with a result column per target. Detail is shown once unless the targets differ. #>
    param($RetirementTarget, $ModernizationTarget)
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $ret = @(if ($RetirementTarget) { $RetirementTarget.Gates })
    $mod = @(if ($ModernizationTarget) { $ModernizationTarget.Gates })
    if ($RetirementTarget -and $ModernizationTarget -and $RetirementTarget.SkuName -eq $ModernizationTarget.SkuName) { $mod = @() }
    if ($ret.Count -eq 0 -and $mod.Count -eq 0) { return '' }
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($g in @($ret) + @($mod)) { if (-not $names.Contains([string]$g.Gate)) { $names.Add([string]$g.Gate) } }
    $head = '<th>Check</th>'
    if ($ret.Count) { $head += "<th>$(if ($mod.Count) { 'Retirement target' } else { 'Result' })$(if ($mod.Count) { " <code>$(& $e $RetirementTarget.SkuName)</code>" })</th>" }
    if ($mod.Count) { $head += "<th>$(if ($ret.Count) { 'Modernization target' } else { 'Result' }) <code>$(& $e $ModernizationTarget.SkuName)</code></th>" }
    $head += '<th>Detail</th>'
    $body = foreach ($name in $names) {
        $r = $ret | Where-Object Gate -eq $name | Select-Object -First 1
        $m = $mod | Where-Object Gate -eq $name | Select-Object -First 1
        $bothPass = $r -and $m -and $r.Result -eq 'Pass' -and $m.Result -eq 'Pass'
        $detail = if ($r -and $m -and -not $bothPass -and $r.Detail -ne $m.Detail) { "<strong>Retirement target:</strong> $(& $e $r.Detail)<br><strong>Modernization target:</strong> $(& $e $m.Detail)" }
        elseif ($r) { & $e $r.Detail }
        else { & $e $m.Detail }
        $cells = "<td>$(& $e $name)</td>"
        if ($ret.Count) { $cells += "<td>$(if ($r) { New-Badge $r.Result } else { "<span class='muted'>&ndash;</span>" })</td>" }
        if ($mod.Count) { $cells += "<td>$(if ($m) { New-Badge $m.Result } else { "<span class='muted'>&ndash;</span>" })</td>" }
        "<tr>$cells<td>$detail</td></tr>"
    }
    "<h3>Mandatory requirement checks</h3><div class='table-wrap'><table><thead><tr>$head</tr></thead><tbody>$($body -join '')</tbody></table></div>"
}

function New-VmDetailHtml {
    <# The collapsible detail block shown under a VM row: header, what to do, what changes, what to validate and the recommended sizes (-ExtendedDetails adds facts, explanations, gates and every evaluated size). #>
    param([Parameter(Mandatory)]$Assessment, [switch]$CheckModernization, [switch]$ExtendedDetails)
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $a = $Assessment
    $s = if ($a.Strategy) { $a.Strategy } else { Get-TargetStrategy -Assessment $a }
    $p = $a.Candidates.Primary; $sc = $a.Candidates.Secondary
    $rt = $s.RetirementTarget
    $mt = if ($CheckModernization -and -not $s.AlreadyModern) { $s.ModernizationTarget } else { $null }
    $parts = if ($CheckModernization) { Get-ModernizationDetailParts -Assessment $a } else { $null }
    $assumptions = @(Get-ConfidenceAssumption -Assessment $a -Strategy $s)
    $confidenceExplanation = Get-ConfidenceTooltip $a.Confidence -Assumptions $assumptions
    $confidenceBody = if (@($a.Confidence.LowReasons).Count -or @($a.Confidence.ValidationItems).Count) { "Confidence in the recommended size: $($a.Confidence.Level). The items to validate first are listed under Validate before resizing.$(if ($assumptions.Count) { " Assumed, without changing the level: $($assumptions -join ' ')" })" } else { $confidenceExplanation }
    $readinessExplanation = "Readiness of the recommended size: $($a.Readiness)."
    if ($script:ReadinessMeaning.Contains([string]$a.Readiness)) { $readinessExplanation += " $($script:ReadinessMeaning[[string]$a.Readiness].Long)" }
    $stage = Get-LifecycleStage -Lifecycle $a.Lifecycle
    $facts = [ordered]@{
        'Microsoft status' = "$(New-Badge $stage) $(New-Badge $a.Lifecycle.EvidenceClass) $(& $e $a.Lifecycle.LearnSeriesName) $(if ($a.Lifecycle.RetirementDate) { "&middot; retires <strong>$($a.Lifecycle.RetirementDate)</strong>" })$(if ($a.Lifecycle.SourceUrl) { " &middot; <a href='$(& $e $a.Lifecycle.SourceUrl)' target='_blank'>source</a>" })$(if ($stage -eq 'End of Life') { " &middot; $(New-LearnLink 'EndOfLifeList' 'End of Life list')" })"
        'Action' = "$(New-Badge $a.Action) &middot; next step: <strong>$(& $e $a.NextStep)</strong> &middot; $(New-Badge $a.Wave)"
        'Recommended size' = if ($p) { "<code>$(& $e $p.SkuName)</code> &middot; $(New-Badge $p.CpuVendor) $($p.vCPUs) vCPU &middot; $($p.MemoryGB) GB &middot; score <strong>$($p.Score)</strong> ($(& $e $p.Band))" } else { "<span class='muted'>$(& $e $a.Candidates.NoCandidateReason)</span>" }
    }
    if ($CheckModernization) {
        $facts['Retirement target'] = if ($rt) { "<code>$(& $e $rt.SkuName)</code> &middot; v$($rt.Generation) &middot; quota $(New-Badge $s.RetirementQuotaStatus)" } elseif ($s.RetirementRequired -or $s.RetirementUnconfirmed) { "<span class='muted'>No validated retirement target</span>" } else { "<span class='muted'>Not required</span>" }
        $facts['Modernization target'] = if ($s.AlreadyModern) { "<span class='muted'>Already on a v6/v7 generation</span>" } elseif ($mt) { "<code>$(& $e $mt.SkuName)</code> &middot; v$($mt.Generation) &middot; $(New-Badge $s.ModernizationReadiness) &middot; $(& $e $s.ModernizationPath)" } else { "<span class='muted'>No validated v6/v7 target</span>" }
        if ($s.RecommendedMigrationPath) { $facts['Recommended path'] = & $e $s.RecommendedMigrationPath }
        if ($a.Modernization -and $a.Modernization.Reason -and $s.ModernizationTargetSource -notin 'Selected', 'Primary' -and -not $s.AlreadyModern) { $facts['Why not a direct v6/v7 move'] = & $e $a.Modernization.Reason }
    }
    $facts['Alternative'] = if ($sc) { "<code>$(& $e $sc.SkuName)</code> (score $($sc.Score)) &middot; $(& $e $a.SecondaryReason)" } else { "<span class='muted'>None in the permitted series</span>" }
    if (-not $CheckModernization) {
        $facts['Newer if converted'] = if ($a.Candidates.FutureGeneration) {
            $fg = @($a.Candidates.FutureGeneration.FailedGates)
            $docs = @(if ($fg -contains 'Disk Controller') { New-LearnLink 'NvmeConvert' 'SCSI to NVMe conversion' }; if ($fg -contains 'VM Generation') { New-LearnLink 'Gen1TrustedLaunch' 'Gen1 to Trusted launch upgrade' })
            "<code>$(& $e $a.Candidates.FutureGeneration.SkuName)</code> &middot; requires $(& $e ($fg -join ', ')) conversion$(if ($docs.Count) { " &middot; " + ($docs -join ' &middot; ') })"
        } else { "<span class='muted'>&ndash;</span>" }
    }
    $facts['Quota'] = "$(New-Badge $a.QuotaStatus)$(if ($a.Quota -and $a.Quota.Family.Limit) { " &middot; $(& $e $a.Quota.Family.QuotaDisplayName): $($a.Quota.Family.CurrentUsage) / $($a.Quota.Family.Limit) used, needs $($a.Quota.Family.RequiredVcpu)" })"
    if ($parts -and $mt) { $facts['Modernization quota'] = "$(New-Badge $s.ModernizationQuotaStatus) / $(New-Badge $s.ModernizationPeakQuotaStatus) (steady / peak) &middot; $($parts.QuotaText) $(& $e $parts.QuotaModel)." }
    $facts['Candidate series'] = & $e $a.Candidates.PermittedSeries
    if ($a.Candidates.VendorChangeRequired) { $facts['CPU vendor change'] = & $e $a.Candidates.VendorChangeReason }
    if ($a.Rightsizing) { $facts['Rightsizing'] = "$(New-Badge $a.Rightsizing.Status) $(& $e $a.Rightsizing.Note)" }
    $factsHtml = if ($ExtendedDetails) { '<dl class="facts">' + (($facts.Keys | ForEach-Object { "<dt>$(& $e $_)</dt><dd>$($facts[$_])</dd>" }) -join '') + '</dl>' } else { '' }
    $validation = @(@($a.ValidationItems) + @($s.ValidationItems) + @($a.Confidence.LowReasons | ForEach-Object { "Low confidence: $_" }) + @($a.Lifecycle.Notes) | Where-Object { $_ } | Select-Object -Unique)
    # "Topic: text" items get a bold topic so the list can be scanned; the wording itself is unchanged.
    $notes = ($validation | ForEach-Object { if ("$_" -match '^([^:/]{2,40}):\s+(.+)$') { "<li><strong>$(& $e $Matches[1]):</strong> $(& $e $Matches[2])</li>" } else { "<li>$(& $e $_)</li>" } }) -join ''
    $blockerChips = @(if ($parts) { foreach ($topic in $parts.BlockerTopics) { "<span class='vd-chip'>$(& $e $topic)</span>" } })
    $blockerLine = if (-not $parts) { '' } elseif ($blockerChips.Count) { "<div class='vd-blockers'><span class='vd-label'>Blockers</span>$($blockerChips -join '')</div>" } else { "<div class='vd-blockers'><span class='vd-label'>Blockers</span><span class='vd-chip ok'>None detected</span></div>" }
    $steps = New-Object System.Collections.Generic.List[string]
    $fam = if ($a.Quota -and $a.Quota.Family) { $a.Quota.Family } else { $null }
    if ($p -or $rt) {
        if ($a.QuotaStatus -eq 'Quota Increase Required' -and $fam -and $fam.Limit) {
            $steps.Add("<li>Request vCPU quota for <strong>$(& $e $fam.QuotaDisplayName)</strong>: $($fam.CurrentUsage) / $($fam.Limit) used, the move needs $($fam.RequiredVcpu) vCPU.</li>")
        }
        elseif ($a.QuotaStatus -and $a.QuotaStatus -notin 'Quota OK', 'Quota Increase Required') { $steps.Add("<li>Confirm the target-family vCPU quota; it could not be verified ($(& $e $a.QuotaStatus)).</li>") }
        elseif ($a.QuotaStatus -eq 'Quota Increase Required') { $steps.Add('<li>Request the target-family and regional vCPU quota increase before the change window.</li>') }
    }
    else { $steps.Add("<li>No replacement size was found in the permitted series; review Microsoft's migration guidance manually.</li>") }
    if ($parts) { foreach ($r in $parts.Remediation) { $steps.Add($r) } }
    else { $steps.Add("<li>Resize in a change window, then validate disks, networking and the application ($(New-LearnLink 'Resize')).</li>") }
    $stepsHtml = "<ol class='vd-steps'>$($steps -join '')</ol>"
    $changesOnly = New-TargetComparisonHtml -Strategy $s -CheckModernization:$CheckModernization -ChangesOnly -NoHeading
    $comparisonFull = New-TargetComparisonHtml -Strategy $s -CheckModernization:$CheckModernization -NoHeading
    $changesHtml = if ($comparisonFull) { "$changesOnly<details class='vd-more'><summary>Show all $(@($s.TargetComparison).Count) attributes</summary>$comparisonFull</details>" } else { "<p class='note'>No target size to compare.</p>" }
    $gates = if ($ExtendedDetails) { New-GateComparisonHtml -RetirementTarget $(if ($rt) { $rt } else { $p }) -ModernizationTarget $mt } else { '' }
    $roleBySku = @{}
    foreach ($pair in @(@('Primary', $p), @('Secondary', $sc), @('Third', $a.Candidates.Third))) { if ($pair[1] -and -not $roleBySku.ContainsKey([string]$pair[1].SkuName)) { $roleBySku[[string]$pair[1].SkuName] = $pair[0] } }
    $allCands = @($a.Candidates.Candidates)
    $shownCands = @(if ($ExtendedDetails) { $allCands } else { $allCands | Where-Object { $roleBySku.ContainsKey([string]$_.SkuName) } })
    $hiddenCands = $allCands.Count - $shownCands.Count
    $cands = ($shownCands | ForEach-Object {
        $role = if ($roleBySku.ContainsKey([string]$_.SkuName)) { New-Badge 'Info' $roleBySku[[string]$_.SkuName] } else { "<span class='muted'>&ndash;</span>" }
        "<tr><td>$role</td><td><code>$(& $e $_.SkuName)</code></td><td>$(New-Badge $_.CpuVendor)</td><td class='num'>v$($_.Generation)</td><td class='num'>$($_.vCPUs) / $($_.MemoryGB)</td><td class='num'><strong>$($_.Score)</strong></td><td>$(New-Badge $_.Availability)</td><td>$(& $e $(if ($_.Rejected) { 'Rejected: ' + $_.RejectionReason } elseif (@($_.ReviewGates).Count) { 'Review: ' + ($_.ReviewGates -join ', ') } else { $_.Variant }))</td></tr>"
    }) -join ''
    $candsHeading = if ($ExtendedDetails) { 'Sizes evaluated' } else { 'Recommended sizes' }
    $candsNote = if ($hiddenCands -gt 0) { "<p class='note'>$hiddenCands more evaluated $(if ($hiddenCands -eq 1) { 'size is' } else { 'sizes are' }) shown when the report is generated with <code>-ExtendedDetails</code>.</p>" } else { '' }
    $explanations = if ($ExtendedDetails) { "<h3>Assessment explanations</h3>`n<dl class=`"facts`"><dt>Confidence: $(& $e $a.Confidence.Level)</dt><dd class=`"assessment-explanation`">$(& $e $confidenceBody)</dd><dt>Readiness: $(& $e $a.Readiness)</dt><dd class=`"assessment-explanation`">$(& $e $readinessExplanation)</dd></dl>" } else { '' }
    $first = if ($rt) { $rt.SkuName } elseif ($p) { $p.SkuName } else { 'no recommendation' }
    $move = "<code>$(& $e $a.Vm.SkuName)</code> <span class='move-arrow'>&rarr;</span> <code>$(& $e $first)</code>$(if ($mt -and $mt.SkuName -ne $first) { " <span class='move-arrow'>&rarr;</span> <code>$(& $e $mt.SkuName)</code>" })"
    $modernBadge = if ($CheckModernization -and $s.ModernizationReadiness) { " $(New-Badge $s.ModernizationReadiness -Label "Modernization: $($s.ModernizationReadiness)" -Title "Path: $($s.ModernizationPath). $($s.RecommendedMigrationPath)")" } else { '' }
        $metaParts = @(if ($a.Wave) { New-Badge $a.Wave }; if ($a.NextStep) { "next step: <strong>$(& $e $a.NextStep)</strong>" })
    $badges = "$(New-Badge $a.Confidence.Level -Label "Confidence: $($a.Confidence.Level)" -Title $confidenceExplanation) $(New-Badge $a.Readiness -Label "Readiness: $($a.Readiness)" -Title $readinessExplanation)$modernBadge"
    $extended = if ($ExtendedDetails) { "<div class='vd-extended'><h4>Extended details</h4>$explanations$factsHtml$gates</div>" } else { '' }
    @"
<div class="vm-detail">
<div class="vd-head"><span class="vd-move">$move</span><span class="vd-badges">$badges</span><div class="vd-meta">$($metaParts -join ' &middot; ')</div></div>
$blockerLine
<div class="vd-cols">
<div class="vd-col">
<section class="vd-card"><h4>What to do</h4>$stepsHtml</section>
$(if ($notes) { "<section class='vd-card'><h4>Validate before resizing</h4><ul class='vd-list'>$notes</ul></section>" })
</div>
<section class="vd-card"><h4>What changes</h4>$changesHtml</section>
</div>
<section class="vd-card"><h4>$candsHeading</h4>$(if ($cands) { "<div class='table-wrap compact'><table class='ref'><thead><tr><th>Role</th><th>Size</th><th>CPU</th><th class='num'>Gen</th><th class='num'>vCPU / GB</th><th class='num'>Score</th><th>Availability</th><th>Notes</th></tr></thead><tbody>$cands</tbody></table></div>$candsNote" } else { "<p class='note'>No current-generation size in the permitted series is offered in this region for this subscription. Review Microsoft's migration guidance for this series manually.</p>" })</section>
$extended
</div>
"@
}

function Get-PageCollectionIssue {
    <# The data-collection problems a page shows: all of them on the tenant page; on a subscription page (-SubscriptionId) that
       subscription's plus the tenant-wide ones. #>
    param([AllowEmptyCollection()][object[]]$Issues = @(), [string]$SubscriptionId)
    @($Issues | Where-Object { $_ -and (-not $SubscriptionId -or -not $_.SubscriptionId -or $_.SubscriptionId -eq $SubscriptionId) })
}

function New-CollectionIssuesHtml {
    <# A warning callout for data that could not be collected. -SubscriptionId limits it to one subscription plus the tenant-wide items. #>
    param([AllowEmptyCollection()][object[]]$Issues = @(), [string]$SubscriptionId, [hashtable]$SubscriptionNames = @{})
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $set = @(Get-PageCollectionIssue -Issues $Issues -SubscriptionId $SubscriptionId)
    if ($set.Count -eq 0) { return '' }
    $items = ($set | ForEach-Object {
            $subscription = if ($_.SubscriptionId -and -not $SubscriptionId) { if ($SubscriptionNames.ContainsKey([string]$_.SubscriptionId)) { $SubscriptionNames[[string]$_.SubscriptionId] } else { $_.SubscriptionId } }
            $where = @($subscription, $_.Region) | Where-Object { $_ }
            "<li><strong>$(& $e $_.Api)</strong>$(if ($where) { " <span class='muted'>&middot; $(& $e ($where -join ' / '))</span>" }): $(& $e $_.Message)$(if ($_.Effect) { " <span class='muted'>$(& $e $_.Effect)</span>" })</li>"
        }) -join ''
    "<div class='callout warn'><strong>Some data could not be collected ($($set.Count)).</strong> The results for the affected scopes are incomplete; fix the cause and run the assessment again.<ul>$items</ul></div>"
}

function New-VmNoRecommendationDetailHtml {
    <# The collapsible block for a listed VM that has no recommendation because no candidate search could run: why, and what to do. Same layout as New-VmDetailHtml. #>
    param([Parameter(Mandatory)]$Assessment)
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $a = $Assessment
    $reason = Get-NoRecommendationReason -Assessment $a
    $why = "<p>$(& $e $(if ($reason) { $reason } else { 'Size characteristics or region catalog unavailable' }))</p>"
    $issueItems = ($a.CollectionIssues | ForEach-Object { "<li><strong>$(& $e $_.Api):</strong> $(& $e $_.Message)$(if ($_.Effect) { " <span class='muted'>$(& $e $_.Effect)</span>" })</li>" }) -join ''
    if ($issueItems) { $why += "<ul class='vd-list'>$issueItems</ul>" }
    $notes = (@(@($a.ValidationItems) + @($a.Lifecycle.Notes) | Where-Object { $_ } | Select-Object -Unique) | ForEach-Object { "<li>$(& $e $_)</li>" }) -join ''
        $metaParts = @(if ($a.Wave) { New-Badge $a.Wave }; if ($a.NextStep) { "next step: <strong>$(& $e $a.NextStep)</strong>" })
    $badges = "$(New-Badge $a.Confidence.Level -Label "Confidence: $($a.Confidence.Level)") $(New-Badge $a.Readiness -Label "Readiness: $($a.Readiness)")"
    $steps = "<ol class='vd-steps'><li>Resolve the problem described here (access, provider registration or service availability), then run the assessment again.</li><li>Until then, check Microsoft's guidance for this size manually ($(New-LearnLink 'EndOfLifeList' 'End of Life list')).</li></ol>"
    @"
<div class="vm-detail">
<div class="vd-head"><span class="vd-move"><code>$(& $e $a.Vm.SkuName)</code> <span class='move-arrow'>&rarr;</span> <code>no recommendation</code></span><span class="vd-badges">$badges</span><div class="vd-meta">$($metaParts -join ' &middot; ')</div></div>
<div class="vd-cols">
<section class="vd-card"><h4>Why there is no recommendation</h4>$why</section>
<div class="vd-col">
<section class="vd-card"><h4>What to do</h4>$steps</section>
$(if ($notes) { "<section class='vd-card'><h4>Validate before resizing</h4><ul class='vd-list'>$notes</ul></section>" })
</div>
</div>
</div>
"@
}

function Get-ModernizationDetailParts {
    <# Blocker topics, remediation steps and quota text for the modernization target of one VM, from Assessment.Strategy. Rendered inside the VM's detail block. #>
    param([Parameter(Mandatory)]$Assessment)
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $a = $Assessment
    $s = if ($a.Strategy) { $a.Strategy } else { Get-TargetStrategy -Assessment $a }
    $p = $s.ModernizationTarget
    $modernQuota = $s.ModernizationQuotaStatus
    $manualValidation = @($s.ValidationItems).Count -gt 0

    $topics = New-Object System.Collections.Generic.List[string]
    if ($s.RedeployReview) { $topics.Add('Deployment model') }
    if ($s.RequiresGenerationChange) { $topics.Add('VM generation') }
    if ($s.RequiresNvmeConversion) { $topics.Add('Disk controller') }
    if ($modernQuota -eq 'Quota Increase Required') { $topics.Add('Quota') }
    if (-not $p -and -not $s.AlreadyModern) { $topics.Add('Target') }
    if ($manualValidation) { $topics.Add('Guest/workload validation') }

    $remediation = New-Object System.Collections.Generic.List[string]
    if ($s.RedeployReview) { $remediation.Add('<li>Deploy a Gen2 VM on a supported OS image and migrate the workload/data (side-by-side).</li>') }
    elseif ($s.RequiresGenerationChange) { $remediation.Add("<li>Upgrade the Gen1 VM to Trusted launch (Gen2), or rebuild if the OS or size is not supported ($(New-LearnLink 'Gen1TrustedLaunch')).</li>") }
    if ($s.RequiresNvmeConversion) { $remediation.Add("<li>Validate guest NVMe support and backup/rollback, then convert the disk controller to NVMe before resizing ($(New-LearnLink 'NvmeConvert')).</li>") }
    if ($modernQuota -eq 'Quota Increase Required') { $remediation.Add('<li>Request the reported target-family and regional vCPU quota before scheduling the migration (use peak demand for side-by-side paths).</li>') }
    if (-not $p -and -not $s.AlreadyModern) { $remediation.Add('<li>Review the modernization reason and candidate table; no v6/v7 size passed the workload gates or is available.</li>') }
    if ($remediation.Count -eq 0) { $remediation.Add("<li>Schedule a standard resize window and complete normal post-resize validation ($(New-LearnLink 'Resize')).</li>") }

    $mq = $a.ModernizationQuota
    $quotaText = if ($mq -and $mq.Family) {
        $q = $mq.Family
        $display = if ($q.QuotaDisplayName) { $q.QuotaDisplayName } else { $q.QuotaName }
        $usage = if ($null -ne $q.Limit) { "$([int]$q.CurrentUsage) / $([int]$q.Limit) used" } else { 'usage unavailable' }
        "<strong>$(& $e $display)</strong>: $usage. This VM adds $([int]$mq.SteadyStateRequiredVcpu) vCPU steady-state and $([int]$mq.PeakMigrationRequiredVcpu) vCPU at peak to the family; regional vCPUs +$([int]$mq.SteadyStateRegionalRequiredVcpu) / +$([int]$mq.PeakMigrationRegionalRequiredVcpu)."
    }
    elseif ($p) { '<span class="muted">Target quota was not captured for this VM. Validate target-family and regional quota before execution.</span>' }
    else { '<span class="muted">No modernization target; no modernization quota demand.</span>' }
    $quotaModel = switch ($s.MigrationQuotaModel) { 'SideBySide' { 'Side-by-side: target capacity is needed while the source still exists' } 'InPlace' { 'In-place resize' } default { 'Not applicable' } }

    [pscustomobject]@{ BlockerTopics = $topics.ToArray(); Remediation = $remediation.ToArray(); QuotaText = $quotaText; QuotaModel = $quotaModel }
}

function Get-BottomLine {
    <# Plain-language summary sentences for the top of a page. -TenantView points quota readers to the subscription reports, which hold the quota table. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Assessments, [switch]$TenantView)
    $out = New-Object System.Collections.Generic.List[string]
    $retiring = @($Assessments | Where-Object { $_.AffectedByRetirement -eq 'Yes' })
    $retired = @($retiring | Where-Object { $_.Lifecycle.EvidenceClass -eq 'Already Retired' })
    $modern = @($Assessments | Where-Object { $_.Wave -eq 'Wave 4 - Modernization' })
    $unknown = @($Assessments | Where-Object { $_.AffectedByRetirement -eq 'Unknown' })
    if ($Assessments.Count -eq 0) { $out.Add('No virtual machines were found in scope.'); return $out.ToArray() }
    if ($retiring.Count -eq 0) { $out.Add("None of the $($Assessments.Count) VMs run on a VM size that Microsoft has retired or scheduled for retirement.") }
    else {
        $out.Add("<strong>$($retiring.Count) of $($Assessments.Count) VMs</strong> run on VM sizes that Microsoft has retired or scheduled for retirement.")
        if ($retired.Count) { $out.Add("<strong>$($retired.Count) VM(s)</strong> are on sizes that are already retired and need immediate attention.") }
    }
    if ($modern.Count) { $out.Add("$($modern.Count) VM(s) run on an older generation that is <em>not</em> retiring (Wave 4 modernization); no retirement deadline applies.") }
    if ($unknown.Count) { $out.Add("$($unknown.Count) VM(s) could not be matched to Microsoft lifecycle data and need manual confirmation.") }
    $quota = @($Assessments | Where-Object QuotaStatus -eq 'Quota Increase Required')
    if ($quota.Count) { $out.Add("$($quota.Count) recommended move(s) need a vCPU quota increase first ($(if ($TenantView) { 'see Quota Actions in the subscription reports' } else { 'see Quota Actions' })).") }
    $ready = @($Assessments | Where-Object { $_.Readiness -eq 'Ready' -and $_.Action -ne 'No Action Required' })
    if ($ready.Count) { $out.Add("$($ready.Count) recommended move(s) are ready to schedule, subject to the listed validation items.") }
    return $out.ToArray()
}

function Get-FamilyCpuOptions {
    <# Latest generation per CPU vendor for a VM family letter, derived from the Microsoft Learn processor catalog. #>
    param($ProcessorCatalog, [Parameter(Mandatory)][string]$Letter)
    if (-not $ProcessorCatalog) { return $null }
    $l = $Letter.ToLowerInvariant()
    $rows = foreach ($p in $ProcessorCatalog.series.PSObject.Properties) {
        if ($p.Name -notmatch "^$l([a-z]*)v(\d+)$") { continue }
        $feat = $Matches[1]; $ver = [int]$Matches[2]
        if ($feat -match '^(c|n|x)' -or $feat -match 'i') { continue }
        if ($p.Value.vendor -notin 'Intel', 'AMD', 'ARM') { continue }
        [pscustomobject]@{ Key = $p.Name; Vendor = $p.Value.vendor; Version = $ver; Len = $p.Name.Length }
    }
    $parts = foreach ($g in (@($rows) | Group-Object Vendor | Sort-Object { @('Intel', 'AMD', 'ARM').IndexOf($_.Name) })) {
        $max = ($g.Group | Measure-Object Version -Maximum).Maximum
        $names = @($g.Group | Where-Object Version -eq $max | Sort-Object Len, Key | Select-Object -First 3 | ForEach-Object { $_.Key.Substring(0, 1).ToUpperInvariant() + $_.Key.Substring(1) })
        "<strong>$($g.Name)</strong> $(ConvertTo-HtmlEncoded ($names -join ', '))"
    }
    if (@($parts).Count -eq 0) { return $null }
    return (@($parts) -join ' &middot; ')
}

function New-ReferenceSections {
    <# Cross-vendor warnings, SKU family reference, CPU-vendor-from-name guide and known limitations. #>
    param($ProcessorCatalog, $Run, $Summary, $CatalogResult)
    $e = { param($x) ConvertTo-HtmlEncoded $x }

    $warn = @"
<div class="grid-2">
<div class="callout warn"><h3>Sensitive to a CPU vendor change (Intel &harr; AMD)</h3><ul>
<li><strong>Licensing:</strong> per-core or per-socket licensed software (for example Oracle, some SAP components) may be priced or certified per processor family.</li>
<li><strong>Instruction sets:</strong> applications compiled for specific extensions (AVX-512, AMX, or vendor-optimised math libraries) must be confirmed on the target processor.</li>
<li><strong>Latency-sensitive workloads:</strong> real-time, trading or tuned HPC workloads can behave differently with different cache and clock profiles.</li>
<li><strong>Infrastructure roles:</strong> domain controllers, clustered or appliance VMs: follow the vendor's support statement before changing CPU vendor.</li>
</ul></div>
<div class="callout ok"><h3>Usually safe to move across vendors</h3><ul>
<li>Stateless web and API tiers, Linux application servers</li>
<li>CI/CD build agents and dev/test environments</li>
<li>General Windows workloads and AVD session hosts running productivity apps</li>
</ul></div>
</div>
<div class="grid-2">
<div class="callout info"><h3>How this assessment handles vendors</h3><ul>
<li>The same CPU vendor is always preferred: Intel &rarr; Intel, AMD &rarr; AMD, ARM &rarr; ARM.</li>
<li>A different vendor is proposed only when no same-vendor size passes the mandatory checks. It is flagged <em>CPU Vendor Change Required</em>, loses 20 score points and lowers confidence.</li>
</ul></div>
<div class="callout danger"><h3>Never cross architecture</h3><ul>
<li>x64 &rarr; Arm64 (Azure Cobalt / Ampere) requires recompiled applications and ARM-compatible OS images. It is never recommended automatically.</li>
<li><strong>Test after any resize:</strong> run the workload for 24&ndash;48 hours and watch CPU patterns and application performance.</li>
</ul></div>
</div>
"@

    $families = @(
        @{ L = 'B'; Fit = 'Burstable: dev/test, small web servers, low average CPU'; Mem = 'Varies'; Fallback = 'Intel Bsv2 &middot; AMD Basv2 &middot; ARM Bpsv2' }
        @{ L = 'D'; Fit = 'General purpose: balanced CPU and memory, most business apps'; Mem = '~4 GiB / vCPU'; Fallback = 'Intel Dsv6 &middot; AMD Dasv6 &middot; ARM Dpsv6' }
        @{ L = 'E'; Fit = 'Memory optimised: databases, caching, analytics'; Mem = '~8 GiB / vCPU'; Fallback = 'Intel Esv6 &middot; AMD Easv6 &middot; ARM Epsv6' }
        @{ L = 'F'; Fit = 'Compute optimised: batch, web front ends, gaming, analytics'; Mem = '~2 GiB / vCPU'; Fallback = 'AMD Fasv6, Falsv6' }
        @{ L = 'L'; Fit = 'Storage optimised: high-throughput local NVMe (NoSQL, data warehousing)'; Mem = '~8 GiB / vCPU'; Fallback = 'Intel Lsv3 &middot; AMD Lasv3' }
        @{ L = 'M'; Fit = 'Memory intensive: SAP HANA, very large in-memory databases'; Mem = 'Up to ~30 GiB / vCPU'; Fallback = 'Intel' }
        @{ L = 'N'; Fit = 'GPU accelerated: AI/ML training and inference, visualisation, rendering'; Mem = 'Varies'; Fallback = 'Intel or AMD host + NVIDIA / AMD GPU' }
    )
    $famRows = foreach ($f in $families) {
        $opts = if ($f.L -in 'M', 'N') { $null } else { Get-FamilyCpuOptions -ProcessorCatalog $ProcessorCatalog -Letter $f.L }
        if (-not $opts) { $opts = $f.Fallback }
        "<tr><td class='fam'>$($f.L)</td><td>$(& $e $f.Fit)</td><td class='nowrap'>$(& $e $f.Mem)</td><td>$opts</td></tr>"
    }
    $famTable = @"
<div class="table-wrap"><table class="ref"><thead><tr><th>Family</th><th>Workload fit</th><th>Memory ratio</th><th>Latest generation by CPU vendor</th></tr></thead><tbody>
$($famRows -join "`n")
</tbody></table></div>
<p class="note">"Latest generation" is taken from the Microsoft Learn size-series processor tables used by this assessment. Confidential (DC/EC), isolated and network-optimised variants are omitted.</p>
"@

    $cpuTable = @"
<div class="table-wrap"><table class="ref"><thead><tr><th>Letter in the size name</th><th>Meaning</th><th>Example</th></tr></thead><tbody>
<tr><td><code>a</code></td><td><span class='badge b-blue'>AMD</span> AMD EPYC processor</td><td><code>Standard_D4<mark>a</mark>s_v5</code></td></tr>
<tr><td><code>p</code></td><td><span class='badge b-blue'>ARM</span> Arm64 processor (Ampere Altra on v5, Azure Cobalt 100 on v6)</td><td><code>Standard_D4<mark>p</mark>s_v6</code></td></tr>
<tr><td>neither <code>a</code> nor <code>p</code></td><td><span class='badge b-blue'>Intel</span> Intel Xeon processor</td><td><code>Standard_D4s_v5</code></td></tr>
<tr><td><code>d</code></td><td>Local temp disk included</td><td><code>Standard_D4a<mark>d</mark>s_v6</code></td></tr>
<tr><td><code>s</code></td><td>Premium Storage capable</td><td><code>Standard_E8<mark>s</mark>_v5</code></td></tr>
<tr><td><code>l</code></td><td>Low memory per vCPU</td><td><code>Standard_D4a<mark>l</mark>s_v6</code></td></tr>
<tr><td><code>m</code></td><td>Memory intensive (highest memory per vCPU in the family)</td><td><code>Standard_F4a<mark>m</mark>s_v6</code></td></tr>
<tr><td><code>b</code></td><td>Higher remote-storage (block) performance</td><td><code>Standard_E8<mark>b</mark>ds_v5</code></td></tr>
<tr><td><code>i</code></td><td>Isolated size (dedicated to one customer)</td><td><code>Standard_E104<mark>i</mark>s_v5</code></td></tr>
<tr><td><code>_v5</code>, <code>_v6</code>&hellip;</td><td>Hardware generation: higher is newer</td><td><code>Standard_D4s<mark>_v6</mark></code></td></tr>
</tbody></table></div>
<div class="callout info"><strong>The name is only a hint.</strong> Exceptions exist: for example, <code>Standard_L8s_v2</code> runs on AMD EPYC 7551 even though it has no <code>a</code>. This assessment reads the CPU vendor from the Microsoft Learn size-series processor tables first (<em>Verified</em>). It falls back to the naming convention only when a series is missing (<em>Partially Verified</em>). Source: <a href="https://learn.microsoft.com/azure/virtual-machines/vm-naming-conventions" target="_blank">Azure VM naming conventions</a>.</div>
"@

    $p = if ($Run) { $Run.Parameters } else { @{} }
    $c = if ($Run) { $Run.Counts } else { $null }
    $get = { param($o, $n) if ($null -ne $o -and (($o -is [System.Collections.IDictionary] -and $o.Contains($n)) -or ($o -isnot [System.Collections.IDictionary] -and $o.PSObject.Properties.Name -contains $n))) { $o.$n } else { $null } }
    $vmCount = if ($Summary) { $Summary.TotalVmsScanned } else { & $get $c 'Vms' }
    $subCount = if ($Summary) { $Summary.TotalSubscriptionsScanned } else { $null }
    $evid = if ($CatalogResult) { $CatalogResult.Source } else { 'Unknown' }
    $lim = @(
        [pscustomobject]@{ C = 'VM inventory (Azure Resource Graph)'; S = 'Done'; N = "$vmCount VMs across $subCount subscription(s), joined to NICs, disks and extensions." }
        [pscustomobject]@{ C = 'Retirement evidence (Microsoft Learn)'; S = $(if ($evid -eq 'Live') { 'Done' } else { 'Partial' }); N = "Retired-sizes list, previous-gen list and migration guide ($evid). No date is inferred from VM age." }
        [pscustomobject]@{ C = 'CPU vendor and processor'; S = 'Done'; N = 'Microsoft Learn size-series processor tables; naming convention used only as a fallback.' }
        [pscustomobject]@{ C = 'Size capabilities and restrictions'; S = 'Done'; N = 'Subscription-scoped Resource SKUs API: temp disk, controller, Hyper-V generation, zones, restrictions.' }
        [pscustomobject]@{ C = 'vCPU quota'; S = 'Done'; N = 'Family and regional quota per subscription/region; demand aggregated across VMs moving to the same family.' }
        [pscustomobject]@{ C = 'Azure Advisor / Service Health'; S = 'Done'; N = "Best-effort corroboration: $(& $get $c 'AdvisorRetirement') Advisor upgrade and retirement recommendations (only those that name a VM size corroborate the lifecycle; the others, such as Trusted launch or scale-set suggestions, are listed as notes) and $(& $get $c 'ServiceHealthRetirement') Service Health retirement events." }
        [pscustomobject]@{ C = 'Retail pricing'; S = $(if ($Run -and $Run.PSObject.Properties.Name -contains 'PricingStatus') { $Run.PricingStatus } elseif (& $get $p 'IncludePricing') { 'Done' } else { 'Skipped' }); N = 'On by default (-SkipPricing turns it off). Partial means only completed regions have prices; incomplete-region results are discarded. Unavailable means no region completed. Blank prices can also mean no matching list price exists. Pay-as-you-go list price x 730 h (prices.azure.com). Excludes EA/MCA discounts, reservations, savings plans and Azure Hybrid Benefit.' }
        [pscustomobject]@{ C = 'Rightsizing telemetry'; S = $(if (& $get $p 'IncludeRightsizing') { 'Done' } else { 'Skipped' }); N = 'Azure Monitor CPU / memory for running VMs with an action. Deallocated VMs have no recent data. Never changes the recommendation.' }
        [pscustomobject]@{ C = 'Physical regional capacity'; S = 'Not verifiable'; N = 'Quota and SKU restrictions do not guarantee allocatable hardware; confirm with a resize or Capacity Reservation.' }
        [pscustomobject]@{ C = 'Nested virtualization / temp-disk usage'; S = 'Not verifiable'; N = 'Not visible from the Azure control plane; confirm with the workload owner.' }
        [pscustomobject]@{ C = 'Network bandwidth caps'; S = 'Not verifiable'; N = 'Not exposed by the Resource SKUs API; see the Microsoft Learn size page.' }
        [pscustomobject]@{ C = 'VM Scale Sets (Uniform)'; S = 'Excluded'; N = 'Only VM resources are inventoried; scale-set models share quota but are assessed separately.' }
        [pscustomobject]@{ C = 'Reserved Instances / Savings Plans'; S = 'Not assessed'; N = 'Requires billing access; check RI exchange options before resizing reserved VMs.' }
    )
    $limRows = foreach ($r in $lim) { "<tr><td><strong>$(& $e $r.C)</strong></td><td>$(New-Badge $r.S)</td><td>$(& $e $r.N)</td></tr>" }
    $limTable = "<div class='table-wrap'><table class='ref'><thead><tr><th>Check</th><th>Status</th><th>Notes</th></tr></thead><tbody>$($limRows -join "`n")</tbody></table></div>"

    return @(
        (New-Section -Id 'upgrade-guidance' -Title 'Upgrade and Modernization Scenarios' -Body (New-UpgradeGuidanceHtml) -Intro 'Recommended steps for each migration path, with examples and Microsoft Learn links, including SCSI to NVMe conversion and Gen1 to Gen2 (Trusted launch).' -Collapsed)
        (New-Section -Id 'cross-vendor' -Title 'Cross-Vendor Migration Warnings' -Body $warn -Intro 'Moving between Intel and AMD is usually transparent to the operating system, but some workloads need validation first.' -Collapsed)
        (New-Section -Id 'sku-families' -Title 'SKU Family Quick Reference' -Body $famTable -Intro 'The first letter of a VM size is its family. Replacements stay in the same family unless Microsoft''s migration guide names another one.' -Collapsed)
        (New-Section -Id 'cpu-vendor' -Title 'CPU Vendor from SKU Name' -Body $cpuTable -Intro 'How to read a VM size name such as <code>Standard_D4ads_v6</code>.' -Collapsed)
        (New-Section -Id 'limitations' -Title 'Known Limitations' -Body $limTable -Intro 'What this assessment could and could not verify. Anything not verifiable is labelled rather than assumed.' -Collapsed)
    ) -join "`n"
}

function Export-HtmlReports {
    param([Parameter(Mandatory)][string]$OutDir, [Parameter(Mandatory)][string]$CssPath, [Parameter(Mandatory)]$Run, [Parameter(Mandatory)]$Summary, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Assessments, $QuotaImpact, $CatalogResult, $ProcessorCatalog, [object[]]$CollectionIssues = @())
    $css = Get-Content $CssPath -Raw
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $s = $Summary
    $indexName = 'index.html'
    $asOf = $Run.AsOf.ToString('yyyy-MM-dd')
    $meta = @("Tenant <strong>$(& $e $Run.Tenant.Name)</strong>", "As of <strong>$asOf</strong>", "Evidence <strong>$(& $e $CatalogResult.Source)</strong>", 'Read-only')
    $dataSource = if ($Run.PSObject.Properties.Name -contains 'DataSource' -and $Run.DataSource -and $Run.DataSource -ne 'Live') { $Run.DataSource } else { $null }
    if ($dataSource) { $meta += "Data <strong>$(& $e $dataSource)</strong>" }
    $reference = New-ReferenceSections -ProcessorCatalog $ProcessorCatalog -Run $Run -Summary $s -CatalogResult $CatalogResult
    $refNav = @(@{ Id = 'upgrade-guidance'; Label = 'Upgrade scenarios' }, @{ Id = 'cross-vendor'; Label = 'Cross-vendor' }, @{ Id = 'sku-families'; Label = 'SKU families' }, @{ Id = 'cpu-vendor'; Label = 'CPU from name' }, @{ Id = 'limitations'; Label = 'Limitations' })
    $checkModernization = [bool](Get-RunParameter -Run $Run -Name 'CheckModernization' -Default $false)
    $includeOptional = [bool](Get-RunParameter -Run $Run -Name 'HtmlIncludeOptionalModernization' -Default $false)
    $maxDetails = [int](Get-RunParameter -Run $Run -Name 'HtmlMaxVmDetails' -Default 250)
    $extendedDetails = [bool](Get-RunParameter -Run $Run -Name 'ExtendedDetails' -Default $false)
    $listed = { param($a) Test-HtmlListedVm -Assessment $a -IncludeOptional:$includeOptional }
    $scopeText = if ($includeOptional) { 'VMs on End of Life or retired sizes (Microsoft-announced retirement) that need action, plus optional modernization (older generations without an announced retirement), are listed.' } else { 'Only VMs on End of Life or retired sizes (Microsoft-announced retirement) that need action are listed.' }
    $ageDays = if ($Run.PSObject.Properties.Name -contains 'SnapshotAgeDays' -and $null -ne $Run.SnapshotAgeDays) { [int]$Run.SnapshotAgeDays } else { $null }
    $staleHtml = if ($null -ne $ageDays -and $ageDays -gt 7) { "<div class='callout warn'><strong>Replayed data is $ageDays days old.</strong> Quota, regional availability and inventory may have changed since the snapshot was captured. Capture a new snapshot before acting on quota or resize decisions.</div>" } else { '' }
    $subFile = { param($id, $name) (Get-SafeFileName $name) + '-' + $id.Substring(0, [math]::Min(8, $id.Length)) + '.html' }

    # -- Tenant index --
    $gen1Vms = Get-Gen1VmCount -Assessments $Assessments
    # The same set as the Wave 4 rows of the executive summary, the Subscriptions table and each subscription page.
    $wave4Vms = @($Assessments | Where-Object { $_.Wave -eq 'Wave 4 - Modernization' }).Count
    $kpis = @(
        (New-Kpi $s.TotalVmsScanned 'VMs assessed' 'neutral' "$($s.TotalSubscriptionsScanned) subscription(s)")
        (New-Kpi $s.AffectedVms 'On retiring sizes' $(if ($s.AffectedVms) { 'orange' } else { 'green' }) 'Microsoft-confirmed')
        (New-Kpi $s.AlreadyRetired 'Already retired' $(if ($s.AlreadyRetired) { 'red' } else { 'green' }))
        (New-Kpi $s.RetirementWithin12Months 'Retire < 12 months' $(if ($s.RetirementWithin12Months) { 'red' } else { 'neutral' }))
        (New-Kpi ($s.RetirementWithin24Months + $s.RetirementWithin36Months) 'Retire in 1-3 years' $(if ($s.RetirementWithin24Months + $s.RetirementWithin36Months) { 'orange' } else { 'neutral' }))
        (New-Kpi $wave4Vms 'Modernization (Wave 4)' 'purple' 'Older, not retiring')
        (New-Kpi $gen1Vms 'Gen1 VMs' $(if ($gen1Vms) { 'yellow' } else { 'green' }) "of $($s.TotalVmsScanned) VM$(if ($s.TotalVmsScanned -ne 1) { 's' })")
        (New-Kpi $s.VmsRequiringQuotaIncrease 'Need quota increase' $(if ($s.VmsRequiringQuotaIncrease) { 'orange' } else { 'neutral' }))
        (New-Kpi $s.HighConfidence 'High-confidence moves' 'green')
    ) -join ''
    $bottom = (Get-BottomLine -Assessments $Assessments -TenantView | ForEach-Object { "<li>$_</li>" }) -join ''
    $srcHtml = (@($CatalogResult.Catalog.sources) | ForEach-Object { "<li><a href='$(& $e $_.Url)' target='_blank'>$(& $e $(if ($_.Title) { $_.Title -replace ' - Azure Virtual Machines \| Microsoft Learn$', '' } else { $_.Name }))</a> <span class='muted'>&middot; updated $(& $e $_.UpdatedAt) &middot; retrieved $(& $e $_.RetrievedUtc)</span></li>" }) -join ''
    $warn = $staleHtml
    $subscriptionNames = @{}
    foreach ($a in $Assessments) { $subscriptionNames[[string]$a.Vm.SubscriptionId] = $a.SubscriptionName }
    $warn += New-CollectionIssuesHtml -Issues $CollectionIssues -SubscriptionNames $subscriptionNames
    if ($CatalogResult.Warning) { $warn += "<div class='callout warn'><strong>Evidence warning:</strong> $(& $e $CatalogResult.Warning)</div>" }
    $unm = @(Get-UnmappedSeriesNames -Catalog $CatalogResult.Catalog)
    if ($unm.Count -gt 0) { $warn += "<div class='callout warn'><strong>Microsoft series without a size mapping (not classified):</strong> $(& $e ($unm -join ', '))</div>" }
    $nonVm = @(Get-NonVmSizeEntries -Catalog $CatalogResult.Catalog)
    if ($nonVm.Count -gt 0) { $warn += "<div class='callout info'><strong>Microsoft lifecycle entries that are not VM sizes:</strong> $(& $e ((@($nonVm) | ForEach-Object { "$($_.Name) ($($_.Category), $($_.Status))" }) -join '; ')). They are not matched to VMs; validate them separately (for example, Dedicated Host SKUs).</div>" }
    # What the page warns about, for the footer: each collection problem, plus the stale snapshot, the evidence warning and unmapped series.
    $indexWarnings = @(Get-PageCollectionIssue -Issues $CollectionIssues).Count + $(if ($staleHtml) { 1 } else { 0 }) + $(if ($CatalogResult.Warning) { 1 } else { 0 }) + $(if ($unm.Count -gt 0) { 1 } else { 0 })

    $waveOrder = 'Wave 1 - Urgent', 'Wave 2 - Near Term', 'Wave 3 - Planned', 'Beyond Horizon', 'Review - Unconfirmed', 'Wave 4 - Modernization'
    $waveRows = foreach ($w in $waveOrder) {
        foreach ($g in (@($Assessments | Where-Object { $_.Wave -eq $w -and (& $listed $_) }) | Group-Object { $_.Vm.SkuName } | Sort-Object Count -Descending)) {
            $f = $g.Group[0]
            $rec = @($g.Group | ForEach-Object { if ($_.Candidates -and $_.Candidates.Primary) { $_.Candidates.Primary.SkuName } else { 'No recommendation' } } | Group-Object | Sort-Object Count -Descending | ForEach-Object { if ($g.Count -gt 1) { "$($_.Name) &times;$($_.Count)" } else { $_.Name } }) -join ', '
            "<tr><td>$(New-Badge $w)</td><td><code>$(& $e $g.Name)</code></td><td>$(New-Badge (Get-LifecycleStage -Lifecycle $f.Lifecycle))<div class='sub'>$(& $e $f.Lifecycle.EvidenceClass)</div></td><td class='num'>$($g.Count)</td><td>$rec</td></tr>"
        }
    }
    $waveHtml = if (@($waveRows).Count) { "<div class='table-wrap'><table><thead><tr><th>Wave</th><th>Current size</th><th>Microsoft status</th><th class='num'>VMs</th><th>Recommended size</th></tr></thead><tbody>$($waveRows -join "`n")</tbody></table></div>" } else { "<div class='callout ok'>No VMs are on End of Life or retired sizes.</div>" }
    $waveIntro = "$scopeText Every VM is in <code>vm-assessment.csv</code> and <code>assessment.json</code>."

    $subRows = foreach ($g in ($Assessments | Group-Object { $_.Vm.SubscriptionId } | Sort-Object { $_.Group[0].SubscriptionName })) {
        $name = $g.Group[0].SubscriptionName
        $aff = @($g.Group | Where-Object AffectedByRetirement -eq 'Yes').Count
        $w1 = @($g.Group | Where-Object Wave -eq 'Wave 1 - Urgent').Count
        $mod = @($g.Group | Where-Object Wave -eq 'Wave 4 - Modernization').Count
        $q = @($g.Group | Where-Object QuotaStatus -eq 'Quota Increase Required').Count
        "<tr><td><a class='strong' href='$(& $subFile $g.Name $name)'>$(& $e $name)</a><div class='sub'>$(& $e $g.Name)</div></td><td class='num'>$($g.Count)</td><td class='num'>$(if ($aff) { New-Badge 'Confirmed Retirement' "$aff" } else { '0' })</td><td class='num'>$(if ($w1) { New-Badge 'Wave 1' "$w1" } else { '0' })</td><td class='num'>$(if ($mod) { New-Badge 'Modernization' "$mod" } else { '0' })</td><td class='num'>$(if ($q) { New-Badge 'Quota Increase' "$q" } else { '0' })</td></tr>"
    }
    $subHtml = if (@($subRows).Count) { "<div class='table-wrap'><table><thead><tr><th>Subscription</th><th class='num'>VMs</th><th class='num'>On retiring sizes</th><th class='num'>Wave 1</th><th class='num'>Wave 4</th><th class='num'>Quota increase</th></tr></thead><tbody>$($subRows -join "`n")</tbody></table></div><p class='note'>Only subscriptions that contain VMs are listed. Select a subscription for per-VM details.</p>" } else { "<p class='note'>No subscriptions with VMs.</p>" }

    $quotaRows = @(if ($QuotaImpact) { @($QuotaImpact.FamilyRows) + @($QuotaImpact.RegionalRows) | Where-Object { $_ } })
    $quotaIntro = 'Demand is added up for all VMs moving into the same subscription, region and VM family. Minimum increase = current usage + needed &minus; limit; the recommended request adds a safety margin.'

    $body = @(
        "<section id='summary' class='card'><h2>Summary</h2><div class='kpis kpis-index'>$kpis</div><div class='bottom-line'><h3>Bottom line</h3><ul>$bottom</ul></div></section>"
        $warn
        (New-Section -Id 'waves' -Title 'Migration Waves' -Body $waveHtml -Intro $waveIntro -Collapsed)
        (New-Section -Id 'subscriptions' -Title 'Subscriptions' -Body $subHtml)
        (New-Section -Id 'evidence' -Title 'Microsoft Retirement Evidence' -Body "<ul class='links'>$srcHtml</ul>" -Intro 'Retirement status comes only from these Microsoft sources. Older sizes without an announced retirement are reported as optional modernization, never as retired.')
        $reference
    ) -join "`n"
    $nav = @(@{ Id = 'summary'; Label = 'Summary' }, @{ Id = 'waves'; Label = 'Waves' }, @{ Id = 'subscriptions'; Label = 'Subscriptions' }, @{ Id = 'evidence'; Label = 'Evidence' }) + $refNav
    (New-HtmlPage -Title "$script:ReportName - $($Run.Tenant.Name)" -Eyebrow $script:ReportName -Heading $Run.Tenant.Name -Subtitle "Tenant $($Run.Tenant.Id)" -Meta $meta -Body $body -Css $css -Nav $nav -Warnings $indexWarnings) | Out-File (Join-Path $OutDir $indexName) -Encoding utf8

    # -- Per-subscription pages --
    $waveRank = { param($w) switch -Regex ($w) { '^Wave 1' { 0 } '^Wave 2' { 1 } '^Wave 3' { 2 } '^Beyond' { 3 } '^Review' { 4 } '^Wave 4' { 5 } default { 9 } } }
    foreach ($g in ($Assessments | Group-Object { $_.Vm.SubscriptionId })) {
        $name = $g.Group[0].SubscriptionName
        $set = @($g.Group)
        $aff = @($set | Where-Object AffectedByRetirement -eq 'Yes').Count
        $mod = @($set | Where-Object Wave -eq 'Wave 4 - Modernization').Count
        $none = @($set | Where-Object Action -eq 'No Action Required').Count
        $gen1 = Get-Gen1VmCount -Assessments $set
        $kp = @(
            (New-Kpi $set.Count 'VMs' 'neutral' "$(@($set | Where-Object { $_.Vm.PowerState -eq 'Running' }).Count) running")
            (New-Kpi $aff 'On retiring sizes' $(if ($aff) { 'orange' } else { 'green' }))
            (New-Kpi $mod 'Modernization (Wave 4)' 'purple' 'Older, not retiring')
            (New-Kpi $gen1 'Gen1 VMs' $(if ($gen1) { 'yellow' } else { 'green' }) "of $($set.Count) VM$(if ($set.Count -ne 1) { 's' })")
            (New-Kpi $none 'No action needed' 'green')
            (New-Kpi @($set | Where-Object QuotaStatus -eq 'Quota Increase Required').Count 'Need quota increase' 'neutral')
            (New-Kpi @($set | Where-Object { $_.Confidence -and $_.Confidence.Level -eq 'HIGH' }).Count 'High-confidence moves' 'green')
        ) -join ''
        $bl = (Get-BottomLine -Assessments $set | ForEach-Object { "<li>$_</li>" }) -join ''
        $retiring = @($set | Where-Object { & $listed $_ })
        $retiringOnly = @($set | Where-Object { Test-RetiringVm -Assessment $_ })
        $tilesHtml = New-TrackTilesHtml -RetiringCount $retiringOnly.Count

        $detailSet = @($retiring | Sort-Object { & $waveRank $_.Wave }, { $_.Vm.Name })
        $detailOmitted = if ($maxDetails -gt 0 -and $detailSet.Count -gt $maxDetails) { $detailSet.Count - $maxDetails } else { 0 }
        if ($detailOmitted) { $detailSet = @($detailSet | Select-Object -First $maxDetails) }
        $detailBlocks = @{}
        foreach ($d in $detailSet) {
            $detailBlocks[(Get-VmAnchorId $d.Vm)] = if ($d.Candidates) { New-VmDetailHtml -Assessment $d -CheckModernization:$checkModernization -ExtendedDetails:$extendedDetails } else { New-VmNoRecommendationDetailHtml -Assessment $d }
        }
        $omittedNote = if ($detailOmitted) { "<div class='callout info'>Details are shown for the first $maxDetails VMs in wave order; $detailOmitted more are in <code>detailed-report.md</code>, <code>vm-assessment.csv</code> and <code>assessment.json</code> (raise or disable the limit with <code>-HtmlMaxVmDetails</code>).</div>" } else { '' }
        $table = New-VmTableHtml -Assessments @($retiring | Sort-Object { & $waveRank $_.Wave }, { $_.Vm.Name }) -CheckModernization:$checkModernization -Details $detailBlocks

        # Compact legend: one row per topic with the badges inline. The long explanations are in a collapsed note.
        $legendItems = { param([string[]]$Items) "<ul class=""legend-items"">" + (($Items | ForEach-Object { "<li>$_</li>" }) -join '') + '</ul>' }
        $readinessItems = @($script:ReadinessMeaning.Keys | ForEach-Object { "$(New-Badge $_) $(& $e $script:ReadinessMeaning[$_].Short)" })
        $legend = @"
<div class="legend">
<dl class="legend-rows">
<div class="legend-row"><dt>Microsoft status</dt><dd>$(& $legendItems @(
    "$(New-Badge 'Retired') size is retired; migrate now"
    "$(New-Badge 'End of Life') retirement announced ($(New-LearnLink 'EndOfLifeList' 'End of Life list'))"
    "$(New-Badge 'Confirmed Retirement') date published"
    "$(New-Badge 'Modernization Recommended') older generation, not retiring"
    "$(New-Badge 'No Retirement Announced') current generation"))</dd></div>
<div class="legend-row"><dt>Confidence<span class="legend-sub">in the recommended size</span></dt><dd>$(& $legendItems @(
    "$(New-Badge 'HIGH') no outstanding items in the assessed evidence"
    "$(New-Badge 'MEDIUM') one item to validate first"
    "$(New-Badge 'LOW') several items, or a blocker"))</dd></div>
<div class="legend-row"><dt>Readiness<span class="legend-sub">checked platform prerequisites</span></dt><dd>$(& $legendItems $readinessItems)</dd></div>
<div class="legend-row"><dt>Score (0&ndash;100)</dt><dd>How closely the recommended size matches the current one: <strong>90+</strong> excellent, <strong>80+</strong> good, <strong>70+</strong> acceptable with review.</dd></div>
</dl>
<p class="legend-note">Confidence and readiness are independent. Neither <em>Ready</em> nor <em>HIGH</em> guarantees hardware allocation or a successful resize; validate guest OS, workload, licensing and capacity first.</p>
<details class="legend-more"><summary>More about confidence and readiness</summary>
<p>The recommended size is the retirement target, or the v6/v7 target when a direct v6/v7 move passes all checks. A failed mandatory check always rejects a size, whatever its score. <em>LOW + Ready</em> passes the checked platform/quota prerequisites but has unresolved assessment items.</p>
<p>Hover over a confidence or readiness badge for its explanation. Generate the report with <code>-ExtendedDetails</code> to also print the facts summary, both explanations and the mandatory requirement checks in each VM's details.</p></details>
</div>
"@

        $subQuotaRows = @($quotaRows | Where-Object SubscriptionId -eq $g.Name)
        $subQuotaHtml = New-QuotaActionsHtml -Rows $subQuotaRows -HideSubscription
        $body = @(
            $staleHtml
            @(New-CollectionIssuesHtml -Issues $CollectionIssues -SubscriptionId $g.Name | Where-Object { $_ })
            "<section id='overview' class='card'><h2>Overview</h2>$tilesHtml<div class='kpis'>$kp</div><div class='bottom-line'><h3>Bottom line</h3><ul>$bl</ul></div></section>"
            (New-TrackHtml -Tone 'retirement' -Label 'Required' -Title 'Retirement remediation' -Description "VMs on sizes Microsoft is retiring. Move them to the recommended size before Microsoft retires them.$(if ($includeOptional) { ' Optional-modernization VMs are also listed (-HtmlIncludeOptionalModernization).' })" -Body (@(
                        (New-Section -Id 'vms' -Title 'VMs with Retiring SKUs' -Body ($legend + $omittedNote + $table) -Intro "$scopeText$(if ($checkModernization) { ' The v6/v7 columns show each VM''s modernization target and its migration path next to its required retirement target.' }) Select a VM's Details to see what to do, what changes and what to validate; upgrade steps: $(New-LearnLink 'Resize' 'resize'), $(New-LearnLink 'NvmeConvert' 'SCSI to NVMe'), $(New-LearnLink 'Gen1TrustedLaunch' 'Gen1 to Trusted launch').")
                    ) -join "`n"))
            (New-Section -Id 'quota' -Title 'Quota Actions' -Body $subQuotaHtml -Intro "Quota requests for this subscription only. $quotaIntro")
            $reference
        ) -join "`n"
        $nav = @(@{ Id = 'overview'; Label = 'Overview' }, @{ Id = 'vms'; Label = 'Retiring VMs'; Group = 'Retirement'; Tone = 'retirement' }, @{ Id = 'quota'; Label = 'Quota' }) + $refNav
        $metaSub = @("Subscription <strong>$(& $e $g.Name)</strong>", "Tenant <strong>$(& $e $Run.Tenant.Name)</strong>", "As of <strong>$asOf</strong>", 'Read-only')
        if ($dataSource) { $metaSub += "Data <strong>$(& $e $dataSource)</strong>" }
        $subWarnings = @(Get-PageCollectionIssue -Issues $CollectionIssues -SubscriptionId $g.Name).Count + $(if ($staleHtml) { 1 } else { 0 })
        (New-HtmlPage -Title "$script:ReportName - $name" -Eyebrow 'Subscription assessment' -Heading $name -Meta $metaSub -Body $body -Css $css -BackLink $indexName -Nav $nav -Warnings $subWarnings) | Out-File (Join-Path $OutDir (& $subFile $g.Name $name)) -Encoding utf8
    }
}

Export-ModuleMember -Function Export-AssessmentData, Export-ExecutiveSummaryMarkdown, Export-DetailedReportMarkdown, Export-HtmlReports, Format-MdTable, ConvertTo-SafeCsvValue, ConvertTo-MarkdownText
