Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Retirement.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'SkuCatalog.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Candidates.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Scoring.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Quota.psm1') -DisableNameChecking

function Test-NeedsCandidates {
    <# Retirement-affected, unconfirmed, previous-gen and (heuristic) aging VMs get replacement analysis; current-gen VMs do not. #>
    param([Parameter(Mandatory)]$Lifecycle)
    if ($Lifecycle.EvidenceClass -ne 'No Retirement Announced') { return $true }
    $info = Get-SkuNameInfo -SkuName $Lifecycle.SkuName
    return ($info.Parsed -and $info.Version -le 4)
}

function New-VmAssessment {
    <#
    .SYNOPSIS
        First-pass assessment of one VM: lifecycle, current profile, replacement candidates (quota applied later).
    #>
    param(
        [Parameter(Mandatory)]$Vm,
        [Parameter(Mandatory)]$Lifecycle,
        [hashtable]$RegionCatalog,
        $ProcessorCatalog,
        [Parameter(Mandatory)]$RetirementCatalog,
        [Parameter(Mandatory)][hashtable]$LifecycleCache,
        [Parameter(Mandatory)][hashtable]$CandidateCache,
        [Parameter(Mandatory)]$Weights,
        [Parameter(Mandatory)][datetime]$AsOf,
        [string]$SubscriptionName,
        [int]$MaxCandidates = 3,
        [switch]$CheckModernization
    )
    $rec = if ($RegionCatalog) { $RegionCatalog[$Vm.SkuName.ToLowerInvariant()] } else { $null }
    $proc = Get-ProcessorInfo -SkuName $Vm.SkuName -ProcessorCatalog $ProcessorCatalog -SkuRecord $rec
    $current = New-CurrentProfile -SkuName $Vm.SkuName -SkuRecord $rec -ProcessorInfo $proc
    $lc = $Lifecycle
    if ($lc.EvidenceClass -eq 'No Retirement Announced' -and $RegionCatalog -and -not $rec) {
        # Size missing from the regional Resource SKU list for this subscription: may be retired/unlisted - do not guess.
        $lc = $Lifecycle.PSObject.Copy()
        $lc.EvidenceClass = 'Unable to Confirm'; $lc.RetirementStatus = 'Unable to Confirm'; $lc.Urgency = 'Unable to Determine'; $lc.DataQuality = 'Unable to Verify'
        $lc.Notes = @($Lifecycle.Notes) + "Size is not returned by the Resource SKUs API for $($Vm.Region) in this subscription and is not in the Microsoft retirement lists; it may be retired, unlisted or restricted. Manual confirmation required."
    }
    $advisorNotes = @()
    if ($Vm.AdvisorRetirement.Count -gt 0) {
        # Advisor ServiceUpgradeAndRetirement covers many features (extensions, images, VMSS...). Only size/series
        # signals corroborate the lifecycle; others are listed separately so they are not mistaken for SKU retirement.
        $items = @($Vm.AdvisorRetirement | ForEach-Object {
                $txt = (@($_.feature, $_.problem) | Where-Object { $_ }) -join ' - '
                [pscustomobject]@{ Text = $txt; Date = $_.retirementDate; IsSize = [bool]("$($_.feature) $($_.problem)" -match '(?i)\b(vm size|vm sizes|size series|series|sku)\b' -and "$($_.feature) $($_.problem)" -notmatch '(?i)\b(image|scale sets?|extension)\b') }
            } | Where-Object { $_.Text } | Sort-Object Text, Date -Unique)
        foreach ($it in $items) {
            $when = if ($it.Date) { " (retirement $($it.Date))" } else { '' }
            $advisorNotes += if ($it.IsSize) { "Azure Advisor size-retirement signal: $($it.Text)$when. Validate against Microsoft Learn." } else { "Azure Advisor (not VM size): $($it.Text)$when." }
        }
    }
    if ($Vm.DedicatedHostId -or $Vm.DedicatedHostGroupId) {
        $hostEntries = @(Get-NonVmSizeEntries -Catalog $RetirementCatalog | Where-Object Category -eq 'ADH')
        if ($hostEntries.Count -gt 0) {
            $advisorNotes += "VM runs on Azure Dedicated Host. Microsoft lists Dedicated Host SKU retirements ($((@($hostEntries) | ForEach-Object { "$($_.Name): $($_.Status) $($_.PlannedRetirementDate)" }) -join '; ')); verify this host's SKU separately."
        }
    }
    if ($advisorNotes.Count -gt 0) {
        $lc = $lc.PSObject.Copy()
        $lc.Notes = @($lc.Notes) + $advisorNotes
    }

    $cand = $null
    if (((Test-NeedsCandidates -Lifecycle $lc) -or ($CheckModernization -and $current.NameInfo.Version -lt 6)) -and $RegionCatalog) {
        $sig = @($Vm.SubscriptionId, $Vm.Region, $Vm.SkuName, $Vm.Zone, $Vm.HyperVGeneration, $Vm.DiskControllerType, $Vm.UsesPremiumStorage, $Vm.UsesUltraDisk,
            $Vm.AcceleratedNetworking, $Vm.EphemeralOsDisk, $Vm.EphemeralPlacement, $Vm.NicCount, $Vm.DataDiskCount, $Vm.WriteAcceleratorDisks, $Vm.SecurityType,
            $Vm.EncryptionAtHost, [bool]$Vm.DedicatedHostId, [bool]$Vm.ProximityPlacementGroup, [bool]$Vm.AvailabilitySetId, [bool]$Vm.VmssId, $Vm.IsSpot, $Vm.Hibernation, $Vm.AzureDiskEncryption, $lc.EvidenceClass, [bool]$CheckModernization) -join '|'
        if (-not $CandidateCache.ContainsKey($sig)) {
            $CandidateCache[$sig] = Find-ReplacementCandidates -Vm $Vm -Current $current -Lifecycle $lc -RegionCatalog $RegionCatalog -ProcessorCatalog $ProcessorCatalog `
                -RetirementCatalog $RetirementCatalog -LifecycleCache $LifecycleCache -Weights $Weights -AsOf $AsOf -MaxCandidates $MaxCandidates -CheckModernization:$CheckModernization
        }
        $cand = $CandidateCache[$sig]
    }
    $modernization = $null
    if ($CheckModernization) {
        if ($current.NameInfo.Version -ge 6) {
            $modernization = [pscustomobject]@{
                Enabled = $true; CurrentGeneration = $current.NameInfo.Version; RecommendedSku = $Vm.SkuName
                RecommendedGeneration = $current.NameInfo.Version; Availability = if ($current.OfferedInRegion) { 'Available' } else { 'Not Available' }
                Status = 'Already on modern generation'; Reason = "$($Vm.SkuName) is already a v$($current.NameInfo.Version) SKU."; Candidate = $null
            }
        }
        elseif ($cand -and $cand.Modernization) {
            $m = $cand.Modernization
            $selected = $m.Candidate
            $fallback = $m.ExistingRecommendation
            $recommended = if ($selected) { $selected } else { $fallback }
            $modernization = [pscustomobject]@{
                Enabled = $true; CurrentGeneration = $current.NameInfo.Version
                RecommendedSku = if ($recommended) { $recommended.SkuName } else { $null }
                RecommendedGeneration = if ($recommended) { $recommended.Generation } else { $null }
                Availability = if ($selected) { $selected.Availability } elseif ($recommended) { $recommended.Availability } else { 'Not Available' }
                Status = $m.PreliminaryStatus; Reason = $m.Reason; Candidate = $selected
            }
        }
        else {
            $modernization = [pscustomobject]@{
                Enabled = $true; CurrentGeneration = $current.NameInfo.Version; RecommendedSku = $null; RecommendedGeneration = $null
                Availability = 'Not Available'; Status = 'SKU unavailable in region'
                Reason = "SKU capability data is unavailable for $($Vm.Region); v6/v7 modernization could not be evaluated."; Candidate = $null
            }
        }
    }
    $affected = switch ($lc.EvidenceClass) {
        { $_ -in 'Confirmed Retirement', 'Retirement Announced', 'Already Retired' } { 'Yes' }
        'Unable to Confirm' { 'Unknown' }
        default { 'No' }
    }
    [pscustomobject]@{
        Vm = $Vm; SubscriptionName = $SubscriptionName; Lifecycle = $lc; Current = $current; Candidates = $cand; Modernization = $modernization
        AffectedByRetirement = $affected
        Quota = $null; QuotaStatus = $null; Readiness = $null; Confidence = $null; Action = $null; NextStep = $null; Wave = $null
        SecondaryReason = $null; Rightsizing = $null; Pricing = $null; DataQuality = $null; ValidationItems = @()
    }
}

function Update-VmAction {
    <# Sets Action and Wave from lifecycle evidence (independent of quota). Idempotent. #>
    param([Parameter(Mandatory)]$Assessment, [ValidateRange(12, 120)][int]$HorizonMonths = 36)
    $a = $Assessment; $c = $a.Candidates
    $primary = if ($c) { $c.Primary } else { $null }
    $modernOptional = $false
    if ($a.Modernization -and $a.Modernization.Candidate) {
        $modernOptional = $true
    }
    elseif ($a.Lifecycle.EvidenceClass -eq 'No Retirement Announced' -and $primary) {
        $bestGen = $primary.Generation
        if ($c.FutureGeneration -and $c.FutureGeneration.Generation -gt $bestGen) { $bestGen = $c.FutureGeneration.Generation }
        $modernOptional = ($bestGen -ge ($a.Current.NameInfo.Version + 2))
    }
    $a.Action = Get-LifecycleAction -Lifecycle $a.Lifecycle -ModernizationOptional $modernOptional
    $a.Wave = Get-MigrationWave -Lifecycle $a.Lifecycle -Action $a.Action -HorizonMonths $HorizonMonths
    return $a
}

function Resolve-ModernizationQuotaChoices {
    <#
    .SYNOPSIS
        Finalizes opt-in modernization choices in v7, v6, existing-recommendation order using aggregate quota.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Assessments,
        [Parameter(Mandatory)][hashtable]$Usage,
        [double]$SafetyPct = 20
    )
    $active = @($Assessments | Where-Object { $_.Candidates -and $_.Candidates.Primary -and $_.Action -ne 'No Action Required' })
    $toMoves = {
        @($active | ForEach-Object {
                [pscustomobject]@{
                    SubscriptionId = $_.Vm.SubscriptionId; Region = $_.Vm.Region; VmId = $_.Vm.Id
                    CurrentFamily = $_.Current.Family; CurrentVcpu = [int]$_.Current.vCPUs
                    TargetSku = $_.Candidates.Primary.SkuName; TargetFamily = $_.Candidates.Primary.Family
                    TargetVcpu = [int]$_.Candidates.Primary.vCPUs; IsAllocated = $_.Vm.IsAllocated
                }
            })
    }

    foreach ($a in @($active | Where-Object { $_.Modernization -and $_.Modernization.Candidate } | Sort-Object { $_.Vm.Id })) {
        $modern = @($a.Candidates.Candidates | Where-Object {
                $_.ModernizationEligible -and -not $_.Rejected -and $_.VendorPreserved -and $_.Availability -eq 'Available'
            } | Sort-Object @{ e = 'Generation'; Descending = $true }, @{ e = 'Score'; Descending = $true }, FeatureDistance, Closeness)
        $existing = $a.Candidates.Modernization.ExistingRecommendation
        $options = @($modern)
        if ($existing -and $existing.SkuName -notin @($options | ForEach-Object SkuName)) { $options += $existing }
        if ($options.Count -eq 0) { continue }

        $original = $a.Candidates.Primary
        $selected = $null
        $selectedQuotaVerified = $false
        $blocked = New-Object System.Collections.Generic.List[object]
        foreach ($option in $options) {
            $a.Candidates.Primary = $option
            $scenario = Measure-QuotaImpact -Moves @(& $toMoves) -Usage $Usage -SafetyPct $SafetyPct
            $status = if ($scenario.ByVm.ContainsKey($a.Vm.Id)) { $scenario.ByVm[$a.Vm.Id].Status } else { 'Quota Information Unavailable' }
            if ($status -eq 'Quota OK') {
                $selected = $option
                $selectedQuotaVerified = $true
                break
            }
            if ($status -in 'Quota Information Unavailable', 'Manual Validation Required') {
                $selected = $option
                break
            }
            if ($status -eq 'Quota Increase Required' -and $option.ModernizationEligible) {
                $blocked.Add([pscustomobject]@{ Candidate = $option; QuotaStatus = $status })
            }
        }

        if (-not $selected) {
            $a.Candidates.Primary = $original
            $a.Modernization.Status = 'Insufficient quota'
            $a.Modernization.Reason += ' No v7, v6, or existing fallback recommendation has sufficient verified aggregate quota.'
            $a.Modernization | Add-Member -NotePropertyName QuotaBlockedAlternatives -NotePropertyValue $blocked.ToArray() -Force
            continue
        }

        $a.Candidates.Primary = $selected
        if ($selected.ModernizationEligible) {
            $a.Modernization.Candidate = $selected
            $a.Modernization.RecommendedSku = $selected.SkuName
            $a.Modernization.RecommendedGeneration = $selected.Generation
            $a.Modernization.Availability = $selected.Availability
            $a.Modernization.Status = "Modernize to v$($selected.Generation)"
            $quotaReason = if ($selectedQuotaVerified) { 'with sufficient aggregate quota' } else { 'whose quota requires manual validation' }
            $a.Modernization.Reason = "$($selected.SkuName) is the newest suitable modernization option $quotaReason that preserves $($a.Current.Vendor) / $($a.Current.Architecture) and passes the workload capability gates."
        }
        else {
            $a.Modernization.Candidate = $null
            $a.Modernization.RecommendedSku = $selected.SkuName
            $a.Modernization.RecommendedGeneration = $selected.Generation
            $a.Modernization.Availability = $selected.Availability
            $a.Modernization.Status = 'Insufficient quota'
            $a.Modernization.Reason = "Suitable v7/v6 options lack sufficient aggregate quota. Retaining existing recommendation $($selected.SkuName)."
        }
        if ($blocked.Count -gt 0) {
            $a.Modernization | Add-Member -NotePropertyName QuotaBlockedAlternatives -NotePropertyValue $blocked.ToArray() -Force
            $newestBlocked = $blocked[0].Candidate
            if ($newestBlocked.SkuName -ne $selected.SkuName) {
                $a.Candidates.Secondary = $newestBlocked
                $a.SecondaryReason = "Newer modernization option blocked by aggregate quota ($($blocked[0].QuotaStatus))"
            }
        }
    }
    return $Assessments
}

function Complete-VmAssessment {
    <#
    .SYNOPSIS
        Second pass: applies aggregated quota results and derives readiness, confidence, action, next step and wave.
    #>
    param([Parameter(Mandatory)]$Assessment, $QuotaResult, [hashtable]$Usage, [ValidateRange(12, 120)][int]$HorizonMonths = 36)
    $a = $Assessment; $vm = $a.Vm; $c = $a.Candidates
    $primary = if ($c) { $c.Primary } else { $null }
    $secondary = if ($c) { $c.Secondary } else { $null }

    $quotaStatus = if ($a.Modernization -and $a.Modernization.Status -eq 'Already on modern generation' -and -not $primary) { 'Not Applicable' }
    elseif (-not $primary) { if ($c) { 'Manual Validation Required' } else { $null } }
    elseif ($QuotaResult) { $QuotaResult.Status } else { 'Quota Information Unavailable' }
    $a.Quota = $QuotaResult; $a.QuotaStatus = $quotaStatus

    if ($a.Modernization -and $a.Modernization.Candidate) {
        if ($quotaStatus -eq 'Quota Increase Required') {
            $a.Modernization.Status = 'Insufficient quota'
            $a.Modernization.Reason += ' The target family or regional vCPU quota is insufficient; request the reported increase before migration.'
        }

        elseif ($quotaStatus -in 'Quota Information Unavailable', 'Manual Validation Required') {
            $a.Modernization.Reason += ' Subscription quota could not be fully verified and requires manual validation.'
        }
    }

    [void](Update-VmAction -Assessment $a -HorizonMonths $HorizonMonths)

    if (-not $c) {
        $a.Readiness = if ($a.Action -eq 'No Action Required') { 'Not Applicable' } else { 'Manual Review Required' }
        $a.NextStep = if ($a.Action -eq 'No Action Required') { 'None' } else { 'Manual Review Required' }
        $a.Confidence = [pscustomobject]@{ Level = if ($a.Action -eq 'No Action Required') { 'N/A' } else { 'LOW' }; LowReasons = @(); ValidationItems = @() }
    }
    else {
        $reviews = @(if ($primary) { $primary.Gates | Where-Object { $_.Result -in 'Review', 'Unknown' -and $_.Gate -notin 'CPU Vendor', 'Nested Virtualization' } | ForEach-Object { "$($_.Gate): $($_.Detail)" } })
        if ($primary -and $primary.Differences) {
            $reduced = @($primary.Differences | Where-Object { $_.Assessment -eq 'Reduced' -and $_.Attribute -in 'Uncached Disk IOPS', 'Uncached Disk MBps' } | ForEach-Object { "$($_.Attribute) $($_.Current) -> $($_.Target)" })
            if ($reduced.Count -gt 0) {
                $reviews += "Capability reduced ($($reduced -join ', ')); validate against observed disk throughput or use the capability-preserving alternative"
            }
        }
        $manual = $c.VendorChangeRequired -or ($primary -and @($primary.ReviewGates | Where-Object { $_ -in 'Dedicated Host', 'Confidential Computing', 'GPU' }).Count -gt 0) -or ($a.Lifecycle.EvidenceClass -eq 'Unable to Confirm')
        $capSensitive = [bool]($vm.ProximityPlacementGroup -or $vm.DedicatedHostId -or $vm.CapacityReservationGroup -or $vm.UsesUltraDisk -or ($a.Current.GPUs -gt 0) -or ($primary -and $primary.vCPUs -ge 64))
        $a.Readiness = Get-DeploymentReadiness -Primary $primary -QuotaStatus $quotaStatus -ManualReview $manual -CapacitySensitive $capSensitive
        $items = @($reviews)
        if (-not $a.Current.CapsKnown) { $items += 'Current size capabilities not available from Resource SKUs API' }
        $a.Confidence = Get-MigrationConfidence -Lifecycle $a.Lifecycle -Primary $primary -Current $a.Current -VendorChangeRequired $c.VendorChangeRequired -QuotaStatus $quotaStatus -ValidationItems $items
        $a.ValidationItems = @($a.Confidence.ValidationItems)
        $a.NextStep = switch ($a.Readiness) {
            'Ready' { if ($a.Action -eq 'No Action Required') { 'None' } else { 'Proceed with Resize (change window)' } }
            'Quota Increase Required' { 'Request Quota Increase' }
            'SKU Restricted' { 'Validate Regional Capacity' }
            'Regional Limitation' { 'Validate Regional Capacity' }
            'Capacity Validation Required' { 'Validate Regional Capacity' }
            default { 'Manual Review Required' }
        }
        if ($secondary) {
            $key = "$($vm.SubscriptionId)|$($vm.Region)".ToLowerInvariant()
            $secFits = Test-FamilyHeadroom -Usage $Usage -Key $key -Family $secondary.Family -RequiredVcpu $secondary.vCPUs
            $why = New-Object System.Collections.Generic.List[string]
            if ($quotaStatus -eq 'Quota Increase Required' -and $secFits -and $secondary.Family -ne $primary.Family) { $why.Add("Quota: $($secondary.Family) has headroom while the primary family needs an increase") }
            if ($secondary.Variant -eq 'Capability-preserving') { $why.Add("Preserves disk throughput caps of the current size ($($secondary.vCPUs) vCPU - validate licensing/cost impact)") }
            if ($secondary.CpuVendor -ne $primary.CpuVendor) { $why.Add("CPU vendor alternative ($($secondary.CpuVendor))") }
            if ($secondary.Family -ne $primary.Family -and -not ($why | Where-Object { $_ -like 'Quota:*' })) { $why.Add("Different quota family ($($secondary.Family)) - fallback if primary quota, capacity or regional availability is constrained") }
            if (($secondary.TempDiskGB -gt 0) -ne ($primary.TempDiskGB -gt 0)) { $why.Add($(if ($secondary.TempDiskGB -gt 0) { "Feature: includes $($secondary.TempDiskGB) GB temp disk" } else { 'Feature: no temp disk (lower cost where local scratch is unused)' })) }
            if ($why.Count -eq 0) { $why.Add('Close alternative in the same family (capacity or licensing fallback)') }
            $a.SecondaryReason = $why -join '; '
        }
    }

    $a.DataQuality = [pscustomobject]@{
        RetirementDate        = if ($a.Lifecycle.RetirementDate) { $a.Lifecycle.DataQuality } elseif ($a.Lifecycle.EvidenceClass -eq 'Unable to Confirm') { 'Unable to Verify' } else { "$($a.Lifecycle.DataQuality) (no date)" }
        CpuVendor             = $a.Current.VendorQuality
        CpuArchitecture       = $a.Current.ArchitectureQuality
        CurrentSkuCapabilities = if ($a.Current.CapsKnown) { 'Verified' } else { 'Unable to Verify' }
        RegionalAvailability  = if ($primary) { 'Verified' } elseif ($c) { 'Partially Verified' } else { 'Not Evaluated' }
        Quota                 = if ($a.Quota) { $a.Quota.DataQuality } elseif ($c) { 'Unable to Verify' } else { 'Not Evaluated' }
        PhysicalCapacity      = 'Unable to Verify'
        NestedVirtualization  = 'Unable to Verify'
        TempDiskUsage         = 'Unable to Verify'
    }
    return $a
}

function Get-TimeRemainingText {
    param($Lifecycle)
    if ($Lifecycle.EvidenceClass -eq 'Already Retired') { return 'Retired' }
    if ($null -ne $Lifecycle.MonthsRemaining) { return "$($Lifecycle.MonthsRemaining) months" }
    return '-'
}

function ConvertTo-AssessmentRow {
    <# Flat row for CSV / Power BI (one row per VM). #>
    param([Parameter(Mandatory)]$A)
    $vm = $A.Vm; $p = if ($A.Candidates) { $A.Candidates.Primary } else { $null }
    $s = if ($A.Candidates) { $A.Candidates.Secondary } else { $null }
    $t = if ($A.Candidates) { $A.Candidates.Third } else { $null }
    $f = if ($A.Candidates) { $A.Candidates.FutureGeneration } else { $null }
    $modern = $A.Modernization
    $recommendedSku = if ($p) { $p.SkuName } elseif ($modern -and $modern.Status -eq 'Already on modern generation') { $vm.SkuName } else { $null }
    $recommendedGeneration = if ($p) { $p.Generation } elseif ($modern -and $modern.Status -eq 'Already on modern generation') { $A.Current.NameInfo.Version } else { $null }
    $diffs = if ($p -and $p.Differences) { (@($p.Differences | Where-Object { $_.Assessment -in 'Changed', 'Reduced', 'Improved' }) | ForEach-Object { "$($_.Attribute): $($_.Current) -> $($_.Target)" }) -join '; ' } else { '' }
    [pscustomobject][ordered]@{
        Subscription            = $A.SubscriptionName
        SubscriptionId          = $vm.SubscriptionId
        ResourceGroup           = $vm.ResourceGroup
        VM                      = $vm.Name
        VmResourceId            = $vm.Id
        Region                  = $vm.Region
        Zone                    = $vm.Zone
        PowerState              = $vm.PowerState
        OsType                  = $vm.OsType
        HyperVGeneration        = $vm.HyperVGeneration
        CurrentSku              = $vm.SkuName
        CurrentSkuGeneration    = $A.Current.NameInfo.Version
        VmFamily                = $A.Current.Family
        CpuVendor               = $A.Current.Vendor
        CpuArchitecture         = $A.Current.Architecture
        vCPU                    = $A.Current.vCPUs
        MemoryGB                = $A.Current.MemoryGB
        AffectedByRetirement    = $A.AffectedByRetirement
        EvidenceClass           = $A.Lifecycle.EvidenceClass
        RetirementStatus        = $A.Lifecycle.RetirementStatus
        RetirementDate          = $A.Lifecycle.RetirementDate
        TimeRemaining           = Get-TimeRemainingText $A.Lifecycle
        Urgency                 = $A.Lifecycle.Urgency
        RecommendedSku          = $recommendedSku
        RecommendedSkuGeneration = $recommendedGeneration
        TargetCpuVendor         = if ($p) { $p.CpuVendor } elseif ($modern -and $modern.Status -eq 'Already on modern generation') { $A.Current.Vendor } else { $null }
        TargetCpuArchitecture   = if ($p) { $p.CpuArchitecture } elseif ($modern -and $modern.Status -eq 'Already on modern generation') { $A.Current.Architecture } else { $null }
        TargetvCPU              = if ($p) { $p.vCPUs } else { $null }
        TargetMemoryGB          = if ($p) { $p.MemoryGB } else { $null }
        CompatibilityScore      = if ($p) { $p.Score } else { $null }
        ScoreBand               = if ($p) { $p.Band } else { $null }
        CpuVendorPreserved      = if ($p) { $p.VendorPreserved } else { $null }
        CpuVendorChangeRequired = if ($A.Candidates) { $A.Candidates.VendorChangeRequired } else { $null }
        RegionAvailable         = if ($p) { $p.Availability } elseif ($A.Candidates) { 'Not Available' } else { $null }
        CurrentVcpu             = $A.Current.vCPUs
        CurrentMemoryGB         = $A.Current.MemoryGB
        RecommendedVcpu         = if ($p) { $p.vCPUs } elseif ($modern -and $modern.Status -eq 'Already on modern generation') { $A.Current.vCPUs } else { $null }
        RecommendedMemoryGB     = if ($p) { $p.MemoryGB } elseif ($modern -and $modern.Status -eq 'Already on modern generation') { $A.Current.MemoryGB } else { $null }
        SkuRegionalAvailability = if ($modern) { $modern.Availability } elseif ($p) { $p.Availability } else { $null }
        QuotaStatus             = $A.QuotaStatus
        ModernizationStatus     = if ($modern) { $modern.Status } else { 'Not Evaluated' }
        RecommendationReason    = if ($modern) { $modern.Reason } elseif ($A.Candidates) { $A.Candidates.NoCandidateReason } else { $null }
        QuotaFamily             = if ($A.Quota) { $A.Quota.Family.QuotaDisplayName } else { $null }
        QuotaMinIncreaseFamily  = if ($A.Quota) { $A.Quota.Family.MinimumIncrease } else { $null }
        QuotaMinIncreaseRegional = if ($A.Quota) { $A.Quota.Regional.MinimumIncrease } else { $null }
        DeploymentReadiness     = $A.Readiness
        Confidence              = $A.Confidence.Level
        Action                  = $A.Action
        NextStep                = $A.NextStep
        Wave                    = $A.Wave
        AlternativeSku          = if ($s) { $s.SkuName } else { $null }
        AlternativeScore        = if ($s) { $s.Score } else { $null }
        AlternativeReason       = $A.SecondaryReason
        ThirdCandidateSku       = if ($t) { $t.SkuName } else { $null }
        NewerGenerationIfConverted = if ($f) { "$($f.SkuName) (requires: $($f.FailedGates -join ', '))" } else { $null }
        NoCandidateReason       = if ($A.Candidates) { $A.Candidates.NoCandidateReason } else { $null }
        VendorChangeReason      = if ($A.Candidates) { $A.Candidates.VendorChangeReason } else { $null }
        MaterialDifferences     = $diffs
        ValidationItems         = ($A.ValidationItems -join ' | ')
        RightsizingStatus       = if ($A.Rightsizing) { $A.Rightsizing.Status } else { $null }
        RightsizingSuggestedSku = if ($A.Rightsizing) { $A.Rightsizing.SuggestedSku } else { $null }
        CurrentMonthlyUSD       = if ($A.Pricing) { $A.Pricing.CurrentMonthly } else { $null }
        TargetMonthlyUSD        = if ($A.Pricing) { $A.Pricing.TargetMonthly } else { $null }
        MicrosoftSource         = $A.Lifecycle.SourceUrl
        AnnouncementUrl         = $A.Lifecycle.AnnouncementUrl
        MigrationGuideUrl       = $A.Lifecycle.MigrationGuideUrl
        DQ_RetirementDate       = $A.DataQuality.RetirementDate
        DQ_CpuVendor            = $A.DataQuality.CpuVendor
        DQ_RegionalAvailability = $A.DataQuality.RegionalAvailability
        DQ_Quota                = $A.DataQuality.Quota
        DQ_PhysicalCapacity     = $A.DataQuality.PhysicalCapacity
        LifecycleNotes          = ($A.Lifecycle.Notes -join ' | ')
    }
}

function New-AssessmentSummary {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Assessments, [int]$SubscriptionsScanned)
    $rows = @($Assessments)
    $cnt = { param($pred) @($rows | Where-Object $pred).Count }
    $affected = @($rows | Where-Object { $_.AffectedByRetirement -eq 'Yes' })
    $grp = {
        param($sel, [object[]]$set)
        @($set | Group-Object $sel | Sort-Object Count -Descending | ForEach-Object { [pscustomobject]@{ Key = if ($_.Name) { $_.Name } else { '(none)' }; Count = $_.Count } })
    }
    $withRec = @($rows | Where-Object { $_.Action -ne 'No Action Required' })
    [pscustomobject][ordered]@{
        TotalSubscriptionsScanned   = $SubscriptionsScanned
        TotalVmsScanned             = $rows.Count
        AffectedVms                 = $affected.Count
        AlreadyRetired              = & $cnt { $_.Lifecycle.EvidenceClass -eq 'Already Retired' }
        RetirementWithin12Months    = & $cnt { $_.Lifecycle.Urgency -eq 'Less than 12 Months' }
        RetirementWithin24Months    = & $cnt { $_.Lifecycle.Urgency -eq '12-24 Months' }
        RetirementWithin36Months    = & $cnt { $_.Lifecycle.Urgency -eq '24-36 Months' }
        RetirementBeyond36Months    = & $cnt { $_.Lifecycle.Urgency -eq 'More than 36 Months' }
        ModernizationRecommended    = & $cnt { $_.Lifecycle.EvidenceClass -eq 'Modernization Recommended' }
        ModernizationOptional       = & $cnt { $_.Action -eq 'Modernization Optional' }
        ModernizeToV7               = & $cnt { $_.Modernization -and $_.Modernization.Status -eq 'Modernize to v7' }
        ModernizeToV6               = & $cnt { $_.Modernization -and $_.Modernization.Status -eq 'Modernize to v6' }
        AlreadyOnModernGeneration   = & $cnt { $_.Modernization -and $_.Modernization.Status -eq 'Already on modern generation' }
        NoRetirementAnnounced       = & $cnt { $_.Lifecycle.EvidenceClass -eq 'No Retirement Announced' }
        UnableToDetermine           = & $cnt { $_.Lifecycle.EvidenceClass -eq 'Unable to Confirm' -or $_.Lifecycle.Urgency -eq 'Unable to Determine' }
        VmsRequiringQuotaIncrease   = & $cnt { $_.QuotaStatus -eq 'Quota Increase Required' }
        VmsWithRegionalRestrictions = & $cnt { $_.Readiness -in 'SKU Restricted', 'Regional Limitation' }
        VmsRequiringCpuVendorChange = & $cnt { $_.Candidates -and $_.Candidates.VendorChangeRequired }
        VmsRequiringManualReview    = & $cnt { $_.Readiness -eq 'Manual Review Required' }
        HighConfidence              = & $cnt { $_.Confidence.Level -eq 'HIGH' }
        MediumConfidence            = & $cnt { $_.Confidence.Level -eq 'MEDIUM' }
        LowConfidence               = & $cnt { $_.Confidence.Level -eq 'LOW' }
        ByEvidenceClass             = & $grp { $_.Lifecycle.EvidenceClass } $rows
        ByWave                      = & $grp { $_.Wave } $rows
        BySubscription              = & $grp { $_.SubscriptionName } $withRec
        ByRegion                    = & $grp { $_.Vm.Region } $withRec
        ByCurrentSku                = & $grp { $_.Vm.SkuName } $withRec
        ByCurrentSkuFamily          = & $grp { if ($_.Current.Family) { $_.Current.Family } else { $_.Current.NameInfo.SeriesKey } } $withRec
        ByRecommendedSku            = & $grp { if ($_.Candidates -and $_.Candidates.Primary) { $_.Candidates.Primary.SkuName } else { '(none)' } } $withRec
        ByRecommendedSkuFamily      = & $grp { if ($_.Candidates -and $_.Candidates.Primary) { $_.Candidates.Primary.Family } else { '(none)' } } $withRec
        ByCpuVendor                 = & $grp { $_.Current.Vendor } $withRec
        ByRetirementDate            = & $grp { $_.Lifecycle.RetirementDate } $affected
        ByMigrationPriority         = & $grp { $_.Action } $rows
        ByDeploymentReadiness       = & $grp { $_.Readiness } $withRec
    }
}

Export-ModuleMember -Function Test-NeedsCandidates, New-VmAssessment, Update-VmAction, Complete-VmAssessment, Resolve-ModernizationQuotaChoices, Get-TimeRemainingText, ConvertTo-AssessmentRow, New-AssessmentSummary
