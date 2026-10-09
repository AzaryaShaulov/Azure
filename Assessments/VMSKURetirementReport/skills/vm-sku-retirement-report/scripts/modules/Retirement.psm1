Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

# Microsoft renamed these pages in September 2026 (old URLs redirect): retired-sizes-list -> retirements-and-capacity-restrictions,
# previous-gen-sizes-list -> end-of-life-sizes-list, d-ds-dv2-dsv2-ls-series-migration-guide -> retired-sizes-modernization-guide.
$script:RetiredListUrl = 'https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions'
$script:PreviousGenUrl = 'https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/end-of-life-sizes-list'
$script:MigrationGuideUrl = 'https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirement/retired-sizes-modernization-guide'
$script:LearnBase = 'https://learn.microsoft.com'

function ConvertTo-NormalizedSeriesName {
    param([AllowEmptyString()][string]$Name)
    $n = ($Name -replace '<[^>]+>', ' ' -replace '&amp;', '&' -replace '[\*\[\]\(\)]', ' ').ToLowerInvariant()
    $n = $n -replace '-series\b', '' -replace '\bseries\b', ''
    $n = ($n -replace '\s+', ' ').Trim().TrimEnd('-').Trim()
    return $n
}

function Get-HtmlCell {
    param([string]$CellHtml, [string]$BaseUrl = 'https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/')
    $links = @([regex]::Matches($CellHtml, '<a[^>]+href="([^"]+)"[^>]*>(.*?)</a>') | ForEach-Object {
            $href = [System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value)
            if ($href.StartsWith('/')) { $href = $script:LearnBase + $href }
            elseif ($href -notmatch '^[a-z]+://' -and -not $href.StartsWith('#')) { $href = ([Uri]::new([Uri]$BaseUrl, $href)).AbsoluteUri }
            [pscustomobject]@{ Href = $href; Text = ([System.Net.WebUtility]::HtmlDecode(($_.Groups[2].Value -replace '<[^>]+>', ''))).Trim() }
        })
    $lines = @(($CellHtml -split '<br\s*/?>') | ForEach-Object { ([System.Net.WebUtility]::HtmlDecode(($_ -replace '<[^>]+>', ''))).Trim() } | Where-Object { $_ })
    [pscustomobject]@{
        Html  = $CellHtml
        Text  = ($lines -join ' ').Trim()
        Lines = $lines
        Links = $links
    }
}

function Get-LearnHtmlTables {
    <#
    .SYNOPSIS
        Extracts every <table> from a Microsoft Learn article with the heading (h2/h3) that precedes it.
    #>
    param([Parameter(Mandatory)][string]$Html, [string]$BaseUrl = 'https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/')
    $tokens = [regex]::Matches($Html, '(?s)<h(?<lvl>[23])[^>]*>(?<h>.*?)</h\k<lvl>>|<table[^>]*>(?<t>.*?)</table>')
    $section = ''
    $tables = New-Object System.Collections.Generic.List[object]
    foreach ($tk in $tokens) {
        if ($tk.Groups['h'].Success -and $tk.Groups['h'].Value) {
            $section = ([System.Net.WebUtility]::HtmlDecode(($tk.Groups['h'].Value -replace '<[^>]+>', ''))).Trim()
            continue
        }
        $body = $tk.Groups['t'].Value
        $headers = @([regex]::Matches($body, '(?s)<th[^>]*>(.*?)</th>') | ForEach-Object { ([System.Net.WebUtility]::HtmlDecode(($_.Groups[1].Value -replace '<[^>]+>', ''))).Trim() })
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($tr in [regex]::Matches($body, '(?s)<tr[^>]*>(.*?)</tr>')) {
            $cells = @([regex]::Matches($tr.Groups[1].Value, '(?s)<td[^>]*>(.*?)</td>') | ForEach-Object { Get-HtmlCell $_.Groups[1].Value -BaseUrl $BaseUrl })
            if ($cells.Count -gt 0) { $rows.Add([pscustomobject]@{ Cells = $cells }) }
        }
        $tables.Add([pscustomobject]@{ Section = $section; Headers = $headers; Rows = $rows.ToArray() })
    }
    return $tables.ToArray()
}

function Get-LearnPageMetadata {
    param([Parameter(Mandatory)][string]$Html)
    $meta = @{}
    foreach ($n in 'updated_at', 'git_commit_id', 'ms.date', 'document_id') {
        $m = [regex]::Match($Html, "<meta name=""$([regex]::Escape($n))"" content=""([^""]*)""")
        $meta[$n] = if ($m.Success) { $m.Groups[1].Value } else { $null }
    }
    $title = [regex]::Match($Html, '(?s)<title>(.*?)</title>')
    [pscustomobject]@{
        Title       = if ($title.Success) { ([System.Net.WebUtility]::HtmlDecode($title.Groups[1].Value)).Trim() } else { $null }
        UpdatedAt   = $meta['updated_at']
        GitCommitId = $meta['git_commit_id']
        MsDate      = $meta['ms.date']
        DocumentId  = $meta['document_id']
    }
}

function Get-SeriesMap {
    param([Parameter(Mandatory)][string]$Path)
    return Get-Content $Path -Raw | ConvertFrom-Json -Depth 20
}

function Resolve-SeriesKeys {
    <#
    .SYNOPSIS
        Resolves a Learn series display name to one or more series-map keys. Returns @() when unmapped.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name, [Parameter(Mandatory)]$SeriesMap)
    $n = ConvertTo-NormalizedSeriesName $Name
    if (-not $n) { return @() }
    $composite = $SeriesMap.compositeNames.PSObject.Properties | Where-Object { $_.Name -eq $n }
    if ($composite) { return @($composite.Value) }
    foreach ($s in $SeriesMap.series) {
        if ($s.key -eq $n -or ($s.aliases -contains $n)) { return @($s.key) }
    }
    if ($n -match '^standard_[a-z0-9_-]+$') { return @($n) }
    return @()
}

function ConvertFrom-RetiredSizesHtml {
    param([Parameter(Mandatory)][string]$Html, [string]$BaseUrl = 'https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/')
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($t in (Get-LearnHtmlTables -Html $Html -BaseUrl $BaseUrl)) {
        if (-not ($t.Headers -match 'Retirement Status')) { continue }
        $iName = [array]::IndexOf($t.Headers, ($t.Headers | Where-Object { $_ -match 'Series' } | Select-Object -First 1))
        $iStatus = [array]::IndexOf($t.Headers, ($t.Headers | Where-Object { $_ -match 'Retirement Status' } | Select-Object -First 1))
        $iAnn = [array]::IndexOf($t.Headers, ($t.Headers | Where-Object { $_ -match 'Announcement' } | Select-Object -First 1))
        $iDate = [array]::IndexOf($t.Headers, ($t.Headers | Where-Object { $_ -match 'Planned|Retirement Date' } | Select-Object -First 1))
        $iGuide = [array]::IndexOf($t.Headers, ($t.Headers | Where-Object { $_ -match 'Migration|Modernization' } | Select-Object -First 1))
        foreach ($r in $t.Rows) {
            $c = $r.Cells
            if ($c.Count -le [math]::Max($iName, $iStatus)) { continue }
            $ann = if ($iAnn -ge 0 -and $iAnn -lt $c.Count) { $c[$iAnn] } else { $null }
            $guide = if ($iGuide -ge 0 -and $iGuide -lt $c.Count) { $c[$iGuide] } else { $null }
            $out.Add([pscustomobject]@{
                    SeriesName            = $c[$iName].Text
                    Category              = ($t.Section -replace '\s*retired sizes\s*$', '')
                    Status                = $c[$iStatus].Text
                    AnnouncementDate      = if ($ann) { ConvertTo-InvariantDate $ann.Text } else { $null }
                    AnnouncementUrl       = if ($ann -and $ann.Links.Count) { $ann.Links[0].Href } else { $null }
                    PlannedRetirementDate = if ($iDate -ge 0 -and $iDate -lt $c.Count) { ConvertTo-InvariantDate $c[$iDate].Text } else { $null }
                    PlannedRetirementText = if ($iDate -ge 0 -and $iDate -lt $c.Count) { $c[$iDate].Text } else { $null }
                    MigrationGuideUrl     = if ($guide -and $guide.Links.Count) { $guide.Links[0].Href } else { $null }
                })
        }
    }
    return $out.ToArray()
}

function ConvertFrom-PreviousGenHtml {
    param([Parameter(Mandatory)][string]$Html, [string]$BaseUrl = 'https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/')
    # Handles both the legacy previous-generation list (Series name | Status or Replacement series | Migration guide) and
    # the End of Life list that replaced it (Series name | Modernization guide). The End of Life page has no status
    # column: every series on it is in the End of Life stage, which Microsoft defines as having an announced retirement.
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($t in (Get-LearnHtmlTables -Html $Html -BaseUrl $BaseUrl)) {
        if (-not ($t.Headers -match 'Series name')) { continue }
        $index = { param($rx) [array]::IndexOf($t.Headers, ($t.Headers | Where-Object { $_ -match $rx } | Select-Object -First 1)) }
        $iName = & $index 'Series name'
        $iStatus = & $index '^(Status|Replacement series)$'
        $iGuide = & $index 'Migration|Modernization'
        foreach ($r in $t.Rows) {
            $c = $r.Cells
            if ($c.Count -le $iName) { continue }
            $guide = if ($iGuide -ge 0 -and $iGuide -lt $c.Count) { $c[$iGuide] } else { $null }
            $out.Add([pscustomobject]@{
                    SeriesName          = $c[$iName].Text
                    Category            = ($t.Section -replace '\s*(previous-gen|End of Life) sizes\s*$', '')
                    Status              = if ($iStatus -ge 0 -and $iStatus -lt $c.Count) { $c[$iStatus].Text } else { 'End of Life' }
                    MigrationGuideLabel = if ($guide) { $guide.Text } else { $null }
                    MigrationGuideUrl   = if ($guide -and $guide.Links.Count) { $guide.Links[0].Href } else { $null }
                })
        }
    }
    return $out.ToArray()
}

function ConvertTo-TargetSeriesKey {
    <#
    .SYNOPSIS
        Converts a migration-guide target token to series keys. "v6 and v7 D-family series" becomes the family/version
        keys d-family-v6 and d-family-v7; a named series such as "Ddsv5" becomes ddsv5.
    #>
    param([AllowEmptyString()][string]$Token)
    $m = [regex]::Match($Token, '(?i)^\s*(?<vers>v\d+(?:\s*(?:,|and|&)\s*v\d+)*)\s+(?<fam>[a-z]+)-family\b')
    if ($m.Success) {
        $fam = $m.Groups['fam'].Value.ToLowerInvariant()
        return @([regex]::Matches($m.Groups['vers'].Value, '\d+') | ForEach-Object { "$fam-family-v$($_.Value)" })
    }
    $key = (ConvertTo-NormalizedSeriesName $Token) -replace '[_\s]', ''
    if ($key) { return @($key) }
    return @()
}

function ConvertFrom-MigrationGuideHtml {
    param([Parameter(Mandatory)][string]$Html, [string]$BaseUrl = 'https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/')
    $replacements = New-Object System.Collections.Generic.List[object]
    $isolated = New-Object System.Collections.Generic.List[object]
    $faq = New-Object System.Collections.Generic.List[object]
    foreach ($t in (Get-LearnHtmlTables -Html $Html -BaseUrl $BaseUrl)) {
        $h = $t.Headers -join '|'
        if ($h -match 'Current VM Series' -and $h -match 'Target VM Series') {
            foreach ($r in $t.Rows) {
                if ($r.Cells.Count -lt 2) { continue }
                $targets = @($r.Cells[1].Lines | ForEach-Object { $_ -split '/' } | ForEach-Object { ConvertTo-TargetSeriesKey $_ } | Where-Object { $_ })
                $replacements.Add([pscustomobject]@{
                        CurrentSeries = @($r.Cells[0].Lines)
                        TargetSeries  = $targets
                        Differences   = if ($r.Cells.Count -ge 3) { @($r.Cells[2].Lines) } else { @() }
                    })
            }
        }
        elseif ($h -match 'Current VM Size' -and $h -match 'Target VM Sizes') {
            foreach ($r in $t.Rows) {
                if ($r.Cells.Count -lt 2) { continue }
                $isolated.Add([pscustomobject]@{
                        CurrentSizes = @($r.Cells[0].Lines)
                        TargetSizes  = @($r.Cells[1].Lines)
                        Differences  = if ($r.Cells.Count -ge 3) { @($r.Cells[2].Lines) } else { @() }
                    })
            }
        }
        elseif ($h -match 'VM Series' -and $h -match 'Retirement Date') {
            $iDate = [array]::IndexOf($t.Headers, ($t.Headers | Where-Object { $_ -match 'Retirement Date' } | Select-Object -First 1))
            foreach ($r in $t.Rows) {
                if ($r.Cells.Count -le $iDate) { continue }
                $txt = $r.Cells[$iDate].Text
                $faq.Add([pscustomobject]@{
                        SeriesName         = $r.Cells[0].Text
                        Ri3YearExpiration  = if ($r.Cells.Count -gt 1) { ConvertTo-InvariantDate $r.Cells[1].Text } else { $null }
                        Ri1YearExpiration  = if ($r.Cells.Count -gt 2) { ConvertTo-InvariantDate $r.Cells[2].Text } else { $null }
                        RetirementDateText = $txt
                        RetirementDate     = ConvertTo-InvariantDate $txt
                        ProductActive      = [bool]($txt -match 'Product active')
                    })
            }
        }
    }
    [pscustomobject]@{ Replacements = $replacements.ToArray(); Isolated = $isolated.ToArray(); Faq = $faq.ToArray() }
}

function New-RetirementCatalog {
    <#
    .SYNOPSIS
        Builds the merged retirement catalog from the three Microsoft Learn lifecycle pages.
    .PARAMETER Pages
        Hashtable with keys RetiredList, PreviousGen, MigrationGuide. Each value: @{ Url; Html; RetrievedUtc }.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Pages,
        [Parameter(Mandatory)]$SeriesMap
    )
    $sources = @()
    foreach ($k in 'RetiredList', 'PreviousGen', 'MigrationGuide') {
        $p = $Pages[$k]
        $meta = Get-LearnPageMetadata -Html $p.Html
        $sources += [pscustomobject]@{
            Name = $k; Url = $p.Url; Title = $meta.Title; UpdatedAt = $meta.UpdatedAt; GitCommitId = $meta.GitCommitId
            MsDate = $meta.MsDate; RetrievedUtc = $p.RetrievedUtc
        }
    }
    $retired = @(ConvertFrom-RetiredSizesHtml -Html $Pages['RetiredList'].Html -BaseUrl $Pages['RetiredList'].Url)
    $prevGen = @(ConvertFrom-PreviousGenHtml -Html $Pages['PreviousGen'].Html -BaseUrl $Pages['PreviousGen'].Url)
    $guide = ConvertFrom-MigrationGuideHtml -Html $Pages['MigrationGuide'].Html -BaseUrl $Pages['MigrationGuide'].Url

    if ($retired.Count -eq 0) { throw 'Retired-sizes page parsed to zero rows; page format may have changed.' }
    if ($prevGen.Count -eq 0) { throw 'Previous-gen page parsed to zero rows; page format may have changed.' }
    if (@($guide.Replacements).Count -eq 0 -and @($guide.Isolated).Count -eq 0 -and @($guide.Faq).Count -eq 0) {
        throw 'Migration guide parsed to zero recognized rows; page format may have changed.'
    }

    $entries = [ordered]@{}
    $unmapped = New-Object System.Collections.Generic.List[object]
    $nonVmSize = New-Object System.Collections.Generic.List[object]
    $nonVmCategories = @(if ($SeriesMap.PSObject.Properties.Name -contains 'nonVmSizeCategories') { $SeriesMap.nonVmSizeCategories })
    $getEntry = {
        param($key)
        if (-not $entries.Contains($key)) {
            $patterns = @()
            $mapped = $SeriesMap.series | Where-Object { $_.key -eq $key } | Select-Object -First 1
            if ($mapped) { $patterns = @($mapped.patterns) }
            elseif ($key -match '^standard_') { $patterns = @('^' + [regex]::Escape($key) + '$') }
            $entries[$key] = [ordered]@{
                key = $key; learnNames = @(); patterns = $patterns
                retiredList = $null; previousGen = $null; guideFaq = $null
                recommendedTargets = @(); guideDifferences = @(); notes = @()
            }
        }
        return $entries[$key]
    }

    foreach ($r in $retired) {
        # Lifecycle rows that are not VM sizes (e.g. Azure Dedicated Host SKUs) never map to VM size patterns.
        if ($nonVmCategories -contains $r.Category) {
            $nonVmSize.Add([pscustomobject]@{
                    Category = $r.Category; Name = $r.SeriesName; Status = $r.Status
                    PlannedRetirementDate = if ($r.PlannedRetirementDate) { $r.PlannedRetirementDate.ToString('yyyy-MM-dd') } else { $null }
                    GuideUrl = $r.MigrationGuideUrl; SourceUrl = $Pages['RetiredList'].Url
                })
            continue
        }
        $keys = @(Resolve-SeriesKeys -Name $r.SeriesName -SeriesMap $SeriesMap)
        if ($keys.Count -eq 0) { $unmapped.Add([pscustomobject]@{ Source = 'RetiredList'; SeriesName = $r.SeriesName; Status = $r.Status; PlannedRetirementDate = $r.PlannedRetirementDate }); continue }
        foreach ($k in $keys) {
            $e = & $getEntry $k
            $e.learnNames = @($e.learnNames + $r.SeriesName | Select-Object -Unique)
            $e.retiredList = [ordered]@{
                status = $r.Status; category = $r.Category
                announcementDate = if ($r.AnnouncementDate) { $r.AnnouncementDate.ToString('yyyy-MM-dd') } else { $null }
                announcementUrl = $r.AnnouncementUrl
                plannedRetirementDate = if ($r.PlannedRetirementDate) { $r.PlannedRetirementDate.ToString('yyyy-MM-dd') } else { $null }
                plannedRetirementText = $r.PlannedRetirementText
                migrationGuideUrl = $r.MigrationGuideUrl
                sourceUrl = $Pages['RetiredList'].Url
            }
        }
    }
    foreach ($p in $prevGen) {
        $keys = @(Resolve-SeriesKeys -Name $p.SeriesName -SeriesMap $SeriesMap)
        if ($keys.Count -eq 0) { $unmapped.Add([pscustomobject]@{ Source = 'PreviousGen'; SeriesName = $p.SeriesName; Status = $p.Status; PlannedRetirementDate = $null }); continue }
        foreach ($k in $keys) {
            $e = & $getEntry $k
            $e.learnNames = @($e.learnNames + $p.SeriesName | Select-Object -Unique)
            $e.previousGen = [ordered]@{
                status = $p.Status; category = $p.Category
                migrationGuideLabel = $p.MigrationGuideLabel; migrationGuideUrl = $p.MigrationGuideUrl
                sourceUrl = $Pages['PreviousGen'].Url
            }
        }
    }
    foreach ($f in $guide.Faq) {
        $keys = @(Resolve-SeriesKeys -Name $f.SeriesName -SeriesMap $SeriesMap)
        if ($keys.Count -eq 0) { $unmapped.Add([pscustomobject]@{ Source = 'MigrationGuideFaq'; SeriesName = $f.SeriesName; Status = $f.RetirementDateText; PlannedRetirementDate = $f.RetirementDate }); continue }
        foreach ($k in $keys) {
            $e = & $getEntry $k
            $e.learnNames = @($e.learnNames + $f.SeriesName | Select-Object -Unique)
            $e.guideFaq = [ordered]@{
                retirementDateText = $f.RetirementDateText
                retirementDate = if ($f.RetirementDate) { $f.RetirementDate.ToString('yyyy-MM-dd') } else { $null }
                productActive = $f.ProductActive
                ri3YearPurchaseEnd = if ($f.Ri3YearExpiration) { $f.Ri3YearExpiration.ToString('yyyy-MM-dd') } else { $null }
                ri1YearPurchaseEnd = if ($f.Ri1YearExpiration) { $f.Ri1YearExpiration.ToString('yyyy-MM-dd') } else { $null }
                sourceUrl = $Pages['MigrationGuide'].Url
            }
        }
    }
    foreach ($rep in $guide.Replacements) {
        foreach ($cur in $rep.CurrentSeries) {
            foreach ($k in @(Resolve-SeriesKeys -Name $cur -SeriesMap $SeriesMap)) {
                if ($k -match '^standard_') { continue }
                $e = & $getEntry $k
                $e.recommendedTargets = @(($e.recommendedTargets + $rep.TargetSeries) | Select-Object -Unique)
                $e.guideDifferences = @(($e.guideDifferences + $rep.Differences) | Select-Object -Unique)
            }
        }
    }

    foreach ($k in @($entries.Keys)) {
        $e = $entries[$k]
        if ($e.patterns.Count -eq 0) {
            $unmapped.Add([pscustomobject]@{ Source = 'SeriesMap'; SeriesName = $k; Status = 'No SKU pattern'; PlannedRetirementDate = $null })
        }
        if (-not $e.retiredList -and $e.guideFaq -and -not $e.guideFaq.productActive -and $e.guideFaq.retirementDate) {
            $e.notes = @($e.notes + 'Retirement date appears in the Microsoft migration guide FAQ but the series is not listed on the retired-sizes list; classified as Retirement Announced (not Confirmed).')
        }
        if (-not $e.retiredList -and $e.previousGen -and $e.previousGen.migrationGuideLabel -match 'Retirement Announced' -and -not ($e.guideFaq -and $e.guideFaq.retirementDate)) {
            $e.notes = @($e.notes + 'Previous-gen page links a retirement migration guide, but the retired-sizes list has no entry or date for this series. No retirement date is asserted.')
        }
        if ($e.guideFaq -and $e.guideFaq.productActive) {
            $e.notes = @($e.notes + "Migration guide FAQ lists this series as 'Product active' (not retiring). Reserved Instance purchase/renewal changes apply from $($e.guideFaq.ri1YearPurchaseEnd).")
        }
    }

    $isoTargets = [ordered]@{}
    foreach ($iso in $guide.Isolated) {
        foreach ($s in $iso.CurrentSizes) { $isoTargets[$s] = @($iso.TargetSizes) }
    }

    [pscustomobject]@{
        schemaVersion   = '1.0'
        generatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        sources         = $sources
        series          = @($entries.Values | ForEach-Object { [pscustomobject]$_ })
        sizeTargets     = [pscustomobject]$isoTargets
        unmappedSeries  = $unmapped.ToArray()
        nonVmSizeEntries = $nonVmSize.ToArray()
    }
}

function Get-UnmappedSeriesNames {
    <# Distinct unmapped Microsoft series names (a series can be unmapped on more than one Learn page). #>
    param($Catalog)
    if (-not $Catalog -or -not ($Catalog.PSObject.Properties.Name -contains 'unmappedSeries')) { return @() }
    return @(@($Catalog.unmappedSeries) | Where-Object { $_ } | ForEach-Object SeriesName | Select-Object -Unique)
}

function Get-NonVmSizeEntries {
    <# Lifecycle entries that are not VM sizes (e.g. Dedicated Host SKUs). Empty for catalogs created before v1.1. #>
    param($Catalog)
    if (-not $Catalog -or -not ($Catalog.PSObject.Properties.Name -contains 'nonVmSizeEntries')) { return @() }
    return @(@($Catalog.nonVmSizeEntries) | Where-Object { $_ })
}

function Get-RetirementCatalog {
    <#
    .SYNOPSIS
        Returns the retirement catalog: live from Microsoft Learn, falling back to the cached catalog.
    #>
    param(
        [Parameter(Mandatory)][string]$SeriesMapPath,
        [Parameter(Mandatory)][string]$CachePath,
        [switch]$Offline,
        [switch]$UpdateCache,
        [int]$TimeoutSec = 30
    )
    $seriesMap = Get-SeriesMap -Path $SeriesMapPath
    $liveError = $null
    if (-not $Offline) {
        try {
            $pages = @{}
            foreach ($pair in @(@('RetiredList', $script:RetiredListUrl), @('PreviousGen', $script:PreviousGenUrl), @('MigrationGuide', $script:MigrationGuideUrl))) {
                $resp = Invoke-WebRequest -Uri $pair[1] -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
                $pages[$pair[0]] = @{ Url = $pair[1]; Html = [string]$resp.Content; RetrievedUtc = (Get-Date).ToUniversalTime().ToString('o') }
            }
            $catalog = New-RetirementCatalog -Pages $pages -SeriesMap $seriesMap
            if ($UpdateCache) {
                $catalog | ConvertTo-Json -Depth 20 | Out-File -FilePath $CachePath -Encoding utf8
            }
            return [pscustomobject]@{ Catalog = $catalog; Source = 'Live'; Warning = $null; SeriesMap = $seriesMap }
        }
        catch {
            $liveError = $_.Exception.Message
            Write-Warning "Live Microsoft Learn retirement fetch failed ($liveError). Falling back to cached catalog."
        }
    }
    if (-not (Test-Path $CachePath)) {
        throw "No live retirement data and no cached catalog at $CachePath. Cannot classify retirements without Microsoft evidence."
    }
    $cached = Get-Content $CachePath -Raw | ConvertFrom-Json -Depth 20
    $when = ($cached.sources | ForEach-Object RetrievedUtc | Sort-Object | Select-Object -First 1)
    $parsed = [datetime]::MinValue
    if ($when -is [string] -and [datetime]::TryParse($when, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsed)) { $when = $parsed }
    if ($when -is [datetime]) { $when = $when.ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC' }
    return [pscustomobject]@{
        Catalog = $cached; Source = "Cached ($when)"; SeriesMap = $seriesMap
        Warning = if ($liveError) { "Live fetch failed: $liveError" } else { 'Offline mode requested.' }
    }
}

function Find-CatalogSeries {
    param([Parameter(Mandatory)][string]$SkuName, [Parameter(Mandatory)]$Catalog)
    $exact = $Catalog.series | Where-Object { $_.key -match '^standard_' -and $_.key -eq $SkuName.ToLowerInvariant() } | Select-Object -First 1
    if ($exact) { return $exact }
    foreach ($s in $Catalog.series) {
        foreach ($p in $s.patterns) {
            if ($SkuName -match $p) { return $s }
        }
    }
    return $null
}

function Get-RetirementUrgency {
    param([AllowNull()][Nullable[datetime]]$RetirementDate, [Parameter(Mandatory)][datetime]$AsOf, [string]$EvidenceClass)
    if ($EvidenceClass -eq 'Unable to Confirm') { return 'Unable to Determine' }
    if (-not $RetirementDate) {
        if ($EvidenceClass -in 'Retirement Announced', 'Confirmed Retirement') { return 'Unable to Determine' }
        return 'No Retirement Announced'
    }
    if ($RetirementDate -le $AsOf) { return 'Already Retired' }
    $months = Get-MonthsBetween -From $AsOf -To $RetirementDate
    if ($months -lt 12) { return 'Less than 12 Months' }
    if ($months -lt 24) { return '12-24 Months' }
    if ($months -lt 36) { return '24-36 Months' }
    return 'More than 36 Months'
}

function Get-LifecycleStage {
    <#
    .SYNOPSIS
        Microsoft VM lifecycle stage for a lifecycle result: Retired, End of Life, Not End of Life or Unknown.
    .DESCRIPTION
        Microsoft defines four stages (Current, Extended, End of Life, Retired); End of Life means a retirement has been
        announced (https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/lifecycle-overview). Current and
        Extended depend on the VM family, so sizes without an announced retirement are reported as 'Not End of Life'
        rather than guessed.
    #>
    param([Parameter(Mandatory)]$Lifecycle)
    $previous = if ($Lifecycle.PSObject.Properties.Name -contains 'PreviousGenStatus') { $Lifecycle.PreviousGenStatus } else { $null }
    switch ($Lifecycle.EvidenceClass) {
        'Already Retired' { return 'Retired' }
        { $_ -in 'Confirmed Retirement', 'Retirement Announced' } { return 'End of Life' }
        'Unable to Confirm' { return 'Unknown' }
        default { if ($previous -eq 'End of Life') { return 'End of Life' } else { return 'Not End of Life' } }
    }
}
function Resolve-SkuLifecycle {
    <#
    .SYNOPSIS
        Classifies a VM size against the Microsoft retirement evidence. Never infers retirement from age.
    #>
    param(
        [Parameter(Mandatory)][string]$SkuName,
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][datetime]$AsOf,
        [string]$CatalogSource = 'Live'
    )
    $info = Get-SkuNameInfo -SkuName $SkuName
    $entry = Find-CatalogSeries -SkuName $SkuName -Catalog $Catalog
    $notes = New-Object System.Collections.Generic.List[string]
    $result = [ordered]@{
        SkuName = $SkuName; SeriesKey = $info.SeriesKey; LearnSeriesName = $null
        EvidenceClass = 'No Retirement Announced'; RetirementStatus = 'No Retirement Announced'
        AnnouncementDate = $null; RetirementDate = $null; MonthsRemaining = $null; Urgency = 'No Retirement Announced'
        SourceUrl = $null; AnnouncementUrl = $null; MigrationGuideUrl = $null; PreviousGenStatus = $null; LifecycleStage = $null
        RecommendedTargets = @(); GuideDifferences = @(); SizeTargets = @(); Notes = @()
        CatalogSource = $CatalogSource; DataQuality = 'Verified'
    }
    if (-not $info.Parsed) {
        $result.EvidenceClass = 'Unable to Confirm'; $result.RetirementStatus = 'Unable to Confirm'
        $result.Urgency = 'Unable to Determine'; $result.DataQuality = 'Unable to Verify'
        $result.Notes = @("VM size name '$SkuName' does not follow the Azure naming convention; cannot match to Microsoft lifecycle data.")
        $result.LifecycleStage = Get-LifecycleStage -Lifecycle ([pscustomobject]$result); return [pscustomobject]$result
    }
    $unmappedHit = @($Catalog.unmappedSeries | Where-Object { (ConvertTo-NormalizedSeriesName $_.SeriesName) -eq $info.SeriesKey })
    if (-not $entry) {
        if ($unmappedHit.Count -gt 0) {
            $result.EvidenceClass = 'Unable to Confirm'; $result.RetirementStatus = 'Unable to Confirm'
            $result.Urgency = 'Unable to Determine'; $result.DataQuality = 'Unable to Verify'
            $result.Notes = @("Microsoft Learn lists series '$($unmappedHit[0].SeriesName)' ($($unmappedHit[0].Source): $($unmappedHit[0].Status)) which has no SKU mapping in series-map.json. Add a mapping to classify.")
        }
        $result.LifecycleStage = Get-LifecycleStage -Lifecycle ([pscustomobject]$result); return [pscustomobject]$result
    }
    $result.LearnSeriesName = ($entry.learnNames -join ' / ')
    $result.RecommendedTargets = @($entry.recommendedTargets)
    $result.GuideDifferences = @($entry.guideDifferences)
    foreach ($n in $entry.notes) { $notes.Add($n) }
    if ($Catalog.sizeTargets -and (@($Catalog.sizeTargets.PSObject.Properties | ForEach-Object Name) -contains $SkuName)) {
        $result.SizeTargets = @($Catalog.sizeTargets.$SkuName)
    }
    if ($entry.previousGen) { $result.PreviousGenStatus = $entry.previousGen.status }

    $date = $null
    if ($entry.retiredList) {
        $rl = $entry.retiredList
        $result.SourceUrl = $rl.sourceUrl; $result.AnnouncementUrl = $rl.announcementUrl; $result.MigrationGuideUrl = $rl.migrationGuideUrl
        $result.AnnouncementDate = $rl.announcementDate
        if ($rl.plannedRetirementDate) { $date = [datetime]::ParseExact($rl.plannedRetirementDate, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) }
        if ($rl.status -match '^Retired' -or ($date -and $date -le $AsOf)) {
            $result.EvidenceClass = 'Already Retired'; $result.RetirementStatus = 'Retired'
        }
        elseif ($date) {
            $result.EvidenceClass = 'Confirmed Retirement'; $result.RetirementStatus = 'Announced'
            if (-not $rl.announcementUrl) { $notes.Add('Planned retirement date listed on Microsoft Learn without a linked Azure Updates announcement.') }
        }
        else {
            $result.EvidenceClass = 'Retirement Announced'; $result.RetirementStatus = 'Announced'
            $result.DataQuality = 'Partially Verified'
            $notes.Add('Retirement announced on Microsoft Learn without a parseable planned retirement date.')
        }
    }
    elseif ($entry.guideFaq -and -not $entry.guideFaq.productActive -and $entry.guideFaq.retirementDate) {
        $date = [datetime]::ParseExact($entry.guideFaq.retirementDate, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        $result.SourceUrl = $entry.guideFaq.sourceUrl; $result.MigrationGuideUrl = $entry.guideFaq.sourceUrl
        $result.EvidenceClass = if ($date -le $AsOf) { 'Already Retired' } else { 'Retirement Announced' }
        $result.RetirementStatus = if ($date -le $AsOf) { 'Retired' } else { 'Announced' }
        $result.DataQuality = 'Partially Verified'
    }
    elseif ($entry.previousGen -and $entry.previousGen.status -eq 'End of Life') {
        # Microsoft defines End of Life as "has an announced retirement"; without a date it can't be scheduled.
        $result.EvidenceClass = 'Retirement Announced'; $result.RetirementStatus = 'Announced'
        $result.SourceUrl = $entry.previousGen.sourceUrl; $result.MigrationGuideUrl = $entry.previousGen.migrationGuideUrl
        $result.DataQuality = 'Partially Verified'
        $notes.Add('Listed on the Microsoft End of Life list (announced retirement) but no planned retirement date was found.')
    }
    elseif ($entry.previousGen) {
        $result.EvidenceClass = 'Modernization Recommended'; $result.RetirementStatus = 'Previous Generation'
        $result.SourceUrl = $entry.previousGen.sourceUrl; $result.MigrationGuideUrl = $entry.previousGen.migrationGuideUrl
    }
    elseif ($entry.guideFaq -and $entry.guideFaq.productActive) {
        $result.EvidenceClass = 'No Retirement Announced'; $result.RetirementStatus = 'Product Active'
        $result.SourceUrl = $entry.guideFaq.sourceUrl
    }

    if ($date) {
        $result.RetirementDate = $date.ToString('yyyy-MM-dd')
        $result.MonthsRemaining = [math]::Max(0, (Get-MonthsBetween -From $AsOf -To $date))
    }
    $result.Urgency = Get-RetirementUrgency -RetirementDate $date -AsOf $AsOf -EvidenceClass $result.EvidenceClass
    if ($CatalogSource -ne 'Live' -and $result.DataQuality -eq 'Verified') { $result.DataQuality = 'Partially Verified'; $notes.Add("Retirement evidence from cached catalog: $CatalogSource.") }
    $result.Notes = $notes.ToArray()
    $result.LifecycleStage = Get-LifecycleStage -Lifecycle ([pscustomobject]$result); return [pscustomobject]$result
}

Export-ModuleMember -Function ConvertTo-NormalizedSeriesName, Get-LearnHtmlTables, Get-LearnPageMetadata, Get-SeriesMap, Resolve-SeriesKeys, `
    ConvertFrom-RetiredSizesHtml, ConvertFrom-PreviousGenHtml, ConvertTo-TargetSeriesKey, ConvertFrom-MigrationGuideHtml, New-RetirementCatalog, Get-RetirementCatalog, `
    Get-UnmappedSeriesNames, Get-NonVmSizeEntries, Find-CatalogSeries, Get-RetirementUrgency, Get-LifecycleStage, Resolve-SkuLifecycle
