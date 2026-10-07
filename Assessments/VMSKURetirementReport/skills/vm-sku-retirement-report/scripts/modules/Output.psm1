Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Retirement.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Assessment.psm1') -DisableNameChecking

$script:Disclaimer = 'UNOFFICIAL ASSESSMENT - FOR PLANNING PURPOSES ONLY. Generated with read-only Azure Resource Manager / Resource Graph queries and Microsoft Learn lifecycle data. Validate every recommendation (workload, licensing, capacity) before resizing.'

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
        $Inventory
    )
    $rows = @($Assessments | ForEach-Object { ConvertTo-AssessmentRow $_ })
    @(ConvertTo-SafeCsvRows -Rows $rows) | Export-Csv -Path (Join-Path $OutDir 'vm-assessment.csv') -NoTypeInformation -Encoding utf8

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
    @(ConvertTo-SafeCsvRows -Rows @($candRows)) | Export-Csv -Path (Join-Path $OutDir 'candidates.csv') -NoTypeInformation -Encoding utf8

    $qRows = @()
    if ($QuotaImpact) { $qRows = @($QuotaImpact.FamilyRows) + @($QuotaImpact.RegionalRows) }
    @(ConvertTo-SafeCsvRows -Rows @($qRows)) | Export-Csv -Path (Join-Path $OutDir 'quota-impact.csv') -NoTypeInformation -Encoding utf8

    $evidence = [ordered]@{
        schemaVersion = '1.0'; generatedUtc = $Run.GeneratedUtc; catalogSource = $CatalogResult.Source; catalogWarning = $CatalogResult.Warning
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
        tenant = $Run.Tenant
        signedInAccount = $Run.Account
        parameters = $Run.Parameters
        disclaimer = $script:Disclaimer
        catalog = [ordered]@{ source = $CatalogResult.Source; warning = $CatalogResult.Warning; sources = $CatalogResult.Catalog.sources; unmappedSeries = $CatalogResult.Catalog.unmappedSeries; nonVmSizeEntries = @(Get-NonVmSizeEntries -Catalog $CatalogResult.Catalog) }
        counts = $Run.Counts
        summary = $Summary
        quota = [ordered]@{ family = if ($QuotaImpact) { @($QuotaImpact.FamilyRows) } else { @() }; regional = if ($QuotaImpact) { @($QuotaImpact.RegionalRows) } else { @() } }
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
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Run, [Parameter(Mandatory)]$Summary, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows, $QuotaImpact, $CatalogResult)
    $s = $Summary
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# VMSKURetirementReport - Executive Summary")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("> $($script:Disclaimer)")
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
    if ($nonVm.Count -gt 0) { [void]$sb.AppendLine("> **Microsoft lifecycle entries that are not VM sizes (validate separately):** $((@($nonVm) | ForEach-Object { "$($_.Name) ($($_.Category), $($_.Status) $($_.PlannedRetirementDate))" }) -join '; ')`n") }

    [void]$sb.AppendLine('## Estate summary')
    [void]$sb.AppendLine()
    $kv = [ordered]@{
        'Total Subscriptions Scanned' = $s.TotalSubscriptionsScanned; 'Total VMs Scanned' = $s.TotalVmsScanned; 'Affected VMs (confirmed/announced retirement)' = $s.AffectedVms
        'Already Retired' = $s.AlreadyRetired; 'Retirement Within 12 Months' = $s.RetirementWithin12Months; 'Retirement Within 12-24 Months' = $s.RetirementWithin24Months
        'Retirement Within 24-36 Months' = $s.RetirementWithin36Months; 'Retirement Beyond 36 Months' = $s.RetirementBeyond36Months
        'Modernization Recommended (Microsoft previous-gen)' = $s.ModernizationRecommended; 'Modernization Optional' = $s.ModernizationOptional
        'Modernize to v7' = $s.ModernizeToV7; 'Modernize to v6' = $s.ModernizeToV6; 'Already on v6/v7' = $s.AlreadyOnModernGeneration
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
        $bySku = @($wr | Group-Object CurrentSku, RecommendedSku, RetirementDate | Sort-Object Count -Descending | ForEach-Object {
                $f = $_.Group[0]
                [pscustomobject]@{ CurrentSku = $f.CurrentSku; RetirementDate = $f.RetirementDate; EvidenceClass = $f.EvidenceClass; RecommendedSku = $f.RecommendedSku; VMs = $_.Count
                    Ready = @($_.Group | Where-Object DeploymentReadiness -eq 'Ready').Count; QuotaIncrease = @($_.Group | Where-Object QuotaStatus -eq 'Quota Increase Required').Count
                    ManualReview = @($_.Group | Where-Object DeploymentReadiness -eq 'Manual Review Required').Count }
            })
        [void]$sb.AppendLine((Format-MdTable -Rows $bySku -Columns 'CurrentSku', 'EvidenceClass', 'RetirementDate', 'RecommendedSku', 'VMs', 'Ready', 'QuotaIncrease', 'ManualReview'))
    }

    $groups = [ordered]@{
        'By subscription' = $s.BySubscription; 'By region' = $s.ByRegion; 'By current SKU' = $s.ByCurrentSku; 'By current SKU family' = $s.ByCurrentSkuFamily
        'By recommended SKU' = $s.ByRecommendedSku; 'By recommended SKU family' = $s.ByRecommendedSkuFamily; 'By CPU vendor' = $s.ByCpuVendor
        'By retirement date' = $s.ByRetirementDate; 'By migration priority (action)' = $s.ByMigrationPriority; 'By deployment readiness' = $s.ByDeploymentReadiness
    }
    [void]$sb.AppendLine('## Groupings (VMs with an action)')
    [void]$sb.AppendLine()
    foreach ($g in $groups.Keys) {
        [void]$sb.AppendLine("### $g")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine((Format-MdTable -Rows @($groups[$g] | Select-Object -First 25) -Columns 'Key', 'Count'))
    }

    if ($QuotaImpact) {
        $need = @($QuotaImpact.FamilyRows + $QuotaImpact.RegionalRows | Where-Object Status -ne 'Quota OK')
        [void]$sb.AppendLine('## Quota actions')
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('Demand is aggregated for all VMs moving into the same subscription / region / family. Minimum increase = (current usage + required) - limit. Recommended increase adds the safety margin. Scope ''Retirement'' covers mandatory migrations only; ''Retirement+Modernization'' also includes optional Wave 4 moves.')
        [void]$sb.AppendLine()
        [void]$sb.AppendLine((Format-MdTable -Rows $need -Columns 'Scope', 'SubscriptionId', 'Region', 'QuotaDisplayName', 'QuotaName', 'Limit', 'CurrentUsage', 'RequiredVcpu', 'PostMigrationUsage', 'MinimumIncrease', 'RecommendedIncrease', 'Status'))
    }
    [void]$sb.AppendLine('## Data quality')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('- Retirement dates come only from Microsoft Learn (retired sizes list, previous-gen list, migration guide). No date is inferred.')
    [void]$sb.AppendLine('- CPU vendor: Microsoft Learn size-series processor tables (Verified) or the Azure VM naming convention (Partially Verified).')
    [void]$sb.AppendLine('- Regional availability and restrictions: subscription-scoped Azure Resource SKUs API (Verified).')
    [void]$sb.AppendLine('- Physical regional capacity, nested virtualization use and temp-disk usage cannot be verified from the control plane (Unable to Verify).')
    Set-Content -Path $Path -Value $sb.ToString() -Encoding utf8
}

function Export-DetailedReportMarkdown {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Assessments, [Parameter(Mandatory)]$Run)
    $sb = New-Object System.Text.StringBuilder
    $checkModernization = if ($Run.Parameters -is [System.Collections.IDictionary]) {
        [bool]$Run.Parameters['CheckModernization']
    }
    else {
        [bool]($Run.Parameters.PSObject.Properties.Name -contains 'CheckModernization' -and $Run.Parameters.CheckModernization)
    }
    [void]$sb.AppendLine($(if ($checkModernization) { '# Detailed VM Reports - Retirement and Modernization Assessment' } else { '# Detailed VM Reports - Retirement-Affected and Unconfirmed VMs' }))
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("> $($script:Disclaimer)")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("Tenant: **$(ConvertTo-MarkdownText $Run.Tenant.Name)** (``$(ConvertTo-MarkdownText $Run.Tenant.Id)``) | As of: **$($Run.AsOf.ToString('yyyy-MM-dd'))** | Tool: VMSKURetirementReport v$(Get-ToolVersion)")
    [void]$sb.AppendLine()
    $affected = @(if ($checkModernization) {
        $Assessments | Sort-Object { $_.SubscriptionName }, { $_.Lifecycle.RetirementDate }, { $_.Vm.Name }
    }
    else {
        $Assessments | Where-Object { $_.AffectedByRetirement -in 'Yes', 'Unknown' } | Sort-Object { $_.SubscriptionName }, { $_.Lifecycle.RetirementDate }, { $_.Vm.Name }
    })
    if ($affected.Count -eq 0) { [void]$sb.AppendLine('_No retirement-affected VMs were found._'); Set-Content -Path $Path -Value $sb.ToString() -Encoding utf8; return }
    $v = { param($x) if ($null -eq $x -or "$x" -eq '') { 'Unknown' } elseif ($x -is [bool]) { if ($x) { 'Yes' } else { 'No' } } else { "$x" } }
    foreach ($sub in ($affected | Group-Object SubscriptionName)) {
        [void]$sb.AppendLine("## Subscription: $(ConvertTo-MarkdownText $sub.Name)")
        [void]$sb.AppendLine()
        foreach ($a in $sub.Group) {
            $vm = $a.Vm; $cur = $a.Current; $lc = $a.Lifecycle; $p = if ($a.Candidates) { $a.Candidates.Primary } else { $null }; $s = if ($a.Candidates) { $a.Candidates.Secondary } else { $null }
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
            foreach ($pair in @(@('Retirement Status', $lc.RetirementStatus), @('Retirement Date', (& $v $lc.RetirementDate)), @('Months Remaining', (& $v $lc.MonthsRemaining)),
                    @('Microsoft Series', (& $v $lc.LearnSeriesName)), @('Microsoft Retirement Source', $src), @('Announcement', $ann),
                    @('Migration Guide', $(if ($lc.MigrationGuideUrl) { "[link]($($lc.MigrationGuideUrl))" } else { '-' })), @('Evidence Classification', $lc.EvidenceClass), @('Data Quality', $lc.DataQuality))) {
                [void]$sb.AppendLine("| $($pair[0]) | $(Format-MdCell $pair[1]) |")
            }
            foreach ($n in @($lc.Notes)) { [void]$sb.AppendLine("`n> Note: $(ConvertTo-MarkdownText $n)") }
            [void]$sb.AppendLine()
            if ($a.Modernization) {
                [void]$sb.AppendLine('**MODERNIZATION ASSESSMENT**')
                [void]$sb.AppendLine()
                [void]$sb.AppendLine("| Attribute | Value |`n|---|---|")
                foreach ($pair in @(@('Status', $a.Modernization.Status), @('Recommended SKU', (& $v $a.Modernization.RecommendedSku)),
                        @('Recommended SKU Generation', $(if ($a.Modernization.RecommendedGeneration) { "v$($a.Modernization.RecommendedGeneration)" } else { 'Unknown' })),
                        @('Regional Availability', $a.Modernization.Availability), @('Quota Status', $a.QuotaStatus), @('Reason', $a.Modernization.Reason))) {
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
                [void]$sb.AppendLine('**MATERIAL DIFFERENCES**')
                [void]$sb.AppendLine()
                [void]$sb.AppendLine((Format-MdTable -Rows @($p.Differences) -Columns 'Attribute', 'Current', 'Target', 'Assessment', 'Note'))
            }
            else {
                [void]$sb.AppendLine("_No primary recommendation: $(if ($a.Candidates) { $a.Candidates.NoCandidateReason } else { 'size characteristics or region catalog unavailable' })_")
                [void]$sb.AppendLine()
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
    Set-Content -Path $Path -Value $sb.ToString() -Encoding utf8
}

function Get-BadgeClass {
    param([string]$Value)
    switch -Regex ($Value) {
        '^(Already Retired|Immediate|Wave 1|LOW|SKU Restricted|Regional Limitation|Less than 12|Fail|Reduced)' { 'b-red'; break }
        '^(Confirmed Retirement|Retirement Announced|Migration Required|Wave 2|Quota Increase|12-24)' { 'b-orange'; break }
        '^(Wave 3|24-36|MEDIUM|Capacity Validation|Manual Review|Unable|Review|Skipped|Partial|Changed|Not verifiable|Excluded|Not assessed)' { 'b-yellow'; break }
        '^(Modernization|Wave 4|Plan Migration)' { 'b-purple'; break }
        '^(HIGH|Ready|Quota OK|No Action|No Retirement|Pass|Done|Improved|Same|Available)' { 'b-green'; break }
        '^(Intel|AMD|ARM|Info)' { 'b-blue'; break }
        default { 'b-grey' }
    }
}

function New-Badge { param([string]$Value, [string]$Label) if (-not $Value) { return "<span class='muted'>&ndash;</span>" } "<span class='badge $(Get-BadgeClass $Value)'>$(ConvertTo-HtmlEncoded $(if ($Label) { $Label } else { $Value }))</span>" }

function Get-VmAnchorId {
    <# Page-unique anchor for a VM detail card. VM names are unique only within a resource group, so both are used. #>
    param([Parameter(Mandatory)]$Vm)
    return 'vm-' + (Get-SafeFileName "$($Vm.ResourceGroup)-$($Vm.Name)").ToLowerInvariant()
}

function New-HtmlPage {
    param([string]$Title, [string]$Eyebrow, [string]$Heading, [string]$Subtitle, [string[]]$Meta, [string]$Body, [string]$Css, [string]$BackLink, [object[]]$Nav)
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $back = if ($BackLink) { "<a href='$BackLink' class='back'>&larr; Tenant summary</a>" } else { '' }
    $metaHtml = (@($Meta) | Where-Object { $_ } | ForEach-Object { "<span class='chip'>$_</span>" }) -join ''
    $navHtml = (@($Nav) | ForEach-Object { "<a href='#$($_.Id)'>$(& $e $_.Label)</a>" }) -join ''
    $version = Get-ToolVersion
    # Allow long VM size names to wrap only after the 'Standard_' prefix, never mid-name.
    $Body = $Body -replace '<code>Standard_', '<code>Standard_<wbr>'
    @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>$(& $e $Title)</title><style>$Css</style></head><body>
<header class="hero"><div class="wrap">
<div class="app-bar">
<div class="brand-lockup"><span class="brand-mark" aria-hidden="true">&#9729;</span><span><strong>VMSKURetirementReport</strong><small>Assessment report v$version</small></span></div>
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
<div class="callout disclaimer"><strong>Unofficial planning report.</strong> Built from read-only Azure Resource Manager / Resource Graph queries and Microsoft Learn lifecycle data. Validate every recommendation (workload, licensing, capacity) before resizing.</div>
$Body
</main>
<footer><div class="wrap"><span class="footer-status"><span aria-hidden="true"></span>Report generated successfully</span><span>VMSKURetirementReport v$version &middot; read-only assessment &middot; $(& $e $Title)</span></div></footer>
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

function New-QuotaActionsHtml {
    <# Quota rows that need action (status other than Quota OK). -HideSubscription drops the column on per-subscription pages. #>
    param([AllowEmptyCollection()][object[]]$Rows, [switch]$HideSubscription)
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $need = @($Rows | Where-Object { $_ -and $_.Status -ne 'Quota OK' })
    if ($need.Count -eq 0) { return "<div class='callout ok'>No quota increase is needed for the recommended moves. <span class='muted'>(Quota OK does not guarantee physical capacity.)</span></div>" }
    $subHead = if ($HideSubscription) { '' } else { '<th>Subscription</th>' }
    $rowsHtml = ($need | ForEach-Object {
            $subCell = if ($HideSubscription) { '' } else { "<td class='sub'>$(& $e $_.SubscriptionId)</td>" }
            $usage = if ($null -eq $_.Limit -or "$($_.Limit)" -eq '') { "<span class='muted'>&ndash;</span>" } else { "$(& $e $_.CurrentUsage) / $(& $e $_.Limit)" }
            "<tr><td>$(& $e $_.Scope)</td>$subCell<td>$(& $e $_.Region)</td><td>$(& $e $(if ($_.QuotaDisplayName) { $_.QuotaDisplayName } else { $_.QuotaName }))</td><td class='num quota-usage'>$usage</td><td class='num'>$(& $e $_.RequiredVcpu)</td><td class='num'><strong>$(& $e $_.MinimumIncrease)</strong></td><td class='num'>$(& $e $_.RecommendedIncrease)</td><td>$(New-Badge $_.Status)</td></tr>"
        }) -join "`n"
    "<div class='table-wrap'><table class='quota-table'><thead><tr><th>Scope</th>$subHead<th>Region</th><th>Quota</th><th class='num quota-usage'>Used / limit</th><th class='num'>Needed</th><th class='num'>Min. increase</th><th class='num'>Recommended request</th><th>Status</th></tr></thead><tbody>$rowsHtml</tbody></table></div><p class='note'><em>Retirement</em> scope covers required migrations only; <em>Retirement+Modernization</em> also includes optional Wave 4 moves.</p>"
}

function New-Kpi {
    param([string]$Value, [string]$Label, [string]$Tone = 'neutral', [string]$Hint)
    "<div class='kpi kpi-$Tone'><div class='kpi-label'>$(ConvertTo-HtmlEncoded $Label)</div><div class='kpi-value'>$(ConvertTo-HtmlEncoded $Value)</div>$(if ($Hint) { "<div class='kpi-hint'>$(ConvertTo-HtmlEncoded $Hint)</div>" })</div>"
}

function Get-BottomLine {
    <# Plain-language summary sentences for the top of a page. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Assessments)
    $out = New-Object System.Collections.Generic.List[string]
    $retiring = @($Assessments | Where-Object { $_.AffectedByRetirement -eq 'Yes' })
    $retired = @($retiring | Where-Object { $_.Lifecycle.EvidenceClass -eq 'Already Retired' })
    $modern = @($Assessments | Where-Object { $_.Wave -eq 'Wave 4 - Modernization' })
    $unknown = @($Assessments | Where-Object { $_.AffectedByRetirement -eq 'Unknown' })
    if ($Assessments.Count -eq 0) { $out.Add('No virtual machines were found in scope.'); return $out.ToArray() }
    if ($retiring.Count -eq 0) { $out.Add("None of the $($Assessments.Count) VMs run on a VM size that Microsoft has retired or scheduled for retirement.") }
    else {
        $dated = @($retiring | Where-Object { $_.Lifecycle.RetirementDate } | Sort-Object { $_.Lifecycle.RetirementDate })
        $first = if ($dated.Count) { " The earliest retirement date is <strong>$($dated[0].Lifecycle.RetirementDate)</strong> ($($dated[0].Vm.SkuName))." } else { '' }
        $out.Add("<strong>$($retiring.Count) of $($Assessments.Count) VMs</strong> run on VM sizes that Microsoft has retired or scheduled for retirement.$first")
        if ($retired.Count) { $out.Add("<strong>$($retired.Count) VM(s)</strong> are on sizes that are already retired and need immediate attention.") }
    }
    if ($modern.Count) { $out.Add("$($modern.Count) VM(s) run on an older generation that is <em>not</em> retiring; upgrading is optional (Wave 4).") }
    if ($unknown.Count) { $out.Add("$($unknown.Count) VM(s) could not be matched to Microsoft lifecycle data and need manual confirmation.") }
    $quota = @($Assessments | Where-Object QuotaStatus -eq 'Quota Increase Required')
    if ($quota.Count) { $out.Add("$($quota.Count) recommended move(s) need a vCPU quota increase first (see Quota actions).") }
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
        [pscustomobject]@{ C = 'Azure Advisor / Service Health'; S = 'Done'; N = "Best-effort corroboration: $(& $get $c 'AdvisorRetirement') Advisor and $(& $get $c 'ServiceHealthRetirement') Service Health retirement signals." }
        [pscustomobject]@{ C = 'Retail pricing'; S = $(if (& $get $p 'IncludePricing') { 'Done' } else { 'Skipped' }); N = 'Pay-as-you-go list price x 730 h (prices.azure.com). Excludes EA/MCA discounts, reservations, savings plans and Azure Hybrid Benefit.' }
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
        (New-Section -Id 'cross-vendor' -Title 'Cross-Vendor Migration Warnings' -Body $warn -Intro 'Moving between Intel and AMD is usually transparent to the operating system, but some workloads need validation first.')
        (New-Section -Id 'sku-families' -Title 'SKU Family Quick Reference' -Body $famTable -Intro 'The first letter of a VM size is its family. Replacements stay in the same family unless Microsoft''s migration guide names another one.' -Collapsed)
        (New-Section -Id 'cpu-vendor' -Title 'CPU Vendor from SKU Name' -Body $cpuTable -Intro 'How to read a VM size name such as <code>Standard_D4ads_v6</code>.' -Collapsed)
        (New-Section -Id 'limitations' -Title 'Known Limitations' -Body $limTable -Intro 'What this assessment could and could not verify. Anything not verifiable is labelled rather than assumed.' -Collapsed)
    ) -join "`n"
}

function Export-HtmlReports {
    param([Parameter(Mandatory)][string]$OutDir, [Parameter(Mandatory)][string]$CssPath, [Parameter(Mandatory)]$Run, [Parameter(Mandatory)]$Summary, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Assessments, $QuotaImpact, $CatalogResult, $ProcessorCatalog)
    $css = Get-Content $CssPath -Raw
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $s = $Summary
    $indexName = 'index.html'
    $asOf = $Run.AsOf.ToString('yyyy-MM-dd')
    $meta = @("Tenant <strong>$(& $e $Run.Tenant.Name)</strong>", "As of <strong>$asOf</strong>", "Evidence <strong>$(& $e $CatalogResult.Source)</strong>", 'Read-only')
    $reference = New-ReferenceSections -ProcessorCatalog $ProcessorCatalog -Run $Run -Summary $s -CatalogResult $CatalogResult
    $refNav = @(@{ Id = 'cross-vendor'; Label = 'Cross-vendor' }, @{ Id = 'sku-families'; Label = 'SKU families' }, @{ Id = 'cpu-vendor'; Label = 'CPU from name' }, @{ Id = 'limitations'; Label = 'Limitations' })
    $subFile = { param($id, $name) (Get-SafeFileName $name) + '-' + $id.Substring(0, [math]::Min(8, $id.Length)) + '.html' }

    # -- Tenant index --
    $kpis = @(
        (New-Kpi $s.TotalVmsScanned 'VMs assessed' 'neutral' "$($s.TotalSubscriptionsScanned) subscription(s)")
        (New-Kpi $s.AffectedVms 'On retiring sizes' $(if ($s.AffectedVms) { 'orange' } else { 'green' }) 'Microsoft-confirmed')
        (New-Kpi $s.AlreadyRetired 'Already retired' $(if ($s.AlreadyRetired) { 'red' } else { 'green' }))
        (New-Kpi $s.RetirementWithin12Months 'Retire < 12 months' $(if ($s.RetirementWithin12Months) { 'red' } else { 'neutral' }))
        (New-Kpi ($s.RetirementWithin24Months + $s.RetirementWithin36Months) 'Retire in 1-3 years' $(if ($s.RetirementWithin24Months + $s.RetirementWithin36Months) { 'orange' } else { 'neutral' }))
        (New-Kpi $s.ModernizationRecommended 'Optional modernization' 'purple' 'Older, not retiring')
        (New-Kpi $s.VmsRequiringQuotaIncrease 'Need quota increase' $(if ($s.VmsRequiringQuotaIncrease) { 'orange' } else { 'neutral' }))
        (New-Kpi $s.HighConfidence 'High-confidence moves' 'green')
    ) -join ''
    $bottom = (Get-BottomLine -Assessments $Assessments | ForEach-Object { "<li>$_</li>" }) -join ''
    $srcHtml = (@($CatalogResult.Catalog.sources) | ForEach-Object { "<li><a href='$(& $e $_.Url)' target='_blank'>$(& $e $(if ($_.Title) { $_.Title -replace ' - Azure Virtual Machines \| Microsoft Learn$', '' } else { $_.Name }))</a> <span class='muted'>&middot; updated $(& $e $_.UpdatedAt) &middot; retrieved $(& $e $_.RetrievedUtc)</span></li>" }) -join ''
    $warn = ''
    if ($CatalogResult.Warning) { $warn += "<div class='callout warn'><strong>Evidence warning:</strong> $(& $e $CatalogResult.Warning)</div>" }
    $unm = @(Get-UnmappedSeriesNames -Catalog $CatalogResult.Catalog)
    if ($unm.Count -gt 0) { $warn += "<div class='callout warn'><strong>Microsoft series without a size mapping (not classified):</strong> $(& $e ($unm -join ', '))</div>" }
    $nonVm = @(Get-NonVmSizeEntries -Catalog $CatalogResult.Catalog)
    if ($nonVm.Count -gt 0) { $warn += "<div class='callout info'><strong>Microsoft lifecycle entries that are not VM sizes:</strong> $(& $e ((@($nonVm) | ForEach-Object { "$($_.Name) ($($_.Category), $($_.Status) $($_.PlannedRetirementDate))" }) -join '; ')). They are not matched to VMs; validate them separately (for example, Dedicated Host SKUs).</div>" }

    $waveOrder = 'Wave 1 - Urgent', 'Wave 2 - Near Term', 'Wave 3 - Planned', 'Beyond Horizon', 'Review - Unconfirmed', 'Wave 4 - Modernization'
    $waveRows = foreach ($w in $waveOrder) {
        foreach ($g in (@($Assessments | Where-Object Wave -eq $w) | Group-Object { $_.Vm.SkuName } | Sort-Object Count -Descending)) {
            $f = $g.Group[0]
            $rec = @($g.Group | ForEach-Object { if ($_.Candidates -and $_.Candidates.Primary) { $_.Candidates.Primary.SkuName } else { 'No recommendation' } } | Group-Object | Sort-Object Count -Descending | ForEach-Object { if ($g.Count -gt 1) { "$($_.Name) &times;$($_.Count)" } else { $_.Name } }) -join ', '
            "<tr><td>$(New-Badge $w)</td><td><code>$(& $e $g.Name)</code></td><td>$(New-Badge $f.Lifecycle.EvidenceClass)</td><td class='nowrap'>$(if ($f.Lifecycle.RetirementDate) { & $e $f.Lifecycle.RetirementDate } else { "<span class='muted'>No date</span>" })</td><td class='num'>$($g.Count)</td><td>$rec</td></tr>"
        }
    }
    $waveHtml = if (@($waveRows).Count) { "<div class='table-wrap'><table><thead><tr><th>Wave</th><th>Current size</th><th>Microsoft status</th><th>Retirement date</th><th class='num'>VMs</th><th>Recommended size</th></tr></thead><tbody>$($waveRows -join "`n")</tbody></table></div>" } else { "<div class='callout ok'>No VMs need migration or modernization.</div>" }
    $waveIntro = 'Waves 1&ndash;3 contain only VMs with a Microsoft retirement date. Wave 4 is optional modernization of older generations and is never mixed with required migrations.'

    $subRows = foreach ($g in ($Assessments | Group-Object { $_.Vm.SubscriptionId } | Sort-Object { $_.Group[0].SubscriptionName })) {
        $name = $g.Group[0].SubscriptionName
        $aff = @($g.Group | Where-Object AffectedByRetirement -eq 'Yes').Count
        $w1 = @($g.Group | Where-Object Wave -eq 'Wave 1 - Urgent').Count
        $mod = @($g.Group | Where-Object Wave -eq 'Wave 4 - Modernization').Count
        $q = @($g.Group | Where-Object QuotaStatus -eq 'Quota Increase Required').Count
        "<tr><td><a class='strong' href='$(& $subFile $g.Name $name)'>$(& $e $name)</a><div class='sub'>$(& $e $g.Name)</div></td><td class='num'>$($g.Count)</td><td class='num'>$(if ($aff) { New-Badge 'Confirmed Retirement' "$aff" } else { '0' })</td><td class='num'>$(if ($w1) { New-Badge 'Wave 1' "$w1" } else { '0' })</td><td class='num'>$(if ($mod) { New-Badge 'Modernization' "$mod" } else { '0' })</td><td class='num'>$(if ($q) { New-Badge 'Quota Increase' "$q" } else { '0' })</td></tr>"
    }
    $subHtml = if (@($subRows).Count) { "<div class='table-wrap'><table><thead><tr><th>Subscription</th><th class='num'>VMs</th><th class='num'>On retiring sizes</th><th class='num'>Wave 1</th><th class='num'>Modernization</th><th class='num'>Quota increase</th></tr></thead><tbody>$($subRows -join "`n")</tbody></table></div><p class='note'>Only subscriptions that contain VMs are listed. Select a subscription for per-VM details.</p>" } else { "<p class='note'>No subscriptions with VMs.</p>" }

    $quotaRows = @(if ($QuotaImpact) { @($QuotaImpact.FamilyRows) + @($QuotaImpact.RegionalRows) | Where-Object { $_ } })
    $quotaIntro = 'Demand is added up for all VMs moving into the same subscription, region and VM family. Minimum increase = current usage + needed &minus; limit; the recommended request adds a safety margin.'
    $qHtml = New-QuotaActionsHtml -Rows $quotaRows

    $body = @(
        "<section id='summary' class='card'><h2>Summary</h2><div class='kpis'>$kpis</div><div class='bottom-line'><h3>Bottom line</h3><ul>$bottom</ul></div></section>"
        $warn
        (New-Section -Id 'waves' -Title 'Migration Waves' -Body $waveHtml -Intro $waveIntro)
        (New-Section -Id 'quota' -Title 'Quota Actions' -Body $qHtml -Intro $quotaIntro)
        (New-Section -Id 'subscriptions' -Title 'Subscriptions' -Body $subHtml)
        (New-Section -Id 'evidence' -Title 'Microsoft Retirement Evidence' -Body "<ul class='links'>$srcHtml</ul>" -Intro 'Retirement status comes only from these Microsoft sources. Older sizes without an announced retirement are reported as optional modernization, never as retired.')
        $reference
    ) -join "`n"
    $nav = @(@{ Id = 'summary'; Label = 'Summary' }, @{ Id = 'waves'; Label = 'Waves' }, @{ Id = 'quota'; Label = 'Quota' }, @{ Id = 'subscriptions'; Label = 'Subscriptions' }, @{ Id = 'evidence'; Label = 'Evidence' }) + $refNav
    (New-HtmlPage -Title "VMSKURetirementReport - $($Run.Tenant.Name)" -Eyebrow 'VMSKURetirementReport' -Heading $Run.Tenant.Name -Subtitle "Tenant $($Run.Tenant.Id)" -Meta $meta -Body $body -Css $css -Nav $nav) | Out-File (Join-Path $OutDir $indexName) -Encoding utf8

    # -- Per-subscription pages --
    $waveRank = { param($w) switch -Regex ($w) { '^Wave 1' { 0 } '^Wave 2' { 1 } '^Wave 3' { 2 } '^Beyond' { 3 } '^Review' { 4 } '^Wave 4' { 5 } default { 9 } } }
    foreach ($g in ($Assessments | Group-Object { $_.Vm.SubscriptionId })) {
        $name = $g.Group[0].SubscriptionName
        $set = @($g.Group)
        $aff = @($set | Where-Object AffectedByRetirement -eq 'Yes').Count
        $mod = @($set | Where-Object Wave -eq 'Wave 4 - Modernization').Count
        $none = @($set | Where-Object Action -eq 'No Action Required').Count
        $kp = @(
            (New-Kpi $set.Count 'VMs' 'neutral' "$(@($set | Where-Object { $_.Vm.PowerState -eq 'Running' }).Count) running")
            (New-Kpi $aff 'On retiring sizes' $(if ($aff) { 'orange' } else { 'green' }))
            (New-Kpi $mod 'Optional modernization' 'purple')
            (New-Kpi $none 'No action needed' 'green')
            (New-Kpi @($set | Where-Object QuotaStatus -eq 'Quota Increase Required').Count 'Need quota increase' 'neutral')
            (New-Kpi @($set | Where-Object { $_.Confidence -and $_.Confidence.Level -eq 'HIGH' }).Count 'High-confidence moves' 'green')
        ) -join ''
        $bl = (Get-BottomLine -Assessments $set | ForEach-Object { "<li>$_</li>" }) -join ''

        $rows = foreach ($a in ($set | Sort-Object { & $waveRank $_.Wave }, { $_.Vm.Name })) {
            $r = ConvertTo-AssessmentRow $a
            $p = if ($a.Candidates) { $a.Candidates.Primary } else { $null }
            $rec = if ($r.RecommendedSku) {
                "<code>$(& $e $r.RecommendedSku)</code><div class='sub'>$(if ($r.TargetCpuVendor) { "$(& $e $r.TargetCpuVendor) &middot; " })$(if ($null -ne $r.CompatibilityScore -and "$($r.CompatibilityScore)" -ne '') { "score $(& $e $r.CompatibilityScore) &middot; " })$(& $e $r.ModernizationStatus)</div>"
            }
            elseif ($a.Action -eq 'No Action Required') { "<span class='muted'>Current generation</span>" } else { "<span class='muted'>None found</span>" }
            $currentTempDisk = if ($null -eq $a.Current.HasTempDisk) { "<span class='muted'>Unable to Verify</span>" } elseif ($a.Current.HasTempDisk) { "$(& $e $a.Current.TempDiskGB) GB" } else { 'None' }
            $currentDiskController = if (@($a.Current.DiskControllerTypes).Count) { & $e (@($a.Current.DiskControllerTypes) -join ', ') } else { "<span class='muted'>Unable to Verify</span>" }
            $currentUncachedIops = if ($null -ne $a.Current.UncachedDiskIOPS) { & $e $a.Current.UncachedDiskIOPS } else { "<span class='muted'>Unable to Verify</span>" }
            $currentUncachedMBps = if ($null -ne $a.Current.UncachedDiskMBps) { & $e $a.Current.UncachedDiskMBps } else { "<span class='muted'>Unable to Verify</span>" }
            $tempDisk = if (-not $p) { "<span class='muted'>&ndash;</span>" } elseif ($null -eq $p.Record.HasTempDisk) { "<span class='muted'>Unable to Verify</span>" } elseif ($p.Record.HasTempDisk) { "$(& $e $p.TempDiskGB) GB" } else { 'None' }
            $diskController = if (-not $p) { "<span class='muted'>&ndash;</span>" } elseif (@($p.Record.DiskControllerTypes).Count) { & $e (@($p.Record.DiskControllerTypes) -join ', ') } else { "<span class='muted'>Unable to Verify</span>" }
            $uncachedIops = if ($p -and $null -ne $p.Record.UncachedDiskIOPS) { & $e $p.Record.UncachedDiskIOPS } elseif ($p) { "<span class='muted'>Unable to Verify</span>" } else { "<span class='muted'>&ndash;</span>" }
            $uncachedMBps = if ($p -and $null -ne $p.Record.UncachedDiskMBps) { & $e $p.Record.UncachedDiskMBps } elseif ($p) { "<span class='muted'>Unable to Verify</span>" } else { "<span class='muted'>&ndash;</span>" }
            $capabilitySummary = "<div class='capability-summary'><div><span class='cap-label'>Temp</span><span>$currentTempDisk &rarr; <strong>$tempDisk</strong></span></div><div><span class='cap-label'>Controller</span><span>$currentDiskController &rarr; <strong>$diskController</strong></span></div><div><span class='cap-label'>IOPS</span><span>$currentUncachedIops &rarr; <strong>$uncachedIops</strong></span></div><div><span class='cap-label'>MBps</span><span>$currentUncachedMBps &rarr; <strong>$uncachedMBps</strong></span></div></div>"
            $ret = if ($r.RetirementDate) { "<div class='sub'>$(& $e $r.RetirementDate) &middot; $(& $e $r.TimeRemaining)</div>" } else { '' }
            $cost = if ($a.Pricing -and $a.Pricing.CurrentMonthly) { "`$$([math]::Round($a.Pricing.CurrentMonthly))$(if ($a.Pricing.TargetMonthly) { " &rarr; `$$([math]::Round($a.Pricing.TargetMonthly))" })" } else { "<span class='muted'>&ndash;</span>" }
            $vmAnchor = Get-VmAnchorId $a.Vm
            $link = if ($a.Candidates -and $a.Action -ne 'No Action Required') { "<a class='strong' href='#$vmAnchor'>$(& $e $r.VM)</a>" } else { "<span class='strong'>$(& $e $r.VM)</span>" }
            "<tr><td>$link<div class='sub'>$(& $e $r.ResourceGroup) &middot; $(& $e $r.Region)$(if ($r.Zone) { " &middot; zone $(& $e $r.Zone)" }) &middot; $(& $e $r.PowerState)</div></td><td><code>$(& $e $r.CurrentSku)</code><div class='sub'>$(New-Badge $r.CpuVendor) $(& $e $r.vCPU) vCPU &middot; $(& $e $r.MemoryGB) GB</div></td><td>$(New-Badge $r.EvidenceClass)$ret</td><td>$rec</td><td class='cap-summary'>$capabilitySummary</td><td>$(New-Badge $r.Action)$(if ($a.Action -ne 'No Action Required') { "<div class='sub'>Readiness: $(& $e $r.DeploymentReadiness) &middot; Confidence: $(& $e $r.Confidence)</div>" })</td><td class='num nowrap'>$cost</td></tr>"
        }
        $table = "<div class='table-wrap'><table class='vm-table'><thead><tr><th>VM</th><th>Current size</th><th>Microsoft status</th><th>Recommended size</th><th>Disk capabilities</th><th>Next step</th><th class='num'>PAYGO / month</th></tr></thead><tbody>$($rows -join "`n")</tbody></table></div><p class='note'>Disk capabilities compare current &rarr; recommended values. Monthly cost is the public pay-as-you-go list price (730 h) for comparison only; your actual rates may differ.</p>"

        $legend = @"
<div class="legend">
<div><h3>Microsoft status</h3><ul class="legend-list">
<li>$(New-Badge 'Already Retired') Size is retired; migrate now.</li>
<li>$(New-Badge 'Confirmed Retirement') Microsoft has published a retirement date.</li>
<li>$(New-Badge 'Modernization Recommended') Older generation, not retiring.</li>
<li>$(New-Badge 'No Retirement Announced') Current generation.</li></ul></div>
<div><h3>Confidence</h3><ul class="legend-list">
<li>$(New-Badge 'HIGH') Everything verified.</li>
<li>$(New-Badge 'MEDIUM') One item to validate first.</li>
<li>$(New-Badge 'LOW') Several items, or a blocker.</li></ul></div>
<div><h3>Score (0&ndash;100)</h3><p>How closely the recommended size matches the current one: <strong>90+</strong> excellent, <strong>80+</strong> good, <strong>70+</strong> acceptable with review. A failed mandatory check always rejects a size, whatever its score.</p></div>
</div>
"@

        $details = foreach ($a in ($set | Where-Object { $_.Candidates -and $_.Action -ne 'No Action Required' } | Sort-Object { & $waveRank $_.Wave }, { $_.Vm.Name })) {
            $p = $a.Candidates.Primary; $sc = $a.Candidates.Secondary
            $facts = [ordered]@{
                'Microsoft status' = "$(New-Badge $a.Lifecycle.EvidenceClass) $(& $e $a.Lifecycle.LearnSeriesName) $(if ($a.Lifecycle.RetirementDate) { "&middot; retires <strong>$($a.Lifecycle.RetirementDate)</strong>" })$(if ($a.Lifecycle.SourceUrl) { " &middot; <a href='$(& $e $a.Lifecycle.SourceUrl)' target='_blank'>source</a>" })"
                'Modernization' = if ($a.Modernization) { "$(New-Badge $a.Modernization.Status) &middot; $(& $e $a.Modernization.Reason)" } else { "<span class='muted'>Not evaluated</span>" }
                'Action' = "$(New-Badge $a.Action) &middot; next step: <strong>$(& $e $a.NextStep)</strong> &middot; $(New-Badge $a.Wave)"
                'Recommended' = if ($p) { "<code>$(& $e $p.SkuName)</code> &middot; $(New-Badge $p.CpuVendor) $($p.vCPUs) vCPU &middot; $($p.MemoryGB) GB &middot; score <strong>$($p.Score)</strong> ($(& $e $p.Band))" } else { "<span class='muted'>$(& $e $a.Candidates.NoCandidateReason)</span>" }
                'Alternative' = if ($sc) { "<code>$(& $e $sc.SkuName)</code> (score $($sc.Score)) &middot; $(& $e $a.SecondaryReason)" } else { "<span class='muted'>None in the permitted series</span>" }
                'Newer if converted' = if ($a.Candidates.FutureGeneration) { "<code>$(& $e $a.Candidates.FutureGeneration.SkuName)</code> &middot; requires $(& $e ($a.Candidates.FutureGeneration.FailedGates -join ', ')) conversion" } else { "<span class='muted'>&ndash;</span>" }
                'Quota' = "$(New-Badge $a.QuotaStatus)$(if ($a.Quota -and $a.Quota.Family.Limit) { " &middot; $(& $e $a.Quota.Family.QuotaDisplayName): $($a.Quota.Family.CurrentUsage) / $($a.Quota.Family.Limit) used, needs $($a.Quota.Family.RequiredVcpu)" })"
                'Candidate series' = & $e $a.Candidates.PermittedSeries
            }
            if ($a.Candidates.VendorChangeRequired) { $facts['CPU vendor change'] = & $e $a.Candidates.VendorChangeReason }
            if ($a.Rightsizing) { $facts['Rightsizing'] = "$(New-Badge $a.Rightsizing.Status) $(& $e $a.Rightsizing.Note)" }
            $factsHtml = ($facts.Keys | ForEach-Object { "<dt>$(& $e $_)</dt><dd>$($facts[$_])</dd>" }) -join ''
            $notes = (@($a.ValidationItems) + @($a.Confidence.LowReasons | ForEach-Object { "Low confidence: $_" }) + @($a.Lifecycle.Notes) | Where-Object { $_ } | ForEach-Object { "<li>$(& $e $_)</li>" }) -join ''
            $diff = if ($p) { (@($p.Differences) | ForEach-Object { "<tr><td>$(& $e $_.Attribute)</td><td>$(& $e $_.Current)</td><td>$(& $e $_.Target)</td><td>$(New-Badge $_.Assessment)</td><td>$(& $e $_.Note)</td></tr>" }) -join '' } else { '' }
            $gates = if ($p) { (@($p.Gates) | ForEach-Object { "<tr><td>$(& $e $_.Gate)</td><td>$(New-Badge $_.Result)</td><td>$(& $e $_.Detail)</td></tr>" }) -join '' } else { '' }
            $cands = (@($a.Candidates.Candidates) | Select-Object -First 8 | ForEach-Object { "<tr><td>$(if ($_.Role -ne 'Candidate') { New-Badge 'Info' $_.Role } else { "<span class='muted'>&ndash;</span>" })</td><td><code>$(& $e $_.SkuName)</code></td><td>$(New-Badge $_.CpuVendor)</td><td class='num'>v$($_.Generation)</td><td class='num'>$($_.vCPUs) / $($_.MemoryGB)</td><td class='num'><strong>$($_.Score)</strong></td><td>$(New-Badge $_.Availability)</td><td>$(& $e $(if ($_.Rejected) { 'Rejected: ' + $_.RejectionReason } elseif (@($_.ReviewGates).Count) { 'Review: ' + ($_.ReviewGates -join ', ') } else { $_.Variant }))</td></tr>" }) -join ''
            @"
<details class="vm" id="$(Get-VmAnchorId $a.Vm)"><summary><span class="vm-name">$(& $e $a.Vm.Name)</span><span class="vm-move"><code>$(& $e $a.Vm.SkuName)</code> &rarr; <code>$(& $e $(if ($p) { $p.SkuName } else { 'no recommendation' }))</code></span><span class="vm-badges">$(New-Badge $a.Confidence.Level) $(New-Badge $a.Readiness)</span></summary>
<div class="vm-body">
<dl class="facts">$factsHtml</dl>
$(if ($notes) { "<div class='callout info'><h3>To validate before resizing</h3><ul>$notes</ul></div>" })
$(if ($diff) { "<h3>Current vs recommended size</h3><div class='table-wrap'><table><thead><tr><th>Attribute</th><th>Current</th><th>Recommended</th><th>Change</th><th>Note</th></tr></thead><tbody>$diff</tbody></table></div>" })
$(if ($gates) { "<h3>Mandatory requirement checks</h3><div class='table-wrap'><table><thead><tr><th>Check</th><th>Result</th><th>Detail</th></tr></thead><tbody>$gates</tbody></table></div>" })
<h3>Sizes evaluated</h3>$(if ($cands) { "<div class='table-wrap'><table><thead><tr><th>Role</th><th>Size</th><th>CPU</th><th class='num'>Gen</th><th class='num'>vCPU / GB</th><th class='num'>Score</th><th>Availability</th><th>Notes</th></tr></thead><tbody>$cands</tbody></table></div>" } else { "<p class='note'>No current-generation size in the permitted series is offered in this region for this subscription. Review Microsoft's migration guidance for this series manually.</p>" })
</div></details>
"@
        }
        $detailHtml = if (@($details).Count) { $details -join "`n" } else { "<div class='callout ok'>No VMs in this subscription need action.</div>" }
        $subQuotaHtml = New-QuotaActionsHtml -Rows @($quotaRows | Where-Object SubscriptionId -eq $g.Name) -HideSubscription
        $body = @(
            "<section id='overview' class='card'><h2>Overview</h2><div class='kpis'>$kp</div><div class='bottom-line'><h3>Bottom line</h3><ul>$bl</ul></div></section>"
            (New-Section -Id 'quota' -Title 'Quota Actions' -Body $subQuotaHtml -Intro "Quota requests for this subscription only. $quotaIntro")
            (New-Section -Id 'vms' -Title 'VM Assessment' -Body ($legend + $table))
            (New-Section -Id 'details' -Title 'Recommendations in Detail' -Body $detailHtml -Intro 'Select a VM to see its evidence, recommended size, what changes, and what to validate first.')
            $reference
        ) -join "`n"
        $nav = @(@{ Id = 'overview'; Label = 'Overview' }, @{ Id = 'quota'; Label = 'Quota' }, @{ Id = 'vms'; Label = 'VMs' }, @{ Id = 'details'; Label = 'Details' }) + $refNav
        $metaSub = @("Subscription <strong>$(& $e $g.Name)</strong>", "Tenant <strong>$(& $e $Run.Tenant.Name)</strong>", "As of <strong>$asOf</strong>", 'Read-only')
        (New-HtmlPage -Title "VMSKURetirementReport - $name" -Eyebrow 'Subscription assessment' -Heading $name -Meta $metaSub -Body $body -Css $css -BackLink $indexName -Nav $nav) | Out-File (Join-Path $OutDir (& $subFile $g.Name $name)) -Encoding utf8
    }
}

Export-ModuleMember -Function Export-AssessmentData, Export-ExecutiveSummaryMarkdown, Export-DetailedReportMarkdown, Export-HtmlReports, Format-MdTable, ConvertTo-SafeCsvValue, ConvertTo-MarkdownText
