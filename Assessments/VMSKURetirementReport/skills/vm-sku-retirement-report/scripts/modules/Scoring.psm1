Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

function Get-ScoreBand {
    param([Parameter(Mandatory)][double]$Score, [Parameter(Mandatory)]$Weights)
    foreach ($b in ($Weights.bands | Sort-Object min -Descending)) { if ($Score -ge $b.min) { return $b.label } }
    return 'Manual Review Required'
}

function Get-CompatibilityScore {
    <#
    .SYNOPSIS
        Weighted 0-100 compatibility score between the current VM size and a candidate (weights from scoring-weights.json).
    .NOTES
        The score never overrides mandatory gates; callers must reject candidates with any 'Fail' gate.
    #>
    param(
        [Parameter(Mandatory)]$Vm,
        [Parameter(Mandatory)]$Current,
        [Parameter(Mandatory)]$Candidate,
        [Parameter(Mandatory)]$CandidateProc,
        [Parameter(Mandatory)][ValidateSet('Same', 'Recommended', 'Other')][string]$FamilyMatch,
        [Parameter(Mandatory)][string]$Availability,
        [Parameter(Mandatory)]$Weights
    )
    $w = $Weights.weights
    $b = [ordered]@{}

    $b.cpuVendor = if ($CandidateProc.Vendor -eq $Current.Vendor) { $w.cpuVendor } else { 0 }
    $b.cpuArchitecture = if ($CandidateProc.Architecture -eq $Current.Architecture) { $w.cpuArchitecture } else { 0 }
    $b.workloadFamily = switch ($FamilyMatch) { 'Same' { $w.workloadFamily } 'Recommended' { [math]::Round($w.workloadFamily * 0.8, 1) } default { 0 } }

    $cv = $Current.vCPUs; $tv = $Candidate.vCPUsAvailable
    $b.vCpu = if ($cv -and $tv) {
        $r = $tv / $cv
        if ($r -lt 1) { 0 } elseif ($r -eq 1) { $w.vCpu } elseif ($r -le 1.25) { $w.vCpu * 0.9 } elseif ($r -le 2) { $w.vCpu * 0.6 } else { $w.vCpu * 0.3 }
    } else { $w.vCpu * 0.5 }

    $cm = $Current.MemoryGB; $tm = $Candidate.MemoryGB
    $b.memory = if ($cm -and $tm) {
        $m = $tm / $cm
        if ($m -lt 0.97) { 0 } elseif ($m -le 1.25) { $w.memory } elseif ($m -le 2) { $w.memory * 0.6 } else { $w.memory * 0.3 }
    } else { $w.memory * 0.5 }

    $b.memoryPerVcpu = if ($cm -and $tm -and $cv -and $tv) {
        $q = [math]::Abs([math]::Log(($tm / $tv) / ($cm / $cv)))
        if ($q -le 0.1) { $w.memoryPerVcpu } elseif ($q -le 0.4) { $w.memoryPerVcpu * 0.6 } else { $w.memoryPerVcpu * 0.2 }
    } else { $w.memoryPerVcpu * 0.5 }

    # Storage capability: premium (40%), temp disk parity (30%), ephemeral / ultra support where used (30%).
    $s = $w.storageCapability
    $prem = if ($Vm.UsesPremiumStorage) { if ($Candidate.PremiumIO) { 0.4 } else { 0 } } elseif ($Current.PremiumIO -and -not $Candidate.PremiumIO) { 0.2 } else { 0.4 }
    $temp = if ($Current.HasTempDisk) { if ($Candidate.HasTempDisk) { 0.3 } else { 0 } } else { 0.3 }
    $special = 0.3
    if ($Vm.EphemeralOsDisk -and -not $Candidate.EphemeralOSDisk) { $special = 0 }
    if ($Vm.UsesUltraDisk -and -not (@($Candidate.UltraSSDZones).Count -gt 0 -or $Candidate.UltraSSDRegional)) { $special = 0 }
    $b.storageCapability = [math]::Round($s * ($prem + $temp + $special), 1)

    $wt = $w.diskThroughput
    $b.diskThroughput = if ($Current.UncachedDiskIOPS -and $Candidate.UncachedDiskIOPS -and $Current.UncachedDiskMBps -and $Candidate.UncachedDiskMBps) {
        $ratio = [math]::Min($Candidate.UncachedDiskIOPS / $Current.UncachedDiskIOPS, $Candidate.UncachedDiskMBps / $Current.UncachedDiskMBps)
        if ($ratio -ge 1) { $wt } elseif ($ratio -ge 0.9) { $wt * 0.6 } else { $wt * 0.2 }
    } else { $wt * 0.5 }

    $wn = $w.network
    $an = if ($Current.AcceleratedNetworking -or $Vm.AcceleratedNetworking) { if ($Candidate.AcceleratedNetworking) { 0.6 } else { 0 } } else { 0.6 }
    $nics = if ($Current.MaxNICs -and $Candidate.MaxNICs) { if ($Candidate.MaxNICs -ge $Current.MaxNICs) { 0.4 } elseif ($Candidate.MaxNICs -ge $Vm.NicCount) { 0.2 } else { 0 } } else { 0.2 }
    $b.network = [math]::Round($wn * ($an + $nics), 1)

    $wl = $w.nicDiskLimits
    $nicOk = if ($null -ne $Candidate.MaxNICs) { if ($Candidate.MaxNICs -ge $Vm.NicCount) { 0.5 } else { 0 } } else { 0.25 }
    $diskOk = if ($null -ne $Candidate.MaxDataDisks) { if ($Candidate.MaxDataDisks -ge $Vm.DataDiskCount) { 0.5 } else { 0 } } else { 0.25 }
    $b.nicDiskLimits = [math]::Round($wl * ($nicOk + $diskOk), 1)

    $wz = $w.zoneRegion
    $reg = if ($Availability -eq 'Available') { 0.6 } else { 0 }
    $zone = if ($Vm.Zone) {
        $z = @($Vm.Zone -split ',')
        if (@($z | Where-Object { @($Candidate.Zones) -contains $_ -and -not (@($Candidate.RestrictedZones) -contains $_) }).Count -eq $z.Count) { 0.4 } else { 0 }
    } else { 0.4 }
    $b.zoneRegion = [math]::Round($wz * ($reg + $zone), 1)

    $wo = $w.otherFeatures
    $gen = if ($Vm.HyperVGeneration -and @($Candidate.HyperVGenerations).Count -gt 0) { if (@($Candidate.HyperVGenerations) -contains $Vm.HyperVGeneration) { 0.4 } else { 0 } } else { 0.2 }
    $sec = switch ($Vm.SecurityType) {
        'TrustedLaunch' { if ($Candidate.TrustedLaunchDisabled -eq $true) { 0 } else { 0.2 } }
        'ConfidentialVM' { if ($Candidate.ConfidentialType) { 0.2 } else { 0 } }
        default { 0.2 }
    }
    $eah = if ($Vm.EncryptionAtHost) { if ($Candidate.EncryptionAtHost) { 0.2 } else { 0 } } else { 0.2 }
    $ctl = if (@($Candidate.DiskControllerTypes) -contains $Vm.DiskControllerType) { 0.2 } else { 0 }
    $b.otherFeatures = [math]::Round($wo * ($gen + $sec + $eah + $ctl), 1)

    $total = 0; foreach ($v in $b.Values) { $total += [double]$v }
    $total = [math]::Round([math]::Min(100, $total), 0)
    [pscustomobject]@{ Total = [int]$total; Band = (Get-ScoreBand -Score $total -Weights $Weights); Breakdown = [pscustomobject]$b }
}

function Get-MigrationConfidence {
    <#
    .SYNOPSIS
        HIGH only when lifecycle, target SKU, CPU vendor, features, region and quota are all verified with no open validation items.
    #>
    param(
        [Parameter(Mandatory)]$Lifecycle,
        $Primary,
        [Parameter(Mandatory)]$Current,
        [bool]$VendorChangeRequired,
        [string]$QuotaStatus,
        [string[]]$ValidationItems = @()
    )
    $low = New-Object System.Collections.Generic.List[string]
    if (-not $Primary) { $low.Add('No valid replacement candidate') }
    if ($VendorChangeRequired) { $low.Add('CPU vendor change required') }
    if (-not $Current.CapsKnown) { $low.Add('Current SKU characteristics incomplete') }
    if ($Primary -and $Primary.Availability -ne 'Available') { $low.Add("Regional availability: $($Primary.Availability)") }
    if ($QuotaStatus -in 'Quota Information Unavailable', 'Manual Validation Required') { $low.Add('Quota could not be validated') }
    if ($Lifecycle.EvidenceClass -eq 'Unable to Confirm') { $low.Add('Lifecycle evidence unavailable') }
    $items = @($ValidationItems | Where-Object { $_ })
    if ($Lifecycle.DataQuality -ne 'Verified') { $items += 'Lifecycle evidence partially verified' }
    if ($QuotaStatus -eq 'Quota Increase Required') { $items += 'Quota increase required' }
    $level = if ($low.Count -gt 0) { 'LOW' } elseif ($items.Count -eq 0) { 'HIGH' } elseif ($items.Count -eq 1) { 'MEDIUM' } else { 'LOW' }
    [pscustomobject]@{ Level = $level; LowReasons = $low.ToArray(); ValidationItems = @($items) }
}

function Get-DeploymentReadiness {
    param(
        $Primary,
        [string]$QuotaStatus,
        [bool]$ManualReview,
        [bool]$CapacitySensitive
    )
    if (-not $Primary) { return 'Manual Review Required' }
    if ($Primary.Availability -eq 'Restricted') { return 'SKU Restricted' }
    if ($Primary.Availability -in 'Not Available', 'Zone Restricted') { return 'Regional Limitation' }
    if ($Primary.Availability -eq 'Unable to Determine') { return 'Manual Review Required' }
    if ($ManualReview) { return 'Manual Review Required' }
    if ($QuotaStatus -eq 'Quota Increase Required') { return 'Quota Increase Required' }
    if ($QuotaStatus -in 'Quota Information Unavailable', 'Manual Validation Required') { return 'Manual Review Required' }
    if ($CapacitySensitive) { return 'Capacity Validation Required' }
    return 'Ready'
}

function Get-LifecycleAction {
    <#
    .SYNOPSIS
        Maps lifecycle evidence to the documented action values. Modernization never produces a 'Migration Required' action.
    #>
    param([Parameter(Mandatory)]$Lifecycle, [bool]$ModernizationOptional)
    switch ($Lifecycle.EvidenceClass) {
        'Already Retired' { return 'Immediate Migration Required' }
        'Unable to Confirm' { return 'Manual Review Required' }
        'Modernization Recommended' { if ($Lifecycle.PreviousGenStatus -match 'Capacity limited') { return 'Plan Migration' } else { return 'Modernization Optional' } }
        'No Retirement Announced' { if ($ModernizationOptional) { return 'Modernization Optional' } else { return 'No Action Required' } }
    }
    switch ($Lifecycle.Urgency) {
        'Already Retired' { 'Immediate Migration Required' }
        'Less than 12 Months' { 'Migration Required Within 12 Months' }
        '12-24 Months' { 'Migration Required Within 24 Months' }
        '24-36 Months' { 'Migration Required Within 36 Months' }
        'More than 36 Months' { 'Plan Migration' }
        default { 'Manual Review Required' }
    }
}

function Get-MigrationWave {
    <#
    .SYNOPSIS
        Assigns the migration wave. Wave 1 (retired or < 12 months) is never deferred; dated retirements at or beyond
        -HorizonMonths are 'Beyond Horizon', earlier ones are Wave 2 (12-24 months) or Wave 3 (24 months to the horizon).
    #>
    param([Parameter(Mandatory)]$Lifecycle, [Parameter(Mandatory)][string]$Action, [ValidateRange(12, 120)][int]$HorizonMonths = 36)
    switch ($Lifecycle.Urgency) {
        'Already Retired' { return 'Wave 1 - Urgent' }
        'Less than 12 Months' { return 'Wave 1 - Urgent' }
    }
    if ($Lifecycle.Urgency -in '12-24 Months', '24-36 Months', 'More than 36 Months') {
        $months = if ($Lifecycle.PSObject.Properties.Name -contains 'MonthsRemaining' -and $null -ne $Lifecycle.MonthsRemaining) { [int]$Lifecycle.MonthsRemaining }
        else { switch ($Lifecycle.Urgency) { '12-24 Months' { 12 } '24-36 Months' { 24 } default { 36 } } }
        if ($months -ge $HorizonMonths) { return 'Beyond Horizon' }
        if ($Lifecycle.Urgency -eq '12-24 Months') { return 'Wave 2 - Near Term' }
        return 'Wave 3 - Planned'
    }
    if ($Lifecycle.EvidenceClass -eq 'Unable to Confirm' -or $Lifecycle.Urgency -eq 'Unable to Determine') { return 'Review - Unconfirmed' }
    if ($Action -in 'Plan Migration', 'Modernization Optional') { return 'Wave 4 - Modernization' }
    return 'None'
}

Export-ModuleMember -Function Get-ScoreBand, Get-CompatibilityScore, Get-MigrationConfidence, Get-DeploymentReadiness, Get-LifecycleAction, Get-MigrationWave
