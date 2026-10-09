#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    End-to-end run of Invoke-VMSKURetirementReport.ps1 against a mock Azure CLI (tests/mock/az.ps1).
    Exercises inventory joins, subscription-scoped SKU catalogs, aggregated quota, the Retirement / Retirement+Modernization /
    Modernization quota scopes and all outputs.
#>
BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:Out = Join-Path $TestDrive 'run'
    $mockDir = Join-Path $PSScriptRoot 'mock'
    $env:PATH = "$mockDir$([System.IO.Path]::PathSeparator)$env:PATH"
    # Retail pricing is on by default; these shims keep it offline (fixture prices, or a blocked API).
    $prices = Join-Path $PSScriptRoot 'fixtures/retail-prices-eastus2.json'
    $script:PricesShim = "function global:Invoke-RestMethod { param([string]`$Uri, [int]`$TimeoutSec) if (`$Uri -like 'https://prices.azure.com/*') { return (Get-Content -LiteralPath '$prices' -Raw | ConvertFrom-Json) }; throw `"Test is offline; blocked request to `$Uri`" }"
    $script:BlockedPricesShim = "function global:Invoke-RestMethod { param([string]`$Uri, [int]`$TimeoutSec) throw `"Test is offline; blocked request to `$Uri`" }"
    $script:Log = & pwsh -NoProfile -Command "$PricesShim; `$env:PATH='$mockDir$([System.IO.Path]::PathSeparator)' + `$env:PATH; & '$(Join-Path $Root 'scripts/Invoke-VMSKURetirementReport.ps1')' -OutputPath '$Out' -OfflineCatalog -AsOfDate '2026-09-24' -ThrottleLimit 2" 2>&1 | Out-String
    $script:Rows = if (Test-Path (Join-Path $Out 'vm-assessment.csv')) { Import-Csv (Join-Path $Out 'vm-assessment.csv') } else { @() }
    $script:ByVm = @{}; foreach ($r in $Rows) { $ByVm[$r.VM] = $r }
}

Describe 'End-to-end assessment (mock Azure)' {
    It 'completes and writes every output' {
        $Log | Should -Match 'Outputs:'
        foreach ($f in 'assessment.json', 'vm-assessment.csv', 'candidates.csv', 'quota-impact.csv', 'retirement-evidence.json', 'executive-summary.md', 'detailed-report.md', 'index.html', 'run.log') {
            Join-Path $Out $f | Should -Exist
        }
        $Rows.Count | Should -Be 7
    }
    It 'links the source repository from every human-readable report' {
        foreach ($file in Get-ChildItem $Out -Filter '*.html') {
            (Get-Content $file.FullName -Raw) | Should -Match '<a href="https://github.com/AzaryaShaulov/Azure" target="_blank" rel="noopener noreferrer">Source repository</a>'
        }
        foreach ($name in 'executive-summary.md', 'detailed-report.md') {
            (Get-Content (Join-Path $Out $name) -Raw) | Should -Match '\[Source repository\]\(https://github.com/AzaryaShaulov/Azure\)'
        }
    }
    It 'includes one standard disclaimer in all supported report formats' {
            $warranty = 'This assessment and its recommendations are provided "AS IS," without warranties or guarantees.'
            $independence = 'This independently developed tool is not an official Microsoft product and is not supported or endorsed by Microsoft.'
            $validation = 'Findings, retirement timelines, SKU compatibility, and modernization recommendations are informational only. Users must verify all recommendations, regional availability, quotas, pricing, VM generation, storage compatibility, and migration requirements against current official Microsoft documentation before implementing production changes.'
            $expected = "$warranty $independence`n`n$validation"
            foreach ($file in Get-ChildItem $Out -Filter '*.html') {
                $html = Get-Content $file.FullName -Raw
                $html | Should -Match '<h2>Disclaimer</h2>'
                ([regex]::Matches($html, 'class="callout disclaimer"')).Count | Should -Be 1
                $html.IndexOf('class="callout disclaimer"') | Should -BeLessThan $html.IndexOf('<footer>')
                $plain = [Net.WebUtility]::HtmlDecode(($html -replace '<[^>]+>', ' '))
                $plain | Should -Match ([regex]::Escape($warranty))
                $plain | Should -Match ([regex]::Escape($independence))
                $plain | Should -Match ([regex]::Escape($validation))
            }
            foreach ($name in 'executive-summary.md', 'detailed-report.md') {
                $md = Get-Content (Join-Path $Out $name) -Raw
                ([regex]::Matches($md, '(?m)^## Disclaimer\r?$')).Count | Should -Be 1
                $md | Should -Match ([regex]::Escape("**$warranty** $independence"))
                $md.TrimEnd() | Should -Match ([regex]::Escape($validation) + '$')
            }
            foreach ($name in 'assessment.json', 'retirement-evidence.json') {
                $j = Get-Content (Join-Path $Out $name) -Raw | ConvertFrom-Json -Depth 40
                $j.disclaimer.Replace("`r`n", "`n") | Should -Be $expected
            }
            foreach ($name in 'vm-assessment.csv', 'candidates.csv', 'quota-impact.csv') {
                (Get-Content (Join-Path $Out $name) -Raw) | Should -Not -Match 'without warranties or guarantees|Disclaimer'
            }
    }
    It 'keeps operator details out of the shared outputs by default' {
        (Get-Content (Join-Path $Out 'assessment.json') -Raw | ConvertFrom-Json).signedInAccount | Should -Be 'a****@contoso.example'
        $runLog = Get-Content (Join-Path $Out 'run.log') -Raw
        $runLog | Should -Not -Match 'admin@contoso\.example'
        $runLog | Should -Match 'Account: a\*\*\*\*@contoso\.example'
        # Minimal transcript header: no local user, machine or host command line.
        $runLog | Should -Not -Match '(?m)^(Username|RunAs User|Machine|Host Application):'
        Join-Path $Out 'data' | Should -Not -Exist
        $outputs = (Get-ChildItem $Out -File | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
        $outputs | Should -Not -Match 'admin@contoso\.example'
    }
    It 'classifies confirmed retirement, beyond-horizon retirement and current sizes' {
        $ByVm['vm-ds3v2'].EvidenceClass | Should -Be 'Confirmed Retirement'
        $ByVm['vm-ds3v2'].Wave | Should -Be 'Wave 2 - Near Term'
        # Microsoft lists Dv3/Dsv3 for retirement on 2029-11-15 (37 months after the 2026-09-24 as-of date).
        $ByVm['vm-d4sv3'].EvidenceClass | Should -Be 'Confirmed Retirement'
        $ByVm['vm-d4sv3'].RetirementDate | Should -Be '2029-11-15'
        $ByVm['vm-d4sv3'].Wave | Should -Be 'Beyond Horizon'
        $ByVm['vm-d4sv3'].Action | Should -Be 'Plan Migration'
        $ByVm['vm-d4sv5'].Action | Should -Be 'No Action Required'
        $ByVm['vm-nc6'].EvidenceClass | Should -Be 'Already Retired'
        $ByVm['vm-nc6'].Action | Should -Be 'Immediate Migration Required'
    }
    It 'joins NICs by resource id (accelerated networking) and recommends a same-vendor size' {
        $ByVm['vm-ds3v2'].RecommendedSku | Should -Be 'Standard_D4ds_v5'
        $ByVm['vm-ds3v2'].TargetCpuVendor | Should -Be 'Intel'
    }
    It 'aggregates retirement quota demand for every VM moving into DDSv5 (incl. deallocated)' {
        $q = Import-Csv (Join-Path $Out 'quota-impact.csv') | Where-Object { $_.Scope -eq 'Retirement' -and $_.QuotaName -eq 'standardddsv5family' }
        # 2 x DS3_v2 (one deallocated) + 2 x D4s_v3 -> 4 x Standard_D4ds_v5 = 16 vCPU; 95 used of 100.
        [int]$q.RequiredVcpu | Should -Be 16
        [int]$q.MinimumIncrease | Should -Be 11
        $ByVm['vm-ds3v2'].QuotaStatus | Should -Be 'Quota Increase Required'
        $ByVm['vm-ds3v2'].DeploymentReadiness | Should -Be 'Quota Increase Required'
        $ByVm['vm-ds3v2'].NextStep | Should -Be 'Request Quota Increase'
    }
    It 'uses Microsoft-guide target series and still requires manual review when current capabilities / target quota are unknown' {
        $ByVm['vm-b2ms'].RecommendedSku | Should -Be 'Standard_B2s_v2'
        $ByVm['vm-b2ms'].QuotaStatus | Should -Be 'Manual Validation Required'
        $ByVm['vm-b2ms'].DeploymentReadiness | Should -Be 'Manual Review Required'
        $ByVm['vm-b2ms'].Confidence | Should -Be 'LOW'
        $ByVm['vm-nc6'].RecommendedSku | Should -BeNullOrEmpty
        $ByVm['vm-nc6'].Confidence | Should -Be 'LOW'
    }
    It 'writes a structured JSON document consumable by other tools' {
        $j = Get-Content (Join-Path $Out 'assessment.json') -Raw | ConvertFrom-Json -Depth 40
        $j.tenant.Name | Should -Be 'Contoso (Sample)'
        $j.summary.TotalVmsScanned | Should -Be 7
        $j.catalog.source | Should -Match '^Cached'
        (@($j.vms | Where-Object { $_.row.VM -eq 'vm-ds3v2' }))[0].recommendation.primary.gates.Count | Should -BeGreaterThan 5
    }
    It 'keeps HTML per subscription with a back link' {
        $sub = Get-ChildItem $Out -Filter 'contoso-prod-*.html'
        $sub | Should -Not -BeNullOrEmpty
        (Get-Content $sub.FullName -Raw) | Should -Match 'Tenant summary'
    }
    It 'lists only VMs on End of Life or retired sizes that need action in the HTML, under Overview' {
        $html = Get-Content (Get-ChildItem $Out -Filter 'contoso-prod-*.html').FullName -Raw
        $html | Should -Match '<h2>VMs with Retiring SKUs</h2>'
        $html | Should -Match '<h2>VMs with Retiring SKUs details</h2>'
        $html | Should -Not -Match 'VM Assessment</h2>|Recommendations in Detail'
        $html.IndexOf("id='overview'") | Should -BeLessThan $html.IndexOf("id='vms'")
        $html.IndexOf("id='vms'") | Should -BeLessThan $html.IndexOf("id='details'")
        $html.IndexOf("id='details'") | Should -BeLessThan $html.IndexOf("id='quota'")
        # Part 1 (retirement) is a labelled band containing both retiring-VM sections; no Part 2 without --check-modernization.
        $html | Should -Match "<div class='track track-retirement' id='track-retirement'"
        $html.IndexOf("id='track-retirement'") | Should -BeLessThan $html.IndexOf("id='vms'")
        $html | Should -Not -Match "id='track-modernization'"
        $html | Should -Match "<span class='toc-group toc-retirement'><span class='toc-group-label'>Retirement</span>"
        $html | Should -Match "class='track-tile track-tile-retirement' href='#track-retirement'"
        $retiring = @($Rows | Where-Object { $_.AffectedByRetirement -eq 'Yes' -and $_.LifecycleStage -in 'End of Life', 'Retired' -and $_.Action -ne 'No Action Required' })
        $excluded = @($Rows | Where-Object { $_.VM -notin $retiring.VM })
        $retiring.Count | Should -BeGreaterThan 0
        $excluded.Count | Should -BeGreaterThan 0
        foreach ($r in $retiring) { $html | Should -Match ">$([regex]::Escape($r.VM))<" }
        foreach ($r in $excluded) { $html | Should -Not -Match ">$([regex]::Escape($r.VM))<" }
        $Rows.Count | Should -Be 7
    }
    It 'reports the Microsoft lifecycle stage (End of Life / Retired) for every VM' {
        $ByVm['vm-ds3v2'].LifecycleStage | Should -Be 'End of Life'
        $ByVm['vm-d4sv3'].LifecycleStage | Should -Be 'End of Life'
        $ByVm['vm-nc6'].LifecycleStage | Should -Be 'Retired'
        $ByVm['vm-d4sv5'].LifecycleStage | Should -Be 'Not End of Life'
        $html = Get-Content (Get-ChildItem $Out -Filter 'contoso-prod-*.html').FullName -Raw
        $html | Should -Match "<span class='badge b-orange'>End of Life</span>"
        $html | Should -Match 'https://learn\.microsoft\.com/azure/virtual-machines/sizes/lifecycle/end-of-life-sizes-list'
        (Get-Content (Join-Path $Out 'detailed-report.md') -Raw) | Should -Match 'Microsoft Lifecycle Stage'
    }
    It 'collapses the cross-vendor section and links Microsoft Learn upgrade and SCSI to NVMe guidance' {
        foreach ($page in @(Get-ChildItem $Out -Filter '*.html')) {
            $html = Get-Content $page.FullName -Raw
            $html | Should -Match "<details id='cross-vendor'"
            $html | Should -Match "id='upgrade-guidance'"
            $html | Should -Match 'https://learn\.microsoft\.com/azure/virtual-machines/nvme-linux'
            $html | Should -Match 'https://learn\.microsoft\.com/azure/virtual-machines/migration/scsi-to-nvme-migration'
            $html | Should -Match 'https://learn\.microsoft\.com/azure/virtual-machines/trusted-launch-existing-vm-gen-1'
        }
    }
    It 'keeps modernization outputs empty without --check-modernization' {
        $q = @(Import-Csv (Join-Path $Out 'quota-impact.csv'))
        @($q | Where-Object Scope -eq 'Modernization').Count | Should -Be 0
        @($q | Where-Object Scope -eq 'Retirement+Modernization').Count | Should -BeGreaterThan 0
        @($Rows | Where-Object { $_.ModernizationTargetSku -or $_.ModernizationPath -or $_.MigrationQuotaModel }).Count | Should -Be 0
        $ByVm['vm-ds3v2'].RetirementTargetSku | Should -Be 'Standard_D4ds_v5'
        $ByVm['vm-ds3v2'].RecommendedMigrationPath | Should -Be 'Retire to Standard_D4ds_v5'
        $ByVm['vm-ds3v2'].NewerGenerationIfConverted | Should -Match '^Standard_D4s_v6'
        $sub = Get-ChildItem $Out -Filter 'contoso-prod-*.html'
        (Get-Content $sub.FullName -Raw) | Should -Not -Match "id='modernization'"
        # The v6/v7 status is hidden in the Recommended size column when the check was not run.
        $vmTable = [regex]::Match((Get-Content $sub.FullName -Raw), "(?s)<table class='vm-table'>.*?</table>").Value
        $vmTable | Should -Not -BeNullOrEmpty
        $vmTable | Should -Not -Match 'Not Evaluated|v6/v7:'
    }
    It 'includes retail PAYGO pricing by default' {
        $j = Get-Content (Join-Path $Out 'assessment.json') -Raw | ConvertFrom-Json -Depth 40
        $j.pricingStatus | Should -Be 'Done'
        $j.parameters.IncludePricing | Should -BeTrue
        $j.parameters.SkipPricing | Should -BeFalse
        $ByVm['vm-ds3v2'].CurrentMonthlyUSD | Should -Not -BeNullOrEmpty
        $ByVm['vm-ds3v2'].TargetMonthlyUSD | Should -Not -BeNullOrEmpty
        $html = Get-Content (Get-ChildItem $Out -Filter 'contoso-prod-*.html').FullName -Raw
        $html | Should -Match "<td class='num nowrap'>\`$\d+ &rarr; \`$\d+</td>"
    }
    It 'rejects -IncludePricing together with -SkipPricing' {
        $log = & pwsh -NoProfile -Command "& '$(Join-Path $Root 'scripts/Invoke-VMSKURetirementReport.ps1')' -IncludePricing -SkipPricing" 2>&1 | Out-String
        (($log -replace '\s*\|\s*', ' ') -replace '\s+', ' ') | Should -Match '-IncludePricing and -SkipPricing cannot be used together'
    }
}

Describe 'End-to-end pricing pagination failures (mock Azure)' {
    It 'discards the incomplete region and reports <Status>' -ForEach @(
        @{ FailedRegion = 'eastus2'; Status = 'Unavailable'; CompletedRegions = 0 }
        @{ FailedRegion = 'westus2'; Status = 'Partial'; CompletedRegions = 1 }
    ) {
        $out = Join-Path $TestDrive "pricing-$Status"
        $requests = Join-Path $TestDrive "pricing-$Status-requests.txt"
        $prices = Join-Path $PSScriptRoot 'fixtures/retail-prices-eastus2.json'
        $mockDir = Join-Path $PSScriptRoot 'mock'
        $shim = @"
function global:Invoke-RestMethod {
    param([string]`$Uri, [int]`$TimeoutSec)
    Add-Content -LiteralPath '$requests' -Value `$Uri
    if (`$Uri -eq 'https://prices.azure.com/$FailedRegion/page2') { throw 'later page blocked' }
    if (`$Uri -notlike 'https://prices.azure.com/*') { throw "Test is offline; blocked request to `$Uri" }
    `$response = Get-Content -LiteralPath '$prices' -Raw | ConvertFrom-Json
    if (`$Uri -match "armRegionName eq '$FailedRegion'") { `$response.NextPageLink = 'https://prices.azure.com/$FailedRegion/page2' }
    return `$response
}
function global:Start-Sleep { param([int]`$Seconds) }
"@
        $log = & pwsh -NoProfile -Command "$shim; `$env:MOCK_AZ_MULTI_REGION='1'; `$env:PATH='$mockDir$([System.IO.Path]::PathSeparator)' + `$env:PATH; & '$(Join-Path $Root 'scripts/Invoke-VMSKURetirementReport.ps1')' -OutputPath '$out' -OfflineCatalog -AsOfDate '2026-09-24' -ThrottleLimit 2" 2>&1 | Out-String
        $log | Should -Match 'Outputs:'
        $flat = ($log -replace '\s*\|\s*', ' ') -replace '\s+', ' '
        ([regex]::Matches($flat, 'Retail pricing unavailable')).Count | Should -Be 1
        $flat | Should -Match "prices from $CompletedRegions completed region\(s\) retained"
        $j = Get-Content (Join-Path $out 'assessment.json') -Raw | ConvertFrom-Json -Depth 40
        $j.pricingStatus | Should -Be $Status
        $rows = @(Import-Csv (Join-Path $out 'vm-assessment.csv'))
        @($rows | Where-Object { $_.Region -eq $FailedRegion -and ($_.CurrentMonthlyUSD -or $_.TargetMonthlyUSD) }).Count | Should -Be 0
        @($j.vms | Where-Object { $_.row.Region -eq $FailedRegion -and $null -ne $_.pricing }).Count | Should -Be 0
        if ($CompletedRegions) {
            @($rows | Where-Object { $_.Region -eq 'eastus2' -and $_.CurrentMonthlyUSD }).Count | Should -BeGreaterThan 0
        }
        else {
            @($rows | Where-Object { $_.CurrentMonthlyUSD -or $_.TargetMonthlyUSD }).Count | Should -Be 0
        }
        (Get-Content $requests -Raw) | Should -Not -Match "armRegionName eq 'westus3'"
        (Get-Content (Join-Path $out 'index.html') -Raw) | Should -Match ">${Status}</span>"
        $html = Get-Content (Get-ChildItem $out -Filter 'contoso-prod-*.html').FullName -Raw
        $failedVm = if ($FailedRegion -eq 'eastus2') { 'vm-ds3v2' } else { 'vm-d4sv3' }
        $failedRow = [regex]::Match($html, "(?s)<tr><td><a[^>]+>$failedVm</a>.*?</tr>").Value
        $failedRow | Should -Not -BeNullOrEmpty
        $failedRow | Should -Not -Match '\$\d'
    }
}

Describe 'End-to-end opt-in modernization assessment (mock Azure)' {
    BeforeAll {
        $mockDir = Join-Path $PSScriptRoot 'mock'
        $script:ModernOut = Join-Path $TestDrive 'modernization'
        $script:ModernLog = & pwsh -NoProfile -Command "$BlockedPricesShim; `$env:PATH='$mockDir$([System.IO.Path]::PathSeparator)' + `$env:PATH; & '$(Join-Path $Root 'scripts/Invoke-VMSKURetirementReport.ps1')' --check-modernization -OutputPath '$ModernOut' -OfflineCatalog -AsOfDate '2026-09-24' -ThrottleLimit 2" 2>&1 | Out-String
        $script:ModernRows = if (Test-Path (Join-Path $ModernOut 'vm-assessment.csv')) { Import-Csv (Join-Path $ModernOut 'vm-assessment.csv') } else { @() }
    }

    It 'completes with one warning and no prices when the Retail Prices API is unreachable' {
        $ModernLog | Should -Match 'Outputs:'
        $flat = ($ModernLog -replace '\s*\|\s*', ' ') -replace '\s+', ' '
        ([regex]::Matches($flat, 'Retail pricing unavailable')).Count | Should -Be 1
        $flat | Should -Match 'Use -SkipPricing to skip this step'
        (Get-Content (Join-Path $ModernOut 'assessment.json') -Raw | ConvertFrom-Json -Depth 40).pricingStatus | Should -Be 'Unavailable'
        @($ModernRows | Where-Object { $_.CurrentMonthlyUSD -or $_.TargetMonthlyUSD }).Count | Should -Be 0
    }

    It 'accepts the exact double-dash flag and records the opt-in parameter' {
        $ModernLog | Should -Match 'Outputs:'
        $json = Get-Content (Join-Path $ModernOut 'assessment.json') -Raw | ConvertFrom-Json -Depth 40
        $json.parameters.CheckModernization | Should -BeTrue
    }

    It 'evaluates every VM and emits the modernization result fields' {
        $ModernRows.Count | Should -Be 7
        @($ModernRows | Where-Object ModernizationStatus -eq 'Not Evaluated').Count | Should -Be 0
        $row = $ModernRows | Where-Object VM -eq 'vm-d4sv5'
        $row.CurrentSkuGeneration | Should -Be '5'
        $row.ModernizationStatus | Should -Not -BeNullOrEmpty
        $row.RecommendationReason | Should -Not -BeNullOrEmpty
        (Get-Content (Join-Path $ModernOut 'detailed-report.md') -Raw) | Should -Match 'VM: vm-d4sv5'
    }

    It 'separates the retirement target from the strategic modernization target' {
        $row = $ModernRows | Where-Object VM -eq 'vm-ds3v2'
        $row.RetirementTargetSku | Should -Be 'Standard_D4ds_v5'
        $row.ModernizationTargetSku | Should -Be 'Standard_D4s_v6'
        $row.ModernizationTargetSource | Should -Be 'Convertible'
        $row.ModernizationPath | Should -Be 'Gen1 + NVMe + Resize'
        $row.MigrationQuotaModel | Should -Be 'SideBySide'
        $row.RecommendedMigrationPath | Should -Match 'Retire to Standard_D4ds_v5 -> modernize to Standard_D4s_v6'
        $row.ModernizationValidationItems | Should -Match 'Guest NVMe readiness: Validation Required'
        $nvme = $ModernRows | Where-Object VM -eq 'vm-d4sv3'
        $nvme.ModernizationPath | Should -Be 'SCSI to NVMe + Resize'
        $nvme.MigrationQuotaModel | Should -Be 'InPlace'
    }

    It 'adds a Modernization quota scope with steady-state and peak demand without changing the other scopes' {
        $q = @(Import-Csv (Join-Path $ModernOut 'quota-impact.csv'))
        $retirement = $q | Where-Object { $_.Scope -eq 'Retirement' -and $_.QuotaName -eq 'standardddsv5family' }
        [int]$retirement.RequiredVcpu | Should -Be 16
        $modernRegional = $q | Where-Object { $_.Scope -eq 'Modernization' -and $_.QuotaName -eq 'cores' }
        $modernRegional | Should -Not -BeNullOrEmpty
        [int]$modernRegional.PeakMigrationRequiredVcpu | Should -BeGreaterThan ([int]$modernRegional.SteadyStateRequiredVcpu)
        $modernRegional.MigrationQuotaModel | Should -Be 'Mixed'
        @($ModernRows | Where-Object { $_.ModernizationTargetSku -and -not $_.ModernizationQuotaStatus }).Count | Should -Be 0
    }

    It 'renders the modernization section from backend quota rows' {
        $html = Get-Content (Get-ChildItem $ModernOut -Filter 'contoso-prod-*.html').FullName -Raw
        $html | Should -Match "id='modernization'"
        $html | Should -Match 'v6/v7 Generation Modernization Paths'
        $html | Should -Not -Match 'v6/v7 Modernization Readiness|<th>Complexity</th>|<dt>Complexity</dt>| complexity</span>'
        $modernTable = [regex]::Match($html, "(?s)<table class='modernization-table'>.*?</table>").Value
        $modernTable | Should -Not -BeNullOrEmpty
        ([regex]::Matches([regex]::Match($modernTable, '(?s)<thead>.*?</thead>').Value, '<th>')).Count | Should -Be 9
        foreach ($row in [regex]::Matches($modernTable, "(?s)<tr class='modernization-summary-row'>.*?</tr>")) {
            ([regex]::Matches($row.Value, '<td(?:>| )')).Count | Should -Be 9
        }
        $modernTable | Should -Match "colspan='9'"
        @($ModernRows | Where-Object ModernizationComplexity).Count | Should -BeGreaterThan 0
        $json = Get-Content (Join-Path $ModernOut 'assessment.json') -Raw | ConvertFrom-Json -Depth 40
        @($json.vms | Where-Object { $_.strategy.Complexity }).Count | Should -BeGreaterThan 0
        $html | Should -Match "class='quota-table quota-impact-table'"
        $html | Should -Match 'Total Regional vCPUs'
        $html | Should -Match 'Upgrade Gen1 VMs to Trusted launch'
        # Part 1 retirement and Part 2 modernization are separate, ordered, colour-coded bands with grouped navigation and tiles.
        $html.IndexOf("id='track-retirement'") | Should -BeLessThan $html.IndexOf("id='vms'")
        $html.IndexOf("id='details'") | Should -BeLessThan $html.IndexOf("id='track-modernization'")
        $html.IndexOf("id='track-modernization'") | Should -BeLessThan $html.IndexOf("id='modernization'")
        $html | Should -Match 'Part 1 &middot; <strong>Required</strong>'
        $html | Should -Match 'Part 2 &middot; <strong>Optional</strong>'
        $html | Should -Match "<span class='toc-group toc-modernization'><span class='toc-group-label'>Modernization</span>"
        $html | Should -Match "class='track-tile track-tile-modernization' href='#track-modernization'"
        $html | Should -Match "class='target-cell retirement-target-cell'"
        [regex]::Match($html, "(?s)<table class='vm-table'>.*?</table>").Value | Should -Match 'v6/v7: '
        $html | Should -Not -Match '<script'
    }
}

Describe 'Snapshot capture and replay (mock Azure)' {
    BeforeAll {
        $mockDir = Join-Path $PSScriptRoot 'mock'
        $script:Script = Join-Path $Root 'scripts/Invoke-VMSKURetirementReport.ps1'
        $script:Capture = Join-Path $TestDrive 'capture'
        $script:CaptureLog = & pwsh -NoProfile -Command "`$env:PATH='$mockDir$([System.IO.Path]::PathSeparator)' + `$env:PATH; & '$Script' -SaveSnapshot -SkipPricing -OutputPath '$Capture' -OfflineCatalog -AsOfDate '2026-09-24' -ThrottleLimit 2" 2>&1 | Out-String
        # Replay runs with no Azure CLI on PATH at all, proving that no Azure call is made (-SkipPricing: fully offline).
        $script:NoAz = { param([string]$ArgText)
            $cmd = "`$env:PATH = ((`$env:PATH -split [regex]::Escape([string][System.IO.Path]::PathSeparator)) | Where-Object { `$_ -and -not (Test-Path (Join-Path `$_ 'az.cmd')) -and -not (Test-Path (Join-Path `$_ 'az.ps1')) -and -not (Test-Path (Join-Path `$_ 'az')) }) -join [System.IO.Path]::PathSeparator; if (Get-Command az -ErrorAction SilentlyContinue) { throw 'az still on PATH' }; & '$Script' -SkipPricing $ArgText"
            & pwsh -NoProfile -Command $cmd 2>&1 | Out-String }
        $script:Replay = Join-Path $TestDrive 'replay'
        $script:ReplayLog = & $NoAz "-FromSnapshot '$Capture' --check-modernization -OutputPath '$Replay' -OfflineCatalog -ThrottleLimit 2"
    }
    It 'records a complete snapshot without tokens or the unmasked account' {
        $CaptureLog | Should -Match 'Snapshot: '
        $manifest = Get-Content (Join-Path $Capture 'snapshot/snapshot.json') -Raw | ConvertFrom-Json
        $manifest.TenantId | Should -Be '22222222-2222-2222-2222-222222222222'
        $manifest.Vms | Should -Be 7
        $text = (Get-ChildItem (Join-Path $Capture 'snapshot') -Recurse -File | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
        $text | Should -Not -Match 'admin@contoso\.example'
        $text | Should -Not -Match 'accessToken'
    }
    It 'replays without Azure CLI and can enable --check-modernization after the capture' {
        $ReplayLog | Should -Match 'Data: replaying snapshot captured'
        $ReplayLog | Should -Match 'Outputs:'
        $j = Get-Content (Join-Path $Replay 'assessment.json') -Raw | ConvertFrom-Json -Depth 40
        $j.dataSource | Should -Match '^Snapshot captured '
        $j.asOfDate | Should -Be '2026-09-24'
        $j.parameters.FromSnapshot | Should -BeTrue
        $j.parameters.CheckModernization | Should -BeTrue
        @(Import-Csv (Join-Path $Replay 'quota-impact.csv') | Where-Object Scope -eq 'Modernization').Count | Should -BeGreaterThan 0
        (Get-Content (Get-ChildItem $Replay -Filter 'contoso-prod-*.html').FullName -Raw) | Should -Match 'Data <strong>Snapshot captured'
    }
    It 'reproduces the captured assessment exactly' {
        $out = Join-Path $TestDrive 'replay-same'
        $null = & $NoAz "-FromSnapshot '$Capture' -OutputPath '$out' -OfflineCatalog -ThrottleLimit 2"
        foreach ($file in 'vm-assessment.csv', 'quota-impact.csv', 'candidates.csv') {
            (Get-Content (Join-Path $out $file) -Raw) | Should -Be (Get-Content (Join-Path $Capture $file) -Raw)
        }
    }
    It 'stores the Microsoft evidence with the snapshot and replays it without -OfflineCatalog' {
        Join-Path $Capture 'snapshot/retirement-catalog.json' | Should -Exist
        (Get-Content (Join-Path $Capture 'snapshot/snapshot.json') -Raw | ConvertFrom-Json).CatalogSource | Should -Match '^Cached'
        $out = Join-Path $TestDrive 'replay-evidence'
        $null = & $NoAz "-FromSnapshot '$Capture' -OutputPath '$out' -ThrottleLimit 2"
        (Get-Content (Join-Path $out 'assessment.json') -Raw | ConvertFrom-Json -Depth 40).catalog.source | Should -Match '^Cached'
        (Get-Content (Join-Path $out 'vm-assessment.csv') -Raw) | Should -Be (Get-Content (Join-Path $Capture 'vm-assessment.csv') -Raw)
    }
    It 'warns when the snapshot is more than 7 days old' {
        $old = Join-Path $TestDrive 'old-capture'
        Copy-Item -Path $Capture -Destination $old -Recurse
        $manifestPath = Join-Path $old 'snapshot/snapshot.json'
        $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
        $m.CapturedUtc = (Get-Date).ToUniversalTime().AddDays(-10).ToString('o')
        $m | ConvertTo-Json -Depth 4 | Set-Content $manifestPath -Encoding utf8
        $out = Join-Path $TestDrive 'replay-old'
        $log = & $NoAz "-FromSnapshot '$old' -OutputPath '$out' -ThrottleLimit 2"
        (($log -replace '\s*\|\s*', ' ') -replace '\s+', ' ') | Should -Match 'The snapshot is 10 days old'
        (Get-Content (Join-Path $out 'index.html') -Raw) | Should -Match 'Replayed data is 10 days old'
    }
    It 'caps the per-VM HTML details and points to the full outputs' {
        $out = Join-Path $TestDrive 'replay-capped'
        $null = & $NoAz "-FromSnapshot '$Capture' -HtmlMaxVmDetails 2 -OutputPath '$out' -ThrottleLimit 2"
        $html = Get-Content (Get-ChildItem $out -Filter 'contoso-prod-*.html').FullName -Raw
        ([regex]::Matches($html, '<details class="vm"')).Count | Should -Be 2
        $html | Should -Match 'Details are shown for the first 2 VMs'
        @(Import-Csv (Join-Path $out 'vm-assessment.csv')).Count | Should -Be 7
    }
    It 'rejects a scope that differs from the capture' {
        $log = & $NoAz "-FromSnapshot '$Capture' -SubscriptionId 99999999-9999-9999-9999-999999999999 -OutputPath '$(Join-Path $TestDrive 'bad')' -OfflineCatalog"
        (($log -replace '\s*\|\s*', ' ') -replace '\s+', ' ') | Should -Match 'SubscriptionId does not match the snapshot scope'
    }
}

Describe 'End-to-end assessment of an empty estate (mock Azure)' {
    It 'completes with zero VMs and still writes the summary outputs (with the opt-in account and raw data)' {
        $mockDir = Join-Path $PSScriptRoot 'mock'
        $out = Join-Path $TestDrive 'empty'
        $log = & pwsh -NoProfile -Command "`$env:MOCK_AZ_EMPTY='1'; `$env:PATH='$mockDir$([System.IO.Path]::PathSeparator)' + `$env:PATH; & '$(Join-Path $Root 'scripts/Invoke-VMSKURetirementReport.ps1')' -OutputPath '$out' -OfflineCatalog -AsOfDate '2026-09-24' -IncludeRightsizing -IncludeOperatorAccount -KeepRawData" 2>&1 | Out-String
        $log | Should -Match 'Outputs:'
        $log | Should -Not -Match 'Rightsizing telemetry unavailable'
        foreach ($f in 'assessment.json', 'vm-assessment.csv', 'executive-summary.md', 'index.html', 'data/vm-inventory.json') { Join-Path $out $f | Should -Exist }
        $j = Get-Content (Join-Path $out 'assessment.json') -Raw | ConvertFrom-Json
        $j.summary.TotalVmsScanned | Should -Be 0
        $j.signedInAccount | Should -Be 'admin@contoso.example'
        $j.parameters.IncludeOperatorAccount | Should -BeTrue
        $j.parameters.KeepRawData | Should -BeTrue
    }
}

Describe 'Authentication preflight (mock Azure)' {
    It 'suggests the single-dash parameter for a double-dash PowerShell parameter' {
        $log = & pwsh -NoProfile -Command "& '$(Join-Path $Root 'scripts/Invoke-VMSKURetirementReport.ps1')' --tenantID 22222222-2222-2222-2222-222222222222" 2>&1 | Out-String
        $log = ($log -replace '\s*\|\s*', ' ') -replace '\s+', ' '
        $log | Should -Match "Unknown argument '--tenantID'\. PowerShell parameters use a single dash: use -TenantId instead\."
    }
    It 'fails fast with sign-in guidance when az waits for interactive sign-in' {
        $mockDir = Join-Path $PSScriptRoot 'mock'
        $out = Join-Path $TestDrive 'hang'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $log = & pwsh -NoProfile -Command "`$env:MOCK_AZ_TOKEN_HANG='1'; `$env:PATH='$mockDir$([System.IO.Path]::PathSeparator)' + `$env:PATH; & '$(Join-Path $Root 'scripts/Invoke-VMSKURetirementReport.ps1')' -OutputPath '$out' -OfflineCatalog -AuthTimeoutSec 10" 2>&1 | Out-String
        $sw.Stop()
        $log = ($log -replace '\s*\|\s*', ' ') -replace '\s+', ' '
        $log | Should -Match 'Timed out after 10 s'
        $log | Should -Match 'az login --tenant 22222222-2222-2222-2222-222222222222'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 90
        Join-Path $out 'vm-assessment.csv' | Should -Not -Exist
    }
}
