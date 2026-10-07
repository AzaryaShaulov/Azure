<#
.SYNOPSIS
    Refreshes the cached catalogs used by the VM SKU retirement assessment.
.DESCRIPTION
    - data/retirement-catalog.json : merged Microsoft Learn lifecycle evidence (retired list, previous-gen list, migration guide).
    - data/processor-catalog.json  : CPU vendor / processor / architecture per VM size series, scraped from the
                                     Microsoft Learn size-series spec pages (MicrosoftDocs/azure-compute-docs, public repo).
    Read-only against Azure; only writes the two JSON files under data/.
.EXAMPLE
    pwsh ./Update-Catalogs.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipRetirement,
    [switch]$SkipProcessor,
    [int]$ThrottleLimit = 10
)
$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'modules/Retirement.psm1') -Force -DisableNameChecking

if (-not $SkipRetirement) {
    Write-Host 'Refreshing retirement catalog from Microsoft Learn...'
    $r = Get-RetirementCatalog -SeriesMapPath (Join-Path $skillRoot 'data/series-map.json') -CachePath (Join-Path $skillRoot 'data/retirement-catalog.json') -UpdateCache
    if ($r.Source -ne 'Live') { throw "Live fetch failed; cache not updated. $($r.Warning)" }
    Write-Host ("  {0} series, {1} unmapped, {2} non-VM-size entries" -f @($r.Catalog.series).Count, @(Get-UnmappedSeriesNames -Catalog $r.Catalog).Count, @(Get-NonVmSizeEntries -Catalog $r.Catalog).Count)
    foreach ($u in @(Get-UnmappedSeriesNames -Catalog $r.Catalog)) { Write-Warning "Unmapped Learn series: $u - add it to data/series-map.json" }
}

if (-not $SkipProcessor) {
    Write-Host 'Refreshing processor catalog from Microsoft Learn size pages...'
    $repo = 'MicrosoftDocs/azure-compute-docs'
    $raw = "https://raw.githubusercontent.com/$repo/main/articles/virtual-machines/sizes"
    $learn = 'https://learn.microsoft.com/azure/virtual-machines/sizes'
    # Optional token avoids the 60 requests/hour anonymous GitHub API limit (CI, frequent maintainers).
    $ghHeaders = @{ 'User-Agent' = 'VMSKURetirementReport' }
    $tok = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } elseif ($env:GH_TOKEN) { $env:GH_TOKEN } else { $null }
    if ($tok) { $ghHeaders['Authorization'] = "Bearer $tok" }
    $categories = 'general-purpose', 'memory-optimized', 'compute-optimized', 'storage-optimized', 'gpu-accelerated', 'fpga-accelerated', 'high-performance-compute'
    $categoryFailures = New-Object System.Collections.Generic.List[string]
    $files = foreach ($c in $categories) {
        try {
            $items = Invoke-RestMethod "https://api.github.com/repos/$repo/contents/articles/virtual-machines/sizes/$c" -Headers $ghHeaders
            $items | Where-Object { $_.name -like '*-series.md' } | ForEach-Object { [pscustomobject]@{ Category = $c; File = $_.name } }
        }
        catch { $categoryFailures.Add("$c ($($_.Exception.Message))") }
    }
    if ($categoryFailures.Count -gt 0) { throw "Processor catalog refresh incomplete; category listing failed: $($categoryFailures -join '; ')" }
    Write-Host "  $(@($files).Count) series pages"

    $results = $files | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $f = $_; $raw = $using:raw; $learn = $using:learn
        $base = $f.File -replace '-series\.md$', ''
        $page = "$raw/$($f.Category)/$($f.File)"
        try {
            $md = (Invoke-WebRequest $page -TimeoutSec 30).Content
            $inc = [regex]::Match($md, '\[!INCLUDE \[[^\]]*specs[^\]]*\]\(([^)]+)\)')
            $specText = if ($inc.Success) {
                $rel = $inc.Groups[1].Value -replace '^\./', ''
                (Invoke-WebRequest "$raw/$($f.Category)/$rel" -TimeoutSec 30).Content
            }
            else { $md }
            $row = ($specText -split "`n") | Where-Object { $_ -match '^\|\s*Processor\s*\|' } | Select-Object -First 1
            if (-not $row) {
                # Older pages describe processors in prose instead of a spec table.
                $mentions = @([regex]::Matches(($md -replace '[\u00AE\u2122]', ''), '((?:\d+(?:st|nd|rd|th) Generation )?(?:Intel|AMD)\s[^,.;()]*?\(([^)]+)\)|Ampere[^,.;]*|Azure Cobalt \d+)') | ForEach-Object { $_.Groups[1].Value.Trim() } | Select-Object -Unique)
                if ($mentions.Count -eq 0) { return [pscustomobject]@{ Series = $base; Category = $f.Category; Found = $false; Page = $page } }
                $procCell = ($mentions -join '<br>') + ' '
            }
            else {
                $cells = $row.Trim().Trim('|') -split '\|'
                $procCell = $cells[-1]
            }
            $procs = @(($procCell -split '<br\s*/?>') | ForEach-Object { ($_ -replace '<[^>]+>', '').Trim() } | Where-Object { $_ })
            $parsed = foreach ($p in $procs) {
                $vendor = if ($p -match 'Intel') { 'Intel' } elseif ($p -match 'AMD') { 'AMD' } elseif ($p -match 'Ampere|Cobalt|Grace|Arm64|ARM') { 'ARM' } else { 'Unknown' }
                $arch = if ($p -match '\[(x86-64|x64)\]') { 'x64' } elseif ($p -match '\[Arm64\]|Ampere|Cobalt|Grace') { 'Arm64' } elseif ($vendor -in 'Intel', 'AMD') { 'x64' } else { 'Unknown' }
                $gen = [regex]::Match($p, '\(([^)]+)\)')
                [pscustomobject]@{ Model = ($p -replace '\s*\[[^\]]+\]\s*', '').Trim(); Vendor = $vendor; Architecture = $arch; Generation = if ($gen.Success) { $gen.Groups[1].Value } else { $null } }
            }
            $vendors = @($parsed | ForEach-Object Vendor | Where-Object { $_ -ne 'Unknown' } | Select-Object -Unique)
            $archs = @($parsed | ForEach-Object Architecture | Where-Object { $_ -ne 'Unknown' } | Select-Object -Unique)
            [pscustomobject]@{
                Series = $base; Category = $f.Category; Found = $true
                Vendor = if ($vendors.Count -eq 1) { $vendors[0] } elseif ($vendors.Count -gt 1) { 'Mixed' } else { 'Unknown' }
                Architecture = if ($archs.Count -eq 1) { $archs[0] } elseif ($archs.Count -gt 1) { 'Mixed' } else { 'Unknown' }
                Processors = @($parsed)
                SourceUrl = "$learn/$($f.Category)/$base-series"
            }
        }
        catch { [pscustomobject]@{ Series = $base; Category = $f.Category; Found = $false; Page = $page; Error = $_.Exception.Message } }
    }

    # Series doc names that differ from the key produced by Get-SkuNameInfo for actual SKU names.
    $aliases = @{
        'bv1' = @('bs', 'bms', 'bls'); 'av2' = @('av2', 'amv2'); 'ev3-esv3' = @('ev3', 'esv3', 'eiv3', 'eisv3')
        'ev4' = @('ev4', 'eiv4'); 'esv4' = @('esv4', 'eisv4'); 'ncv3' = @('ncsv3', 'ncrsv3'); 'nvv3' = @('nvsv3'); 'nvv4' = @('nvasv4')
        'lsv2' = @('lsv2'); 'fsv2' = @('fsv2'); 'dv2' = @('dv2'); 'dsv2' = @('dsv2')
        'ebdsv5-ebsv5' = @('ebdsv5', 'ebsv5')
    }
    $pageFailures = @($results | Where-Object { -not $_.Found })
    if ($pageFailures.Count -gt 0) {
        throw "Processor catalog refresh incomplete; $($pageFailures.Count) page(s) had no verified processor data: $((@($pageFailures | Select-Object -First 10 | ForEach-Object Series)) -join ', ')"
    }
    $series = [ordered]@{}
    foreach ($r in ($results | Sort-Object Series)) {
        if (-not $r.Found) { Write-Warning "No processor row: $($r.Series)"; continue }
        $keys = if ($aliases.ContainsKey($r.Series)) { $aliases[$r.Series] } else { @($r.Series -replace '-', '') }
        foreach ($k in $keys) {
            $series[$k] = [ordered]@{
                docSeries = $r.Series; category = $r.Category; vendor = $r.Vendor; architecture = $r.Architecture
                processors = $r.Processors; sourceUrl = $r.SourceUrl
            }
        }
    }
    $catalog = [ordered]@{
        schemaVersion = '1.0'
        generatedUtc  = (Get-Date).ToUniversalTime().ToString('o')
        source        = "https://github.com/$repo (Microsoft Learn size-series spec pages)"
        note          = 'CPU vendor per series from the Processor row of each Microsoft Learn size-series spec table. Series absent here fall back to the Azure VM naming convention (Partially Verified).'
        series        = $series
    }
    $out = Join-Path $skillRoot 'data/processor-catalog.json'
    $existingCount = if (Test-Path -LiteralPath $out) {
        $existing = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json -Depth 10
        @($existing.series.PSObject.Properties).Count
    }
    else { 0 }
    if ($series.Count -eq 0 -or ($existingCount -gt 0 -and $series.Count -lt [math]::Floor($existingCount * 0.9))) {
        throw "Processor catalog validation failed: generated $($series.Count) keys; existing catalog has $existingCount. Existing catalog preserved."
    }
    $tmp = "$out.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $catalog | ConvertTo-Json -Depth 10 | Out-File $tmp -Encoding utf8
        $check = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json -Depth 10
        if (@($check.series.PSObject.Properties).Count -ne $series.Count) { throw 'Processor catalog round-trip validation failed.' }
        Move-Item -LiteralPath $tmp -Destination $out -Force
    }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    Write-Host "  wrote $($series.Count) series keys -> $out"
}
