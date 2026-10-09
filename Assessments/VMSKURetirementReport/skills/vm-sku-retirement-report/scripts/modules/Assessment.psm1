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
        $lc | Add-Member -NotePropertyName LifecycleStage -NotePropertyValue 'Unknown' -Force
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
        # Each VM gets its own container: quota resolution changes Primary/Secondary per VM, and identical VMs share the
        # cached evaluation (the candidate objects themselves are read-only after selection).
        $cand = $CandidateCache[$sig].PSObject.Copy()
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
        RetirementQuota = $null; ModernizationQuota = $null; Strategy = $null
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
    .PARAMETER SafetyPct
        Accepted for compatibility; the choice depends only on whether the steady-state demand fits the current limit.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Usage', Justification = 'Read inside the quota status script block.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SafetyPct', Justification = 'Kept for backward compatibility of callers.')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Assessments,
        [Parameter(Mandatory)][hashtable]$Usage,
        [double]$SafetyPct = 20
    )
    $active = @($Assessments | Where-Object { $_.Candidates -and $_.Candidates.Primary -and $_.Action -ne 'No Action Required' })

    # Steady-state demand is aggregated once and then updated incrementally per decision, using the same rules and status
    # precedence as Measure-QuotaImpact (family: allocated same-family move adds the vCPU delta, otherwise the target;
    # regional: allocated adds the delta, deallocated the target). This keeps the choice linear in the number of VMs.
    $familyDemand = @{}; $regionalDemand = @{}
    $demandOf = {
        param($Assessment, $Target)
        $pair = "$($Assessment.Vm.SubscriptionId)|$($Assessment.Vm.Region)".ToLowerInvariant()
        $family = if ($Target.Family) { "$($Target.Family)".ToLowerInvariant() } else { '' }
        $vcpu = [int]$Target.vCPUs
        $delta = [math]::Max(0, $vcpu - [int]$Assessment.Current.vCPUs)
        $sameFamily = $Assessment.Current.Family -and $Target.Family -and $Assessment.Current.Family -ieq $Target.Family
        [pscustomobject]@{
            Pair = $pair; Family = $family; FamilyKey = "$pair|$family"
            FamilyVcpu = if ($Assessment.Vm.IsAllocated -and $sameFamily) { $delta } else { $vcpu }
            RegionalVcpu = if ($Assessment.Vm.IsAllocated) { $delta } else { $vcpu }
        }
    }
    $apply = {
        param($Demand, [int]$Sign)
        $familyDemand[$Demand.FamilyKey] = [int]$familyDemand[$Demand.FamilyKey] + $Sign * $Demand.FamilyVcpu
        $regionalDemand[$Demand.Pair] = [int]$regionalDemand[$Demand.Pair] + $Sign * $Demand.RegionalVcpu
    }
    $statusOf = {
        param($Demand)
        $pairUsage = $Usage[$Demand.Pair]
        $family = if (-not $Demand.Family) { 'Manual Validation Required' }
        elseif (-not $pairUsage) { 'Quota Information Unavailable' }
        elseif (-not $pairUsage.ContainsKey($Demand.Family)) { 'Manual Validation Required' }
        else { $q = $pairUsage[$Demand.Family]; if ($q.Used + $familyDemand[$Demand.FamilyKey] -gt $q.Limit) { 'Quota Increase Required' } else { 'Quota OK' } }
        $regional = if ($pairUsage -and $pairUsage.ContainsKey('cores')) {
            $q = $pairUsage['cores']; if ($q.Used + $regionalDemand[$Demand.Pair] -gt $q.Limit) { 'Quota Increase Required' } else { 'Quota OK' }
        }
        else { 'Quota Information Unavailable' }
        Get-CombinedQuotaStatus @($family, $regional)
    }
    foreach ($x in $active) { & $apply (& $demandOf $x $x.Candidates.Primary) 1 }

    foreach ($a in @($active | Where-Object { $_.Modernization -and $_.Modernization.Candidate } | Sort-Object { $_.Vm.Id })) {
        $modern = @($a.Candidates.Candidates | Where-Object {
                $_.ModernizationEligible -and -not $_.Rejected -and $_.VendorPreserved -and $_.Availability -eq 'Available'
            } | Sort-Object @{ e = 'Generation'; Descending = $true }, @{ e = 'Score'; Descending = $true }, FeatureDistance, Closeness)
        $existing = $a.Candidates.Modernization.ExistingRecommendation
        $options = @($modern)
        if ($existing -and $existing.SkuName -notin @($options | ForEach-Object SkuName)) { $options += $existing }
        if ($options.Count -eq 0) { continue }

        $original = $a.Candidates.Primary
        & $apply (& $demandOf $a $original) -1
        $selected = $null
        $selectedQuotaVerified = $false
        $blocked = New-Object System.Collections.Generic.List[object]
        foreach ($option in $options) {
            $d = & $demandOf $a $option
            & $apply $d 1
            $status = & $statusOf $d
            & $apply $d -1
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
        & $apply (& $demandOf $a $(if ($selected) { $selected } else { $original })) 1

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
    .PARAMETER QuotaResult
        Quota result for Candidates.Primary; drives QuotaStatus, Readiness and NextStep.
    .PARAMETER RetirementQuotaResult
        Quota result for the retirement target (Retirement scope).
    .PARAMETER ModernizationQuotaResult
        Quota result for the strategic v6/v7 target (Modernization scope, with steady-state and peak demand).
    #>
    param([Parameter(Mandatory)]$Assessment, $QuotaResult, $RetirementQuotaResult, $ModernizationQuotaResult, [hashtable]$Usage, [ValidateRange(12, 120)][int]$HorizonMonths = 36)
    $a = $Assessment; $vm = $a.Vm; $c = $a.Candidates
    $a.RetirementQuota = $RetirementQuotaResult; $a.ModernizationQuota = $ModernizationQuotaResult
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
    $a.Strategy = Get-TargetStrategy -Assessment $a
    return $a
}

$script:Gen1UpgradeUnsupportedOs = '(?i)(windows ?server[^0-9]*2016|/2016-|\bdebian\b|cbl-?mariner|azure[ -]?linux)'

function Get-ModernizationTargetInfo {
    <#
    .SYNOPSIS
        Strategic v6/v7 target of one assessment and the conversion work it implies. Independent of quota results, so
        it can build the Modernization quota scope and the final target strategy. Returns $null target unless
        -CheckModernization was used.
    #>
    param([Parameter(Mandatory)]$Assessment)
    $a = $Assessment; $c = $a.Candidates; $m = $a.Modernization
    $enabled = [bool]($m -and $m.Enabled)
    $alreadyModern = [bool]($m -and $m.Status -eq 'Already on modern generation')
    $target = $null; $source = $null
    if ($enabled -and -not $alreadyModern -and $c) {
        $blocked = @(if ($m.PSObject.Properties.Name -contains 'QuotaBlockedAlternatives') { $m.QuotaBlockedAlternatives | Where-Object { $_ -and $_.Candidate } })
        if ($m.Candidate) { $target = $m.Candidate; $source = 'Selected' }
        elseif ($c.Primary -and $c.Primary.Generation -ge 6) { $target = $c.Primary; $source = 'Primary' }
        elseif ($blocked.Count -gt 0) { $target = $blocked[0].Candidate; $source = 'QuotaBlocked' }
        elseif ($c.FutureGeneration -and $c.FutureGeneration.Generation -ge 6) { $target = $c.FutureGeneration; $source = 'Convertible' }
    }
    # Conversion flags come from the selected target only; a target that passed its gates needs no conversion.
    $failed = @(if ($target -and $source -eq 'Convertible') { $target.FailedGates })
    $requiresGen = $failed -contains 'VM Generation'
    $requiresNvme = $failed -contains 'Disk Controller'
    $osEvidence = (@($a.Vm.OsName, $a.Vm.OsVersion, $a.Vm.ImageReference) | Where-Object { $_ }) -join ' '
    $redeploy = $false; $redeployReason = $null
    if ($requiresGen -and $osEvidence -match $script:Gen1UpgradeUnsupportedOs) {
        $redeploy = $true
        $redeployReason = "Gen1 to Trusted launch upgrade is not supported for this guest OS ($osEvidence); deploy a Gen2 VM and migrate the workload"
    }
    [pscustomobject]@{
        Enabled = $enabled; AlreadyModern = $alreadyModern; Target = $target; Source = $source
        RequiresGenerationChange = $requiresGen; RequiresNvmeConversion = $requiresNvme
        RedeployReview = $redeploy; RedeployReason = $redeployReason; GuestOsReported = [bool]$osEvidence
        MigrationQuotaModel = if (-not $target) { $null } elseif ($requiresGen -or $redeploy) { 'SideBySide' } else { 'InPlace' }
    }
}

function Get-TargetStrategy {
    <#
    .SYNOPSIS
        Single source of truth for the retirement target, the strategic modernization target, the migration path,
        complexity, modernization readiness and modernization validation items. Output only renders this object.
    #>
    param([Parameter(Mandatory)]$Assessment)
    $a = $Assessment; $c = $a.Candidates
    $p = if ($c) { $c.Primary } else { $null }
    $info = Get-ModernizationTargetInfo -Assessment $a
    $retirementScope = $a.AffectedByRetirement -in 'Yes', 'Unknown'

    $retTarget = $null
    if ($retirementScope -and $c) {
        $retTarget = if ($c.Modernization -and $c.Modernization.ExistingRecommendation) { $c.Modernization.ExistingRecommendation } else { $p }
    }
    $retQuota = if (-not $retTarget) { if ($retirementScope -and $c) { 'Manual Validation Required' } else { $null } }
    elseif ($a.RetirementQuota) { $a.RetirementQuota.Status }
    elseif ($p -and $retTarget.SkuName -eq $p.SkuName) { $a.QuotaStatus }
    else { 'Quota Information Unavailable' }

    $t = $info.Target
    $modernSku = if ($t) { $t.SkuName } elseif ($info.AlreadyModern) { $a.Vm.SkuName } else { $null }
    $modernGen = if ($t) { $t.Generation } elseif ($info.AlreadyModern) { $a.Current.NameInfo.Version } else { $null }
    $modernQuota = $null; $modernPeak = $null
    if ($t) {
        if ($a.ModernizationQuota) { $modernQuota = $a.ModernizationQuota.Status; $modernPeak = $a.ModernizationQuota.PeakStatus }
        elseif ($p -and $t.SkuName -eq $p.SkuName) { $modernQuota = $a.QuotaStatus; $modernPeak = $a.QuotaStatus }
        else { $modernQuota = 'Quota Information Unavailable'; $modernPeak = 'Quota Information Unavailable' }
        if ($info.Source -eq 'QuotaBlocked' -and $modernQuota -ne 'Quota Increase Required') { $modernQuota = 'Quota Increase Required' }
    }

    $items = New-Object System.Collections.Generic.List[string]
    if ($t) {
        if ($info.RequiresNvmeConversion) { $items.Add("Guest NVMe readiness: Validation Required - $($t.SkuName) supports NVMe only; confirm the guest OS has NVMe drivers and discovers OS/data disks over NVMe before conversion (Azure controller support does not prove guest readiness).") }
        if ($info.RequiresGenerationChange) {
            $osNote = if ($info.GuestOsReported) { '' } else { ' Guest OS not reported by Azure; confirm it.' }
            $items.Add("Gen1 to Gen2: Validation Required - Microsoft supports Gen1 to Gen2 only through the Trusted launch upgrade (supported OS and size; not Windows Server 2016, Debian or Azure Linux). Validate MBR to GPT conversion, boot and rollback.$osNote")
        }
        if ($info.RedeployReview) { $items.Add("Redeploy: Validation Required - $($info.RedeployReason).") }
        if ($a.Vm.AcceleratedNetworking -and $t.Generation -ge 6) { $items.Add("MANA networking: Validation Required - $($t.SkuName) uses the Microsoft Azure Network Adapter; confirm guest MANA driver support (Accelerated Networking on the current VM does not prove MANA readiness).") }
        $targetNoTemp = $null -ne $t.TempDiskGB -and $t.TempDiskGB -eq 0
        if ($a.Current.HasTempDisk -and $targetNoTemp) { $items.Add("Temporary disk: Unknown / workload validation required - current size has a $($a.Current.TempDiskGB) GB temp disk and $($t.SkuName) has none; confirm the workload does not depend on it (pagefile, tempdb, caches, scripts).") }
        elseif ($a.Current.HasTempDisk -and $t.Generation -ge 6) { $items.Add("Temporary disk: Unknown / workload validation required - $($t.SkuName) may present local temp storage as NVMe; validate drive letters, mount points, pagefile and scripts that use the temp drive.") }
    }

    $quotaIncrease = $modernQuota -eq 'Quota Increase Required'
    $tempRemoved = $t -and $a.Current.HasTempDisk -and $null -ne $t.TempDiskGB -and $t.TempDiskGB -eq 0
    $prereqs = @(@($info.RequiresNvmeConversion, $quotaIncrease, [bool]$tempRemoved) | Where-Object { $_ })

    $path = if (-not $info.Enabled) { $null }
    elseif ($info.AlreadyModern) { 'Already Modern' }
    elseif (-not $t) { 'No Validated Modern Target' }
    elseif ($info.RedeployReview) { 'Redeploy / Rebuild Review' }
    elseif ($info.RequiresGenerationChange -and $info.RequiresNvmeConversion) { 'Gen1 + NVMe + Resize' }
    elseif ($info.RequiresGenerationChange) { 'Gen1 Modernization + Resize' }
    elseif ($info.RequiresNvmeConversion) { 'SCSI to NVMe + Resize' }
    else { 'Direct Resize' }

    $complexity = if (-not $info.Enabled) { $null }
    elseif ($info.AlreadyModern) { 'None' }
    elseif (-not $t) { 'Unknown' }
    elseif ($info.RedeployReview -or $info.RequiresGenerationChange -or @($prereqs).Count -ge 2) { 'High' }
    elseif (@($prereqs).Count -eq 1) { 'Medium' }
    else { 'Low' }

    $status = if (-not $info.Enabled) { $null }
    elseif ($info.AlreadyModern) { 'Current' }
    elseif (-not $t) { 'Manual Review' }
    elseif ($info.RedeployReview) { 'Redeploy Review' }
    elseif ($quotaIncrease) { 'Quota Increase' }
    elseif ($info.RequiresGenerationChange -or $info.RequiresNvmeConversion) { 'Convertible' }
    elseif ($modernQuota -in 'Quota Information Unavailable', 'Manual Validation Required') { 'Manual Review' }
    elseif ($p -and $t.SkuName -eq $p.SkuName -and $a.Readiness -in 'SKU Restricted', 'Regional Limitation', 'Manual Review Required') { 'Manual Review' }
    else { 'Ready' }

    $retSku = if ($retTarget) { $retTarget.SkuName } else { $null }
    $conversion = if ($info.RedeployReview) { ' (redeploy review required)' }
    elseif ($info.RequiresGenerationChange -and $info.RequiresNvmeConversion) { ' (requires Gen1 to Trusted launch upgrade and SCSI to NVMe conversion)' }
    elseif ($info.RequiresGenerationChange) { ' (requires Gen1 to Trusted launch upgrade)' }
    elseif ($info.RequiresNvmeConversion) { ' (requires SCSI to NVMe conversion)' }
    else { '' }
    $prefix = if ($a.AffectedByRetirement -eq 'Unknown') { 'Retirement unconfirmed - validate lifecycle; ' } else { '' }
    $migrationPath = if ($info.AlreadyModern -and -not $retirementScope) { 'No retirement move required; already on modern generation' }
    elseif ($retirementScope -and $retSku) {
        if ($t -and $modernSku -ne $retSku) {
            if ($retTarget.Generation -lt $modernGen) { "${prefix}Retire to $retSku -> modernize to $modernSku$conversion" }
            else { "${prefix}Retire to $retSku; alternative modern target $modernSku$conversion" }
        }
        elseif ($t) { "${prefix}Move directly to $modernSku" }
        elseif ($info.Enabled) { "${prefix}Retire to $retSku; no validated v6/v7 target" }
        else { "${prefix}Retire to $retSku" }
    }
    elseif ($retirementScope -and $c) { "${prefix}No validated retirement target - manual review" }
    elseif ($t) { "Optional modernization to $modernSku$conversion" }
    elseif ($p -and $a.Action -and $a.Action -ne 'No Action Required') { "Optional move to $($p.SkuName)" }
    else { $null }

    [pscustomobject]@{
        RetirementRequired = $a.AffectedByRetirement -eq 'Yes'
        RetirementUnconfirmed = $a.AffectedByRetirement -eq 'Unknown'
        RetirementTarget = $retTarget
        RetirementTargetSku = $retSku
        RetirementTargetGeneration = if ($retTarget) { $retTarget.Generation } else { $null }
        RetirementQuotaStatus = $retQuota
        ModernizationEnabled = $info.Enabled
        AlreadyModern = $info.AlreadyModern
        ModernizationTarget = $t
        ModernizationTargetSku = if ($info.Enabled) { $modernSku } else { $null }
        ModernizationTargetGeneration = if ($info.Enabled) { $modernGen } else { $null }
        ModernizationTargetSource = $info.Source
        RequiresGenerationChange = $info.RequiresGenerationChange
        RequiresNvmeConversion = $info.RequiresNvmeConversion
        RedeployReview = $info.RedeployReview
        RedeployReason = $info.RedeployReason
        MigrationQuotaModel = $info.MigrationQuotaModel
        ModernizationQuotaStatus = $modernQuota
        ModernizationPeakQuotaStatus = $modernPeak
        ModernizationPath = $path
        Complexity = $complexity
        ModernizationReadiness = $status
        ValidationItems = $items.ToArray()
        RecommendedMigrationPath = $migrationPath
    }
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
    $st = if ($A.Strategy) { $A.Strategy } else { Get-TargetStrategy -Assessment $A }
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
        RetirementTargetSku     = $st.RetirementTargetSku
        RetirementTargetGeneration = $st.RetirementTargetGeneration
        RetirementQuotaStatus   = $st.RetirementQuotaStatus
        ModernizationTargetSku  = $st.ModernizationTargetSku
        ModernizationTargetGeneration = $st.ModernizationTargetGeneration
        ModernizationTargetSource = $st.ModernizationTargetSource
        ModernizationPath       = $st.ModernizationPath
        ModernizationComplexity = $st.Complexity
        ModernizationReadiness  = $st.ModernizationReadiness
        ModernizationQuotaStatus = $st.ModernizationQuotaStatus
        ModernizationPeakQuotaStatus = $st.ModernizationPeakQuotaStatus
        MigrationQuotaModel     = $st.MigrationQuotaModel
        RecommendedMigrationPath = $st.RecommendedMigrationPath
        ModernizationValidationItems = (@($st.ValidationItems) -join ' | ')
        LifecycleStage          = Get-LifecycleStage -Lifecycle $A.Lifecycle
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

Export-ModuleMember -Function Test-NeedsCandidates, New-VmAssessment, Update-VmAction, Complete-VmAssessment, Resolve-ModernizationQuotaChoices, Get-ModernizationTargetInfo, Get-TargetStrategy, Get-TimeRemainingText, ConvertTo-AssessmentRow, New-AssessmentSummary
