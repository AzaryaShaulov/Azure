Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

function Get-QuotaUsage {
    <#
    .SYNOPSIS
        Returns compute usage/limits for a subscription + region as a hashtable keyed by lower-case quota name.
    #>
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$Region)
    $raw = Invoke-AzJson -Arguments @('vm', 'list-usage', '--location', $Region, '--subscription', $SubscriptionId) -AllowFailure
    if ($null -eq $raw) { return $null }
    $d = @{}
    foreach ($u in @($raw)) {
        if (-not $u -or -not $u.name) { continue }
        $d[$u.name.value.ToLowerInvariant()] = [pscustomobject]@{
            Name = $u.name.value; LocalName = $u.localName; Used = [int]$u.currentValue; Limit = [int]$u.limit
        }
    }
    return $d
}

function Get-QuotaUsages {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Pairs, [int]$ThrottleLimit = 6)
    $modulePath = Join-Path $PSScriptRoot 'Quota.psm1'
    $results = $Pairs | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        Import-Module $using:modulePath -DisableNameChecking
        $p = $_
        [pscustomobject]@{ Key = "$($p.SubscriptionId)|$($p.Region)".ToLowerInvariant(); Usage = (Get-QuotaUsage -SubscriptionId $p.SubscriptionId -Region $p.Region) }
    }
    $out = @{}
    foreach ($r in @($results)) { $out[$r.Key] = $r.Usage }
    return $out
}

function Get-QuotaIncrease {
    <#
    .SYNOPSIS
        Minimum and recommended quota increase for a family / regional quota.
    .EXAMPLE
        Get-QuotaIncrease -Limit 100 -Used 92 -Required 16 -SafetyPct 20   # MinimumIncrease 8, RecommendedIncrease 12
    #>
    param([Parameter(Mandatory)][int]$Limit, [Parameter(Mandatory)][int]$Used, [Parameter(Mandatory)][int]$Required, [double]$SafetyPct = 20)
    $post = $Used + $Required
    $min = [math]::Max(0, $post - $Limit)
    $rec = if ($min -gt 0) { [int][math]::Ceiling($min + ($Required * $SafetyPct / 100)) } else { 0 }
    [pscustomobject]@{
        Limit = $Limit; Used = $Used; Remaining = ($Limit - $Used); Required = $Required; PostMigrationUsage = $post
        MinimumIncrease = $min; RecommendedIncrease = $rec; RecommendedNewLimit = ($Limit + $rec)
        Status = if ($min -gt 0) { 'Quota Increase Required' } else { 'Quota OK' }
    }
}

function New-QuotaImpactRow {
    <#
    .SYNOPSIS
        Builds one QuotaRow. Original columns keep their original order; steady/peak columns are appended.
    #>
    param(
        [string]$SubscriptionId, [string]$Region, [string]$QuotaName, [string]$QuotaDisplayName, [int]$VmCount, [string]$TargetSkus,
        [int]$SteadyRequired, [AllowNull()]$RequiredAllocatedOnly, [int]$PeakRequired, [int]$SideBySideCount, $QuotaUsage,
        [double]$SafetyPct = 20, [string]$Scope, [switch]$UnknownFamily, [switch]$UsageAvailable
    )
    $model = if ($SideBySideCount -le 0) { 'InPlace' } elseif ($SideBySideCount -ge $VmCount) { 'SideBySide' } else { 'Mixed' }
    $row = [ordered]@{
        SubscriptionId = $SubscriptionId; Region = $Region; QuotaName = $QuotaName; QuotaDisplayName = $QuotaDisplayName
        VmCount = $VmCount; TargetSkus = $TargetSkus; Limit = $null; CurrentUsage = $null; Remaining = $null
        RequiredVcpu = $SteadyRequired; RequiredVcpuAllocatedOnly = $RequiredAllocatedOnly; PostMigrationUsage = $null
        MinimumIncrease = $null; RecommendedIncrease = $null; RecommendedNewLimit = $null
        Status = 'Quota Information Unavailable'; DataQuality = 'Unable to Verify'; Scope = $Scope
        MigrationQuotaModel = $model; SideBySideVmCount = $SideBySideCount
        SteadyStateRequiredVcpu = $SteadyRequired; PeakMigrationRequiredVcpu = $PeakRequired; PeakPostMigrationUsage = $null
        PeakMinimumIncrease = $null; PeakRecommendedIncrease = $null; PeakRecommendedNewLimit = $null
        PeakStatus = 'Quota Information Unavailable'
    }
    if ($UnknownFamily) {
        $row.QuotaName = '(unknown family)'; $row.Status = 'Manual Validation Required'; $row.PeakStatus = 'Manual Validation Required'
    }
    elseif ($QuotaUsage) {
        $steady = Get-QuotaIncrease -Limit $QuotaUsage.Limit -Used $QuotaUsage.Used -Required $SteadyRequired -SafetyPct $SafetyPct
        $peak = Get-QuotaIncrease -Limit $QuotaUsage.Limit -Used $QuotaUsage.Used -Required $PeakRequired -SafetyPct $SafetyPct
        if (-not $row.QuotaDisplayName) { $row.QuotaDisplayName = $QuotaUsage.LocalName }
        $row.Limit = $steady.Limit; $row.CurrentUsage = $steady.Used; $row.Remaining = $steady.Remaining
        $row.PostMigrationUsage = $steady.PostMigrationUsage; $row.MinimumIncrease = $steady.MinimumIncrease
        $row.RecommendedIncrease = $steady.RecommendedIncrease; $row.RecommendedNewLimit = $steady.RecommendedNewLimit
        $row.Status = $steady.Status; $row.DataQuality = 'Verified'
        $row.PeakPostMigrationUsage = $peak.PostMigrationUsage; $row.PeakMinimumIncrease = $peak.MinimumIncrease
        $row.PeakRecommendedIncrease = $peak.RecommendedIncrease; $row.PeakRecommendedNewLimit = $peak.RecommendedNewLimit
        $row.PeakStatus = $peak.Status
    }
    elseif ($UsageAvailable) {
        $row.Status = 'Manual Validation Required'; $row.PeakStatus = 'Manual Validation Required'; $row.DataQuality = 'Partially Verified'
    }
    return [pscustomobject]$row
}

function Get-PropertySum {
    param([AllowEmptyCollection()][object[]]$Items, [Parameter(Mandatory)][string]$Property)
    $sum = 0
    foreach ($i in @($Items)) { if ($i) { $sum += [int]$i.$Property } }
    return $sum
}

function Get-CombinedQuotaStatus {
    param([string[]]$Statuses)
    if ($Statuses -contains 'Quota Information Unavailable') { return 'Quota Information Unavailable' }
    if ($Statuses -contains 'Manual Validation Required') { return 'Manual Validation Required' }
    if ($Statuses -contains 'Quota Increase Required') { return 'Quota Increase Required' }
    return 'Quota OK'
}

function Measure-QuotaImpact {
    <#
    .SYNOPSIS
        Aggregates migration demand per subscription/region/target family and per regional vCPU total.
    .DESCRIPTION
        Demand is summed across every VM moving into the same target family (not validated per VM in isolation).
        RequiredVcpu / MinimumIncrease / Status remain the steady-state (post-migration) values.

        MigrationQuotaModel may be supplied on each move:
          - InPlace (default): the VM is resized; source and target never consume quota at the same time.
          - SideBySide: a replacement VM may run while the source still exists, so peak demand is the full target vCPU.

        Family quota (steady): allocated same-family resize +max(0, target - current); otherwise +target.
        Family quota (peak):   SideBySide same-family +target (the source keeps its current usage); otherwise = steady.
        Regional vCPUs (steady): allocated +max(0, target - current); deallocated +target.
        Regional vCPUs (peak):   SideBySide +target; otherwise = steady.
    .PARAMETER Moves
        Objects: SubscriptionId, Region, VmId, CurrentFamily, CurrentVcpu, TargetSku, TargetFamily, TargetVcpu,
        IsAllocated, and optional MigrationQuotaModel (InPlace|SideBySide).
    .PARAMETER Scope
        Optional scope label written to every row (Retirement, Retirement+Modernization, Modernization).
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Moves, [Parameter(Mandatory)][hashtable]$Usage, [double]$SafetyPct = 20, [string]$Scope)
    $familyRows = New-Object System.Collections.Generic.List[object]
    $regionalRows = New-Object System.Collections.Generic.List[object]
    $byVm = @{}
    $vmDemand = @{}

    foreach ($grp in ($Moves | Group-Object { "$($_.SubscriptionId)|$($_.Region)".ToLowerInvariant() })) {
        $pairUsage = $Usage[$grp.Name]
        $sub, $region = $grp.Name -split '\|'

        foreach ($v in $grp.Group) {
            $sameFamily = $v.CurrentFamily -and $v.TargetFamily -and $v.CurrentFamily -ieq $v.TargetFamily
            $model = if ($v.PSObject.Properties.Name -contains 'MigrationQuotaModel' -and $v.MigrationQuotaModel -eq 'SideBySide') { 'SideBySide' } else { 'InPlace' }
            $target = [int]$v.TargetVcpu
            $delta = [math]::Max(0, $target - [int]$v.CurrentVcpu)
            $steadyFamily = if ($v.IsAllocated -and $sameFamily) { $delta } else { $target }
            $steadyRegional = if ($v.IsAllocated) { $delta } else { $target }
            $vmDemand[$v.VmId] = [pscustomobject]@{
                MigrationQuotaModel = $model
                SteadyStateFamilyVcpu = $steadyFamily
                PeakMigrationFamilyVcpu = if ($model -eq 'SideBySide' -and $sameFamily) { $target } else { $steadyFamily }
                SteadyStateRegionalVcpu = $steadyRegional
                PeakMigrationRegionalVcpu = if ($model -eq 'SideBySide') { $target } else { $steadyRegional }
            }
        }

        foreach ($fg in ($grp.Group | Group-Object { if ($_.TargetFamily) { $_.TargetFamily.ToLowerInvariant() } else { '' } })) {
            $vms = @($fg.Group)
            $demand = @($vms | ForEach-Object { $vmDemand[$_.VmId] })
            $steady = Get-PropertySum $demand SteadyStateFamilyVcpu
            $peak = Get-PropertySum $demand PeakMigrationFamilyVcpu
            $alloc = Get-PropertySum @($vms | Where-Object IsAllocated | ForEach-Object { $vmDemand[$_.VmId] }) SteadyStateFamilyVcpu
            $sideBySide = @($demand | Where-Object MigrationQuotaModel -eq 'SideBySide').Count
            $familyUsage = if ($fg.Name -and $pairUsage -and $pairUsage.ContainsKey($fg.Name)) { $pairUsage[$fg.Name] } else { $null }
            $familyObj = New-QuotaImpactRow -SubscriptionId $sub -Region $region -QuotaName $fg.Name -VmCount $vms.Count `
                -TargetSkus (@($vms | ForEach-Object TargetSku | Sort-Object -Unique) -join ', ') -SteadyRequired $steady -RequiredAllocatedOnly $alloc `
                -PeakRequired $peak -SideBySideCount $sideBySide -QuotaUsage $familyUsage -SafetyPct $SafetyPct -Scope $Scope `
                -UnknownFamily:(-not $fg.Name) -UsageAvailable:([bool]$pairUsage)
            $familyRows.Add($familyObj)
            foreach ($v in $vms) {
                if (-not $byVm.ContainsKey($v.VmId)) { $byVm[$v.VmId] = @{} }
                $byVm[$v.VmId].Family = $familyObj
            }
        }

        $demand = @($grp.Group | ForEach-Object { $vmDemand[$_.VmId] })
        $regionalUsage = if ($pairUsage -and $pairUsage.ContainsKey('cores')) { $pairUsage['cores'] } else { $null }
        $regionalObj = New-QuotaImpactRow -SubscriptionId $sub -Region $region -QuotaName 'cores' -QuotaDisplayName 'Total Regional vCPUs' `
            -VmCount @($grp.Group).Count -TargetSkus '' -SteadyRequired (Get-PropertySum $demand SteadyStateRegionalVcpu) -RequiredAllocatedOnly $null `
            -PeakRequired (Get-PropertySum $demand PeakMigrationRegionalVcpu) -SideBySideCount @($demand | Where-Object MigrationQuotaModel -eq 'SideBySide').Count `
            -QuotaUsage $regionalUsage -SafetyPct $SafetyPct -Scope $Scope
        $regionalRows.Add($regionalObj)
        foreach ($m in $grp.Group) {
            if (-not $byVm.ContainsKey($m.VmId)) { $byVm[$m.VmId] = @{} }
            $byVm[$m.VmId].Regional = $regionalObj
        }
    }

    $vmStatus = @{}
    foreach ($k in $byVm.Keys) {
        $f = $byVm[$k].Family; $r = $byVm[$k].Regional; $d = $vmDemand[$k]
        $vmStatus[$k] = [pscustomobject]@{
            Status = Get-CombinedQuotaStatus @($f.Status, $r.Status)
            PeakStatus = Get-CombinedQuotaStatus @($f.PeakStatus, $r.PeakStatus)
            MigrationQuotaModel = $d.MigrationQuotaModel
            SteadyStateRequiredVcpu = [int]$d.SteadyStateFamilyVcpu
            PeakMigrationRequiredVcpu = [int]$d.PeakMigrationFamilyVcpu
            SteadyStateRegionalRequiredVcpu = [int]$d.SteadyStateRegionalVcpu
            PeakMigrationRegionalRequiredVcpu = [int]$d.PeakMigrationRegionalVcpu
            Family = $f
            Regional = $r
            DataQuality = if ($f.DataQuality -eq 'Verified' -and $r.DataQuality -eq 'Verified') { 'Verified' } elseif ($f.DataQuality -eq 'Unable to Verify' -and $r.DataQuality -eq 'Unable to Verify') { 'Unable to Verify' } else { 'Partially Verified' }
        }
    }
    [pscustomobject]@{ FamilyRows = $familyRows.ToArray(); RegionalRows = $regionalRows.ToArray(); ByVm = $vmStatus }
}
function Test-FamilyHeadroom {
    <# Returns $true when the family quota in sub/region can absorb RequiredVcpu (used for secondary-recommendation reasoning). #>
    param([hashtable]$Usage, [string]$Key, [string]$Family, [int]$RequiredVcpu)
    if (-not $Usage -or -not $Usage[$Key] -or -not $Family) { return $null }
    $u = $Usage[$Key]
    $f = $Family.ToLowerInvariant()
    if (-not $u.ContainsKey($f)) { return $null }
    return ($u[$f].Limit - $u[$f].Used) -ge $RequiredVcpu
}

Export-ModuleMember -Function Get-QuotaUsage, Get-QuotaUsages, Get-QuotaIncrease, Measure-QuotaImpact, Test-FamilyHeadroom
