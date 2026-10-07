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

function Measure-QuotaImpact {
    <#
    .SYNOPSIS
        Aggregates migration demand per subscription/region/target family and per regional vCPU total.
    .DESCRIPTION
        Demand is summed across every VM moving into the same target family (not validated per VM in isolation).
        In-place resize model: target family needs +target vCPU for every migrated VM (allocated or deallocated, because a
        deallocated VM consumes quota when started). Regional total vCPUs needs +(target - current) for allocated VMs
        and +target for deallocated VMs.
    .PARAMETER Moves
        Objects: SubscriptionId, Region, VmId, CurrentFamily, CurrentVcpu, TargetSku, TargetFamily, TargetVcpu, IsAllocated.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Moves, [Parameter(Mandatory)][hashtable]$Usage, [double]$SafetyPct = 20)
    $familyRows = New-Object System.Collections.Generic.List[object]
    $regionalRows = New-Object System.Collections.Generic.List[object]
    $byVm = @{}

    foreach ($grp in ($Moves | Group-Object { "$($_.SubscriptionId)|$($_.Region)".ToLowerInvariant() })) {
        $pairUsage = $Usage[$grp.Name]
        $sub, $region = $grp.Name -split '\|'
        foreach ($fg in ($grp.Group | Group-Object { if ($_.TargetFamily) { $_.TargetFamily.ToLowerInvariant() } else { '' } })) {
            $vms = @($fg.Group)
            $required = 0
            $requiredAlloc = 0
            foreach ($v in $vms) {
                $sameFamily = $v.CurrentFamily -and $v.TargetFamily -and $v.CurrentFamily -ieq $v.TargetFamily
                $demand = if ($v.IsAllocated -and $sameFamily) {
                    [math]::Max(0, [int]$v.TargetVcpu - [int]$v.CurrentVcpu)
                }
                else {
                    [int]$v.TargetVcpu
                }
                $required += $demand
                if ($v.IsAllocated) { $requiredAlloc += $demand }
            }
            $row = [ordered]@{
                SubscriptionId = $sub; Region = $region; QuotaName = $fg.Name; QuotaDisplayName = $null
                VmCount = $vms.Count; TargetSkus = (@($vms | ForEach-Object TargetSku | Sort-Object -Unique) -join ', ')
                Limit = $null; CurrentUsage = $null; Remaining = $null; RequiredVcpu = $required; RequiredVcpuAllocatedOnly = $requiredAlloc
                PostMigrationUsage = $null; MinimumIncrease = $null; RecommendedIncrease = $null; RecommendedNewLimit = $null
                Status = 'Quota Information Unavailable'; DataQuality = 'Unable to Verify'
            }
            if (-not $fg.Name) { $row.Status = 'Manual Validation Required'; $row.QuotaName = '(unknown family)' }
            elseif ($pairUsage -and $pairUsage.ContainsKey($fg.Name)) {
                $q = $pairUsage[$fg.Name]
                $calc = Get-QuotaIncrease -Limit $q.Limit -Used $q.Used -Required $required -SafetyPct $SafetyPct
                $row.QuotaDisplayName = $q.LocalName; $row.Limit = $calc.Limit; $row.CurrentUsage = $calc.Used; $row.Remaining = $calc.Remaining
                $row.PostMigrationUsage = $calc.PostMigrationUsage; $row.MinimumIncrease = $calc.MinimumIncrease
                $row.RecommendedIncrease = $calc.RecommendedIncrease; $row.RecommendedNewLimit = $calc.RecommendedNewLimit
                $row.Status = $calc.Status; $row.DataQuality = 'Verified'
            }
            elseif ($pairUsage) { $row.Status = 'Manual Validation Required'; $row.DataQuality = 'Partially Verified' }
            $familyRows.Add([pscustomobject]$row)
            foreach ($v in $vms) { $byVm[$v.VmId] = @{ Family = [pscustomobject]$row } }
        }

        $delta = 0
        foreach ($m in $grp.Group) { $delta += if ($m.IsAllocated) { [math]::Max(0, [int]$m.TargetVcpu - [int]$m.CurrentVcpu) } else { [int]$m.TargetVcpu } }
        $reg = [ordered]@{
            SubscriptionId = $sub; Region = $region; QuotaName = 'cores'; QuotaDisplayName = 'Total Regional vCPUs'
            VmCount = @($grp.Group).Count; TargetSkus = ''; Limit = $null; CurrentUsage = $null; Remaining = $null
            RequiredVcpu = $delta; RequiredVcpuAllocatedOnly = $null; PostMigrationUsage = $null; MinimumIncrease = $null
            RecommendedIncrease = $null; RecommendedNewLimit = $null; Status = 'Quota Information Unavailable'; DataQuality = 'Unable to Verify'
        }
        if ($pairUsage -and $pairUsage.ContainsKey('cores')) {
            $q = $pairUsage['cores']
            $calc = Get-QuotaIncrease -Limit $q.Limit -Used $q.Used -Required $delta -SafetyPct $SafetyPct
            $reg.Limit = $calc.Limit; $reg.CurrentUsage = $calc.Used; $reg.Remaining = $calc.Remaining
            $reg.PostMigrationUsage = $calc.PostMigrationUsage; $reg.MinimumIncrease = $calc.MinimumIncrease
            $reg.RecommendedIncrease = $calc.RecommendedIncrease; $reg.RecommendedNewLimit = $calc.RecommendedNewLimit
            $reg.Status = $calc.Status; $reg.DataQuality = 'Verified'
        }
        $regionalRows.Add([pscustomobject]$reg)
        foreach ($m in $grp.Group) { $byVm[$m.VmId].Regional = [pscustomobject]$reg }
    }

    $vmStatus = @{}
    foreach ($k in $byVm.Keys) {
        $f = $byVm[$k].Family; $r = $byVm[$k].Regional
        $statuses = @($f.Status, $r.Status)
        $status = if ($statuses -contains 'Quota Information Unavailable') { 'Quota Information Unavailable' }
        elseif ($statuses -contains 'Manual Validation Required') { 'Manual Validation Required' }
        elseif ($statuses -contains 'Quota Increase Required') { 'Quota Increase Required' }
        else { 'Quota OK' }
        $vmStatus[$k] = [pscustomobject]@{
            Status = $status; Family = $f; Regional = $r
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
