Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

function ConvertTo-SkuRecord {
    <#
    .SYNOPSIS
        Normalizes one Microsoft.Compute/skus entry (virtualMachines) into a flat capability record.
    #>
    param([Parameter(Mandatory)]$Sku, [Parameter(Mandatory)][string]$Region)
    $p = { param($o, $n) if ($null -ne $o -and $o.PSObject.Properties.Name -contains $n) { $o.$n } else { $null } }
    $cap = @{}
    foreach ($c in @(& $p $Sku 'capabilities')) { if ($c) { $cap[$c.name] = [string]$c.value } }
    $num = { param($k) if ($cap.ContainsKey($k) -and $cap[$k] -match '^-?\d+(\.\d+)?$') { [double]$cap[$k] } else { $null } }
    $bool = { param($k) if ($cap.ContainsKey($k)) { $cap[$k] -eq 'True' } else { $null } }
    $list = { param($k) if ($cap.ContainsKey($k) -and $cap[$k]) { @($cap[$k] -split '\s*,\s*' | Where-Object { $_ }) } else { @() } }

    $loc = @(& $p $Sku 'locationInfo') | Where-Object { $_ -and $_.location -and $_.location -ieq $Region } | Select-Object -First 1
    if (-not $loc) { $loc = @(& $p $Sku 'locationInfo') | Select-Object -First 1 }
    $zones = if ($loc -and $loc.PSObject.Properties.Name -contains 'zones' -and $loc.zones) { @($loc.zones | Sort-Object) } else { @() }
    $ultraZones = @()
    if ($loc -and $loc.PSObject.Properties.Name -contains 'zoneDetails' -and $loc.zoneDetails) {
        foreach ($zd in @($loc.zoneDetails)) {
            $zcaps = @(& $p $zd 'capabilities')
            if ($zcaps | Where-Object { $_.name -eq 'UltraSSDAvailable' -and $_.value -eq 'True' }) {
                $zn = if ($zd.PSObject.Properties.Name -contains 'name') { $zd.name } else { $zd.Name }
                $ultraZones += @($zn)
            }
        }
    }
    $locationRestricted = $false; $restrictedZones = @(); $reasons = @()
    foreach ($r in @(& $p $Sku 'restrictions')) {
        if (-not $r) { continue }
        $ri = & $p $r 'restrictionInfo'
        $locations = @(& $p $ri 'locations' | Where-Object { $_ })
        if ($locations.Count -eq 0) {
            $values = @(& $p $r 'values' | Where-Object { $_ })
            if ((& $p $r 'type') -eq 'Location') { $locations = $values }
        }
        if ($locations.Count -gt 0 -and -not ($locations | Where-Object { $_ -ieq $Region })) { continue }
        $reasons += (& $p $r 'reasonCode')
        if ((& $p $r 'type') -eq 'Location') { $locationRestricted = $true }
        elseif ((& $p $r 'type') -eq 'Zone') {
            $zonesForRestriction = @(& $p $ri 'zones' | Where-Object { $_ })
            if ($zonesForRestriction.Count -eq 0) { $zonesForRestriction = @(& $p $r 'values' | Where-Object { $_ }) }
            $restrictedZones += $zonesForRestriction
        }
    }
    $tempMb = & $num 'MaxResourceVolumeMB'
    $vcpu = & $num 'vCPUs'
    $vcpuAvail = & $num 'vCPUsAvailable'
    [pscustomobject]@{
        Name                    = $Sku.name
        Region                  = $Region.ToLowerInvariant()
        Family                  = & $p $Sku 'family'
        Tier                    = & $p $Sku 'tier'
        vCPUs                   = if ($vcpu) { [int]$vcpu } else { $null }
        vCPUsAvailable          = if ($vcpuAvail) { [int]$vcpuAvail } elseif ($vcpu) { [int]$vcpu } else { $null }
        MemoryGB                = & $num 'MemoryGB'
        TempDiskGB              = if ($null -ne $tempMb) { [math]::Round($tempMb / 1024, 0) } else { $null }
        HasTempDisk             = if ($null -ne $tempMb) { $tempMb -gt 0 } else { $null }
        NvmeDiskSizeGiB         = if ((& $num 'NvmeDiskSizeInMiB')) { [math]::Round((& $num 'NvmeDiskSizeInMiB') / 1024, 0) } else { $null }
        PremiumIO               = & $bool 'PremiumIO'
        AcceleratedNetworking   = & $bool 'AcceleratedNetworkingEnabled'
        MaxNICs                 = & $num 'MaxNetworkInterfaces'
        MaxDataDisks            = & $num 'MaxDataDiskCount'
        UncachedDiskIOPS        = & $num 'UncachedDiskIOPS'
        UncachedDiskMBps        = if ((& $num 'UncachedDiskBytesPerSecond')) { [math]::Round((& $num 'UncachedDiskBytesPerSecond') / 1MB, 0) } else { $null }
        CachedIOPS              = & $num 'CombinedTempDiskAndCachedIOPS'
        CachedMBps              = if ((& $num 'CombinedTempDiskAndCachedReadBytesPerSecond')) { [math]::Round((& $num 'CombinedTempDiskAndCachedReadBytesPerSecond') / 1MB, 0) } else { $null }
        HyperVGenerations       = @(& $list 'HyperVGenerations')
        CpuArchitecture         = if ($cap.ContainsKey('CpuArchitectureType')) { $cap['CpuArchitectureType'] } else { $null }
        EphemeralOSDisk         = & $bool 'EphemeralOSDiskSupported'
        EphemeralPlacements     = @(& $list 'SupportedEphemeralOSDiskPlacements')
        EncryptionAtHost        = & $bool 'EncryptionAtHostSupported'
        TrustedLaunchDisabled   = & $bool 'TrustedLaunchDisabled'
        ConfidentialType        = if ($cap.ContainsKey('ConfidentialComputingType')) { $cap['ConfidentialComputingType'] } else { $null }
        DiskControllerTypes     = @($ctl = @(& $list 'DiskControllerTypes'); if ($ctl.Count -gt 0) { $ctl } else { @('SCSI') })
        DiskControllerReported  = $cap.ContainsKey('DiskControllerTypes')
        MaxWriteAccelDisks      = & $num 'MaxWriteAcceleratorDisksAllowed'
        GPUs                    = & $num 'GPUs'
        RdmaEnabled             = & $bool 'RdmaEnabled'
        LowPriorityCapable      = & $bool 'LowPriorityCapable'
        CapacityReservation     = & $bool 'CapacityReservationSupported'
        UltraSSDRegional        = & $bool 'UltraSSDAvailable'
        UltraSSDZones           = @($ultraZones | Sort-Object -Unique)
        Zones                   = $zones
        LocationRestricted      = $locationRestricted
        RestrictedZones         = @($restrictedZones | Sort-Object -Unique)
        RestrictionReasons      = @($reasons | Where-Object { $_ } | Sort-Object -Unique)
        # Not exposed by the Resource SKUs API; left explicit so outputs never imply verification.
        NetworkBandwidthMbps    = $null
        NestedVirtualization    = $null
    }
}

function Get-RegionSkuCatalog {
    <#
    .SYNOPSIS
        Returns VM size records for a subscription + region (capabilities + subscription-specific restrictions).
    .DESCRIPTION
        Uses the Microsoft.Compute/skus REST API with a token for the subscription's own tenant (about 15x faster
        than 'az vm list-skus' and tenant-independent); falls back to 'az vm list-skus --all' if REST fails.
    #>
    param([Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$Region, [string]$RawCachePath)
    $raw = $null
    try {
        $tok = (Invoke-AzJson -Arguments @('account', 'get-access-token', '--subscription', $SubscriptionId, '--resource', 'https://management.azure.com')).accessToken
        $url = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Compute/skus?api-version=2021-07-01&`$filter=location eq '$Region'"
        $items = New-Object System.Collections.Generic.List[object]
        $pages = 0
        while ($url -and $pages -lt 50) {
            $resp = $null
            for ($attempt = 1; $attempt -le 3 -and -not $resp; $attempt++) {
                try { $resp = Invoke-SnapshotRest -Request "GET $url" -Live { Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $tok" } -TimeoutSec 180 } }
                catch { if ($attempt -eq 3) { throw }; Start-Sleep -Seconds (2 * $attempt) }
            }
            foreach ($v in @($resp.value)) { if ($v) { $items.Add($v) } }
            $url = if ($resp.PSObject.Properties.Name -contains 'nextLink') { $resp.nextLink } else { $null }
            $pages++
        }
        $raw = $items.ToArray()
    }
    catch {
        Write-Verbose "Compute SKUs REST failed for $SubscriptionId/$Region ($($_.Exception.Message)); falling back to az vm list-skus."
        $raw = $null
    }
    if (-not $raw -or @($raw).Count -eq 0) {
        $raw = Invoke-AzJson -Arguments @('vm', 'list-skus', '--location', $Region, '--resource-type', 'virtualMachines', '--all', '--subscription', $SubscriptionId) -AllowFailure
    }
    if ($RawCachePath -and $raw) { $raw | ConvertTo-Json -Depth 20 -Compress | Out-File $RawCachePath -Encoding utf8 }
    $dict = @{}
    foreach ($s in @($raw)) {
        if (-not $s -or $s.resourceType -ne 'virtualMachines') { continue }
        $dict[$s.name.ToLowerInvariant()] = ConvertTo-SkuRecord -Sku $s -Region $Region
    }
    return $dict
}

function Get-SkuCatalogs {
    <#
    .SYNOPSIS
        Fetches SKU catalogs for many subscription/region pairs in parallel (az CLI, read-only).
    .OUTPUTS
        Hashtable keyed "subscriptionId|region" -> hashtable skuNameLower -> SKU record.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Pairs,
        [string]$RawCacheDir,
        [int]$ThrottleLimit = 6
    )
    $modulePath = Join-Path $PSScriptRoot 'SkuCatalog.psm1'
    $results = $Pairs | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        Import-Module $using:modulePath -DisableNameChecking
        $p = $_
        $cache = if ($using:RawCacheDir) { Join-Path $using:RawCacheDir ("skus-{0}-{1}.json" -f $p.SubscriptionId, $p.Region) } else { $null }
        try {
            $cat = Get-RegionSkuCatalog -SubscriptionId $p.SubscriptionId -Region $p.Region -RawCachePath $cache
            [pscustomobject]@{ Key = "$($p.SubscriptionId)|$($p.Region)".ToLowerInvariant(); Catalog = $cat; Error = $null }
        }
        catch {
            [pscustomobject]@{ Key = "$($p.SubscriptionId)|$($p.Region)".ToLowerInvariant(); Catalog = @{}; Error = $_.Exception.Message }
        }
    }
    $out = @{}
    foreach ($r in @($results)) {
        $out[$r.Key] = $r.Catalog
        if ($r.Error) { Write-Warning "Could not retrieve the subscription-scoped SKU catalog for $($r.Key): $($r.Error). Recommendations for this scope will remain unavailable." }
    }
    return $out
}

function Get-ProcessorInfo {
    <#
    .SYNOPSIS
        Resolves CPU vendor/architecture/processor models for a VM size.
        Priority: Microsoft Learn processor catalog (Verified) -> SKU CpuArchitectureType + naming convention (Partially Verified).
    #>
    param([Parameter(Mandatory)][string]$SkuName, $ProcessorCatalog, $SkuRecord)
    $info = Get-SkuNameInfo -SkuName $SkuName
    $entry = $null
    $entryQuality = 'Partially Verified'
    if ($ProcessorCatalog -and $info.Parsed) {
        if ($info.SeriesKey -and ($ProcessorCatalog.series.PSObject.Properties.Name -contains $info.SeriesKey)) {
            $entry = $ProcessorCatalog.series.$($info.SeriesKey)
            $entryQuality = 'Verified'
        }
        elseif ($info.BaseKey -and ($ProcessorCatalog.series.PSObject.Properties.Name -contains $info.BaseKey)) {
            $entry = $ProcessorCatalog.series.$($info.BaseKey)
        }
    }
    $arch = if ($SkuRecord -and $SkuRecord.CpuArchitecture) { $SkuRecord.CpuArchitecture } elseif ($entry) { $entry.architecture } elseif ($info.VendorHint -eq 'ARM') { 'Arm64' } elseif ($info.Parsed) { 'x64' } else { 'Unknown' }
    $archQuality = if ($SkuRecord -and $SkuRecord.CpuArchitecture) { 'Verified' } elseif ($entry) { $entryQuality } else { 'Partially Verified' }
    if ($entry -and $entry.vendor -in 'Intel', 'AMD', 'ARM') {
        $models = @($entry.processors | ForEach-Object { $_.Model })
        $gens = @($entry.processors | ForEach-Object { $_.Generation } | Where-Object { $_ })
        return [pscustomobject]@{
            Vendor = $entry.vendor; Architecture = $arch; Processors = $models; Generations = $gens
            VendorQuality = $entryQuality; ArchitectureQuality = $archQuality; VendorSource = $entry.sourceUrl
        }
    }
    $vendor = if ($arch -eq 'Arm64') { 'ARM' } else { $info.VendorHint }
    [pscustomobject]@{
        Vendor = $vendor; Architecture = $arch; Processors = @(); Generations = @()
        VendorQuality = 'Partially Verified'; ArchitectureQuality = $archQuality
        VendorSource = 'https://learn.microsoft.com/azure/virtual-machines/vm-naming-conventions'
    }
}

function Get-RetailPrices {
    <#
    .SYNOPSIS
        Pay-as-you-go hourly retail prices (USD) for the given SKUs in a region. Informational only.
    .OUTPUTS
        Hashtable "skuName|Linux" / "skuName|Windows" -> hourly price.
    #>
    param([Parameter(Mandatory)][string]$Region, [Parameter(Mandatory)][string[]]$SkuNames)
    $want = @{}; foreach ($s in $SkuNames) { if ($s) { $want[$s.ToLowerInvariant()] = $true } }
    $prices = @{}
    $url = "https://prices.azure.com/api/retail/prices?`$filter=serviceName eq 'Virtual Machines' and armRegionName eq '$Region' and priceType eq 'Consumption'"
    $page = 0
    while ($url -and $page -lt 200) {
        $resp = $null
        for ($i = 1; $i -le 3 -and -not $resp; $i++) {
            try { $resp = Invoke-RestMethod -Uri $url -TimeoutSec 60 } catch { Start-Sleep -Seconds (2 * $i) }
        }
        if (-not $resp) { break }
        foreach ($it in $resp.Items) {
            if ($it.unitOfMeasure -ne '1 Hour' -or -not $it.armSkuName) { continue }
            if ($it.skuName -match 'Spot|Low Priority') { continue }
            $k = $it.armSkuName.ToLowerInvariant()
            if (-not $want.ContainsKey($k)) { continue }
            $os = if ($it.productName -match 'Windows') { 'Windows' } else { 'Linux' }
            $key = "$k|$os"
            if (-not $prices.ContainsKey($key) -or $it.retailPrice -lt $prices[$key]) { $prices[$key] = [double]$it.retailPrice }
        }
        $url = $resp.NextPageLink; $page++
    }
    return $prices
}

Export-ModuleMember -Function ConvertTo-SkuRecord, Get-RegionSkuCatalog, Get-SkuCatalogs, Get-ProcessorInfo, Get-RetailPrices
