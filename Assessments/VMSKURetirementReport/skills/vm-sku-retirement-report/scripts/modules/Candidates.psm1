Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Retirement.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'SkuCatalog.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Scoring.psm1') -DisableNameChecking

function New-CurrentProfile {
    <#
    .SYNOPSIS
        Builds the current-size profile from Resource SKU data (authoritative) or, when the size is no longer offered,
        from the size name (partial).
    #>
    param([Parameter(Mandatory)][string]$SkuName, $SkuRecord, [Parameter(Mandatory)]$ProcessorInfo)
    $info = Get-SkuNameInfo -SkuName $SkuName
    $known = [bool]$SkuRecord
    $vcpu = if ($known -and $SkuRecord.vCPUsAvailable) { $SkuRecord.vCPUsAvailable } elseif ($info.Constrained) { $info.Constrained } elseif ($info.Parsed) { $info.Size } else { $null }
    [pscustomobject]@{
        SkuName               = $SkuName
        NameInfo              = $info
        CapsKnown             = $known
        CapsSource            = if ($known) { 'Azure Resource SKUs API' } else { 'SKU name only (size not offered in region / retired)' }
        Family                = if ($known) { $SkuRecord.Family } else { $null }
        vCPUs                 = $vcpu
        vCPUsTotal            = if ($known) { $SkuRecord.vCPUs } else { $vcpu }
        MemoryGB              = if ($known) { $SkuRecord.MemoryGB } else { $null }
        HasTempDisk           = if ($known) { $SkuRecord.HasTempDisk } else { $null }
        TempDiskGB            = if ($known) { $SkuRecord.TempDiskGB } else { $null }
        PremiumIO             = if ($known) { $SkuRecord.PremiumIO } else { $null }
        AcceleratedNetworking = if ($known) { $SkuRecord.AcceleratedNetworking } else { $null }
        MaxNICs               = if ($known) { $SkuRecord.MaxNICs } else { $null }
        MaxDataDisks          = if ($known) { $SkuRecord.MaxDataDisks } else { $null }
        UncachedDiskIOPS      = if ($known) { $SkuRecord.UncachedDiskIOPS } else { $null }
        UncachedDiskMBps      = if ($known) { $SkuRecord.UncachedDiskMBps } else { $null }
        HyperVGenerations     = if ($known) { @($SkuRecord.HyperVGenerations) } else { @() }
        DiskControllerTypes   = if ($known) { @($SkuRecord.DiskControllerTypes) } else { @() }
        GPUs                  = if ($known) { $SkuRecord.GPUs } else { $null }
        Zones                 = if ($known) { @($SkuRecord.Zones) } else { @() }
        Architecture          = $ProcessorInfo.Architecture
        Vendor                = $ProcessorInfo.Vendor
        Processors            = @($ProcessorInfo.Processors)
        VendorQuality         = $ProcessorInfo.VendorQuality
        ArchitectureQuality   = $ProcessorInfo.ArchitectureQuality
        OfferedInRegion       = $known
        LocationRestricted    = if ($known) { $SkuRecord.LocationRestricted } else { $null }
    }
}

function Get-CandidateAvailability {
    param([Parameter(Mandatory)]$Vm, [Parameter(Mandatory)]$Candidate)
    if ($Candidate.LocationRestricted) { return 'Restricted' }
    if ($Vm.Zone) {
        foreach ($z in @($Vm.Zone -split ',')) {
            if (-not (@($Candidate.Zones) -contains $z)) { return 'Not Available' }
            if (@($Candidate.RestrictedZones) -contains $z) { return 'Zone Restricted' }
        }
    }
    return 'Available'
}

function Test-CandidateGates {
    <#
    .SYNOPSIS
        Evaluates mandatory workload requirements. Result per gate: Pass | Fail | Review | Info | Unknown.
        Any 'Fail' rejects the candidate irrespective of its compatibility score.
    #>
    param([Parameter(Mandatory)]$Vm, [Parameter(Mandatory)]$Current, [Parameter(Mandatory)]$Candidate, [Parameter(Mandatory)]$CandidateProc)
    $g = New-Object System.Collections.Generic.List[object]
    $add = { param($n, $r, $d) $g.Add([pscustomobject]@{ Gate = $n; Result = $r; Detail = $d }) }

    if ($CandidateProc.Architecture -ne $Current.Architecture) { & $add 'CPU Architecture' 'Fail' "$($Current.Architecture) -> $($CandidateProc.Architecture) requires application recompilation" }
    else { & $add 'CPU Architecture' 'Pass' $Current.Architecture }

    if ($CandidateProc.Vendor -ne $Current.Vendor) { & $add 'CPU Vendor' 'Review' "CPU vendor change $($Current.Vendor) -> $($CandidateProc.Vendor); validate licensing, instruction sets and performance" }
    else { & $add 'CPU Vendor' 'Pass' $Current.Vendor }

    $gens = @($Candidate.HyperVGenerations)
    if (-not $Vm.HyperVGeneration) { & $add 'VM Generation' 'Unknown' 'VM Hyper-V generation not reported; validate Gen1/Gen2 before resize' }
    elseif ($gens.Count -eq 0) { & $add 'VM Generation' 'Unknown' 'Target Hyper-V generation support not reported' }
    elseif ($gens -contains $Vm.HyperVGeneration) { & $add 'VM Generation' 'Pass' "$($Vm.HyperVGeneration) supported" }
    else { & $add 'VM Generation' 'Fail' "VM is $($Vm.HyperVGeneration); target supports $($gens -join ',') only - in-place resize not possible (Gen1->Gen2 conversion or rebuild required)" }

    $ctl = @($Candidate.DiskControllerTypes)
    if ($ctl -contains $Vm.DiskControllerType) {
        $d = "$($Vm.DiskControllerType) supported"
        if (-not $Vm.DiskControllerReported) { $d += ' (VM controller not reported; Azure default SCSI assumed)' }
        & $add 'Disk Controller' 'Pass' $d
    }
    else { & $add 'Disk Controller' 'Fail' "VM uses $($Vm.DiskControllerType); target supports $($ctl -join ',') only - controller conversion required (validate OS NVMe driver support)" }

    if ($Vm.UsesPremiumStorage -and -not $Candidate.PremiumIO) { & $add 'Premium Storage' 'Fail' 'VM uses Premium/Ultra disks; target does not support Premium Storage' }
    elseif ($Vm.UsesPremiumStorage) { & $add 'Premium Storage' 'Pass' 'Supported' }

    if ($Vm.UsesUltraDisk) {
        $ultraOk = if ($Vm.Zone) { @(@($Vm.Zone -split ',') | Where-Object { @($Candidate.UltraSSDZones) -contains $_ }).Count -gt 0 } else { [bool]$Candidate.UltraSSDRegional -or @($Candidate.UltraSSDZones).Count -gt 0 }
        if ($ultraOk) { & $add 'Ultra Disk' 'Pass' 'Ultra Disk available for target in VM zone/region' } else { & $add 'Ultra Disk' 'Fail' 'Ultra Disk not available for target size in the VM zone/region' }
    }

    if ($Vm.AcceleratedNetworking) {
        if ($Candidate.AcceleratedNetworking) { & $add 'Accelerated Networking' 'Pass' 'Supported' } else { & $add 'Accelerated Networking' 'Fail' "$($Vm.AcceleratedNicCount) NIC(s) use Accelerated Networking; target does not support it" }
    }

    if ($Vm.EphemeralOsDisk) {
        $place = @($Candidate.EphemeralPlacements)
        if (-not $Candidate.EphemeralOSDisk) { & $add 'Ephemeral OS Disk' 'Fail' 'Target does not support ephemeral OS disks' }
        elseif ($place.Count -gt 0 -and -not ($place -contains $Vm.EphemeralPlacement)) { & $add 'Ephemeral OS Disk' 'Fail' "Ephemeral placement $($Vm.EphemeralPlacement) not supported (target: $($place -join ','))" }
        else { & $add 'Ephemeral OS Disk' 'Pass' "Placement $($Vm.EphemeralPlacement)" }
    }

    if ($Current.HasTempDisk -and $Candidate.HasTempDisk -eq $false) { & $add 'Temp / Local Disk' 'Review' "Current size has a $($Current.TempDiskGB) GB temp disk; target has none - validate pagefile, tempdb, caches or scripts using the temp drive" }
    elseif ($Current.HasTempDisk -and $Candidate.HasTempDisk) { & $add 'Temp / Local Disk' 'Pass' "Temp disk $($Current.TempDiskGB) GB -> $($Candidate.TempDiskGB) GB" }

    if ($null -ne $Candidate.MaxNICs -and $Vm.NicCount -gt $Candidate.MaxNICs) { & $add 'NIC Count' 'Fail' "VM has $($Vm.NicCount) NICs; target max $($Candidate.MaxNICs)" }
    else { & $add 'NIC Count' 'Pass' "$($Vm.NicCount) <= $($Candidate.MaxNICs)" }

    if ($null -ne $Candidate.MaxDataDisks -and $Vm.DataDiskCount -gt $Candidate.MaxDataDisks) { & $add 'Data Disk Count' 'Fail' "VM has $($Vm.DataDiskCount) data disks; target max $($Candidate.MaxDataDisks)" }
    else { & $add 'Data Disk Count' 'Pass' "$($Vm.DataDiskCount) <= $($Candidate.MaxDataDisks)" }

    if ($Vm.WriteAcceleratorDisks -gt 0) {
        if ($Candidate.MaxWriteAccelDisks -and $Candidate.MaxWriteAccelDisks -ge $Vm.WriteAcceleratorDisks) { & $add 'Write Accelerator' 'Pass' 'Supported' }
        else { & $add 'Write Accelerator' 'Fail' "$($Vm.WriteAcceleratorDisks) Write Accelerator disk(s); target allows $([int]$Candidate.MaxWriteAccelDisks)" }
    }

    switch ($Vm.SecurityType) {
        'TrustedLaunch' { if ($Candidate.TrustedLaunchDisabled -eq $true) { & $add 'Security Type' 'Fail' 'VM uses Trusted Launch; target does not support it' } else { & $add 'Security Type' 'Pass' 'Trusted Launch supported' } }
        'ConfidentialVM' { if (-not $Candidate.ConfidentialType) { & $add 'Confidential Computing' 'Fail' 'VM is a Confidential VM; target is not a confidential size' } else { & $add 'Confidential Computing' 'Review' "Confidential type $($Candidate.ConfidentialType); validate attestation / TEE compatibility" } }
    }
    if ($Vm.EncryptionAtHost) {
        if ($Candidate.EncryptionAtHost) { & $add 'Encryption at Host' 'Pass' 'Supported' } else { & $add 'Encryption at Host' 'Fail' 'VM uses encryption at host; target does not support it' }
    }
    if ($Vm.AzureDiskEncryption) { & $add 'Azure Disk Encryption' 'Info' 'ADE extension present; ADE is size-independent but validate Key Vault access after resize' }

    if ($Current.GPUs -gt 0) {
        if ($Candidate.GPUs -ge $Current.GPUs) { & $add 'GPU' 'Review' "GPU count $($Current.GPUs) -> $($Candidate.GPUs); validate GPU model, driver and framework compatibility" }
        else { & $add 'GPU' 'Fail' "Target has fewer GPUs ($([int]$Candidate.GPUs)) than current ($($Current.GPUs))" }
    }

    $avail = Get-CandidateAvailability -Vm $Vm -Candidate $Candidate
    switch ($avail) {
        'Available' { & $add 'Region / Zone' 'Pass' $(if ($Vm.Zone) { "Available in $($Vm.Region) zone $($Vm.Zone)" } else { "Available in $($Vm.Region)" }) }
        'Restricted' { & $add 'Region / Zone' 'Review' "Restricted for this subscription in $($Vm.Region) ($(@($Candidate.RestrictionReasons) -join ','))" }
        default { & $add 'Region / Zone' 'Fail' "$avail in zone $($Vm.Zone)" }
    }

    if ($Vm.DedicatedHostId -or $Vm.DedicatedHostGroupId) { & $add 'Dedicated Host' 'Review' 'VM runs on Azure Dedicated Host; target size must be supported by the host SKU type' }
    if ($Vm.ProximityPlacementGroup) { & $add 'Proximity Placement Group' 'Review' 'VM is in a proximity placement group; validate target size availability in the same datacenter' }
    if ($Vm.AvailabilitySetId) { & $add 'Availability Set' 'Review' 'If the target size is not on the current hardware cluster, all VMs in the availability set must be deallocated to resize' }
    if ($Vm.VmssId) { & $add 'VM Scale Set (Flexible)' 'Review' 'VM belongs to a scale set; resize through the scale set model where applicable' }
    if ($Vm.IsSpot) { & $add 'Spot Priority' 'Info' 'Spot VM; target Spot capacity and eviction rates differ per size' }
    if ($Vm.Hibernation) { & $add 'Hibernation' 'Info' 'Hibernation enabled; validate support on target size' }
    & $add 'Nested Virtualization' 'Unknown' 'Not detectable from Azure control plane; confirm with workload owner if Hyper-V/containers-in-VM are used'
    return $g.ToArray()
}

function Get-MaterialDifferences {
    param([Parameter(Mandatory)]$Current, [Parameter(Mandatory)]$Candidate, [Parameter(Mandatory)]$CandidateProc)
    $d = New-Object System.Collections.Generic.List[object]
    $cmp = {
        param($attr, $cur, $tgt, [switch]$HigherIsBetter, [string]$note)
        $a = if ($null -eq $cur -or $null -eq $tgt -or "$cur" -eq '' -or "$tgt" -eq '') { 'Unknown' }
        elseif ("$cur" -eq "$tgt") { 'Same' }
        elseif ($HigherIsBetter -and $null -ne ($cur -as [double]) -and $null -ne ($tgt -as [double])) { if ([double]$tgt -gt [double]$cur) { 'Improved' } else { 'Reduced' } }
        else { 'Changed' }
        $d.Add([pscustomobject]@{ Attribute = $attr; Current = $cur; Target = $tgt; Assessment = $a; Note = $note })
    }
    & $cmp 'CPU Vendor' $Current.Vendor $CandidateProc.Vendor
    & $cmp 'CPU Architecture' $Current.Architecture $CandidateProc.Architecture
    & $cmp 'Processor' (($Current.Processors | Select-Object -First 2) -join '; ') (($CandidateProc.Processors | Select-Object -First 2) -join '; ')
    & $cmp 'vCPU' $Current.vCPUs $Candidate.vCPUsAvailable -HigherIsBetter
    & $cmp 'Memory (GB)' $Current.MemoryGB $Candidate.MemoryGB -HigherIsBetter
    $curTemp = if ($null -eq $Current.HasTempDisk) { $null } elseif ($Current.HasTempDisk) { "$($Current.TempDiskGB) GB" } else { 'None' }
    $tgtTemp = if ($null -eq $Candidate.HasTempDisk) { $null } elseif ($Candidate.HasTempDisk) { "$($Candidate.TempDiskGB) GB" } else { 'None' }
    & $cmp 'Temp / Local Disk' $curTemp $tgtTemp -note $(if ($Current.HasTempDisk -and -not $Candidate.HasTempDisk) { 'Temp disk removed - validate pagefile / tempdb / scratch usage' } else { '' })
    & $cmp 'Disk Controller' ($Current.DiskControllerTypes -join ',') ($Candidate.DiskControllerTypes -join ',') -note $(if (-not (@($Candidate.DiskControllerTypes) -contains 'SCSI')) { 'NVMe only' } else { '' })
    & $cmp 'Hyper-V Generation' ($Current.HyperVGenerations -join ',') ($Candidate.HyperVGenerations -join ',') -note $(if (-not (@($Candidate.HyperVGenerations) -contains 'V1')) { 'Gen2 only' } else { '' })
    & $cmp 'Uncached Disk IOPS' $Current.UncachedDiskIOPS $Candidate.UncachedDiskIOPS -HigherIsBetter
    & $cmp 'Uncached Disk MBps' $Current.UncachedDiskMBps $Candidate.UncachedDiskMBps -HigherIsBetter
    & $cmp 'Max Data Disks' $Current.MaxDataDisks $Candidate.MaxDataDisks -HigherIsBetter
    & $cmp 'Max NICs' $Current.MaxNICs $Candidate.MaxNICs -HigherIsBetter
    & $cmp 'Accelerated Networking' $Current.AcceleratedNetworking $Candidate.AcceleratedNetworking
    & $cmp 'Premium Storage' $Current.PremiumIO $Candidate.PremiumIO
    & $cmp 'Availability Zones' ($Current.Zones -join ',') ($Candidate.Zones -join ',')
    $d.Add([pscustomobject]@{ Attribute = 'Network Bandwidth'; Current = $null; Target = $null; Assessment = 'Unknown'; Note = 'Not exposed by Resource SKUs API; see Microsoft Learn size page' })
    return $d.ToArray()
}

function Find-ReplacementCandidates {
    <#
    .SYNOPSIS
        Selects primary / secondary / third replacement sizes for one VM.
    .DESCRIPTION
        Pool: sizes offered in the VM's region whose own lifecycle is 'No Retirement Announced', same CPU architecture,
        within Microsoft's recommended target series for the retiring series (migration guide) or otherwise the same
        workload family, with vCPU and memory >= current (never downsized). One (smallest fitting) size per series.
        Same CPU vendor is mandatory preference; cross-vendor (Intel<->AMD) only if no same-vendor candidate passes gates.
    #>
    param(
        [Parameter(Mandatory)]$Vm,
        [Parameter(Mandatory)]$Current,
        [Parameter(Mandatory)]$Lifecycle,
        [Parameter(Mandatory)][hashtable]$RegionCatalog,
        $ProcessorCatalog,
        [Parameter(Mandatory)]$RetirementCatalog,
        [Parameter(Mandatory)][hashtable]$LifecycleCache,
        [Parameter(Mandatory)]$Weights,
        [Parameter(Mandatory)][datetime]$AsOf,
        [int]$MaxCandidates = 3,
        [switch]$CheckModernization
    )
    $curInfo = $Current.NameInfo
    $allowedSeries = @($Lifecycle.RecommendedTargets)
    $sizeTargets = @($Lifecycle.SizeTargets | ForEach-Object { $_.ToLowerInvariant() })
    $modernOffered = 0
    $modernLifecycleEligible = 0
    $modernArchitectureMatches = 0
    $pool = New-Object System.Collections.Generic.List[object]
    foreach ($rec in $RegionCatalog.Values) {
        if ($rec.Name -ieq $Vm.SkuName) { continue }
        if ($rec.Tier -eq 'Basic') { continue }
        $info = Get-SkuNameInfo -SkuName $rec.Name
        if (-not $info.Parsed -or $info.IsPromo) { continue }
        if ($info.Constrained -and -not $curInfo.Constrained) { continue }
        if ($info.Features -match 'i' -and $curInfo.Features -notmatch 'i') { continue }
        $modernEligible = [bool]($CheckModernization -and $curInfo.Version -lt 6 -and $info.Version -in 6, 7 -and $info.Family -eq $curInfo.Family)
        if ($modernEligible) { $modernOffered++ }

        $existingEligible = $true
        $famMatch = 'Same'
        if ($sizeTargets.Count -gt 0) {
            $existingEligible = $sizeTargets -contains $rec.Name.ToLowerInvariant()
            if ($existingEligible) { $famMatch = if ($info.Family -eq $curInfo.Family) { 'Same' } else { 'Recommended' } }
        }
        elseif ($allowedSeries.Count -gt 0) {
            # Guide targets are series keys (ddsv5) or family/version keys ("v6 and v7 D-family series" -> d-family-v6).
            $familyVersionKey = '{0}-family-v{1}' -f $info.Family.ToLowerInvariant(), $info.Version
            $existingEligible = $allowedSeries -contains $info.SeriesKey -or $allowedSeries -contains $info.BaseKey -or $allowedSeries -contains $familyVersionKey
            if ($existingEligible) { $famMatch = if ($info.Family -eq $curInfo.Family) { 'Same' } else { 'Recommended' } }
        }
        else { $existingEligible = $info.Family -eq $curInfo.Family }
        if (-not $existingEligible -and -not $modernEligible) { continue }

        if (-not $LifecycleCache.ContainsKey($rec.Name)) { $LifecycleCache[$rec.Name] = Resolve-SkuLifecycle -SkuName $rec.Name -Catalog $RetirementCatalog -AsOf $AsOf }
        if ($LifecycleCache[$rec.Name].EvidenceClass -ne 'No Retirement Announced') { continue }
        if ($modernEligible) { $modernLifecycleEligible++ }
        if ($info.Version -lt $curInfo.Version) { continue }
        if ($existingEligible -and $Lifecycle.EvidenceClass -in 'Modernization Recommended', 'No Retirement Announced' -and $info.Version -le $curInfo.Version) { $existingEligible = $false }
        if (-not $existingEligible -and -not $modernEligible) { continue }

        $proc = Get-ProcessorInfo -SkuName $rec.Name -ProcessorCatalog $ProcessorCatalog -SkuRecord $rec
        if ($modernEligible -and $proc.Architecture -eq $Current.Architecture) { $modernArchitectureMatches++ }
        if ($proc.Architecture -ne $Current.Architecture) { continue }
        if ($Current.vCPUs -and $rec.vCPUsAvailable -and $rec.vCPUsAvailable -lt $Current.vCPUs) { continue }
        if ($Current.MemoryGB -and $rec.MemoryGB -and $rec.MemoryGB -lt ($Current.MemoryGB * 0.97)) { continue }
        if ($Current.GPUs -gt 0 -and -not ($rec.GPUs -ge $Current.GPUs)) { continue }
        if (-not $Current.CapsKnown -and $curInfo.Parsed -and $rec.vCPUsAvailable -lt $curInfo.Size) { continue }

        $pool.Add([pscustomobject]@{
                Record = $rec; Info = $info; Proc = $proc; FamilyMatch = $famMatch
                ExistingEligible = $existingEligible; ModernizationEligible = $modernEligible
            })
    }

    # Smallest fitting size per series (never downsize, avoid over-provisioning). When that size lowers the VM-level
    # disk throughput caps, also evaluate the smallest size in the same series that preserves them (design rule: capability
    # regressions are never hidden; the preserving option is offered as an alternative).
    $perSeries = New-Object System.Collections.Generic.List[object]
    foreach ($sg in ($pool | Group-Object { $_.Info.SeriesKey })) {
        $sorted = @($sg.Group | Sort-Object { $_.Record.vCPUsAvailable }, { $_.Record.MemoryGB })
        $first = $sorted[0]
        $first | Add-Member -NotePropertyName Variant -NotePropertyValue 'Closest size' -Force
        $perSeries.Add($first)
        if ($Current.UncachedDiskIOPS -and $Current.UncachedDiskMBps -and $first.Record.UncachedDiskIOPS -and $first.Record.UncachedDiskMBps -and
            ($first.Record.UncachedDiskIOPS -lt $Current.UncachedDiskIOPS -or $first.Record.UncachedDiskMBps -lt $Current.UncachedDiskMBps)) {
            $keep = $sorted | Where-Object {
                $_.Record.UncachedDiskIOPS -ge $Current.UncachedDiskIOPS -and $_.Record.UncachedDiskMBps -ge $Current.UncachedDiskMBps -and
                $_.Record.vCPUsAvailable -le (2 * $Current.vCPUs)
            } | Select-Object -First 1
            if ($keep -and $keep.Record.Name -ne $first.Record.Name) {
                $keep | Add-Member -NotePropertyName Variant -NotePropertyValue 'Capability-preserving' -Force
                $perSeries.Add($keep)
            }
        }
    }

    $evaluated = foreach ($c in $perSeries) {
        $gates = Test-CandidateGates -Vm $Vm -Current $Current -Candidate $c.Record -CandidateProc $c.Proc
        $avail = Get-CandidateAvailability -Vm $Vm -Candidate $c.Record
        $score = Get-CompatibilityScore -Vm $Vm -Current $Current -Candidate $c.Record -CandidateProc $c.Proc -FamilyMatch $c.FamilyMatch -Availability $avail -Weights $Weights
        $fails = @($gates | Where-Object Result -eq 'Fail')
        $reviews = @($gates | Where-Object Result -eq 'Review')
        $cv = if ($Current.vCPUs) { $c.Record.vCPUsAvailable / $Current.vCPUs } else { 1 }
        $cm = if ($Current.MemoryGB -and $c.Record.MemoryGB) { $c.Record.MemoryGB / $Current.MemoryGB } else { 1 }
        $headroom = [math]::Round(([math]::Min($cv, $cm) - 1) * 100, 0)
        [pscustomobject]@{
            SkuName            = $c.Record.Name
            Variant            = $c.Variant
            SeriesKey          = $c.Info.SeriesKey
            Family             = $c.Record.Family
            WorkloadFamily     = $c.Info.Family
            Generation         = $c.Info.Version
            FamilyMatch        = $c.FamilyMatch
            CpuVendor          = $c.Proc.Vendor
            CpuArchitecture    = $c.Proc.Architecture
            CpuGeneration      = (@($c.Proc.Generations) | Select-Object -First 1)
            Processors         = @($c.Proc.Processors)
            VendorQuality      = $c.Proc.VendorQuality
            vCPUs              = $c.Record.vCPUsAvailable
            MemoryGB           = $c.Record.MemoryGB
            TempDiskGB         = $c.Record.TempDiskGB
            Availability       = $avail
            ZoneAvailable      = if ($Vm.Zone) { $avail -eq 'Available' -or $avail -eq 'Restricted' } else { $null }
            Score              = $score.Total
            Band               = $score.Band
            ScoreBreakdown     = $score.Breakdown
            Gates              = $gates
            FailedGates        = @($fails | ForEach-Object Gate)
            ReviewGates        = @($reviews | ForEach-Object Gate)
            Rejected           = $fails.Count -gt 0
            RejectionReason    = ($fails | ForEach-Object { "$($_.Gate): $($_.Detail)" }) -join ' | '
            VendorPreserved    = $c.Proc.Vendor -eq $Current.Vendor
            CapacityHeadroomPct = $headroom
            Closeness          = [math]::Round(($cv - 1) + ($cm - 1), 3)
            FeatureDistance    = @($c.Info.Features.ToCharArray() | Where-Object { $curInfo.Features -notmatch $_ }).Count + @($curInfo.Features.ToCharArray() | Where-Object { $c.Info.Features -notmatch $_ }).Count
            Differences        = $null
            Role               = 'Candidate'
            Record             = $c.Record
            ExistingEligible   = $c.ExistingEligible
            ModernizationEligible = $c.ModernizationEligible
        }
    }
    $evaluated = @($evaluated)

    $valid = @($evaluated | Where-Object { -not $_.Rejected -and $_.ExistingEligible })
    $sameVendor = @($valid | Where-Object VendorPreserved)
    $vendorChange = $false; $vendorReason = $null
    $selectable = $sameVendor
    if ($sameVendor.Count -eq 0 -and $valid.Count -gt 0) {
        $selectable = $valid; $vendorChange = $true
        $blocked = @($evaluated | Where-Object { $_.VendorPreserved -and $_.Rejected } | Select-Object -First 3 | ForEach-Object { "$($_.SkuName) ($($_.RejectionReason))" })
        $vendorReason = if ($blocked.Count -gt 0) { "No same-vendor ($($Current.Vendor)) size passes mandatory requirements: $($blocked -join '; ')" } else { "No current-generation $($Current.Vendor) size in the permitted series is offered in $($Vm.Region)" }
    }
    $available = @($selectable | Where-Object Availability -eq 'Available')
    $threshold = $Weights.primarySelection.preferNewestGenerationAtOrAboveScore
    $strong = @($available | Where-Object { $_.Score -ge $threshold })
    # Generation numbers are only comparable within a workload family (Bsv2 is B-series' current generation while D is
    # on v6/v7), so keep the newest generation per family and then rank across families by score.
    $tier = if ($strong.Count -gt 0) {
        @($strong | Group-Object WorkloadFamily | ForEach-Object {
                $g = @($_.Group); $best = ($g | Measure-Object Generation -Maximum).Maximum
                $g | Where-Object Generation -eq $best
            })
    }
    else { $available }
    $existingPrimary = $tier | Sort-Object @{ e = 'Score'; Descending = $true }, @{ e = 'FeatureDistance'; Descending = $false }, @{ e = 'Closeness'; Descending = $false }, SkuName | Select-Object -First 1

    $modernAvailable = @($evaluated | Where-Object {
            $_.ModernizationEligible -and -not $_.Rejected -and $_.VendorPreserved -and $_.Availability -eq 'Available'
        })
    $modernPrimary = $modernAvailable |
        Sort-Object @{ e = 'Generation'; Descending = $true }, @{ e = 'Score'; Descending = $true }, FeatureDistance, Closeness, SkuName |
        Select-Object -First 1
    $primary = if ($CheckModernization -and $modernPrimary) { $modernPrimary } else { $existingPrimary }
    if ($modernPrimary) {
        $vendorChange = $false
        $vendorReason = $null
        $available = @($modernAvailable) + @($available | Where-Object { $_.SkuName -notin @($modernAvailable | ForEach-Object SkuName) })
    }

    $secondary = $null; $third = $null
    if ($primary) {
        $primary.Role = 'Primary'
        # Alternatives never fall back to an older generation than the primary (design rule: no aging replacement).
        $rest = @($available | Where-Object { $_.SkuName -ne $primary.SkuName -and ($_.WorkloadFamily -ne $primary.WorkloadFamily -or $_.Generation -ge $primary.Generation) } | Sort-Object @{ e = { if ($_.Family -ne $primary.Family) { 0 } else { 1 } } }, @{ e = 'Score'; Descending = $true }, @{ e = 'Generation'; Descending = $true }, FeatureDistance, Closeness)
        if ($MaxCandidates -ge 2) {
            $secondary = $rest | Select-Object -First 1
            if ($secondary) { $secondary.Role = 'Secondary' }
        }
        if ($MaxCandidates -ge 3) {
            $third = $rest | Where-Object { -not $secondary -or $_.SkuName -ne $secondary.SkuName } | Sort-Object @{ e = 'Score'; Descending = $true }, FeatureDistance, Closeness | Select-Object -First 1
            if ($third) { $third.Role = 'Third' }
        }
        foreach ($x in @($primary, $secondary, $third) | Where-Object { $_ }) {
            $x.Differences = Get-MaterialDifferences -Current $Current -Candidate $x.Record -CandidateProc ([pscustomobject]@{ Vendor = $x.CpuVendor; Architecture = $x.CpuArchitecture; Processors = $x.Processors })
        }
    }

    # Newer generation that is blocked only by convertible requirements (Gen1->Gen2, SCSI->NVMe).
    $future = $evaluated | Where-Object {
        $_.Rejected -and $_.VendorPreserved -and $_.Availability -eq 'Available' -and
        @($_.FailedGates | Where-Object { $_ -notin 'VM Generation', 'Disk Controller' }).Count -eq 0 -and
        (-not $primary -or ($_.WorkloadFamily -eq $primary.WorkloadFamily -and $_.Generation -gt $primary.Generation))
    } | Sort-Object @{ e = 'Generation'; Descending = $true }, @{ e = 'Score'; Descending = $true } | Select-Object -First 1

    $noCandidateReason = $null
    if (-not $primary) {
        $noCandidateReason = if ($evaluated.Count -eq 0) { "No current-generation size with >= $($Current.vCPUs) vCPU / $(if ($Current.MemoryGB) { "$($Current.MemoryGB) GB" } else { 'unknown GB (current size not in Resource SKUs API)' }) in the permitted series ($(if ($allowedSeries.Count) { $allowedSeries -join ', ' } else { "$($curInfo.Family)-series" })) is offered in $($Vm.Region) for this subscription" }
        elseif ($selectable.Count -gt 0) { 'Valid candidates exist but none is available (restricted/zone) in the VM region for this subscription' }
        else { 'All candidates fail mandatory requirements: ' + ((@($evaluated | Sort-Object Score -Descending | Select-Object -First 3) | ForEach-Object { "$($_.SkuName) [$($_.RejectionReason)]" }) -join '; ') }
    }
    $modernization = $null
    if ($CheckModernization) {
        $modernEvaluated = @($evaluated | Where-Object ModernizationEligible)
        $modernSameVendor = @($modernEvaluated | Where-Object VendorPreserved)
        $preliminaryStatus = if ($modernPrimary) { "Modernize to v$($modernPrimary.Generation)" }
        elseif ($modernOffered -eq 0) { 'SKU unavailable in region' }
        elseif ($modernLifecycleEligible -gt 0 -and $modernArchitectureMatches -eq 0) { 'Architecture mismatch' }
        elseif ($modernSameVendor.Count -eq 0) { 'No suitable modern SKU found' }
        elseif (@($modernSameVendor | Where-Object { -not $_.Rejected -and $_.Availability -ne 'Available' }).Count -gt 0) { 'SKU unavailable in region' }
        else { 'No suitable modern SKU found' }
        $reason = if ($modernPrimary) {
            "$($modernPrimary.SkuName) is the newest suitable v$($modernPrimary.Generation) option that preserves $($Current.Vendor) / $($Current.Architecture), meets the workload capability gates, and is available in $($Vm.Region)."
        }
        elseif ($preliminaryStatus -eq 'Architecture mismatch') {
            "v6/v7 $($curInfo.Family)-series sizes were found in $($Vm.Region), but none preserves the current $($Current.Architecture) architecture."
        }
        elseif ($preliminaryStatus -eq 'SKU unavailable in region') {
            "No suitable v6/v7 $($curInfo.Family)-series size is available to this subscription in $($Vm.Region)$(if ($Vm.Zone) { " zone $($Vm.Zone)" })."
        }
        else {
            $details = @($modernSameVendor | Sort-Object Score -Descending | Select-Object -First 3 | ForEach-Object {
                    if ($_.Rejected) { "$($_.SkuName): $($_.RejectionReason)" } else { "$($_.SkuName): $($_.Availability)" }
                })
            "No same-vendor v6/v7 size passed all workload requirements$(if ($details.Count) { ': ' + ($details -join '; ') } else { '.' })"
        }
        if (-not $modernPrimary -and $existingPrimary) { $reason += " Retaining existing recommendation $($existingPrimary.SkuName)." }
        $modernization = [pscustomobject]@{
            Enabled = $true
            Candidate = $modernPrimary
            ExistingRecommendation = $existingPrimary
            PreliminaryStatus = $preliminaryStatus
            Reason = $reason
        }
    }
    [pscustomobject]@{
        Candidates           = @($evaluated | Sort-Object @{ e = 'Rejected'; Descending = $false }, @{ e = 'Score'; Descending = $true })
        Primary              = $primary
        Secondary            = $secondary
        Third                = $third
        FutureGeneration     = $future
        VendorChangeRequired = $vendorChange
        VendorChangeReason   = $vendorReason
        NoCandidateReason    = $noCandidateReason
        PermittedSeries      = if ($sizeTargets.Count -gt 0) { 'Microsoft migration guide (isolated size targets)' } elseif ($allowedSeries.Count -gt 0) { 'Microsoft migration guide: ' + ($allowedSeries -join ', ') } else { "Same workload family ($($curInfo.Family)-series)" }
        Modernization        = $modernization
    }
}

Export-ModuleMember -Function New-CurrentProfile, Get-CandidateAvailability, Test-CandidateGates, Get-MaterialDifferences, Find-ReplacementCandidates
