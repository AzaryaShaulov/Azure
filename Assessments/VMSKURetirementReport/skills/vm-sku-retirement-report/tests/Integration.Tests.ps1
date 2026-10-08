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
    $script:Log = & pwsh -NoProfile -Command "`$env:PATH='$mockDir$([System.IO.Path]::PathSeparator)' + `$env:PATH; & '$(Join-Path $Root 'scripts/Invoke-VMSKURetirementReport.ps1')' -OutputPath '$Out' -OfflineCatalog -AsOfDate '2026-09-24' -ThrottleLimit 2" 2>&1 | Out-String
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
    It 'lists only VMs with an announced retirement date and a required action in the HTML, under Overview' {
        $html = Get-Content (Get-ChildItem $Out -Filter 'contoso-prod-*.html').FullName -Raw
        $html | Should -Match '<h2>VMs with Retiring SKUs</h2>'
        $html | Should -Match '<h2>VMs with Retiring SKUs details</h2>'
        $html | Should -Not -Match 'VM Assessment</h2>|Recommendations in Detail'
        $html.IndexOf("id='overview'") | Should -BeLessThan $html.IndexOf("id='vms'")
        $html.IndexOf("id='vms'") | Should -BeLessThan $html.IndexOf("id='details'")
        $html.IndexOf("id='details'") | Should -BeLessThan $html.IndexOf("id='quota'")
        $retiring = @($Rows | Where-Object { $_.AffectedByRetirement -eq 'Yes' -and $_.RetirementDate -and $_.Action -ne 'No Action Required' })
        $excluded = @($Rows | Where-Object { $_.VM -notin $retiring.VM })
        $retiring.Count | Should -BeGreaterThan 0
        $excluded.Count | Should -BeGreaterThan 0
        foreach ($r in $retiring) { $html | Should -Match ">$([regex]::Escape($r.VM))<" }
        foreach ($r in $excluded) { $html | Should -Not -Match ">$([regex]::Escape($r.VM))<" }
        $Rows.Count | Should -Be 7
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
    }
}

Describe 'End-to-end opt-in modernization assessment (mock Azure)' {
    BeforeAll {
        $mockDir = Join-Path $PSScriptRoot 'mock'
        $script:ModernOut = Join-Path $TestDrive 'modernization'
        $script:ModernLog = & pwsh -NoProfile -Command "`$env:PATH='$mockDir$([System.IO.Path]::PathSeparator)' + `$env:PATH; & '$(Join-Path $Root 'scripts/Invoke-VMSKURetirementReport.ps1')' --check-modernization -OutputPath '$ModernOut' -OfflineCatalog -AsOfDate '2026-09-24' -ThrottleLimit 2" 2>&1 | Out-String
        $script:ModernRows = if (Test-Path (Join-Path $ModernOut 'vm-assessment.csv')) { Import-Csv (Join-Path $ModernOut 'vm-assessment.csv') } else { @() }
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
        $html | Should -Match "class='quota-table quota-impact-table'"
        $html | Should -Match 'Total Regional vCPUs'
        $html | Should -Match 'Upgrade Gen1 VMs to Trusted launch'
        $html | Should -Not -Match '<script'
    }
}

Describe 'Snapshot capture and replay (mock Azure)' {
    BeforeAll {
        $mockDir = Join-Path $PSScriptRoot 'mock'
        $script:Script = Join-Path $Root 'scripts/Invoke-VMSKURetirementReport.ps1'
        $script:Capture = Join-Path $TestDrive 'capture'
        $script:CaptureLog = & pwsh -NoProfile -Command "`$env:PATH='$mockDir$([System.IO.Path]::PathSeparator)' + `$env:PATH; & '$Script' -SaveSnapshot -OutputPath '$Capture' -OfflineCatalog -AsOfDate '2026-09-24' -ThrottleLimit 2" 2>&1 | Out-String
        # Replay runs with no Azure CLI on PATH at all, proving that no Azure call is made.
        $script:NoAz = { param([string]$ArgText)
            $cmd = "`$env:PATH = ((`$env:PATH -split [regex]::Escape([string][System.IO.Path]::PathSeparator)) | Where-Object { `$_ -and -not (Test-Path (Join-Path `$_ 'az.cmd')) -and -not (Test-Path (Join-Path `$_ 'az.ps1')) -and -not (Test-Path (Join-Path `$_ 'az')) }) -join [System.IO.Path]::PathSeparator; if (Get-Command az -ErrorAction SilentlyContinue) { throw 'az still on PATH' }; & '$Script' $ArgText"
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
