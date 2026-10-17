Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'SkuCatalog.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Candidates.psm1') -DisableNameChecking

function Get-Percentile {
    param([double[]]$Values, [double]$Percentile)
    $v = @($Values | Where-Object { $null -ne $_ } | Sort-Object)
    if ($v.Count -eq 0) { return $null }
    $idx = [math]::Ceiling(($Percentile / 100) * $v.Count) - 1
    return [math]::Round($v[[math]::Max(0, [math]::Min($idx, $v.Count - 1))], 2)
}

function Get-VmUtilization {
    <#
    .SYNOPSIS
        Pulls hourly 'Percentage CPU' and 'Available Memory Bytes' for VMs via the Azure Monitor metrics batch API.
    .OUTPUTS
        Hashtable vmId(lower) -> { CpuP95, CpuMax, MemAvailP05Bytes, Samples }.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Vms,
        [int]$LookbackDays = 30,
        [string]$TenantId
    )
    $tokArgs = @('account', 'get-access-token', '--resource', 'https://metrics.monitor.azure.com')
    if ($TenantId) { $tokArgs += @('--tenant', $TenantId) }
    $token = (Invoke-AzJson -Arguments $tokArgs).accessToken
    $end = (Get-Date).ToUniversalTime()
    $start = $end.AddDays(-$LookbackDays)
    $out = @{}
    foreach ($grp in ($Vms | Group-Object { "$($_.SubscriptionId)|$($_.Region)" })) {
        $sub, $region = $grp.Name -split '\|'
        $ids = @($grp.Group | ForEach-Object Id)
        for ($i = 0; $i -lt $ids.Count; $i += 50) {
            $batch = $ids[$i..([math]::Min($i + 49, $ids.Count - 1))]
            $uri = "https://$region.metrics.monitor.azure.com/subscriptions/$sub/metrics:getBatch?starttime=$($start.ToString('s'))Z&endtime=$($end.ToString('s'))Z&interval=PT1H&metricnamespace=Microsoft.Compute/virtualMachines&metricnames=Percentage%20CPU,Available%20Memory%20Bytes&aggregation=average,maximum&api-version=2023-10-01"
            $body = @{ resourceids = @($batch) } | ConvertTo-Json -Depth 3
            $resp = $null
            for ($a = 1; $a -le 3 -and -not $resp; $a++) {
                try { $resp = Invoke-SnapshotRest -Request "POST metrics $sub $region lookback=$LookbackDays $($batch -join ',')" -Live { Invoke-RestMethod -Method Post -Uri $uri -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' -Body $body -TimeoutSec 120 } }
                catch { Write-Verbose "Metrics batch failed ($a): $($_.Exception.Message)"; if ((Get-SnapshotMode) -eq 'Replay') { break }; Start-Sleep -Seconds (3 * $a) }
            }
            if (-not $resp) { continue }
            foreach ($v in @($resp.values)) {
                $cpuAvg = @(); $cpuMax = @(); $memAvail = @()
                foreach ($m in @($v.value)) {
                    $pts = @($m.timeseries | ForEach-Object { $_.data } | Where-Object { $_ })
                    if ($m.name.value -eq 'Percentage CPU') {
                        $cpuAvg = @($pts | Where-Object { $_.PSObject.Properties.Name -contains 'average' } | ForEach-Object { [double]$_.average })
                        $cpuMax = @($pts | Where-Object { $_.PSObject.Properties.Name -contains 'maximum' } | ForEach-Object { [double]$_.maximum })
                    }
                    elseif ($m.name.value -eq 'Available Memory Bytes') {
                        $memAvail = @($pts | Where-Object { $_.PSObject.Properties.Name -contains 'average' } | ForEach-Object { [double]$_.average })
                    }
                }
                $out[$v.resourceid.ToLowerInvariant()] = [pscustomobject]@{
                    CpuP95 = Get-Percentile $cpuAvg 95
                    CpuMax = if ($cpuMax.Count) { [math]::Round(($cpuMax | Measure-Object -Maximum).Maximum, 1) } else { $null }
                    MemAvailP05Bytes = Get-Percentile $memAvail 5
                    Samples = $cpuAvg.Count
                }
            }
        }
    }
    return $out
}

function Find-HalfSize {
    <#
    .SYNOPSIS
        The size to suggest for a VM whose recommended size is Primary: the same-series size with half the vCPUs that passes the
        same mandatory checks as a migration target for this VM. Returns the size record, or $null and the reason none was chosen.
    #>
    param($Primary, [hashtable]$RegionCatalog, $Vm, $Current, $ProcessorCatalog)
    $none = { param($Reason) [pscustomobject]@{ Record = $null; Reason = $Reason } }
    if (-not $Primary -or -not $RegionCatalog) { return (& $none $null) }
    if ($Primary.vCPUs -le 2) { return (& $none 'the recommended size has 2 vCPUs or fewer') }
    if (-not $Vm -or -not $Current) { return (& $none 'the VM details needed to check a smaller size were not provided') }
    $primaryInfo = Get-SkuNameInfo -SkuName $Primary.SkuName
    # Half of the active vCPUs of a constrained-vCPU size says nothing about its memory or its price.
    if ($primaryInfo.Constrained) { return (& $none 'the recommended size is a constrained-vCPU size') }
    $half = [int]($Primary.vCPUs / 2)
    $sameSeries = New-Object System.Collections.Generic.List[object]
    foreach ($rec in $RegionCatalog.Values) {
        if ($rec.vCPUsAvailable -ne $half -or $rec.Tier -eq 'Basic') { continue }
        $info = Get-SkuNameInfo -SkuName $rec.Name
        if (-not $info.Parsed -or $info.IsPromo -or $info.SeriesKey -ne $primaryInfo.SeriesKey) { continue }
        # A constrained-vCPU size is billed for its full core count, so it saves nothing; isolated sizes are for isolated VMs.
        if ($info.Constrained) { continue }
        if ($info.Features -match 'i' -and $primaryInfo.Features -notmatch 'i') { continue }
        $sameSeries.Add($rec)
    }
    if ($sameSeries.Count -eq 0) { return (& $none "the $($primaryInfo.SeriesKey) series has no unconstrained $half-vCPU size for this VM's region and subscription") }
    $rejected = New-Object System.Collections.Generic.List[string]
    # Largest memory first, then name, so the choice never depends on the order of the catalog.
    foreach ($rec in @($sameSeries | Sort-Object @{ e = 'MemoryGB'; Descending = $true }, Name)) {
        $proc = Get-ProcessorInfo -SkuName $rec.Name -ProcessorCatalog $ProcessorCatalog -SkuRecord $rec
        $failed = @(Test-CandidateGates -Vm $Vm -Current $Current -Candidate $rec -CandidateProc $proc | Where-Object Result -eq 'Fail')
        $availability = Get-CandidateAvailability -Vm $Vm -Candidate $rec
        if ($failed.Count -eq 0 -and $availability -eq 'Available') { return [pscustomobject]@{ Record = $rec; Reason = $null } }
        $rejected.Add("$($rec.Name): $(if ($failed.Count) { ($failed | ForEach-Object { "$($_.Gate): $($_.Detail)" }) -join ' | ' } else { "availability: $availability" })")
    }
    return (& $none "no $half-vCPU size passes the mandatory checks for this VM ($($rejected -join '; '))")
}

function Get-RightsizingOpportunity {
    <#
    .SYNOPSIS
        Flags a potential rightsizing opportunity. Informational only - never changes the migration recommendation.
    .DESCRIPTION
        The signal is low CPU (the P95 of the hourly averages) and, when the guest reports available memory, low memory use over
        at least seven days. Hourly averages hide short bursts, so the highest hourly maximum is reported next to the P95.
        The suggested size has half the vCPUs of the recommended size, in the same series. It is offered only when it passes the
        same mandatory checks as a migration target for this VM (NIC and data disk limits, storage, networking, zone and region
        availability and so on); constrained-vCPU sizes are never suggested. Without -Vm and -Current the signal is still
        reported but no size is suggested, because the checks cannot be run.
    #>
    param(
        $Utilization,
        $Primary,
        [hashtable]$RegionCatalog,
        [double]$MemoryGB,
        $Vm,
        $Current,
        $ProcessorCatalog,
        [int]$MinSamples = 24 * 7,
        [double]$CpuThresholdPct = 20,
        [double]$MemThresholdPct = 40
    )
    if (-not $Utilization -or $Utilization.Samples -lt $MinSamples) {
        return [pscustomobject]@{ Status = 'Insufficient Data'; CpuP95 = $(if ($Utilization) { $Utilization.CpuP95 } else { $null }); MemUsedP95Pct = $null; SuggestedSku = $null; Note = 'Less than 7 days of hourly metrics (or metrics unavailable)' }
    }
    # Zero bytes available is the busiest case, not a missing metric.
    $memUsed = if ($null -ne $Utilization.MemAvailP05Bytes -and $MemoryGB) { [math]::Round((1 - ($Utilization.MemAvailP05Bytes / ($MemoryGB * 1GB))) * 100, 1) } else { $null }
    $cpuLow = $null -ne $Utilization.CpuP95 -and $Utilization.CpuP95 -lt $CpuThresholdPct
    $memLow = $null -eq $memUsed -or $memUsed -lt $MemThresholdPct
    if (-not ($cpuLow -and $memLow)) {
        return [pscustomobject]@{ Status = 'No Opportunity'; CpuP95 = $Utilization.CpuP95; MemUsedP95Pct = $memUsed; SuggestedSku = $null; Note = '' }
    }
    $half = Find-HalfSize -Primary $Primary -RegionCatalog $RegionCatalog -Vm $Vm -Current $Current -ProcessorCatalog $ProcessorCatalog
    $peakProperty = $Utilization.PSObject.Properties['CpuMax']
    $peak = if ($peakProperty -and $null -ne $peakProperty.Value) { ", highest hourly maximum $($peakProperty.Value)%" } else { '' }
    $noSize = if ($half.Reason) { " No smaller size is suggested: $($half.Reason)." } else { '' }
    [pscustomobject]@{
        Status = 'Potential Rightsizing Opportunity'; CpuP95 = $Utilization.CpuP95; MemUsedP95Pct = $memUsed
        SuggestedSku = if ($half.Record) { $half.Record.Name } else { $null }
        Note = "P95 of hourly average CPU $($Utilization.CpuP95)%$peak / memory used $(if ($null -ne $memUsed) { "$memUsed%" } else { 'n/a (guest metric unavailable)' }).$noSize Evaluate after migration; not applied to the retirement recommendation."
    }
}

Export-ModuleMember -Function Get-Percentile, Get-VmUtilization, Get-RightsizingOpportunity
