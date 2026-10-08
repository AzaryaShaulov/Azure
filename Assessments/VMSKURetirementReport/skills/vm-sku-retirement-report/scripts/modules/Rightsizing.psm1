Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

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

function Get-RightsizingOpportunity {
    <#
    .SYNOPSIS
        Flags a potential rightsizing opportunity. Informational only - never changes the migration recommendation.
    #>
    param(
        $Utilization,
        $Primary,
        [hashtable]$RegionCatalog,
        [double]$MemoryGB,
        [int]$MinSamples = 24 * 7,
        [double]$CpuThresholdPct = 20,
        [double]$MemThresholdPct = 40
    )
    if (-not $Utilization -or $Utilization.Samples -lt $MinSamples) {
        return [pscustomobject]@{ Status = 'Insufficient Data'; CpuP95 = $(if ($Utilization) { $Utilization.CpuP95 } else { $null }); MemUsedP95Pct = $null; SuggestedSku = $null; Note = 'Less than 7 days of hourly metrics (or metrics unavailable)' }
    }
    $memUsed = if ($Utilization.MemAvailP05Bytes -and $MemoryGB) { [math]::Round((1 - ($Utilization.MemAvailP05Bytes / ($MemoryGB * 1GB))) * 100, 1) } else { $null }
    $cpuLow = $null -ne $Utilization.CpuP95 -and $Utilization.CpuP95 -lt $CpuThresholdPct
    $memLow = $null -eq $memUsed -or $memUsed -lt $MemThresholdPct
    if (-not ($cpuLow -and $memLow)) {
        return [pscustomobject]@{ Status = 'No Opportunity'; CpuP95 = $Utilization.CpuP95; MemUsedP95Pct = $memUsed; SuggestedSku = $null; Note = '' }
    }
    $suggest = $null
    if ($Primary -and $RegionCatalog -and $Primary.vCPUs -gt 2) {
        $pInfo = Get-SkuNameInfo -SkuName $Primary.SkuName
        $half = [int]($Primary.vCPUs / 2)
        $suggest = $RegionCatalog.Values | Where-Object {
            $i = Get-SkuNameInfo -SkuName $_.Name
            $i.SeriesKey -eq $pInfo.SeriesKey -and $_.vCPUsAvailable -eq $half -and -not $_.LocationRestricted
        } | Select-Object -First 1
    }
    [pscustomobject]@{
        Status = 'Potential Rightsizing Opportunity'; CpuP95 = $Utilization.CpuP95; MemUsedP95Pct = $memUsed
        SuggestedSku = if ($suggest) { $suggest.Name } else { $null }
        Note = "P95 CPU $($Utilization.CpuP95)% / memory used $(if ($null -ne $memUsed) { "$memUsed%" } else { 'n/a (guest metric unavailable)' }). Evaluate after migration; not applied to the retirement recommendation."
    }
}

Export-ModuleMember -Function Get-Percentile, Get-VmUtilization, Get-RightsizingOpportunity
