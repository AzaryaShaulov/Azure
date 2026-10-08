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
        retirementQuota = $A.RetirementQuota
        modernizationQuota = $A.ModernizationQuota
        strategy       = if ($A.Strategy) {
            $st = [ordered]@{}
            foreach ($prop in $A.Strategy.PSObject.Properties) {
                $st[$prop.Name] = if ($prop.Name -in 'RetirementTarget', 'ModernizationTarget') { ConvertTo-CandidateSummary $prop.Value } else { $prop.Value }
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
        dataSource = if ($Run.PSObject.Properties.Name -contains 'DataSource' -and $Run.DataSource) { $Run.DataSource } else { 'Live' }
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
        [void]$sb.AppendLine('Demand is aggregated for all VMs moving into the same subscription / region / family. Minimum increase = (current usage + required) - limit. Recommended increase adds the safety margin. Scope ''Retirement'' covers mandatory migrations to their retirement target; ''Retirement+Modernization'' also includes optional Wave 4 moves; ''Modernization'' (only with --check-modernization) covers the strategic v6/v7 targets with steady-state and peak demand.')
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
    $checkModernization = [bool](Get-RunParameter -Run $Run -Name 'CheckModernization' -Default $false)
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
        '^(Already Retired|Immediate|Wave 1|LOW|SKU Restricted|Regional Limitation|Less than 12|Fail|Reduced|Redeploy Review)' { 'b-red'; break }
        '^(Confirmed Retirement|Retirement Announced|Migration Required|Wave 2|Quota Increase|12-24)' { 'b-orange'; break }
        '^(Wave 3|24-36|MEDIUM|Capacity Validation|Manual Review|Manual Validation|Convertible|Unable|Review|Skipped|Partial|Changed|Not verifiable|Excluded|Not assessed)' { 'b-yellow'; break }
        '^(Modernization|Wave 4|Plan Migration)' { 'b-purple'; break }
        '^(HIGH|Ready|Current|Quota OK|No Action|No Retirement|Pass|Done|Improved|Same|Available)' { 'b-green'; break }
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
    $navHtml = New-NavHtml -Nav $Nav
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
    <# Wraps the sections of one part of a subscription page (retirement or modernization) in a labelled, colour-coded band. #>
    param([Parameter(Mandatory)][ValidateSet('retirement', 'modernization')][string]$Tone, [Parameter(Mandatory)][string]$Part,
        [Parameter(Mandatory)][string]$Label, [Parameter(Mandatory)][string]$Title, [string]$Description, [string]$Body)
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $icon = if ($Tone -eq 'retirement') { '&#9888;' } else { '&#8599;' }
    @"
<div class='track track-$Tone' id='track-$Tone' role='region' aria-labelledby='track-$Tone-title'>
<div class='track-banner'><span class='track-icon' aria-hidden='true'>$icon</span><div class='track-text'><span class='track-part'>$(& $e $Part) &middot; <strong>$(& $e $Label)</strong></span><div class='track-title' id='track-$Tone-title' role='heading' aria-level='2'>$(& $e $Title)</div>$(if ($Description) { "<p class='track-desc'>$Description</p>" })</div></div>
$Body
</div>
"@
}

function New-TrackTilesHtml {
    <# Overview tiles that introduce and link to the retirement part and (when enabled) the modernization part. #>
    param([int]$RetiringCount, [string]$EarliestDate, [switch]$ShowModernization, [int]$ModernizationCount)
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $retHint = if ($RetiringCount -and $EarliestDate) { "Earliest retirement $(& $e $EarliestDate). Act before the dates shown." } elseif ($RetiringCount) { 'Act before the dates shown.' } else { 'No VMs on sizes with an announced retirement date.' }
    $tiles = @("<a class='track-tile track-tile-retirement' href='#track-retirement'><span class='track-tile-part'>Part 1 &middot; Required</span><span class='track-tile-value'>$RetiringCount</span><span class='track-tile-label'>VMs on retiring sizes</span><span class='track-tile-hint'>$retHint</span></a>")
    if ($ShowModernization) {
        $tiles += "<a class='track-tile track-tile-modernization' href='#track-modernization'><span class='track-tile-part'>Part 2 &middot; Optional</span><span class='track-tile-value'>$ModernizationCount</span><span class='track-tile-label'>VMs with a v6/v7 target</span><span class='track-tile-hint'>Longer-term moves to current generations. Plan when it suits.</span></a>"
    }
    "<div class='track-tiles'>$($tiles -join '')</div>"
}

# Microsoft Learn guidance for the upgrade path (URLs verified 2026-10-07).
$script:LearnDocs = [ordered]@{
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
    <# HTML scope: VMs affected by a Microsoft retirement announcement with a published date and a required action. #>
    param([Parameter(Mandatory)]$Assessment)
    $a = $Assessment
    return [bool]($a.AffectedByRetirement -eq 'Yes' -and $a.Lifecycle.RetirementDate -and $a.Action -and $a.Action -ne 'No Action Required')
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
    <# Microsoft Learn links for the retirement upgrade path, SCSI to NVMe conversion and Gen1 to Gen2. #>
    $groups = @($script:LearnDocs.Values | Group-Object { $_.Topic })
    $order = 'Retirement', 'Resize', 'SCSI to NVMe', 'Gen1 to Gen2', 'Networking and temp disk'
    $cards = foreach ($t in $order) {
        $g = $groups | Where-Object Name -eq $t
        if (-not $g) { continue }
        $items = (@($g.Group) | ForEach-Object { "<li><a href='$(ConvertTo-HtmlEncoded $_.Url)' target='_blank'>$(ConvertTo-HtmlEncoded $_.Title)</a></li>" }) -join ''
        "<div class='callout info'><h3>$(ConvertTo-HtmlEncoded $t)</h3><ul class='links'>$items</ul></div>"
    }
    @"
<ol class='upgrade-steps'>
<li><strong>Confirm the retirement</strong> and the Microsoft-recommended target series for each retiring size.</li>
<li><strong>Check prerequisites</strong>: Gen1 VMs need the Trusted launch upgrade before a Gen2-only size; SCSI VMs need NVMe conversion before an NVMe-only size (validate guest OS support first).</li>
<li><strong>Request quota</strong> for the target family and regional vCPUs (see Quota Actions).</li>
<li><strong>Resize in a change window</strong>, then validate disks, networking (MANA), temp-disk usage and application health.</li>
</ol>
<div class='grid-2'>$($cards -join '')</div>
"@
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
    "<div class='table-wrap'><table class='quota-table'><thead><tr><th>Scope</th>$subHead<th>Region</th><th>Quota</th><th class='num quota-usage'>Used / limit</th><th class='num'>Needed</th><th class='num'>Min. increase</th><th class='num'>Recommended request</th><th>Status</th></tr></thead><tbody>$rowsHtml</tbody></table></div><p class='note'><em>Retirement</em> scope covers required migrations to their retirement target; <em>Retirement+Modernization</em> also includes optional Wave 4 moves; <em>Modernization</em> (only with <code>--check-modernization</code>) covers the strategic v6/v7 targets.</p>"
}

function New-Kpi {
    param([string]$Value, [string]$Label, [string]$Tone = 'neutral', [string]$Hint)
    "<div class='kpi kpi-$Tone'><div class='kpi-label'>$(ConvertTo-HtmlEncoded $Label)</div><div class='kpi-value'>$(ConvertTo-HtmlEncoded $Value)</div>$(if ($Hint) { "<div class='kpi-hint'>$(ConvertTo-HtmlEncoded $Hint)</div>" })</div>"
}

function Get-ModernizationViewModel {
    <# Presentation wrapper around Assessment.Strategy (Get-TargetStrategy). No compatibility or quota decisions here. #>
    param([Parameter(Mandatory)]$Assessment)
    $a = $Assessment
    $s = if ($a.Strategy) { $a.Strategy } else { Get-TargetStrategy -Assessment $a }
    $t = $s.ModernizationTarget
    $blockers = New-Object System.Collections.Generic.List[string]
    if ($s.RedeployReview) { $blockers.Add('Guest OS not supported for Gen1 upgrade') }
    if ($s.RequiresGenerationChange) { $blockers.Add('Gen1 / target requires Gen2 (Trusted launch upgrade)') }
    if ($s.RequiresNvmeConversion) { $blockers.Add("$($a.Vm.DiskControllerType) / target requires NVMe") }
    if ($s.ModernizationQuotaStatus -eq 'Quota Increase Required') { $blockers.Add('Target-family or regional quota') }
    elseif ($s.ModernizationQuotaStatus -in 'Quota Information Unavailable', 'Manual Validation Required') { $blockers.Add('Quota validation') }
    if (-not $t -and -not $s.AlreadyModern) {
        $blockers.Add($(if ($a.Modernization -and $a.Modernization.Status) { "No validated v6/v7 target ($($a.Modernization.Status))" } else { 'No validated v6/v7 target' }))
    }
    $validation = @($s.ValidationItems)
    if ($validation.Count -gt 0 -and $blockers.Count -eq 0) { $blockers.Add('Guest/workload validation') }
    [pscustomobject]@{
        Assessment = $a
        Strategy = $s
        VmName = $a.Vm.Name
        ResourceGroup = $a.Vm.ResourceGroup
        Region = $a.Vm.Region
        CurrentSku = $a.Vm.SkuName
        CurrentGeneration = $a.Vm.HyperVGeneration
        CurrentController = $a.Vm.DiskControllerType
        RetirementRequired = $s.RetirementRequired
        RetirementUnconfirmed = $s.RetirementUnconfirmed
        RetirementTargetSku = $s.RetirementTargetSku
        RetirementTargetGeneration = $s.RetirementTargetGeneration
        RetirementQuotaStatus = $s.RetirementQuotaStatus
        ModernizationTargetSku = $s.ModernizationTargetSku
        ModernizationTargetGeneration = $s.ModernizationTargetGeneration
        Target = $t
        TargetSku = if ($t) { $t.SkuName } else { $null }
        TargetSource = $s.ModernizationTargetSource
        Path = $s.ModernizationPath
        RecommendedPath = $s.RecommendedMigrationPath
        Complexity = $s.Complexity
        Status = $s.ModernizationReadiness
        Blocker = if ($blockers.Count) { $blockers -join '; ' } else { 'None' }
        RequiresGenerationModernization = $s.RequiresGenerationChange
        RequiresNvmeConversion = $s.RequiresNvmeConversion
        RedeployReview = $s.RedeployReview
        ValidationItems = $validation
        ManualValidation = $validation.Count -gt 0
        QuotaStatus = $s.ModernizationQuotaStatus
        PeakQuotaStatus = $s.ModernizationPeakQuotaStatus
        MigrationQuotaModel = $s.MigrationQuotaModel
        AlreadyModern = $s.AlreadyModern
    }
}
function New-ActionGroupHtml {
    param([string]$Title, [AllowEmptyCollection()][object[]]$Models, [string]$Tone = 'grey', [int]$MaxItems = 5)
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $items = @($Models)
    $list = if ($items.Count) {
        (@($items | Select-Object -First $MaxItems | ForEach-Object { "<li>$(& $e $_.VmName)</li>" }) -join '') + $(if ($items.Count -gt $MaxItems) { "<li class='muted'>+$($items.Count - $MaxItems) more</li>" } else { '' })
    }
    else { "<li class='muted'>None</li>" }
    "<div class='action-group action-$Tone'><h3><span>$(& $e $Title)</span><span class='count'>$($items.Count)</span></h3><ul>$list</ul></div>"
}

function New-ModernizationQuotaImpactHtml {
    <# Renders the backend Modernization-scope quota rows (steady-state vs peak) for one subscription. #>
    param([AllowEmptyCollection()][object[]]$QuotaRows)
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $rows = @($QuotaRows | Where-Object { $_ -and $_.PSObject.Properties.Name -contains 'Scope' -and $_.Scope -eq 'Modernization' } |
            Sort-Object @{ e = { if ($_.QuotaName -eq 'cores') { 1 } else { 0 } } }, Region, QuotaName)
    if ($rows.Count -eq 0) { return "<div class='callout ok'>No v6/v7 target quota demand is present in this subscription.</div>" }
    $num = { param($v, [switch]$Strong) if ($null -eq $v -or "$v" -eq '') { "<span class='muted'>&ndash;</span>" } elseif ($Strong) { "<strong>$([int]$v)</strong>" } else { "$([int]$v)" } }
    $html = foreach ($r in $rows) {
        $name = if ($r.QuotaDisplayName) { $r.QuotaDisplayName } else { $r.QuotaName }
        $usage = if ($null -ne $r.Limit) { "$([int]$r.CurrentUsage) / $([int]$r.Limit)" } else { "<span class='muted'>Unavailable</span>" }
        $model = if ($r.MigrationQuotaModel -eq 'InPlace') { 'In-place resize' } else { "$($r.MigrationQuotaModel) ($($r.SideBySideVmCount) side-by-side)" }
        "<tr><td>$(& $e $r.Region)</td><td>$(& $e $name)</td><td class='num'>$([int]$r.VmCount)</td><td class='num quota-usage'>$usage</td><td class='num steady'>$([int]$r.SteadyStateRequiredVcpu)</td><td class='num peak'>$([int]$r.PeakMigrationRequiredVcpu)</td><td class='num'>$(& $num $r.MinimumIncrease)</td><td class='num'>$(& $num $r.PeakMinimumIncrease -Strong)</td><td class='num'>$(& $num $r.PeakRecommendedIncrease)</td><td class='quota-model'>$(& $e $model)</td><td>$(New-Badge $r.PeakStatus)</td></tr>"
    }
    @"
<div class='table-wrap'><table class='quota-table quota-impact-table'><thead><tr><th>Region</th><th>Quota</th><th class='num'>VMs</th><th class='num'>Used / limit</th><th class='num'>Steady-state demand</th><th class='num'>Peak migration demand</th><th class='num'>Steady min. increase</th><th class='num'>Peak min. increase</th><th class='num'>Peak recommended request</th><th>Planning model</th><th>Peak status</th></tr></thead><tbody>$($html -join "`n")</tbody></table></div>
<div class='quota-impact-note'><strong>Peak planning model:</strong> resizes and SCSI to NVMe conversions are modeled in place. Gen1 to Gen2 (Trusted launch upgrade) and redeploy paths are conservatively modeled as side-by-side, so the target capacity is added while the source still exists. These are planning estimates from <code>quota-impact.csv</code> scope <em>Modernization</em>; validate the final migration method and Azure capacity before execution.</div>
"@
}
function New-ModernizationDetailRowHtml {
    param([Parameter(Mandatory)]$Model, [int]$ColSpan = 9)
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $a = $Model.Assessment
    $p = $Model.Target

    $currentFacts = [ordered]@{
        'VM' = $Model.VmName
        'Resource group' = $Model.ResourceGroup
        'Region' = $Model.Region
        'Current SKU' = $Model.CurrentSku
        'VM generation' = $(if ($Model.CurrentGeneration) { $Model.CurrentGeneration } else { 'Unknown' })
        'Disk controller' = $(if ($Model.CurrentController) { $Model.CurrentController } else { 'Unknown' })
        'CPU vendor' = $(if ($a.Current -and $a.Current.Vendor) { $a.Current.Vendor } else { 'Unknown' })
        'vCPU / memory' = "$(if ($a.Current) { $a.Current.vCPUs } else { '?' }) vCPU / $(if ($a.Current) { $a.Current.MemoryGB } else { '?' }) GB"
        'Temp / local disk' = $(if ($a.Current -and $null -ne $a.Current.TempDiskGB) { "$($a.Current.TempDiskGB) GB" } else { 'Unknown' })
        'Power state' = $(if ($a.Vm.PowerState) { $a.Vm.PowerState } else { 'Unknown' })
    }
    $currentHtml = ($currentFacts.Keys | ForEach-Object { "<dt>$(& $e $_)</dt><dd>$(& $e $currentFacts[$_])</dd>" }) -join ''

    $targetFacts = [ordered]@{
        'Retirement required' = $(if ($Model.RetirementRequired) { 'Yes' } elseif ($Model.RetirementUnconfirmed) { 'Unconfirmed - validate lifecycle' } else { 'No' })
        'Retirement target' = $(if ($Model.RetirementTargetSku) { $Model.RetirementTargetSku } elseif ($Model.RetirementRequired -or $Model.RetirementUnconfirmed) { 'No validated retirement target' } else { 'Not required' })
        'Retirement target generation' = $(if ($Model.RetirementTargetGeneration) { "v$($Model.RetirementTargetGeneration)" } else { 'N/A' })
        'Retirement target quota' = $(if ($Model.RetirementQuotaStatus) { $Model.RetirementQuotaStatus } else { 'N/A' })
        'Modernization target' = $(if ($Model.ModernizationTargetSku) { $Model.ModernizationTargetSku } else { 'No validated v6/v7 target' })
        'Modernization generation' = $(if ($Model.ModernizationTargetGeneration) { "v$($Model.ModernizationTargetGeneration)" } else { 'Unknown' })
        'Modern target family' = $(if ($p -and $p.Family) { $p.Family } else { 'Unknown' })
        'Modern target CPU vendor' = $(if ($p -and $p.CpuVendor) { $p.CpuVendor } else { 'Unknown' })
        'Modern target vCPU / memory' = $(if ($p) { "$($p.vCPUs) vCPU / $($p.MemoryGB) GB" } else { 'N/A' })
        'Modernization method' = $Model.Path
        'Recommended path' = $Model.RecommendedPath
        'Complexity' = $Model.Complexity
        'Status' = $Model.Status
        'Modernization quota (steady / peak)' = $(if ($Model.QuotaStatus) { "$($Model.QuotaStatus) / $($Model.PeakQuotaStatus)" } else { 'N/A' })
    }
    $targetHtml = ($targetFacts.Keys | ForEach-Object { "<dt>$(& $e $_)</dt><dd>$(& $e $targetFacts[$_])</dd>" }) -join ''

    $s = $Model.Strategy
    $blockerItems = New-Object System.Collections.Generic.List[string]
    if ($Model.RedeployReview) { $blockerItems.Add("<li><strong>Deployment model:</strong> $(& $e $s.RedeployReason).</li>") }
    if ($Model.RequiresGenerationModernization) { $blockerItems.Add('<li><strong>VM generation:</strong> Gen1 source; the v6/v7 target is Gen2-only, which requires the Trusted launch upgrade.</li>') }
    if ($Model.RequiresNvmeConversion) { $blockerItems.Add("<li><strong>Disk controller:</strong> $(& $e $Model.CurrentController) source; the target supports NVMe only.</li>") }
    if ($Model.QuotaStatus -eq 'Quota Increase Required') { $blockerItems.Add('<li><strong>Quota:</strong> Target-family and/or regional vCPU quota must be increased before migration.</li>') }
    if (-not $p -and -not $Model.AlreadyModern) { $blockerItems.Add("<li><strong>Target:</strong> $(& $e $Model.Blocker).</li>") }
    if ($Model.ManualValidation) { $blockerItems.Add('<li><strong>Guest/workload validation:</strong> One or more requirements cannot be proven from Azure control-plane data (see checklist).</li>') }
    if ($blockerItems.Count -eq 0) { $blockerItems.Add('<li>No modernization blocker was detected from the available assessment data.</li>') }

    $remediation = New-Object System.Collections.Generic.List[string]
    if ($Model.RedeployReview) { $remediation.Add('<li>Deploy a Gen2 VM on a supported OS image and migrate the workload/data (side-by-side).</li>') }
    elseif ($Model.RequiresGenerationModernization) { $remediation.Add("<li>Upgrade the Gen1 VM to Trusted launch (Gen2), or rebuild if the OS or size is not supported ($(New-LearnLink 'Gen1TrustedLaunch')).</li>") }
    if ($Model.RequiresNvmeConversion) { $remediation.Add("<li>Validate guest NVMe support and backup/rollback, then convert the disk controller to NVMe before resizing ($(New-LearnLink 'NvmeConvert')).</li>") }
    if ($Model.QuotaStatus -eq 'Quota Increase Required') { $remediation.Add('<li>Request the reported target-family and regional vCPU quota before scheduling the migration (use peak demand for side-by-side paths).</li>') }
    if (-not $p -and -not $Model.AlreadyModern) { $remediation.Add('<li>Review the modernization reason and candidate table; no v6/v7 size passed the workload gates or is available.</li>') }
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
    $quotaModel = switch ($Model.MigrationQuotaModel) { 'SideBySide' { 'Side-by-side: target capacity is needed while the source still exists' } 'InPlace' { 'In-place resize' } default { 'Not applicable' } }

    $validationItems = @(@($a.ValidationItems) + @($Model.ValidationItems) | Where-Object { $_ })
    $validationHtml = if ($validationItems.Count) { (@($validationItems | Select-Object -Unique | ForEach-Object { "<li>$(& $e $_)</li>" }) -join '') } else { '<li>Standard post-resize application and infrastructure validation.</li>' }

    $diff = if ($p -and $p.Differences) { (@($p.Differences) | ForEach-Object { "<tr><td>$(& $e $_.Attribute)</td><td>$(& $e $_.Current)</td><td>$(& $e $_.Target)</td><td>$(New-Badge $_.Assessment)</td><td>$(& $e $_.Note)</td></tr>" }) -join '' } else { '' }
    $gates = if ($p -and $p.Gates) { (@($p.Gates) | ForEach-Object { "<tr><td>$(& $e $_.Gate)</td><td>$(New-Badge $_.Result)</td><td>$(& $e $_.Detail)</td></tr>" }) -join '' } else { '' }
    $candidateRows = if ($a.Candidates -and $a.Candidates.Candidates) { (@($a.Candidates.Candidates) | Select-Object -First 6 | ForEach-Object { "<tr><td>$(if ($_.Role -and $_.Role -ne 'Candidate') { New-Badge 'Info' $_.Role } else { '<span class=''muted''>&ndash;</span>' })</td><td><code>$(& $e $_.SkuName)</code></td><td>$(& $e $_.CpuVendor)</td><td class='num'>v$($_.Generation)</td><td class='num'>$($_.vCPUs) / $($_.MemoryGB)</td><td class='num'>$($_.Score)</td><td>$(New-Badge $_.Availability)</td><td>$(& $e $(if ($_.Rejected) { 'Rejected: ' + $_.RejectionReason } elseif (@($_.ReviewGates).Count) { 'Review: ' + ($_.ReviewGates -join ', ') } else { $_.Variant }))</td></tr>" }) -join '' } else { '' }

    $anchor = 'modernization-' + (Get-VmAnchorId $a.Vm)
    @"
<tr class='modernization-detail-row'><td colspan='$ColSpan'>
<details class='modernization-vm-detail' id='$anchor'>
<summary><span>Extended VM details</span><span class='detail-summary-meta'>$(& $e $Model.VmName) &middot; $(& $e $Model.Path) &middot; $(& $e $Model.Complexity) complexity</span></summary>
<div class='modernization-vm-detail-body'>
  <div class='vm-detail-grid'>
    <div class='vm-detail-card'><h4>Current VM</h4><dl class='facts compact-facts'>$currentHtml</dl></div>
    <div class='vm-detail-card target-strategy-card'><h4>Retirement &amp; Modernization Strategy</h4><dl class='facts compact-facts'>$targetHtml</dl></div>
    <div class='vm-detail-card'><h4>Blockers &amp; Required Changes</h4><ul>$($blockerItems -join '')</ul><h5>Recommended remediation</h5><ol>$($remediation -join '')</ol></div>
    <div class='vm-detail-card'><h4>Quota &amp; Migration Capacity</h4><p>$quotaText</p><p><strong>Planning model:</strong> $(& $e $quotaModel)</p><p class='note'>Use the subscription-level quota impact table for aggregated steady-state and peak demand.</p></div>
  </div>
  <div class='vm-detail-wide'><h4>Validation Checklist</h4><ul class='validation-grid'>$validationHtml</ul></div>
  $(if ($diff) { "<div class='vm-detail-wide'><h4>Current vs Modern Target</h4><div class='table-wrap'><table class='detail-table'><thead><tr><th>Attribute</th><th>Current</th><th>Target</th><th>Assessment</th><th>Note</th></tr></thead><tbody>$diff</tbody></table></div></div>" })
  $(if ($gates) { "<div class='vm-detail-wide'><h4>Mandatory Compatibility Gates</h4><div class='table-wrap'><table class='detail-table'><thead><tr><th>Gate</th><th>Result</th><th>Detail</th></tr></thead><tbody>$gates</tbody></table></div></div>" })
  $(if ($candidateRows) { "<div class='vm-detail-wide'><h4>Top Evaluated Alternatives</h4><div class='table-wrap'><table class='detail-table'><thead><tr><th>Role</th><th>SKU</th><th>CPU</th><th class='num'>Gen</th><th class='num'>vCPU / GB</th><th class='num'>Score</th><th>Availability</th><th>Notes</th></tr></thead><tbody>$candidateRows</tbody></table></div></div>" })
</div>
</details>
</td></tr>
"@
}

function New-ModernizationSectionHtml {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Assessments, [AllowEmptyCollection()][object[]]$QuotaRows, [int]$MaxDetails = 0)
    $e = { param($x) ConvertTo-HtmlEncoded $x }
    $models = @($Assessments | ForEach-Object { Get-ModernizationViewModel -Assessment $_ })
    $detailCount = 0
    if ($models.Count -eq 0) { return "<div class='callout ok'>No VMs in this subscription are on sizes with an announced Microsoft retirement date.</div>" }

    $direct = @($models | Where-Object { $_.Path -eq 'Direct Resize' -and $_.Status -eq 'Ready' })
    $nvme = @($models | Where-Object RequiresNvmeConversion)
    $gen1 = @($models | Where-Object RequiresGenerationModernization)
    $quota = @($models | Where-Object QuotaStatus -eq 'Quota Increase Required')
    $redeploy = @($models | Where-Object RedeployReview)
    $manual = @($models | Where-Object Status -eq 'Manual Review')
    $modern = @($models | Where-Object AlreadyModern)

    $kpis = @(
        (New-Kpi $direct.Count 'Direct resize ready' 'green' 'No conversion blocker found')
        (New-Kpi $nvme.Count 'NVMe conversion' 'yellow' 'SCSI / controller remediation')
        (New-Kpi $gen1.Count 'Gen1 modernization' 'orange' 'Gen2-capable path required')
        (New-Kpi $quota.Count 'Quota increase' 'purple' 'Target-family or regional')
        (New-Kpi $redeploy.Count 'Redeploy / rebuild review' 'red' 'Gen1 upgrade not supported for the guest OS')
        (New-Kpi $manual.Count 'Manual validation' 'grey' 'No validated target or quota unverified')
        (New-Kpi $modern.Count 'Already v6/v7' 'blue' 'No modernization required')
    ) -join ''

    $tableRows = foreach ($m in ($models | Where-Object { -not $_.AlreadyModern } | Sort-Object @{ e = { switch ($_.Status) { 'Quota Increase' { 0 } 'Redeploy Review' { 1 } 'Convertible' { 2 } 'Manual Review' { 3 } 'Ready' { 4 } default { 5 } } } }, VmName)) {
        $retirementTarget = if ($m.RetirementTargetSku) { "<code>$(& $e $m.RetirementTargetSku)</code>$(if ($m.RetirementTargetGeneration) { "<div class='sub'>v$($m.RetirementTargetGeneration) &middot; retirement</div>" })" } elseif ($m.RetirementUnconfirmed) { "<span class='badge b-yellow'>Unconfirmed</span>" } elseif (-not $m.RetirementRequired) { "<span class='badge b-green'>Not required</span>" } else { "<span class='muted'>No validated target</span>" }
        $target = if ($m.ModernizationTargetSku) { "<code>$(& $e $m.ModernizationTargetSku)</code>$(if ($m.ModernizationTargetGeneration) { "<div class='sub'>v$($m.ModernizationTargetGeneration) &middot; strategic</div>" })" } else { "<span class='muted'>&ndash;</span>" }
        $currentGen = if ($m.CurrentGeneration) { $m.CurrentGeneration } else { 'Unknown' }
        $controller = if ($m.CurrentController) { $m.CurrentController } else { 'Unknown' }
        $complexityBadge = switch ($m.Complexity) {
            'Low' { "<span class='badge b-green'>Low</span>" }
            'Medium' { "<span class='badge b-yellow'>Medium</span>" }
            'High' { "<span class='badge b-red'>High</span>" }
            default { "<span class='badge b-grey'>$(& $e $m.Complexity)</span>" }
        }
        $summaryRow = "<tr class='modernization-summary-row'><td><strong>$(& $e $m.VmName)</strong><div class='sub'>$(& $e $m.ResourceGroup) &middot; $(& $e $m.Region)</div></td><td><code>$(& $e $m.CurrentSku)</code></td><td><div class='inline-meta'><span>$(& $e $currentGen)</span><span class='muted'>&middot;</span><span>$(& $e $controller)</span></div></td><td class='target-cell retirement-target-cell'>$retirementTarget</td><td class='target-cell modernization-target-cell'>$target</td><td class='path-cell'><div class='path-primary'>$(& $e $m.Path)</div><div class='sub recommended-sequence'>$(& $e $m.RecommendedPath)</div></td><td>$complexityBadge</td><td class='blocker-cell'>$(& $e $m.Blocker)</td><td>$(New-Badge $m.QuotaStatus)</td><td class='status-cell'>$(New-Badge $m.Status)</td></tr>"
        $summaryRow
        $detailCount++
        if ($MaxDetails -le 0 -or $detailCount -le $MaxDetails) { New-ModernizationDetailRowHtml -Model $m -ColSpan 10 }
    }
    $table = "<div class='target-legend'><span><strong>Retirement target</strong> = supported move required to remediate an affected/EOL SKU.</span><span><strong>Modernization target</strong> = strategic v6/v7 destination when <code>-CheckModernization</code> is enabled.</span></div><div class='table-wrap'><table class='modernization-table'><thead><tr><th>VM</th><th>Current SKU</th><th>Gen / controller</th><th>Retirement target</th><th>Modernization target</th><th>Recommended path</th><th>Complexity</th><th>Key blocker / validation</th><th>Quota</th><th>Status</th></tr></thead><tbody>$($tableRows -join "`n")</tbody></table></div><p class='note'>The two targets can be the same. When they differ, the report explicitly shows whether v5 is an immediate retirement landing zone and v6/v7 is the longer-term modernization destination. A modern target can still be shown when direct resize is blocked by convertible VM generation and/or disk-controller requirements.</p>"
    if ($MaxDetails -gt 0 -and $detailCount -gt $MaxDetails) { $table += "<p class='note'>Extended details are shown for the first $MaxDetails VMs; every VM remains in the table above, <code>vm-assessment.csv</code> and <code>assessment.json</code>.</p>" }

    $groups = @(
        (New-ActionGroupHtml -Title 'Ready for Direct Resize' -Models $direct -Tone 'green')
        (New-ActionGroupHtml -Title 'SCSI -> NVMe Required' -Models $nvme -Tone 'yellow')
        (New-ActionGroupHtml -Title 'Gen1 Modernization Required' -Models $gen1 -Tone 'orange')
        (New-ActionGroupHtml -Title 'Redeploy / Rebuild Review' -Models $redeploy -Tone 'red')
        (New-ActionGroupHtml -Title 'Quota Increase Required' -Models $quota -Tone 'purple')
        (New-ActionGroupHtml -Title 'Manual Review Required' -Models $manual -Tone 'grey')
    ) -join ''

    $guidance = New-Object System.Collections.Generic.List[string]
    if ($nvme.Count) { $guidance.Add("<div class='guidance-item'><strong>SCSI to NVMe conversion</strong><span>Validate guest NVMe driver support, backup/rollback, boot and disk visibility before moving to an NVMe-only v6/v7 target. The report does not claim guest readiness from control-plane data. See $(New-LearnLink 'NvmeConvert'), $(New-LearnLink 'NvmeInPlace'), $(New-LearnLink 'NvmeOsImages') and $(New-LearnLink 'NvmeFaq').</span></div>") }
    if ($gen1.Count) { $guidance.Add("<div class='guidance-item'><strong>Gen1 to Gen2 (Trusted launch upgrade)</strong><span>Gen1 VMs cannot resize to Gen2-only sizes. Microsoft supports Gen1 to Gen2 only through the Trusted launch upgrade, for supported OS versions and sizes (not Windows Server 2016, Debian or Azure Linux); otherwise redeploy. See <a href='https://learn.microsoft.com/azure/virtual-machines/trusted-launch-existing-vm-gen-1'>Upgrade Gen1 VMs to Trusted launch</a>.</span></div>") }
    if ($quota.Count) { $guidance.Add("<div class='guidance-item'><strong>Quota planning</strong><span>Request target-family and/or regional vCPU quota before the migration window. Use peak demand when the chosen path requires source and target capacity to coexist.</span></div>") }
    if (@($models | Where-Object { @($_.ValidationItems | Where-Object { $_ -like 'Temporary disk:*' }).Count -gt 0 }).Count) { $guidance.Add("<div class='guidance-item'><strong>Temporary / local disk</strong><span>Confirm whether the workload depends on ephemeral local storage. Preserve an appropriate <code>d</code> variant where local temp disk capability is required. See $(New-LearnLink 'NoTempDisk').</span></div>") }
    if (@($models | Where-Object { @($_.ValidationItems | Where-Object { $_ -like 'MANA networking:*' }).Count -gt 0 }).Count) { $guidance.Add("<div class='guidance-item'><strong>MANA / guest validation</strong><span>Accelerated Networking does not by itself prove guest MANA readiness. Validate guest drivers, networking, backup, monitoring and application health after modernization. See $(New-LearnLink 'Mana').</span></div>") }
    if ($guidance.Count -eq 0) { $guidance.Add("<div class='guidance-item'><strong>No additional remediation guidance</strong><span>No conversion-specific modernization blockers were detected from the available Azure control-plane data.</span></div>") }

    $examples = New-Object System.Collections.Generic.List[string]
    foreach ($path in @('Direct Resize','SCSI to NVMe + Resize','Gen1 + NVMe + Resize','Gen1 Modernization + Resize','Redeploy / Rebuild Review')) {
        $m = @($models | Where-Object Path -eq $path | Select-Object -First 1)
        if ($m.Count -eq 0) { continue }
        $x = $m[0]
        $step = switch ($path) { 'Direct Resize' { 'Resize' } 'SCSI to NVMe + Resize' { 'Convert to NVMe' } 'Gen1 + NVMe + Resize' { 'Gen2 + NVMe' } 'Gen1 Modernization + Resize' { 'Trusted launch (Gen2)' } default { 'New Gen2 VM' } }
        $targetNode = if ($x.TargetSku) { $x.TargetSku } else { 'Select validated v6/v7 target' }
        $examples.Add("<div class='migration-path'><span class='migration-path-name'>$(& $e $path)</span><span class='migration-node'>$(& $e $x.CurrentSku)</span><span class='migration-arrow'>&rarr; $(& $e $step) &rarr;</span><span class='migration-node'>$(& $e $targetNode)</span></div>")
    }
    if ($examples.Count -eq 0) { $examples.Add("<div class='migration-path'><span class='migration-path-name'>No migration example required</span><span class='migration-node'>Current environment</span><span class='migration-arrow'>&rarr;</span><span class='migration-node'>Already modern / no target identified</span></div>") }

    $quotaHtml = New-ModernizationQuotaImpactHtml -QuotaRows $QuotaRows
    @"
<div class='kpis modernization-kpis'>$kpis</div>
<div class='modernization-subheading'><h3>VM Modernization Assessment</h3><span class='note'>Actionable target, path, blocker, quota and validation view.</span></div>
$table
<div class='modernization-subheading'><h3>Action Groups</h3><span class='note'>VMs grouped by the work required before migration.</span></div>
<div class='action-groups'>$groups</div>
<div class='modernization-subheading'><h3>Quota Impact: Steady State vs Peak Migration</h3><span class='note'>From quota-impact.csv scope Modernization; peak assumes side-by-side capacity for Gen1/redeploy paths.</span></div>
$quotaHtml
<div class='modernization-panels'>
  <div class='modernization-panel'><h3>Contextual Modernization Guidance</h3><div class='modernization-panel-body'><div class='guidance-list'>$($guidance -join '')</div></div></div>
  <div class='modernization-panel'><h3>Migration Path Examples</h3><div class='modernization-panel-body'><div class='migration-paths'>$($examples -join '')</div></div></div>
</div>
"@
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
        (New-Section -Id 'upgrade-guidance' -Title 'Upgrade Path and SCSI to NVMe Guidance' -Body (New-UpgradeGuidanceHtml) -Intro 'Microsoft Learn documentation for moving retiring VMs to a current size, including SCSI to NVMe conversion and Gen1 to Gen2 (Trusted launch).')
        (New-Section -Id 'cross-vendor' -Title 'Cross-Vendor Migration Warnings' -Body $warn -Intro 'Moving between Intel and AMD is usually transparent to the operating system, but some workloads need validation first.' -Collapsed)
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
    $dataSource = if ($Run.PSObject.Properties.Name -contains 'DataSource' -and $Run.DataSource -and $Run.DataSource -ne 'Live') { $Run.DataSource } else { $null }
    if ($dataSource) { $meta += "Data <strong>$(& $e $dataSource)</strong>" }
    $reference = New-ReferenceSections -ProcessorCatalog $ProcessorCatalog -Run $Run -Summary $s -CatalogResult $CatalogResult
    $refNav = @(@{ Id = 'upgrade-guidance'; Label = 'Upgrade guidance' }, @{ Id = 'cross-vendor'; Label = 'Cross-vendor' }, @{ Id = 'sku-families'; Label = 'SKU families' }, @{ Id = 'cpu-vendor'; Label = 'CPU from name' }, @{ Id = 'limitations'; Label = 'Limitations' })
    $checkModernization = [bool](Get-RunParameter -Run $Run -Name 'CheckModernization' -Default $false)
    $includeOptional = [bool](Get-RunParameter -Run $Run -Name 'HtmlIncludeOptionalModernization' -Default $false)
    $maxDetails = [int](Get-RunParameter -Run $Run -Name 'HtmlMaxVmDetails' -Default 250)
    $listed = { param($a) Test-HtmlListedVm -Assessment $a -IncludeOptional:$includeOptional }
    $scopeText = if ($includeOptional) { 'VMs on sizes with an announced Microsoft retirement date and a required action, plus optional modernization (older generations without an announced retirement), are listed.' } else { 'Only VMs on sizes with an announced Microsoft retirement date and a required action are listed.' }
    $ageDays = if ($Run.PSObject.Properties.Name -contains 'SnapshotAgeDays' -and $null -ne $Run.SnapshotAgeDays) { [int]$Run.SnapshotAgeDays } else { $null }
    $staleHtml = if ($null -ne $ageDays -and $ageDays -gt 7) { "<div class='callout warn'><strong>Replayed data is $ageDays days old.</strong> Quota, regional availability and inventory may have changed since the snapshot was captured. Capture a new snapshot before acting on quota or resize decisions.</div>" } else { '' }
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
    $warn = $staleHtml
    if ($CatalogResult.Warning) { $warn += "<div class='callout warn'><strong>Evidence warning:</strong> $(& $e $CatalogResult.Warning)</div>" }
    $unm = @(Get-UnmappedSeriesNames -Catalog $CatalogResult.Catalog)
    if ($unm.Count -gt 0) { $warn += "<div class='callout warn'><strong>Microsoft series without a size mapping (not classified):</strong> $(& $e ($unm -join ', '))</div>" }
    $nonVm = @(Get-NonVmSizeEntries -Catalog $CatalogResult.Catalog)
    if ($nonVm.Count -gt 0) { $warn += "<div class='callout info'><strong>Microsoft lifecycle entries that are not VM sizes:</strong> $(& $e ((@($nonVm) | ForEach-Object { "$($_.Name) ($($_.Category), $($_.Status) $($_.PlannedRetirementDate))" }) -join '; ')). They are not matched to VMs; validate them separately (for example, Dedicated Host SKUs).</div>" }

    $waveOrder = 'Wave 1 - Urgent', 'Wave 2 - Near Term', 'Wave 3 - Planned', 'Beyond Horizon', 'Review - Unconfirmed', 'Wave 4 - Modernization'
    $waveRows = foreach ($w in $waveOrder) {
        foreach ($g in (@($Assessments | Where-Object { $_.Wave -eq $w -and (& $listed $_) }) | Group-Object { $_.Vm.SkuName } | Sort-Object Count -Descending)) {
            $f = $g.Group[0]
            $rec = @($g.Group | ForEach-Object { if ($_.Candidates -and $_.Candidates.Primary) { $_.Candidates.Primary.SkuName } else { 'No recommendation' } } | Group-Object | Sort-Object Count -Descending | ForEach-Object { if ($g.Count -gt 1) { "$($_.Name) &times;$($_.Count)" } else { $_.Name } }) -join ', '
            "<tr><td>$(New-Badge $w)</td><td><code>$(& $e $g.Name)</code></td><td>$(New-Badge $f.Lifecycle.EvidenceClass)</td><td class='nowrap'>$(if ($f.Lifecycle.RetirementDate) { & $e $f.Lifecycle.RetirementDate } else { "<span class='muted'>No date</span>" })</td><td class='num'>$($g.Count)</td><td>$rec</td></tr>"
        }
    }
    $waveHtml = if (@($waveRows).Count) { "<div class='table-wrap'><table><thead><tr><th>Wave</th><th>Current size</th><th>Microsoft status</th><th>Retirement date</th><th class='num'>VMs</th><th>Recommended size</th></tr></thead><tbody>$($waveRows -join "`n")</tbody></table></div>" } else { "<div class='callout ok'>No VMs are on sizes with an announced Microsoft retirement date.</div>" }
    $waveIntro = "$scopeText Every VM is in <code>vm-assessment.csv</code> and <code>assessment.json</code>."

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
        $retiring = @($set | Where-Object { & $listed $_ })
        $retiringOnly = @($set | Where-Object { Test-RetiringVm -Assessment $_ })
        $earliest = @($retiringOnly | ForEach-Object { "$($_.Lifecycle.RetirementDate)" } | Where-Object { $_ } | Sort-Object | Select-Object -First 1)
        $modernTargets = if ($checkModernization) { @($retiring | Where-Object { $s = if ($_.Strategy) { $_.Strategy } else { Get-TargetStrategy -Assessment $_ }; $s.ModernizationTargetSku -and -not $s.AlreadyModern }).Count } else { 0 }
        $tilesHtml = New-TrackTilesHtml -RetiringCount $retiringOnly.Count -EarliestDate $(if ($earliest.Count) { $earliest[0] } else { '' }) -ShowModernization:$checkModernization -ModernizationCount $modernTargets

        $rows = foreach ($a in ($retiring | Sort-Object { & $waveRank $_.Wave }, { $_.Vm.Name })) {
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
        $table = if (@($rows).Count) { "<div class='table-wrap'><table class='vm-table'><thead><tr><th>VM</th><th>Current size</th><th>Microsoft status</th><th>Recommended size</th><th>Disk capabilities</th><th>Next step</th><th class='num'>PAYGO / month</th></tr></thead><tbody>$($rows -join "`n")</tbody></table></div><p class='note'>$scopeText Every VM is in <code>vm-assessment.csv</code>. Disk capabilities compare current &rarr; recommended values. Monthly cost is the public pay-as-you-go list price (730 h) for comparison only; your actual rates may differ.</p>" } else { "<div class='callout ok'>No VMs in this subscription are on sizes with an announced Microsoft retirement date.</div>" }

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

        $detailSet = @($retiring | Where-Object { $_.Candidates } | Sort-Object { & $waveRank $_.Wave }, { $_.Vm.Name })
        $detailOmitted = if ($maxDetails -gt 0 -and $detailSet.Count -gt $maxDetails) { $detailSet.Count - $maxDetails } else { 0 }
        if ($detailOmitted) { $detailSet = @($detailSet | Select-Object -First $maxDetails) }
        $details = foreach ($a in $detailSet) {
            $p = $a.Candidates.Primary; $sc = $a.Candidates.Secondary
            $facts = [ordered]@{
                'Microsoft status' = "$(New-Badge $a.Lifecycle.EvidenceClass) $(& $e $a.Lifecycle.LearnSeriesName) $(if ($a.Lifecycle.RetirementDate) { "&middot; retires <strong>$($a.Lifecycle.RetirementDate)</strong>" })$(if ($a.Lifecycle.SourceUrl) { " &middot; <a href='$(& $e $a.Lifecycle.SourceUrl)' target='_blank'>source</a>" })"
                'Modernization' = if ($a.Modernization) { "$(New-Badge $a.Modernization.Status) &middot; $(& $e $a.Modernization.Reason)" } else { "<span class='muted'>Not evaluated</span>" }
                'Action' = "$(New-Badge $a.Action) &middot; next step: <strong>$(& $e $a.NextStep)</strong> &middot; $(New-Badge $a.Wave)"
                'Recommended' = if ($p) { "<code>$(& $e $p.SkuName)</code> &middot; $(New-Badge $p.CpuVendor) $($p.vCPUs) vCPU &middot; $($p.MemoryGB) GB &middot; score <strong>$($p.Score)</strong> ($(& $e $p.Band))" } else { "<span class='muted'>$(& $e $a.Candidates.NoCandidateReason)</span>" }
                'Alternative' = if ($sc) { "<code>$(& $e $sc.SkuName)</code> (score $($sc.Score)) &middot; $(& $e $a.SecondaryReason)" } else { "<span class='muted'>None in the permitted series</span>" }
                'Newer if converted' = if ($a.Candidates.FutureGeneration) {
                    $fg = @($a.Candidates.FutureGeneration.FailedGates)
                    $docs = @(if ($fg -contains 'Disk Controller') { New-LearnLink 'NvmeConvert' 'SCSI to NVMe conversion' }; if ($fg -contains 'VM Generation') { New-LearnLink 'Gen1TrustedLaunch' 'Gen1 to Trusted launch upgrade' })
                    "<code>$(& $e $a.Candidates.FutureGeneration.SkuName)</code> &middot; requires $(& $e ($fg -join ', ')) conversion$(if ($docs.Count) { " &middot; " + ($docs -join ' &middot; ') })"
                } else { "<span class='muted'>&ndash;</span>" }
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
        $omittedNote = if ($detailOmitted) { "<div class='callout info'>Details are shown for the first $maxDetails VMs in wave order; $detailOmitted more are in <code>detailed-report.md</code>, <code>vm-assessment.csv</code> and <code>assessment.json</code> (raise or disable the limit with <code>-HtmlMaxVmDetails</code>).</div>" } else { '' }
        $detailHtml = if (@($details).Count) { $omittedNote + ($details -join "`n") } else { "<div class='callout ok'>No VMs in this subscription are on sizes with an announced Microsoft retirement date.</div>" }
        $subQuotaRows = @($quotaRows | Where-Object SubscriptionId -eq $g.Name)
        $subQuotaHtml = New-QuotaActionsHtml -Rows $subQuotaRows -HideSubscription
        $modernizationHtml = if ($checkModernization) { New-ModernizationSectionHtml -Assessments $retiring -QuotaRows $subQuotaRows -MaxDetails $maxDetails } else { $null }
        $body = @(
            $staleHtml
            "<section id='overview' class='card'><h2>Overview</h2>$tilesHtml<div class='kpis'>$kp</div><div class='bottom-line'><h3>Bottom line</h3><ul>$bl</ul></div></section>"
            (New-TrackHtml -Tone 'retirement' -Part 'Part 1' -Label 'Required' -Title 'Retirement remediation' -Description "VMs on sizes Microsoft is retiring. Move them to the recommended size before the retirement date.$(if ($includeOptional) { ' Optional-modernization VMs are also listed (-HtmlIncludeOptionalModernization).' })" -Body (@(
                        (New-Section -Id 'vms' -Title 'VMs with Retiring SKUs' -Body ($legend + $table) -Intro $scopeText)
                        (New-Section -Id 'details' -Title 'VMs with Retiring SKUs details' -Body $detailHtml -Intro "Select a VM to see its evidence, recommended size, what changes, and what to validate first. Upgrade steps: $(New-LearnLink 'Resize' 'resize'), $(New-LearnLink 'NvmeConvert' 'SCSI to NVMe'), $(New-LearnLink 'Gen1TrustedLaunch' 'Gen1 to Trusted launch').")
                    ) -join "`n"))
            $(if ($checkModernization) {
                    New-TrackHtml -Tone 'modernization' -Part 'Part 2' -Label 'Optional' -Title 'v6/v7 Modernization' -Description 'Longer-term moves of these VMs to current v6/v7 generations. Plan them when it suits; they do not replace the required retirement moves above.' -Body (
                        New-Section -Id 'modernization' -Title 'v6/v7 Modernization Readiness' -Body $modernizationHtml -Intro 'Direct resize readiness, Gen1/NVMe conversion paths, quota impact, remediation groups and contextual migration guidance for the VMs in Part 1.')
                })
            (New-Section -Id 'quota' -Title 'Quota Actions' -Body $subQuotaHtml -Intro "Quota requests for this subscription only. $quotaIntro")
            $reference
        ) -join "`n"
        $nav = @(@{ Id = 'overview'; Label = 'Overview' }, @{ Id = 'vms'; Label = 'Retiring VMs'; Group = 'Retirement'; Tone = 'retirement' }, @{ Id = 'details'; Label = 'Details'; Group = 'Retirement'; Tone = 'retirement' }) +
            $(if ($checkModernization) { @(@{ Id = 'modernization'; Label = 'v6/v7 readiness'; Group = 'Modernization'; Tone = 'modernization' }) } else { @() }) + @(@{ Id = 'quota'; Label = 'Quota' }) + $refNav
        $metaSub = @("Subscription <strong>$(& $e $g.Name)</strong>", "Tenant <strong>$(& $e $Run.Tenant.Name)</strong>", "As of <strong>$asOf</strong>", 'Read-only')
        if ($dataSource) { $metaSub += "Data <strong>$(& $e $dataSource)</strong>" }
        (New-HtmlPage -Title "VMSKURetirementReport - $name" -Eyebrow 'Subscription assessment' -Heading $name -Meta $metaSub -Body $body -Css $css -BackLink $indexName -Nav $nav) | Out-File (Join-Path $OutDir (& $subFile $g.Name $name)) -Encoding utf8
    }
}

Export-ModuleMember -Function Export-AssessmentData, Export-ExecutiveSummaryMarkdown, Export-DetailedReportMarkdown, Export-HtmlReports, Format-MdTable, ConvertTo-SafeCsvValue, ConvertTo-MarkdownText
