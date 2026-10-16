#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Offline unit tests for the VM SKU retirement assessment. No Azure access required.
    Run:  Invoke-Pester -Path ./tests -Output Detailed
#>
BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    foreach ($m in 'Common', 'Retirement', 'SkuCatalog', 'Inventory', 'Scoring', 'Candidates', 'Quota', 'Rightsizing', 'Assessment', 'Output') {
        Import-Module (Join-Path $Root "scripts/modules/$m.psm1") -Force -DisableNameChecking
    }
    $script:SeriesMap = Get-SeriesMap -Path (Join-Path $Root 'data/series-map.json')
    $script:Weights = Get-Content (Join-Path $Root 'data/scoring-weights.json') -Raw | ConvertFrom-Json
    $script:Proc = Get-Content (Join-Path $Root 'data/processor-catalog.json') -Raw | ConvertFrom-Json
    $script:AsOf = [datetime]'2026-09-24'
    $fx = Join-Path $PSScriptRoot 'fixtures'
    $pages = @{
        RetiredList    = @{ Url = 'https://learn.microsoft.com/test/retired'; Html = (Get-Content (Join-Path $fx 'retired-sizes-list.html') -Raw); RetrievedUtc = '2026-09-24T00:00:00Z' }
        PreviousGen    = @{ Url = 'https://learn.microsoft.com/test/prevgen'; Html = (Get-Content (Join-Path $fx 'previous-gen-sizes-list.html') -Raw); RetrievedUtc = '2026-09-24T00:00:00Z' }
        MigrationGuide = @{ Url = 'https://learn.microsoft.com/test/guide'; Html = (Get-Content (Join-Path $fx 'migration-guide.html') -Raw); RetrievedUtc = '2026-09-24T00:00:00Z' }
    }
    $script:Catalog = New-RetirementCatalog -Pages $pages -SeriesMap $SeriesMap
    $script:SkuCat = @{}
    foreach ($s in (Get-Content (Join-Path $fx 'skus-eastus2.json') -Raw | ConvertFrom-Json)) { $SkuCat[$s.name.ToLowerInvariant()] = ConvertTo-SkuRecord -Sku $s -Region 'eastus2' }

    function script:New-TestVm {
        param([string]$Name = 'vm1', [string]$Sku, [string]$Gen = 'V2', [string]$Controller, [string[]]$Zones, [string]$DiskType = 'Premium_LRS', [bool]$Accel = $true, [int]$Nics = 1, [string]$Security = '', [string]$Power = 'PowerState/running')
        $row = [pscustomobject]@{
            id = "/subscriptions/s1/resourcegroups/rg/providers/microsoft.compute/virtualmachines/$Name"; name = $Name; resourceGroup = 'rg'; subscriptionId = 's1'; location = 'eastus2'
            zones = $Zones; vmSize = $Sku; powerState = $Power; osType = 'Linux'; hyperVGen = $Gen; osDiskType = $DiskType; diskController = $Controller
            dataDisks = @(); nicIds = @(1..$Nics | ForEach-Object { @{ id = "nic$_" } }); securityType = $Security; encryptionAtHost = $false
        }
        ConvertTo-VmRecord -Vm $row -Nics @(1..$Nics | ForEach-Object { [pscustomobject]@{ accelerated = $Accel } })
    }
    function script:Invoke-TestAssessment {
        param(
            $Vm,
            [hashtable]$Catalog = $script:SkuCat,
            $RetirementCatalog = $script:Catalog,
            [datetime]$AsOfDate = $script:AsOf,
            [int]$MaxCandidates = 3,
            [switch]$CheckModernization,
            [string]$QuotaStatus = 'Quota OK'
        )
        $lc = Resolve-SkuLifecycle -SkuName $Vm.SkuName -Catalog $RetirementCatalog -AsOf $AsOfDate
        $a = New-VmAssessment -Vm $Vm -Lifecycle $lc -RegionCatalog $Catalog -ProcessorCatalog $script:Proc -RetirementCatalog $RetirementCatalog `
            -LifecycleCache @{} -CandidateCache @{} -Weights $script:Weights -AsOf $AsOfDate -SubscriptionName 'sub1' -MaxCandidates $MaxCandidates `
            -CheckModernization:$CheckModernization
        $q = [pscustomobject]@{ Status = $QuotaStatus; DataQuality = 'Verified'; Family = [pscustomobject]@{ QuotaDisplayName = 'x'; MinimumIncrease = 0; RecommendedIncrease = 0; CurrentUsage = 0; Limit = 100; RequiredVcpu = 4 }; Regional = [pscustomobject]@{ MinimumIncrease = 0 } }
        Complete-VmAssessment -Assessment $a -QuotaResult $q -Usage @{}
    }
}

Describe 'SKU name parsing (Azure naming convention)' {
    It 'parses <Sku>' -ForEach @(
        @{ Sku = 'Standard_D4s_v5'; Family = 'D'; Features = 's'; Version = 5; Key = 'dsv5'; Vendor = 'Intel' }
        @{ Sku = 'Standard_DS3_v2'; Family = 'D'; Features = 's'; Version = 2; Key = 'dsv2'; Vendor = 'Intel' }
        @{ Sku = 'Standard_D2_v2_Promo'; Family = 'D'; Features = ''; Version = 2; Key = 'dv2'; Vendor = 'Intel' }
        @{ Sku = 'Standard_E4-2s_v3'; Family = 'E'; Features = 's'; Version = 3; Key = 'esv3'; Vendor = 'Intel' }
        @{ Sku = 'Standard_D4as_v5'; Family = 'D'; Features = 'as'; Version = 5; Key = 'dasv5'; Vendor = 'AMD' }
        @{ Sku = 'Standard_D4ps_v6'; Family = 'D'; Features = 'ps'; Version = 6; Key = 'dpsv6'; Vendor = 'ARM' }
        @{ Sku = 'Standard_NC24ads_A100_v4'; Family = 'NC'; Features = 'ads'; Version = 4; Key = 'ncadsa100v4'; Vendor = 'AMD' }
        @{ Sku = 'Standard_B2ms'; Family = 'B'; Features = 'ms'; Version = 1; Key = 'bms'; Vendor = 'Intel' }
    ) {
        $i = Get-SkuNameInfo -SkuName $Sku
        $i.Parsed | Should -BeTrue
        $i.Family | Should -Be $Family
        $i.Features | Should -Be $Features
        $i.Version | Should -Be $Version
        $i.SeriesKey | Should -Be $Key
        $i.VendorHint | Should -Be $Vendor
    }
    It 'flags constrained and promo sizes' {
        (Get-SkuNameInfo 'Standard_E4-2s_v3').Constrained | Should -Be 2
        (Get-SkuNameInfo 'Standard_D2_v2_Promo').IsPromo | Should -BeTrue
    }
}

Describe 'Default assessment output path' {
    It 'stores tenant reports under the repository reports folder' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) 'VMSKURetirementReport'
        $path = Get-DefaultAssessmentOutputPath -RepositoryRoot $root -TenantName 'Contoso / Production' -RunStamp '2026-09-28_1933'
        $path | Should -Be (Join-Path (Join-Path (Join-Path $root 'reports') 'Contoso---Production') '2026-09-28_1933-VMSKURetirementReport')
    }
}

Describe 'Personal data in outputs and messages' {
    It 'masks the signed-in account (<Account> -> <Expected>)' -ForEach @(
        @{ Account = 'jane.doe@contoso.com'; Expected = 'j****@contoso.com' }
        @{ Account = 'a@contoso.example'; Expected = 'a****@contoso.example' }
        @{ Account = '11111111-aaaa-bbbb-cccc-222222222222'; Expected = '1111****' }
        @{ Account = 'svc'; Expected = '****' }
    ) {
        Get-MaskedAccount $Account | Should -Be $Expected
    }
    It 'returns nothing for an empty account' {
        Get-MaskedAccount $null | Should -BeNullOrEmpty
        Get-MaskedAccount '' | Should -BeNullOrEmpty
    }
    It 'hides the home directory in displayed paths' {
        ConvertTo-DisplayPath (Join-Path $HOME 'repo/reports/run') | Should -Be (Join-Path '~' 'repo/reports/run')
        ConvertTo-DisplayPath 'D:\data\reports' | Should -Be 'D:\data\reports'
    }
    It 'sanitizes Azure CLI error text before it is shown or logged' {
        $raw = "ERROR: AADSTS50076: User 'jane.doe@contoso.com' must use MFA.`n  Cache: $(Join-Path $HOME '.azure/msal_token_cache.json')"
        $safe = ConvertTo-SafeCliMessage $raw
        $safe | Should -Match "User 'j\*\*\*\*@contoso\.com' must use MFA\. Cache: ~"
        $safe | Should -Not -Match 'jane\.doe'
        $safe | Should -Not -Match ([regex]::Escape($HOME))
        (ConvertTo-SafeCliMessage ('x' * 1000)).Length | Should -Be 403
        ConvertTo-SafeCliMessage $null | Should -Be ''
    }
    It 'throws sanitized errors from Invoke-AzJson' {
        $fake = Join-Path $TestDrive 'fake-az'; New-Item -ItemType Directory $fake -Force | Out-Null
        Set-Content (Join-Path $fake 'az.ps1') -Value "Write-Error `"ERROR: The user 'jane.doe@contoso.com' has no access.`" -ErrorAction Continue; exit 1"
        $savedPath = $env:PATH
        try {
            $env:PATH = "$fake$([System.IO.Path]::PathSeparator)$env:PATH"
            $msg = try { Invoke-AzJson -Arguments @('account', 'show') -MaxRetries 0; '' } catch { $_.Exception.Message }
        }
        finally { $env:PATH = $savedPath }
        $msg | Should -Match 'failed \(exit 1\)'
        $msg | Should -Match 'j\*\*\*\*@contoso\.com'
        $msg | Should -Not -Match 'jane\.doe'
    }
}

Describe 'Microsoft Learn lifecycle parsing' {
    It 'parses the retired-sizes table with dates and announcement links' {
        $d = $Catalog.series | Where-Object key -eq 'dsv2'
        $d.retiredList.status | Should -Be 'Announced'
        $d.retiredList.plannedRetirementDate | Should -Be '2028-05-01'
        $d.retiredList.announcementUrl | Should -Match 'azure.microsoft.com/updates'
    }
    It 'maps single-SKU rows (Standard_M192ids_v2) to exact patterns' {
        $m = Find-CatalogSeries -SkuName 'Standard_M192ids_v2' -Catalog $Catalog
        $m.key | Should -Be 'standard_m192ids_v2'
    }
    It 'captures migration-guide replacement series' {
        ($Catalog.series | Where-Object key -eq 'av2').recommendedTargets | Should -Contain 'bsv2'
        ($Catalog.series | Where-Object key -eq 'np').recommendedTargets | Should -Contain 'ncadsh100v5'
    }
    It 'fails closed when the migration guide parses to no recognized rows' {
        $badPages = @{} + $pages
        $badPages.MigrationGuide = @{ Url = 'https://learn.microsoft.com/test/guide'; Html = '<html><body><p>unexpected layout</p></body></html>'; RetrievedUtc = '2026-09-24T00:00:00Z' }
        { New-RetirementCatalog -Pages $badPages -SeriesMap $SeriesMap } | Should -Throw '*Migration guide parsed to zero recognized rows*'
    }
    It 'records Microsoft source provenance' {
        @($Catalog.sources).Count | Should -Be 3
        ($Catalog.sources | Where-Object Name -eq 'RetiredList').GitCommitId | Should -Not -BeNullOrEmpty
    }
    It 'reports unknown Learn series as unmapped instead of guessing' {
        @($Catalog.unmappedSeries | Where-Object SeriesName -eq 'Zz-series').Count | Should -Be 1
    }
}

Describe 'Lifecycle classification (never infer retirement from age)' {
    It '<Sku> -> <Class> / <Urgency>' -ForEach @(
        @{ Sku = 'Standard_DS3_v2'; Class = 'Confirmed Retirement'; Urgency = '12-24 Months'; Date = '2028-05-01' }
        @{ Sku = 'Standard_F8s_v2'; Class = 'Confirmed Retirement'; Urgency = '24-36 Months'; Date = '2028-11-15' }
        @{ Sku = 'Standard_B2ms'; Class = 'Confirmed Retirement'; Urgency = '24-36 Months'; Date = '2028-11-15' }
        @{ Sku = 'Standard_NC6s_v3'; Class = 'Already Retired'; Urgency = 'Already Retired'; Date = '2025-09-30' }
        @{ Sku = 'Standard_NV12s_v3'; Class = 'Confirmed Retirement'; Urgency = 'Less than 12 Months'; Date = '2026-09-30' }
        @{ Sku = 'Standard_HB120rs_v2'; Class = 'Retirement Announced'; Urgency = 'Less than 12 Months'; Date = '2027-05-31' }
        @{ Sku = 'Standard_D4s_v3'; Class = 'Modernization Recommended'; Urgency = 'No Retirement Announced'; Date = $null }
        @{ Sku = 'Standard_E8s_v4'; Class = 'Modernization Recommended'; Urgency = 'No Retirement Announced'; Date = $null }
        @{ Sku = 'Standard_D4s_v5'; Class = 'No Retirement Announced'; Urgency = 'No Retirement Announced'; Date = $null }
        @{ Sku = 'Standard_B4as_v2'; Class = 'No Retirement Announced'; Urgency = 'No Retirement Announced'; Date = $null }
        @{ Sku = 'Standard_D8as_v4'; Class = 'No Retirement Announced'; Urgency = 'No Retirement Announced'; Date = $null }
    ) {
        $r = Resolve-SkuLifecycle -SkuName $Sku -Catalog $Catalog -AsOf $AsOf
        $r.EvidenceClass | Should -Be $Class
        $r.Urgency | Should -Be $Urgency
        $r.RetirementDate | Should -Be $Date
    }
    It 'notes that Dv3/Dsv3 are Product active (not retiring) per the migration guide' {
        $r = Resolve-SkuLifecycle -SkuName 'Standard_D4s_v3' -Catalog $Catalog -AsOf $AsOf
        ($r.Notes -join ' ') | Should -Match 'Product active'
    }
    It 'classifies a SKU of an unmapped Learn series as Unable to Confirm' {
        $r = Resolve-SkuLifecycle -SkuName 'Standard_Z4_v9' -Catalog $Catalog -AsOf $AsOf
        $r.EvidenceClass | Should -BeIn 'No Retirement Announced', 'Unable to Confirm'
        $r2 = Resolve-SkuLifecycle -SkuName 'Standard_Zz4' -Catalog $Catalog -AsOf $AsOf
        $r2.EvidenceClass | Should -Be 'Unable to Confirm'
    }
    It 'marks cached evidence as Partially Verified' {
        $r = Resolve-SkuLifecycle -SkuName 'Standard_DS3_v2' -Catalog $Catalog -AsOf $AsOf -CatalogSource 'Cached (2026-09-01)'
        $r.DataQuality | Should -Be 'Partially Verified'
    }
    It 'computes urgency buckets from the Microsoft date only' {
        Get-RetirementUrgency -RetirementDate ([datetime]'2027-01-01') -AsOf $AsOf -EvidenceClass 'Confirmed Retirement' | Should -Be 'Less than 12 Months'
        Get-RetirementUrgency -RetirementDate ([datetime]'2030-01-01') -AsOf $AsOf -EvidenceClass 'Confirmed Retirement' | Should -Be 'More than 36 Months'
        Get-RetirementUrgency -RetirementDate $null -AsOf $AsOf -EvidenceClass 'Retirement Announced' | Should -Be 'Unable to Determine'
    }
}

Describe 'Processor / CPU vendor resolution' {
    It 'uses the Learn processor catalog over naming (Lsv2 is AMD despite no "a")' {
        $p = Get-ProcessorInfo -SkuName 'Standard_L8s_v2' -ProcessorCatalog $Proc -SkuRecord $null
        $p.Vendor | Should -Be 'AMD'
        $p.VendorQuality | Should -Be 'Verified'
    }
    It 'falls back to the naming convention as Partially Verified' {
        $p = Get-ProcessorInfo -SkuName 'Standard_Q4s_v9' -ProcessorCatalog $Proc -SkuRecord $null
        $p.VendorQuality | Should -Be 'Partially Verified'
    }
    It 'labels a base-series catalog fallback as Partially Verified' {
        $catalog = [pscustomobject]@{ series = [pscustomobject]@{
                dsv5 = [pscustomobject]@{ vendor = 'Intel'; architecture = 'x64'; processors = @('Intel test'); sourceUrl = 'https://learn.microsoft.com/test' }
            } }
        $p = Get-ProcessorInfo -SkuName 'Standard_D4ds_v5' -ProcessorCatalog $catalog -SkuRecord $null
        $p.Vendor | Should -Be 'Intel'
        $p.VendorQuality | Should -Be 'Partially Verified'
    }
    It 'takes architecture from Resource SKU capability data' {
        $p = Get-ProcessorInfo -SkuName 'Standard_D4ps_v6' -ProcessorCatalog $Proc -SkuRecord $SkuCat['standard_d4ps_v6']
        $p.Architecture | Should -Be 'Arm64'
        $p.Vendor | Should -Be 'ARM'
    }
}

Describe 'Resource SKU normalization' {
    It 'reads capabilities, arrays and subscription restrictions' {
        $r = $SkuCat['standard_d4s_v6']
        $r.HyperVGenerations | Should -Be @('V2')
        $r.DiskControllerTypes | Should -Be @('NVMe')
        $r.HasTempDisk | Should -BeFalse
        $SkuCat['standard_e4s_v5'].LocationRestricted | Should -BeTrue
        $SkuCat['standard_d4s_v3'].DiskControllerTypes | Should -Be @('SCSI')
    }
    It 'ignores location and zone restrictions that apply only to another region' {
        $sku = [pscustomobject]@{
            name = 'Standard_Test_v1'; family = 'standardTestFamily'; tier = 'Standard'
            capabilities = @([pscustomobject]@{ name = 'vCPUs'; value = '2' })
            locationInfo = @([pscustomobject]@{ location = 'eastus2'; zones = @('1', '2', '3') })
            restrictions = @(
                [pscustomobject]@{ type = 'Location'; reasonCode = 'NotAvailableForSubscription'; values = @('westus'); restrictionInfo = [pscustomobject]@{ locations = @('westus') } }
                [pscustomobject]@{ type = 'Zone'; reasonCode = 'NotAvailableForSubscription'; values = @('1'); restrictionInfo = [pscustomobject]@{ locations = @('westus'); zones = @('1') } }
            )
        }
        $r = ConvertTo-SkuRecord -Sku $sku -Region 'eastus2'
        $r.LocationRestricted | Should -BeFalse
        $r.RestrictedZones | Should -BeNullOrEmpty
    }
}

Describe 'Candidate selection and mandatory gates' {
    It 'Gen1 SCSI Dsv2 -> same-vendor v5 with temp disk; v6 rejected with explicit reasons' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1')
        $a.Candidates.Primary.SkuName | Should -Be 'Standard_D4ds_v5'
        $a.Candidates.Primary.CpuVendor | Should -Be 'Intel'
        $v6 = $a.Candidates.Candidates | Where-Object SkuName -eq 'Standard_D4s_v6'
        $v6.Rejected | Should -BeTrue
        $v6.FailedGates | Should -Contain 'VM Generation'
        $v6.FailedGates | Should -Contain 'Disk Controller'
        $a.Candidates.FutureGeneration.SkuName | Should -Be 'Standard_D4s_v6'
    }

    Describe 'Opt-in v6/v7 modernization assessment' {
        BeforeAll {
            $script:ModernCatalog = @{
                'standard_d4s_v3' = $SkuCat['standard_d4s_v3']
                'standard_d4s_v6' = $SkuCat['standard_d4s_v6']
            }
            $v7 = $SkuCat['standard_d4s_v6'].PSObject.Copy()
            $v7.Name = 'Standard_D4s_v7'
            $v7.Family = 'standardDSv7Family'
            $script:ModernCatalog['standard_d4s_v7'] = $v7
        }

        It 'does not run or alter recommendations unless explicitly enabled' {
            $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_D4s_v5' -Controller 'NVMe')
            $a.Candidates | Should -BeNullOrEmpty
            $a.Modernization | Should -BeNullOrEmpty
            (ConvertTo-AssessmentRow $a).ModernizationStatus | Should -Be 'Not Evaluated'
        }

        It 'prefers a suitable v7 SKU over v6 and reports all modernization fields' {
            $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_D4s_v3' -Controller 'NVMe') -Catalog $ModernCatalog -CheckModernization
            $row = ConvertTo-AssessmentRow $a
            $a.Candidates.Primary.SkuName | Should -Be 'Standard_D4s_v7'
            $row.CurrentSkuGeneration | Should -Be 3
            $row.RecommendedSkuGeneration | Should -Be 7
            $row.ModernizationStatus | Should -Be 'Modernize to v7'
            $row.CurrentVcpu | Should -Be 4
            $row.RecommendedVcpu | Should -Be 4
            $row.SkuRegionalAvailability | Should -Be 'Available'
            $row.RecommendationReason | Should -Match 'newest suitable v7'
        }

        It 'falls back to v6 when no suitable v7 SKU exists' {
            $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_D4s_v3' -Controller 'NVMe') -Catalog @{
                'standard_d4s_v3' = $SkuCat['standard_d4s_v3']
                'standard_d4s_v6' = $SkuCat['standard_d4s_v6']
            } -CheckModernization
            $a.Candidates.Primary.SkuName | Should -Be 'Standard_D4s_v6'
            $a.Modernization.Status | Should -Be 'Modernize to v6'
        }

        It 'retains the existing recommendation when v6/v7 options fail workload gates' {
            $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1') -CheckModernization
            $a.Candidates.Primary.SkuName | Should -Be 'Standard_D4ds_v5'
            $a.Modernization.Status | Should -Be 'No suitable modern SKU found'
            $a.Modernization.Reason | Should -Match 'Retaining existing recommendation Standard_D4ds_v5'
        }

        It 'marks v6 and v7 VMs as already modern without creating a migration' {
            $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_D4s_v6' -Controller 'NVMe') -Catalog $ModernCatalog -CheckModernization
            $row = ConvertTo-AssessmentRow $a
            $a.Action | Should -Be 'No Action Required'
            $row.RecommendedSku | Should -Be 'Standard_D4s_v6'
            $row.ModernizationStatus | Should -Be 'Already on modern generation'
            $row.QuotaStatus | Should -Be 'Not Applicable'
        }

        It 'still applies retirement quota when an already-modern VM has a migration recommendation' {
            $modern = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_D4s_v6' -Controller 'NVMe') -Catalog $ModernCatalog -CheckModernization
            $replacement = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_D4s_v3' -Controller 'NVMe') -Catalog $ModernCatalog
            $modern.Candidates = $replacement.Candidates
            $q = [pscustomobject]@{ Status = 'Quota Increase Required'; DataQuality = 'Verified'; Family = [pscustomobject]@{ MinimumIncrease = 4 }; Regional = [pscustomobject]@{ MinimumIncrease = 0 } }
            [void](Complete-VmAssessment -Assessment $modern -QuotaResult $q -Usage @{})
            $modern.QuotaStatus | Should -Be 'Quota Increase Required'
            $modern.Readiness | Should -Be 'Quota Increase Required'
        }

        It 'reports insufficient quota for an otherwise suitable modernization target' {
            $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_D4s_v3' -Controller 'NVMe') -Catalog $ModernCatalog -CheckModernization -QuotaStatus 'Quota Increase Required'
            $a.Modernization.Status | Should -Be 'Insufficient quota'
            $a.Modernization.Reason | Should -Match 'quota is insufficient'
        }

        It 'falls back from quota-blocked v7 to deployable v6 and retains v7 as an alternative' {
            $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_D4s_v3' -Controller 'NVMe') -Catalog $ModernCatalog -CheckModernization
            $usage = @{ 's1|eastus2' = @{
                    'standarddsv7family' = [pscustomobject]@{ Name = 'standardDSv7Family'; LocalName = 'DSv7'; Used = 100; Limit = 100 }
                    'standarddsv6family' = [pscustomobject]@{ Name = 'standardDSv6Family'; LocalName = 'DSv6'; Used = 0; Limit = 100 }
                    'cores' = [pscustomobject]@{ Name = 'cores'; LocalName = 'Regional'; Used = 4; Limit = 100 }
                } }
            [void](Resolve-ModernizationQuotaChoices -Assessments @($a) -Usage $usage)
            $a.Candidates.Primary.SkuName | Should -Be 'Standard_D4s_v6'
            $a.Modernization.Status | Should -Be 'Modernize to v6'
            $a.Candidates.Secondary.SkuName | Should -Be 'Standard_D4s_v7'
            $a.SecondaryReason | Should -Match 'blocked by aggregate quota'
        }

        It 'gives identical VMs independent quota decisions even though they share one candidate evaluation' {
            $cache = @{}
            $make = { param($Name)
                $vm = New-TestVm -Name $Name -Sku 'Standard_D4s_v3' -Controller 'NVMe'
                $lc = Resolve-SkuLifecycle -SkuName $vm.SkuName -Catalog $Catalog -AsOf $AsOf
                $x = New-VmAssessment -Vm $vm -Lifecycle $lc -RegionCatalog $ModernCatalog -ProcessorCatalog $Proc -RetirementCatalog $Catalog `
                    -LifecycleCache @{} -CandidateCache $cache -Weights $Weights -AsOf $AsOf -SubscriptionName 'sub1' -CheckModernization
                Update-VmAction -Assessment $x }
            $a1 = & $make 'vm-a'; $a2 = & $make 'vm-b'
            $cache.Count | Should -Be 1
            [object]::ReferenceEquals($a1.Candidates, $a2.Candidates) | Should -BeFalse
            $usage = @{ 's1|eastus2' = @{
                    'standarddsv7family' = [pscustomobject]@{ Name = 'standardDSv7Family'; LocalName = 'DSv7'; Used = 0; Limit = 4 }
                    'standarddsv6family' = [pscustomobject]@{ Name = 'standardDSv6Family'; LocalName = 'DSv6'; Used = 0; Limit = 100 }
                    'cores' = [pscustomobject]@{ Name = 'cores'; LocalName = 'Regional'; Used = 0; Limit = 100 } } }
            [void](Resolve-ModernizationQuotaChoices -Assessments @($a1, $a2) -Usage $usage)
            # Only one 4-vCPU VM fits the DSv7 limit; the other falls back to v6 and keeps v7 as the quota-blocked alternative.
            @(@($a1, $a2) | Where-Object { $_.Candidates.Primary.SkuName -eq 'Standard_D4s_v7' }).Count | Should -Be 1
            @(@($a1, $a2) | Where-Object { $_.Candidates.Primary.SkuName -eq 'Standard_D4s_v6' }).Count | Should -Be 1
            $fallback = @($a1, $a2) | Where-Object { $_.Candidates.Primary.SkuName -eq 'Standard_D4s_v6' }
            $fallback.Candidates.Secondary.SkuName | Should -Be 'Standard_D4s_v7'
            $fallback.Modernization.Status | Should -Be 'Modernize to v6'
        }

        It 'resolves modernization quota for a large estate in linear time' {
            $cache = @{}
            $set = foreach ($i in 1..300) {
                $vm = New-TestVm -Name ('vm{0:d3}' -f $i) -Sku 'Standard_D4s_v3' -Controller 'NVMe'
                $lc = Resolve-SkuLifecycle -SkuName $vm.SkuName -Catalog $Catalog -AsOf $AsOf
                Update-VmAction -Assessment (New-VmAssessment -Vm $vm -Lifecycle $lc -RegionCatalog $ModernCatalog -ProcessorCatalog $Proc -RetirementCatalog $Catalog `
                        -LifecycleCache @{} -CandidateCache $cache -Weights $Weights -AsOf $AsOf -SubscriptionName 'sub1' -CheckModernization)
            }
            $usage = @{ 's1|eastus2' = @{
                    'standarddsv7family' = [pscustomobject]@{ Name = 'standardDSv7Family'; LocalName = 'DSv7'; Used = 0; Limit = 400 }
                    'standarddsv6family' = [pscustomobject]@{ Name = 'standardDSv6Family'; LocalName = 'DSv6'; Used = 0; Limit = 2000 }
                    'cores' = [pscustomobject]@{ Name = 'cores'; LocalName = 'Regional'; Used = 0; Limit = 5000 } } }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            [void](Resolve-ModernizationQuotaChoices -Assessments @($set) -Usage $usage)
            $sw.Stop()
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 15
            @($set | Where-Object { $_.Candidates.Primary.SkuName -eq 'Standard_D4s_v7' }).Count | Should -Be 100
            @($set | Where-Object { $_.Candidates.Primary.SkuName -eq 'Standard_D4s_v6' }).Count | Should -Be 200
        }
        It 'does not treat unavailable quota information as verified insufficiency' {
            $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_D4s_v3' -Controller 'NVMe') -Catalog $ModernCatalog -CheckModernization
            [void](Resolve-ModernizationQuotaChoices -Assessments @($a) -Usage @{})
            $a.Candidates.Primary.SkuName | Should -Be 'Standard_D4s_v7'
            $a.Modernization.Status | Should -Be 'Modernize to v7'
            $a.Modernization.Reason | Should -Match 'quota requires manual validation'
            $a.Modernization.PSObject.Properties.Name | Should -Not -Contain 'QuotaBlockedAlternatives'
        }

        It 'reports architecture mismatch when only Arm64 modern sizes are available' {
            $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_D4s_v5') -Catalog @{
                'standard_d4s_v5' = $SkuCat['standard_d4s_v5']
                'standard_d4ps_v6' = $SkuCat['standard_d4ps_v6']
            } -CheckModernization
            $a.Modernization.Status | Should -Be 'Architecture mismatch'
            $a.Modernization.Reason | Should -Match 'none preserves.*x64'
        }

        It 'reports regional unavailability when the region catalog has no v6/v7 family size' {
            $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_D4s_v5') -Catalog @{
                'standard_d4s_v5' = $SkuCat['standard_d4s_v5']
            } -CheckModernization
            $a.Modernization.Status | Should -Be 'SKU unavailable in region'
        }
    }
    It 'never auto-selects a different CPU vendor when a same-vendor size is valid' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1')
        $a.Candidates.VendorChangeRequired | Should -BeFalse
        @($a.Candidates.Primary, $a.Candidates.Secondary | Where-Object { $_ } | Where-Object { $_.CpuVendor -ne 'Intel' }).Count | Should -Be 0
    }
    It 'never downsizes (low-memory Dlsv5 is excluded)' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_D4s_v3')
        @($a.Candidates.Candidates | Where-Object SkuName -eq 'Standard_D4ls_v5').Count | Should -Be 0
    }
    It 'never crosses CPU architecture (Arm64 candidate excluded for x64 VM)' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_D4s_v3')
        @($a.Candidates.Candidates | Where-Object CpuArchitecture -ne 'x64').Count | Should -Be 0
    }
    It 'surfaces disk-throughput regression and offers a capability-preserving alternative' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1')
        ($a.ValidationItems -join ' ') | Should -Match 'Capability reduced'
        $a.Confidence.Level | Should -Not -Be 'HIGH'
        @($a.Candidates.Candidates | Where-Object Variant -eq 'Capability-preserving').Count | Should -BeGreaterThan 0
    }
    It 'NVMe Gen2 VM goes to the newest generation and flags temp-disk removal' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_D4s_v3' -Controller 'NVMe')
        $a.Candidates.Primary.SkuName | Should -Be 'Standard_D4s_v6'
        ($a.ValidationItems -join ' ') | Should -Match 'Temp / Local Disk'
        $a.Confidence.Level | Should -Be 'MEDIUM'
    }
    It 'rejects a candidate that lacks Accelerated Networking when the VM uses it' {
        $vm = New-TestVm -Sku 'Standard_D4s_v3'
        $cand = $SkuCat['standard_d4s_v5'].PSObject.Copy(); $cand.AcceleratedNetworking = $false
        $gates = Test-CandidateGates -Vm $vm -Current (New-CurrentProfile -SkuName $vm.SkuName -SkuRecord $SkuCat['standard_d4s_v3'] -ProcessorInfo (Get-ProcessorInfo 'Standard_D4s_v3' $Proc $SkuCat['standard_d4s_v3'])) -Candidate $cand -CandidateProc ([pscustomobject]@{ Vendor = 'Intel'; Architecture = 'x64' })
        ($gates | Where-Object Gate -eq 'Accelerated Networking').Result | Should -Be 'Fail'
    }
    It 'rejects too few NICs and zone unavailability' {
        $vm = New-TestVm -Sku 'Standard_D4s_v3' -Nics 3 -Zones @('3')
        $cur = New-CurrentProfile -SkuName $vm.SkuName -SkuRecord $SkuCat['standard_d4s_v3'] -ProcessorInfo (Get-ProcessorInfo 'Standard_D4s_v3' $Proc $SkuCat['standard_d4s_v3'])
        $gates = Test-CandidateGates -Vm $vm -Current $cur -Candidate $SkuCat['standard_e4s_v5'] -CandidateProc ([pscustomobject]@{ Vendor = 'Intel'; Architecture = 'x64' })
        ($gates | Where-Object Gate -eq 'NIC Count').Result | Should -Be 'Fail'
        ($gates | Where-Object Gate -eq 'Region / Zone').Result | Should -Be 'Review'
    }
    It 'never uses a restricted SKU as the primary' {
        $only = @{ 'standard_d4s_v3' = $SkuCat['standard_d4s_v3']; 'standard_e4s_v5' = $SkuCat['standard_e4s_v5'] }
        $vm = New-TestVm -Sku 'Standard_E4s_v3'
        $only['standard_e4s_v3'] = ($SkuCat['standard_d4s_v3'].PSObject.Copy()); $only['standard_e4s_v3'].Name = 'Standard_E4s_v3'; $only['standard_e4s_v3'].MemoryGB = 32
        $a = Invoke-TestAssessment -Vm $vm -Catalog $only
        $a.Candidates.Primary | Should -BeNullOrEmpty
        $a.Readiness | Should -Be 'Manual Review Required'
        $a.Confidence.Level | Should -Be 'LOW'
    }
    It 'flags CPU Vendor Change Required only when no same-vendor size passes' {
        $only = @{ 'standard_ds3_v2' = $SkuCat['standard_ds3_v2']; 'standard_d4as_v5' = $SkuCat['standard_d4as_v5'] }
        $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1') -Catalog $only
        $a.Candidates.VendorChangeRequired | Should -BeTrue
        $a.Candidates.Primary.CpuVendor | Should -Be 'AMD'
        $a.Confidence.Level | Should -Be 'LOW'
        $a.Readiness | Should -Be 'Manual Review Required'
    }
}

Describe 'Compatibility score' {
    It 'totals the documented weights to 100' {
        ($Weights.weights.PSObject.Properties.Value | Measure-Object -Sum).Sum | Should -Be 100
    }
    It 'scores an identical-capability same-vendor candidate as Excellent' {
        $vm = New-TestVm -Sku 'Standard_D4s_v3'
        $cur = New-CurrentProfile -SkuName $vm.SkuName -SkuRecord $SkuCat['standard_d4s_v3'] -ProcessorInfo (Get-ProcessorInfo 'Standard_D4s_v3' $Proc $SkuCat['standard_d4s_v3'])
        $s = Get-CompatibilityScore -Vm $vm -Current $cur -Candidate $SkuCat['standard_d4ds_v5'] -CandidateProc ([pscustomobject]@{ Vendor = 'Intel'; Architecture = 'x64' }) -FamilyMatch Same -Availability Available -Weights $Weights
        $s.Total | Should -BeGreaterOrEqual 90
        $s.Band | Should -Be 'Excellent Match'
    }
    It 'removes the 20 vendor points on a vendor change' {
        $vm = New-TestVm -Sku 'Standard_D4s_v3'
        $cur = New-CurrentProfile -SkuName $vm.SkuName -SkuRecord $SkuCat['standard_d4s_v3'] -ProcessorInfo (Get-ProcessorInfo 'Standard_D4s_v3' $Proc $SkuCat['standard_d4s_v3'])
        $s = Get-CompatibilityScore -Vm $vm -Current $cur -Candidate $SkuCat['standard_d4as_v5'] -CandidateProc ([pscustomobject]@{ Vendor = 'AMD'; Architecture = 'x64' }) -FamilyMatch Same -Availability Available -Weights $Weights
        $s.Breakdown.cpuVendor | Should -Be 0
    }
    It 'bands scores per the documented thresholds' {
        Get-ScoreBand -Score 95 -Weights $Weights | Should -Be 'Excellent Match'
        Get-ScoreBand -Score 85 -Weights $Weights | Should -Be 'Good Match'
        Get-ScoreBand -Score 72 -Weights $Weights | Should -Be 'Acceptable with Review'
        Get-ScoreBand -Score 50 -Weights $Weights | Should -Be 'Manual Review Required'
    }
}

Describe 'Quota math' {
    It 'matches the documented example: limit 100, used 92, need 16 -> +8 minimum' {
        $q = Get-QuotaIncrease -Limit 100 -Used 92 -Required 16 -SafetyPct 20
        $q.PostMigrationUsage | Should -Be 108
        $q.MinimumIncrease | Should -Be 8
        $q.RecommendedIncrease | Should -Be 12
        $q.Status | Should -Be 'Quota Increase Required'
    }
    It 'returns Quota OK with no increase when headroom exists' {
        $q = Get-QuotaIncrease -Limit 100 -Used 50 -Required 16
        $q.MinimumIncrease | Should -Be 0
        $q.Status | Should -Be 'Quota OK'
    }
    It 'aggregates demand across VMs moving to the same family' {
        $usage = @{ 's1|eastus2' = @{ 'standarddsv5family' = [pscustomobject]@{ Name = 'standardDSv5Family'; LocalName = 'Standard DSv5 Family vCPUs'; Used = 92; Limit = 100 }; 'cores' = [pscustomobject]@{ Name = 'cores'; LocalName = 'Total Regional vCPUs'; Used = 200; Limit = 350 } } }
        $moves = @(
            [pscustomobject]@{ SubscriptionId = 's1'; Region = 'eastus2'; VmId = 'a'; CurrentFamily = 'standardDSv2Family'; CurrentVcpu = 4; TargetSku = 'Standard_D4s_v5'; TargetFamily = 'standardDSv5Family'; TargetVcpu = 4; IsAllocated = $true }
            [pscustomobject]@{ SubscriptionId = 's1'; Region = 'eastus2'; VmId = 'b'; CurrentFamily = 'standardDSv2Family'; CurrentVcpu = 4; TargetSku = 'Standard_D4s_v5'; TargetFamily = 'standardDSv5Family'; TargetVcpu = 4; IsAllocated = $true }
            [pscustomobject]@{ SubscriptionId = 's1'; Region = 'eastus2'; VmId = 'c'; CurrentFamily = 'standardDSv2Family'; CurrentVcpu = 8; TargetSku = 'Standard_D8s_v5'; TargetFamily = 'standardDSv5Family'; TargetVcpu = 8; IsAllocated = $false }
        )
        $r = Measure-QuotaImpact -Moves $moves -Usage $usage -SafetyPct 20
        $f = $r.FamilyRows[0]
        $f.RequiredVcpu | Should -Be 16
        $f.RequiredVcpuAllocatedOnly | Should -Be 8
        $f.MinimumIncrease | Should -Be 8
        $r.RegionalRows[0].RequiredVcpu | Should -Be 8
        $r.ByVm['a'].Status | Should -Be 'Quota Increase Required'
    }
    It 'reports missing usage as Quota Information Unavailable' {
        $moves = @([pscustomobject]@{ SubscriptionId = 's9'; Region = 'eastus2'; VmId = 'x'; CurrentFamily = 'f'; CurrentVcpu = 2; TargetSku = 't'; TargetFamily = 'standardDSv5Family'; TargetVcpu = 2; IsAllocated = $true })
        (Measure-QuotaImpact -Moves $moves -Usage @{} -SafetyPct 20).ByVm['x'].Status | Should -Be 'Quota Information Unavailable'
    }
    It 'aggregates multiple subscription and region groups without losing the usage map' {
        $usage = @{
            's1|eastus2' = @{ 'standarddsv5family' = [pscustomobject]@{ Name = 'standardDSv5Family'; LocalName = 'DSv5'; Used = 0; Limit = 100 }; 'cores' = [pscustomobject]@{ Name = 'cores'; LocalName = 'Regional'; Used = 4; Limit = 100 } }
            's2|centralus' = @{ 'standardesv5family' = [pscustomobject]@{ Name = 'standardESv5Family'; LocalName = 'ESv5'; Used = 0; Limit = 100 }; 'cores' = [pscustomobject]@{ Name = 'cores'; LocalName = 'Regional'; Used = 8; Limit = 100 } }
        }
        $moves = @(
            [pscustomobject]@{ SubscriptionId = 's1'; Region = 'eastus2'; VmId = 'a'; CurrentFamily = 'oldD'; CurrentVcpu = 4; TargetSku = 'Standard_D4s_v5'; TargetFamily = 'standardDSv5Family'; TargetVcpu = 4; IsAllocated = $true }
            [pscustomobject]@{ SubscriptionId = 's2'; Region = 'centralus'; VmId = 'b'; CurrentFamily = 'oldE'; CurrentVcpu = 8; TargetSku = 'Standard_E8s_v5'; TargetFamily = 'standardESv5Family'; TargetVcpu = 8; IsAllocated = $true }
        )

        $r = Measure-QuotaImpact -Moves $moves -Usage $usage -SafetyPct 20

        $r.FamilyRows.Count | Should -Be 2
        $r.RegionalRows.Count | Should -Be 2
        $r.ByVm['a'].Status | Should -Be 'Quota OK'
        $r.ByVm['b'].Status | Should -Be 'Quota OK'
    }
    It 'uses only the positive vCPU delta for an allocated same-family resize' {
        $usage = @{ 's1|eastus2' = @{ 'standarddsv5family' = [pscustomobject]@{ Name = 'standardDSv5Family'; LocalName = 'DSv5'; Used = 90; Limit = 100 }; 'cores' = [pscustomobject]@{ Name = 'cores'; LocalName = 'Regional'; Used = 90; Limit = 100 } } }
        $moves = @([pscustomobject]@{ SubscriptionId = 's1'; Region = 'eastus2'; VmId = 'same'; CurrentFamily = 'standardDSv5Family'; CurrentVcpu = 4; TargetSku = 'Standard_D8s_v5'; TargetFamily = 'standardDSv5Family'; TargetVcpu = 8; IsAllocated = $true })
        $r = Measure-QuotaImpact -Moves $moves -Usage $usage
        $r.FamilyRows[0].RequiredVcpu | Should -Be 4
        $r.RegionalRows[0].RequiredVcpu | Should -Be 4
    }
    It 'uses the full target for deallocated same-family and allocated cross-family moves' {
        $usage = @{ 's1|eastus2' = @{ 'standarddsv5family' = [pscustomobject]@{ Name = 'standardDSv5Family'; LocalName = 'DSv5'; Used = 0; Limit = 100 }; 'cores' = [pscustomobject]@{ Name = 'cores'; LocalName = 'Regional'; Used = 0; Limit = 100 } } }
        $moves = @(
            [pscustomobject]@{ SubscriptionId = 's1'; Region = 'eastus2'; VmId = 'deallocated'; CurrentFamily = 'standardDSv5Family'; CurrentVcpu = 4; TargetSku = 'Standard_D8s_v5'; TargetFamily = 'standardDSv5Family'; TargetVcpu = 8; IsAllocated = $false }
            [pscustomobject]@{ SubscriptionId = 's1'; Region = 'eastus2'; VmId = 'cross'; CurrentFamily = 'old'; CurrentVcpu = 4; TargetSku = 'Standard_D8s_v5'; TargetFamily = 'standardDSv5Family'; TargetVcpu = 8; IsAllocated = $true }
        )
        (Measure-QuotaImpact -Moves $moves -Usage $usage).FamilyRows[0].RequiredVcpu | Should -Be 16
    }
    It 'keeps RequiredVcpu as steady-state and calculates peak side-by-side demand' {
        $usage = @{ 's1|eastus2' = @{ 'standarddsv6family' = [pscustomobject]@{ Name = 'standardDSv6Family'; LocalName = 'DSv6'; Used = 96; Limit = 100 }; 'cores' = [pscustomobject]@{ Name = 'cores'; LocalName = 'Regional'; Used = 96; Limit = 100 } } }
        $moves = @(
            [pscustomobject]@{ SubscriptionId = 's1'; Region = 'eastus2'; VmId = 'gen1'; CurrentFamily = 'standardDSv6Family'; CurrentVcpu = 4; TargetSku = 'Standard_D8s_v6'; TargetFamily = 'standardDSv6Family'; TargetVcpu = 8; IsAllocated = $true; MigrationQuotaModel = 'SideBySide' }
        )
        $r = Measure-QuotaImpact -Moves $moves -Usage $usage -SafetyPct 20
        $f = $r.FamilyRows[0]
        $f.RequiredVcpu | Should -Be 4
        $f.SteadyStateRequiredVcpu | Should -Be 4
        $f.PeakMigrationRequiredVcpu | Should -Be 8
        $f.MinimumIncrease | Should -Be 0
        $f.PeakMinimumIncrease | Should -Be 4
        $f.MigrationQuotaModel | Should -Be 'SideBySide'
        $r.ByVm['gen1'].MigrationQuotaModel | Should -Be 'SideBySide'
        $r.ByVm['gen1'].PeakStatus | Should -Be 'Quota Increase Required'
    }
    It 'reports Mixed when a quota family contains in-place and side-by-side migrations' {
        $usage = @{ 's1|eastus2' = @{ 'standarddsv6family' = [pscustomobject]@{ Name = 'standardDSv6Family'; LocalName = 'DSv6'; Used = 0; Limit = 100 }; 'cores' = [pscustomobject]@{ Name = 'cores'; LocalName = 'Regional'; Used = 0; Limit = 100 } } }
        $moves = @(
            [pscustomobject]@{ SubscriptionId = 's1'; Region = 'eastus2'; VmId = 'a'; CurrentFamily = 'old'; CurrentVcpu = 4; TargetSku = 'Standard_D4s_v6'; TargetFamily = 'standardDSv6Family'; TargetVcpu = 4; IsAllocated = $true; MigrationQuotaModel = 'InPlace' }
            [pscustomobject]@{ SubscriptionId = 's1'; Region = 'eastus2'; VmId = 'b'; CurrentFamily = 'standardDSv6Family'; CurrentVcpu = 4; TargetSku = 'Standard_D8s_v6'; TargetFamily = 'standardDSv6Family'; TargetVcpu = 8; IsAllocated = $true; MigrationQuotaModel = 'SideBySide' }
        )
        $r = Measure-QuotaImpact -Moves $moves -Usage $usage
        $r.FamilyRows[0].MigrationQuotaModel | Should -Be 'Mixed'
        $r.FamilyRows[0].SideBySideVmCount | Should -Be 1
        $r.FamilyRows[0].PeakMigrationRequiredVcpu | Should -BeGreaterThan $r.FamilyRows[0].SteadyStateRequiredVcpu
    }
}

Describe 'Quota scopes, shortages and aggregation' {
    BeforeAll {
        $script:Move = { param($Vm, $Sub = 's1', $Region = 'eastus2', $Family = 'standardDDSv5Family', $Vcpu = 4, $Model = 'InPlace', $CurrentFamily = 'standardDSv2Family')
            [pscustomobject]@{ SubscriptionId = $Sub; Region = $Region; VmId = $Vm; CurrentFamily = $CurrentFamily; CurrentVcpu = 4; TargetSku = 'Standard_D4ds_v5'; TargetFamily = $Family; TargetVcpu = $Vcpu; IsAllocated = $true; MigrationQuotaModel = $Model } }
        $script:Usage = { param($FamilyUsed, $FamilyLimit, $CoresUsed, $CoresLimit)
            @{ 's1|eastus2' = @{
                    'standardddsv5family' = [pscustomobject]@{ Name = 'standardDDSv5Family'; LocalName = 'DDSv5'; Used = $FamilyUsed; Limit = $FamilyLimit }
                    'cores' = [pscustomobject]@{ Name = 'cores'; LocalName = 'Regional'; Used = $CoresUsed; Limit = $CoresLimit } } } }
    }
    It 'keeps the original QuotaRow columns in order and appends the steady/peak columns' {
        $r = Measure-QuotaImpact -Moves @(& $Move 'a') -Usage (& $Usage 0 100 0 100) -Scope 'Retirement'
        $names = @($r.FamilyRows[0].PSObject.Properties.Name)
        ($names[0..17] -join ',') | Should -Be 'SubscriptionId,Region,QuotaName,QuotaDisplayName,VmCount,TargetSkus,Limit,CurrentUsage,Remaining,RequiredVcpu,RequiredVcpuAllocatedOnly,PostMigrationUsage,MinimumIncrease,RecommendedIncrease,RecommendedNewLimit,Status,DataQuality,Scope'
        ($names[18..26] -join ',') | Should -Be 'MigrationQuotaModel,SideBySideVmCount,SteadyStateRequiredVcpu,PeakMigrationRequiredVcpu,PeakPostMigrationUsage,PeakMinimumIncrease,PeakRecommendedIncrease,PeakRecommendedNewLimit,PeakStatus'
        $r.FamilyRows[0].Scope | Should -Be 'Retirement'
        $r.RegionalRows[0].Scope | Should -Be 'Retirement'
    }
    It 'reports a regional-only shortage' {
        $r = Measure-QuotaImpact -Moves @(& $Move 'a') -Usage (& $Usage 0 100 98 100)
        $r.FamilyRows[0].Status | Should -Be 'Quota OK'
        $r.ByVm['a'].Status | Should -Be 'Quota OK'
        $side = Measure-QuotaImpact -Moves @(& $Move 'a' -Model 'SideBySide') -Usage (& $Usage 0 100 98 100)
        $side.RegionalRows[0].Status | Should -Be 'Quota OK'
        $side.RegionalRows[0].PeakStatus | Should -Be 'Quota Increase Required'
        $side.RegionalRows[0].PeakMinimumIncrease | Should -Be 2
        $side.ByVm['a'].PeakStatus | Should -Be 'Quota Increase Required'
    }
    It 'reports a family-only shortage' {
        $r = Measure-QuotaImpact -Moves @(& $Move 'a') -Usage (& $Usage 98 100 0 350)
        $r.FamilyRows[0].Status | Should -Be 'Quota Increase Required'
        $r.RegionalRows[0].Status | Should -Be 'Quota OK'
        $r.ByVm['a'].Status | Should -Be 'Quota Increase Required'
    }
    It 'flags missing quota data instead of assuming capacity' {
        $none = Measure-QuotaImpact -Moves @(& $Move 'a') -Usage @{}
        $none.ByVm['a'].Status | Should -Be 'Quota Information Unavailable'
        $none.ByVm['a'].PeakStatus | Should -Be 'Quota Information Unavailable'
        $noFamily = Measure-QuotaImpact -Moves @(& $Move 'a' -Family 'standardDSv7Family') -Usage (& $Usage 0 100 0 100)
        $noFamily.FamilyRows[0].Status | Should -Be 'Manual Validation Required'
        $noFamily.FamilyRows[0].PeakStatus | Should -Be 'Manual Validation Required'
    }
    It 'keeps subscriptions, regions and target families separate' {
        $moves = @(
            (& $Move 'a'), (& $Move 'b' -Family 'standardDSv6Family'), (& $Move 'c' -Region 'westus3'), (& $Move 'd' -Sub 's2')
        )
        $r = Measure-QuotaImpact -Moves $moves -Usage @{}
        $r.FamilyRows.Count | Should -Be 4
        $r.RegionalRows.Count | Should -Be 3
        @($r.FamilyRows | Where-Object { $_.SubscriptionId -eq 's1' -and $_.Region -eq 'eastus2' }).Count | Should -Be 2
    }
    It 'does not double count a cross-family side-by-side move' {
        $r = Measure-QuotaImpact -Moves @(& $Move 'a' -Model 'SideBySide' -Vcpu 8) -Usage (& $Usage 0 100 0 100)
        $r.FamilyRows[0].SteadyStateRequiredVcpu | Should -Be 8
        $r.FamilyRows[0].PeakMigrationRequiredVcpu | Should -Be 8
        $r.RegionalRows[0].SteadyStateRequiredVcpu | Should -Be 4
        $r.RegionalRows[0].PeakMigrationRequiredVcpu | Should -Be 8
    }
}

Describe 'Retirement target vs modernization target' {
    BeforeAll {
        $script:StratCatalog = @{
            'standard_d4s_v3' = $SkuCat['standard_d4s_v3']
            'standard_d4s_v6' = $SkuCat['standard_d4s_v6']
        }
        $v7 = $SkuCat['standard_d4s_v6'].PSObject.Copy()
        $v7.Name = 'Standard_D4s_v7'; $v7.Family = 'standardDSv7Family'
        $script:StratCatalog['standard_d4s_v7'] = $v7
    }
    It 'keeps v5 as the retirement target and v6 as a convertible Gen1 + NVMe modernization target' {
        $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1') -CheckModernization
        $s = $a.Strategy
        $s.RetirementTargetSku | Should -Be 'Standard_D4ds_v5'
        $s.RetirementTargetGeneration | Should -Be 5
        $s.ModernizationTargetSku | Should -Be 'Standard_D4s_v6'
        $s.ModernizationTargetSource | Should -Be 'Convertible'
        $s.RequiresGenerationChange | Should -BeTrue
        $s.RequiresNvmeConversion | Should -BeTrue
        $s.ModernizationPath | Should -Be 'Gen1 + NVMe + Resize'
        $s.Complexity | Should -Be 'High'
        $s.MigrationQuotaModel | Should -Be 'SideBySide'
        $s.RecommendedMigrationPath | Should -Match '^Retire to Standard_D4ds_v5 -> modernize to Standard_D4s_v6 \(requires Gen1 to Trusted launch upgrade and SCSI to NVMe conversion\)$'
        ($s.ValidationItems -join ' ') | Should -Match 'Guest NVMe readiness: Validation Required'
        ($s.ValidationItems -join ' ') | Should -Match 'Guest OS not reported'
        $row = ConvertTo-AssessmentRow $a
        $row.RecommendedSku | Should -Be 'Standard_D4ds_v5'
        $row.RetirementTargetSku | Should -Be 'Standard_D4ds_v5'
        $row.ModernizationTargetSku | Should -Be 'Standard_D4s_v6'
    }
    It 'models Gen2 SCSI to NVMe as an in-place conversion' {
        $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_D4s_v3') -CheckModernization
        $a.Strategy.ModernizationPath | Should -Be 'SCSI to NVMe + Resize'
        $a.Strategy.RequiresGenerationChange | Should -BeFalse
        $a.Strategy.MigrationQuotaModel | Should -Be 'InPlace'
        $a.Strategy.RecommendedMigrationPath | Should -Match 'requires SCSI to NVMe conversion'
    }
    It 'reports a direct v7 resize and requires MANA validation for Accelerated Networking' {
        $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_D4s_v3' -Controller 'NVMe') -Catalog $StratCatalog -CheckModernization
        $s = $a.Strategy
        $a.Candidates.Primary.SkuName | Should -Be 'Standard_D4s_v7'
        $s.ModernizationTargetSku | Should -Be 'Standard_D4s_v7'
        $s.ModernizationTargetSource | Should -Be 'Selected'
        $s.ModernizationPath | Should -Be 'Direct Resize'
        $s.ModernizationReadiness | Should -Be 'Ready'
        $s.MigrationQuotaModel | Should -Be 'InPlace'
        $expectedRetirement = if ($a.AffectedByRetirement -notin 'Yes', 'Unknown') { $null } elseif ($a.Candidates.Modernization.ExistingRecommendation) { $a.Candidates.Modernization.ExistingRecommendation.SkuName } else { 'Standard_D4s_v7' }
        $s.RetirementTargetSku | Should -Be $expectedRetirement
        if (-not $expectedRetirement) { $s.RecommendedMigrationPath | Should -Be 'Optional modernization to Standard_D4s_v7' }
        ($s.ValidationItems -join ' ') | Should -Match 'MANA networking: Validation Required'
    }
    It 'derives conversion flags from the selected target, not from FutureGeneration' {
        $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_D4s_v3' -Controller 'NVMe') -Catalog $StratCatalog -CheckModernization
        $a.Candidates.FutureGeneration = [pscustomobject]@{ SkuName = 'Standard_D4s_v8'; Generation = 8; FailedGates = @('Disk Controller', 'VM Generation') }
        $s = Get-TargetStrategy -Assessment $a
        $s.RequiresNvmeConversion | Should -BeFalse
        $s.RequiresGenerationChange | Should -BeFalse
        $s.ModernizationPath | Should -Be 'Direct Resize'
    }
    It 'shows a quota-blocked modern target as a quota action, not as redeploy' {
        $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1') -CheckModernization
        $a.Candidates.FutureGeneration = $null
        $blocked = [pscustomobject]@{ SkuName = 'Standard_D4ds_v6'; Generation = 6; Family = 'standardDDSv6Family'; vCPUs = 4; TempDiskGB = 150; FailedGates = @() }
        $a.Modernization | Add-Member -NotePropertyName QuotaBlockedAlternatives -NotePropertyValue @([pscustomobject]@{ Candidate = $blocked; QuotaStatus = 'Quota Increase Required' }) -Force
        $s = Get-TargetStrategy -Assessment $a
        $s.ModernizationTargetSource | Should -Be 'QuotaBlocked'
        $s.ModernizationQuotaStatus | Should -Be 'Quota Increase Required'
        $s.ModernizationReadiness | Should -Be 'Quota Increase'
        $s.RedeployReview | Should -BeFalse
    }
    It 'recommends redeploy review only when the guest OS cannot use the Gen1 Trusted launch upgrade' {
        $vm = New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1'
        $vm.OsName = 'debian 11'
        $a = Invoke-TestAssessment -Vm $vm -CheckModernization
        $a.Strategy.RedeployReview | Should -BeTrue
        $a.Strategy.ModernizationPath | Should -Be 'Redeploy / Rebuild Review'
        $a.Strategy.ModernizationReadiness | Should -Be 'Redeploy Review'
        $a.Strategy.MigrationQuotaModel | Should -Be 'SideBySide'
        $vm2 = New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1'
        $vm2.OsName = 'Ubuntu 22.04'
        (Invoke-TestAssessment -Vm $vm2 -CheckModernization).Strategy.RedeployReview | Should -BeFalse
    }
    It 'flags unconfirmed retirement in the migration path' {
        $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1')
        $a.AffectedByRetirement = 'Unknown'
        $s = Get-TargetStrategy -Assessment $a
        $s.RetirementUnconfirmed | Should -BeTrue
        $s.RecommendedMigrationPath | Should -Match '^Retirement unconfirmed - validate lifecycle; Retire to Standard_D4ds_v5$'
    }
    It 'leaves modernization fields empty without -CheckModernization' {
        $row = ConvertTo-AssessmentRow (Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1'))
        $row.RetirementTargetSku | Should -Be 'Standard_D4ds_v5'
        $row.RecommendedMigrationPath | Should -Be 'Retire to Standard_D4ds_v5'
        $row.ModernizationTargetSku | Should -BeNullOrEmpty
        $row.ModernizationPath | Should -BeNullOrEmpty
        $row.MigrationQuotaModel | Should -BeNullOrEmpty
        $row.NewerGenerationIfConverted | Should -Match '^Standard_D4s_v6'
        $row.ModernizationMaterialDifferences | Should -BeNullOrEmpty
    }
    It 'compares the current size with both targets, including a convertible target that was never ranked' {
        $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1') -CheckModernization
        $a.Strategy.ModernizationTargetSource | Should -Be 'Convertible'
        @($a.Candidates.FutureGeneration.Differences | Where-Object { $_ }).Count | Should -Be 0
        $rows = @($a.Strategy.TargetComparison)
        $rows.Count | Should -BeGreaterThan 10
        $controller = $rows | Where-Object Attribute -eq 'Disk Controller'
        $controller.RetirementChange | Should -Be 'Same'
        $controller.ModernizationTarget | Should -Be 'NVMe'
        $controller.ModernizationChange | Should -Be 'Changed'
        $controller.RetirementNote | Should -BeNullOrEmpty
        $controller.ModernizationNote | Should -Match 'NVMe only'
        @($rows | Where-Object { -not $_.ModernizationChange }).Count | Should -Be 0
        @($rows | Where-Object { -not $_.RetirementChange }).Count | Should -Be 0
        $row = ConvertTo-AssessmentRow $a
        $row.ModernizationMaterialDifferences | Should -Match 'Disk Controller: SCSI -> NVMe'
        @($row.PSObject.Properties.Name)[-1] | Should -Be 'ModernizationMaterialDifferences'
    }
    It 'keeps the retirement comparison without -CheckModernization and leaves the modernization columns empty' {
        $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1')
        $rows = @($a.Strategy.TargetComparison)
        $rows.Count | Should -BeGreaterThan 10
        @($rows | Where-Object { $_.ModernizationChange -or $_.ModernizationTarget }).Count | Should -Be 0
        @($rows | Where-Object { -not $_.RetirementChange }).Count | Should -Be 0
    }
    It 'reuses ranked differences, computes missing ones and builds one merged comparison' {
        $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1')
        $primary = $a.Candidates.Primary
        $primary.Differences | Should -Not -BeNullOrEmpty
        @(Get-TargetDifferences -Current $a.Current -Target $primary).Count | Should -Be @($primary.Differences).Count
        @(Get-TargetDifferences -Current $a.Current -Target $null).Count | Should -Be 0
        @(Get-TargetDifferences -Current $a.Current -Target ([pscustomobject]@{ Differences = $null; Record = $null })).Count | Should -Be 0
        $unranked = $a.Candidates.Candidates | Where-Object { -not $_.Differences } | Select-Object -First 1
        @(Get-TargetDifferences -Current $a.Current -Target $unranked).Count | Should -BeGreaterThan 10
        $merged = @(New-TargetComparison -RetirementDifferences @([pscustomobject]@{ Attribute = 'vCPU'; Current = 4; Target = 4; Assessment = 'Same'; Note = 'a' }) -ModernizationDifferences @([pscustomobject]@{ Attribute = 'vCPU'; Current = 4; Target = 8; Assessment = 'Improved'; Note = 'b' }, [pscustomobject]@{ Attribute = 'Memory (GB)'; Current = 16; Target = 32; Assessment = 'Improved'; Note = '' }))
        $merged.Count | Should -Be 2
        $merged[0].RetirementTarget | Should -Be 4
        $merged[0].ModernizationTarget | Should -Be 8
        $merged[0].RetirementNote | Should -Be 'a'
        $merged[0].ModernizationNote | Should -Be 'b'
        $merged[1].RetirementChange | Should -BeNullOrEmpty
        $merged[1].ModernizationChange | Should -Be 'Improved'
    }
}

Describe 'Microsoft lifecycle stage' {
    It 'maps <Evidence> to <Stage>' -ForEach @(
        @{ Evidence = 'Already Retired'; Previous = $null; Stage = 'Retired' }
        @{ Evidence = 'Confirmed Retirement'; Previous = $null; Stage = 'End of Life' }
        @{ Evidence = 'Retirement Announced'; Previous = 'End of Life'; Stage = 'End of Life' }
        @{ Evidence = 'Modernization Recommended'; Previous = 'Previous Generation'; Stage = 'Not End of Life' }
        @{ Evidence = 'No Retirement Announced'; Previous = $null; Stage = 'Not End of Life' }
        @{ Evidence = 'Unable to Confirm'; Previous = $null; Stage = 'Unknown' }
    ) {
        Get-LifecycleStage -Lifecycle ([pscustomobject]@{ EvidenceClass = $Evidence; PreviousGenStatus = $Previous }) | Should -Be $Stage
    }
    It 'classifies a series on the Microsoft End of Life list as End of Life' {
        $lc = Resolve-SkuLifecycle -SkuName 'Standard_DS3_v2' -Catalog $Catalog -AsOf $AsOf
        $lc.LifecycleStage | Should -Be 'End of Life'
        (ConvertTo-AssessmentRow (Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1'))).LifecycleStage | Should -Be 'End of Life'
    }
}
Describe 'HTML VM scope' {
    It 'lists retiring VMs by default and optional modernization only when requested' {
        InModuleScope Output {
            $vm = { param($Affected, $Evidence, $Date, $Action) [pscustomobject]@{ AffectedByRetirement = $Affected; Lifecycle = [pscustomobject]@{ EvidenceClass = $Evidence; PreviousGenStatus = $null; RetirementDate = $Date }; Action = $Action } }
            $retiring = & $vm 'Yes' 'Confirmed Retirement' '2028-05-01' 'Plan Migration'
            $retired = & $vm 'Yes' 'Already Retired' '2025-09-30' 'Immediate Migration Required'
            $endOfLifeNoDate = & $vm 'Yes' 'Retirement Announced' $null 'Manual Review Required'
            $optional = & $vm 'No' 'Modernization Recommended' $null 'Modernization Optional'
            $current = & $vm 'No' 'No Retirement Announced' $null 'No Action Required'
            $unconfirmed = & $vm 'Unknown' 'Unable to Confirm' $null 'Manual Review Required'
            Test-HtmlListedVm -Assessment $retiring | Should -BeTrue
            Test-HtmlListedVm -Assessment $retired | Should -BeTrue
            # End of Life means Microsoft announced the retirement, so these VMs are listed even before a date is published.
            Test-HtmlListedVm -Assessment $endOfLifeNoDate | Should -BeTrue
            Test-HtmlListedVm -Assessment $optional | Should -BeFalse
            Test-HtmlListedVm -Assessment $optional -IncludeOptional | Should -BeTrue
            Test-HtmlListedVm -Assessment $current -IncludeOptional | Should -BeFalse
            Test-HtmlListedVm -Assessment $unconfirmed -IncludeOptional | Should -BeFalse
        }
    }
}
Describe 'Confidence, readiness, actions and waves' {
    It 'HIGH only when nothing is left to validate' {
        $lc = [pscustomobject]@{ EvidenceClass = 'Confirmed Retirement'; DataQuality = 'Verified' }
        $p = [pscustomobject]@{ Availability = 'Available' }
        $cur = [pscustomobject]@{ CapsKnown = $true }
        (Get-MigrationConfidence -Lifecycle $lc -Primary $p -Current $cur -VendorChangeRequired $false -QuotaStatus 'Quota OK').Level | Should -Be 'HIGH'
        (Get-MigrationConfidence -Lifecycle $lc -Primary $p -Current $cur -VendorChangeRequired $false -QuotaStatus 'Quota Increase Required').Level | Should -Be 'MEDIUM'
        (Get-MigrationConfidence -Lifecycle $lc -Primary $p -Current $cur -VendorChangeRequired $true -QuotaStatus 'Quota OK').Level | Should -Be 'LOW'
        (Get-MigrationConfidence -Lifecycle $lc -Primary $p -Current $cur -VendorChangeRequired $false -QuotaStatus 'Quota Information Unavailable').Level | Should -Be 'LOW'
    }
    It 'maps urgency to documented action values' -ForEach @(
        @{ Class = 'Already Retired'; Urgency = 'Already Retired'; Expected = 'Immediate Migration Required' }
        @{ Class = 'Confirmed Retirement'; Urgency = 'Less than 12 Months'; Expected = 'Migration Required Within 12 Months' }
        @{ Class = 'Confirmed Retirement'; Urgency = '12-24 Months'; Expected = 'Migration Required Within 24 Months' }
        @{ Class = 'Confirmed Retirement'; Urgency = '24-36 Months'; Expected = 'Migration Required Within 36 Months' }
        @{ Class = 'Confirmed Retirement'; Urgency = 'More than 36 Months'; Expected = 'Plan Migration' }
        @{ Class = 'Unable to Confirm'; Urgency = 'Unable to Determine'; Expected = 'Manual Review Required' }
    ) {
        Get-LifecycleAction -Lifecycle ([pscustomobject]@{ EvidenceClass = $Class; Urgency = $Urgency; PreviousGenStatus = $null }) | Should -Be $Expected
    }
    It 'keeps modernization out of retirement waves' {
        $lc = [pscustomobject]@{ EvidenceClass = 'Modernization Recommended'; Urgency = 'No Retirement Announced'; PreviousGenStatus = 'Next-gen available' }
        $act = Get-LifecycleAction -Lifecycle $lc
        $act | Should -Be 'Modernization Optional'
        Get-MigrationWave -Lifecycle $lc -Action $act | Should -Be 'Wave 4 - Modernization'
        $lc2 = [pscustomobject]@{ EvidenceClass = 'Modernization Recommended'; Urgency = 'No Retirement Announced'; PreviousGenStatus = 'Capacity limited' }
        Get-LifecycleAction -Lifecycle $lc2 | Should -Be 'Plan Migration'
    }
    It 'assigns retirement waves by urgency' {
        Get-MigrationWave -Lifecycle ([pscustomobject]@{ EvidenceClass = 'Already Retired'; Urgency = 'Already Retired' }) -Action 'x' | Should -Be 'Wave 1 - Urgent'
        Get-MigrationWave -Lifecycle ([pscustomobject]@{ EvidenceClass = 'Confirmed Retirement'; Urgency = '12-24 Months' }) -Action 'x' | Should -Be 'Wave 2 - Near Term'
        Get-MigrationWave -Lifecycle ([pscustomobject]@{ EvidenceClass = 'Confirmed Retirement'; Urgency = '24-36 Months' }) -Action 'x' | Should -Be 'Wave 3 - Planned'
    }
    It 'readiness prefers restriction and quota blockers over Ready' {
        Get-DeploymentReadiness -Primary ([pscustomobject]@{ Availability = 'Restricted' }) -QuotaStatus 'Quota OK' | Should -Be 'SKU Restricted'
        Get-DeploymentReadiness -Primary ([pscustomobject]@{ Availability = 'Available' }) -QuotaStatus 'Quota Increase Required' | Should -Be 'Quota Increase Required'
        Get-DeploymentReadiness -Primary ([pscustomobject]@{ Availability = 'Available' }) -QuotaStatus 'Quota OK' -CapacitySensitive $true | Should -Be 'Capacity Validation Required'
        Get-DeploymentReadiness -Primary ([pscustomobject]@{ Availability = 'Available' }) -QuotaStatus 'Quota OK' | Should -Be 'Ready'
    }
}

Describe 'Rightsizing stays separate' {
    It 'flags low utilization without touching the primary recommendation' {
        $p = [pscustomobject]@{ SkuName = 'Standard_D8s_v5'; vCPUs = 8 }
        $r = Get-RightsizingOpportunity -Utilization ([pscustomobject]@{ CpuP95 = 7; CpuMax = 30; MemAvailP05Bytes = 28GB; Samples = 720 }) -Primary $p -RegionCatalog $SkuCat -MemoryGB 32
        $r.Status | Should -Be 'Potential Rightsizing Opportunity'
        $r.SuggestedSku | Should -Be 'Standard_D4s_v5'
        $p.SkuName | Should -Be 'Standard_D8s_v5'
    }
    It 'reports insufficient data' {
        (Get-RightsizingOpportunity -Utilization $null -Primary $null -RegionCatalog @{} -MemoryGB 8).Status | Should -Be 'Insufficient Data'
    }
}

Describe 'Output writers (offline)' {
    It 'includes the standard disclaimer when the detailed report has no assessment rows' {
        $out = Join-Path $TestDrive 'empty-details.md'
        $run = [pscustomobject]@{ AsOf = $AsOf; Tenant = [pscustomobject]@{ Id = 't'; Name = 'Test' }; Parameters = @{} }
        Export-DetailedReportMarkdown -Path $out -Assessments @() -Run $run
        $md = Get-Content $out -Raw
        $md | Should -Match '_No retirement-affected VMs were found._'
        ([regex]::Matches($md, '(?m)^## Disclaimer\r?$')).Count | Should -Be 1
        $md | Should -Match 'not an official Microsoft product and is not supported or endorsed by Microsoft'
        $md.TrimEnd() | Should -Match 'before implementing production changes\.$'
    }
    It 'writes CSV / JSON / Markdown / HTML for a small synthetic estate' {
        $out = Join-Path $TestDrive 'out'; New-Item -ItemType Directory $out | Out-Null
        $as = @(
            (Invoke-TestAssessment (New-TestVm -Name 'a' -Sku 'Standard_DS3_v2' -Gen 'V1')),
            (Invoke-TestAssessment (New-TestVm -Name 'b' -Sku 'Standard_D4s_v3')),
            (Invoke-TestAssessment (New-TestVm -Name 'c' -Sku 'Standard_D4s_v5'))
        )
        $sum = New-AssessmentSummary -Assessments $as -SubscriptionsScanned 1
        $sum.TotalVmsScanned | Should -Be 3
        $sum.AffectedVms | Should -Be 1
        $run = [pscustomobject]@{ GeneratedUtc = 'now'; AsOf = $AsOf; Tenant = [pscustomobject]@{ Id = 't'; Name = 'Test' }; Account = 'x'; Parameters = @{ HorizonMonths = 36 }; Counts = @{} }
        $cr = [pscustomobject]@{ Catalog = $Catalog; Source = 'Live'; Warning = $null }
        $rows = Export-AssessmentData -OutDir $out -Run $run -Assessments $as -Summary $sum -QuotaImpact $null -CatalogResult $cr -Inventory $null
        Export-ExecutiveSummaryMarkdown -Path (Join-Path $out 'executive-summary.md') -Run $run -Summary $sum -Rows $rows -QuotaImpact $null -CatalogResult $cr
        Export-DetailedReportMarkdown -Path (Join-Path $out 'detailed-report.md') -Assessments $as -Run $run
        Export-HtmlReports -OutDir $out -CssPath (Join-Path $Root 'templates/report.css') -Run $run -Summary $sum -Assessments $as -QuotaImpact $null -CatalogResult $cr -ProcessorCatalog $Proc
        foreach ($f in 'vm-assessment.csv', 'candidates.csv', 'quota-impact.csv', 'assessment.json', 'retirement-evidence.json', 'executive-summary.md', 'detailed-report.md', 'index.html') {
            Join-Path $out $f | Should -Exist
        }
        $csv = Import-Csv (Join-Path $out 'vm-assessment.csv')
        $csv.Count | Should -Be 3
        ($csv | Where-Object VM -eq 'a').Action | Should -Be 'Migration Required Within 24 Months'
        ($csv | Where-Object VM -eq 'c').Action | Should -Be 'No Action Required'
        $json = Get-Content (Join-Path $out 'assessment.json') -Raw | ConvertFrom-Json -Depth 30
        $json.schemaVersion | Should -Be '1.0'
        @($json.vms).Count | Should -Be 3
        $mdText = Get-Content (Join-Path $out 'detailed-report.md') -Raw
        $mdText | Should -Match 'PRIMARY RECOMMENDATION'
        # Without -CheckModernization the comparison covers the retirement target only.
        $mdText | Should -Match '\*\*CURRENT VS TARGET SIZE\*\*'
        $mdText | Should -Match '\| Attribute \| Current \| Retirement target \| Note \|'
        $mdText | Should -Not -Match 'Modernization target|MODERNIZATION ASSESSMENT|MATERIAL DIFFERENCES'
        $idx = Get-Content (Join-Path $out 'index.html') -Raw
        foreach ($sec in 'Cross-Vendor Migration Warnings', 'SKU Family Quick Reference', 'CPU Vendor from SKU Name', 'Known Limitations', 'Bottom line') { $idx | Should -Match ([regex]::Escape($sec)) }
        $idx | Should -Match 'Dsv\d|Dasv\d'
        $idx | Should -Match '<td><strong>VM inventory \(Azure Resource Graph\)</strong></td>'
        $idx | Should -Match '<td><strong>Physical regional capacity</strong></td><td><span class=''badge b-yellow''>Not verifiable</span>'
    }
}

Describe 'Tenant-scoped Resource Graph (REST) paging' {
    It 'follows $skipToken across pages and chunks subscriptions without using the az default tenant' {
        Mock -ModuleName Inventory Invoke-AzJson { [pscustomobject]@{ accessToken = 'tok' } }
        $script:calls = @()
        Mock -ModuleName Inventory Invoke-RestMethod {
            $b = $Body | ConvertFrom-Json
            $script:calls += , $b
            if (-not ($b.options.PSObject.Properties.Name -contains '$skipToken')) {
                [pscustomobject]@{ data = @([pscustomobject]@{ id = 'a' }, [pscustomobject]@{ id = 'b' }); '$skipToken' = 'page2' }
            }
            else { [pscustomobject]@{ data = @([pscustomobject]@{ id = 'c' }) } }
        }
        $rows = Invoke-ArgQuery -Query 'Resources | take 3' -SubscriptionIds @('s1', 's2') -TenantId 't-other'
        @($rows).Count | Should -Be 3
        $script:calls.Count | Should -Be 2
        $script:calls[0].subscriptions | Should -Be @('s1', 's2')
        $script:calls[1].options.'$skipToken' | Should -Be 'page2'
        Should -Invoke -ModuleName Inventory Invoke-AzJson -ParameterFilter { $Arguments -contains '--tenant' -and $Arguments -contains 't-other' }
    }
}

Describe 'Selection regressions found against live Azure data' {
    It 'breaks score ties by feature similarity (E4s_v3 -> E4ds_v5, not the specialised E4bds_v5)' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_E4s_v3' -Gen 'V1')
        $a.Candidates.Primary.SkuName | Should -Be 'Standard_E4ds_v5'
    }
    It 'never offers an alternative older than the primary generation (no v4 for a v3 -> v5 move)' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_D4s_v3')
        $a.Candidates.Primary.Generation | Should -Be 5
        @($a.Candidates.Secondary, $a.Candidates.Third | Where-Object { $_ } | Where-Object { $_.Generation -lt 5 }).Count | Should -Be 0
        @($a.Candidates.Candidates | Where-Object SkuName -eq 'Standard_D4ds_v4').Count | Should -Be 1
    }
}

Describe 'Quota regressions found against live Azure data' {
    It 'handles a family whose moving VMs are all deallocated' {
        $usage = @{ 's1|eastus2' = @{ 'standardddsv5family' = [pscustomobject]@{ Name = 'standardDDSv5Family'; LocalName = 'x'; Used = 0; Limit = 100 }; 'cores' = [pscustomobject]@{ Name = 'cores'; LocalName = 'Total Regional vCPUs'; Used = 10; Limit = 100 } } }
        $moves = @([pscustomobject]@{ SubscriptionId = 's1'; Region = 'eastus2'; VmId = 'd'; CurrentFamily = 'f'; CurrentVcpu = 4; TargetSku = 'Standard_D4ds_v5'; TargetFamily = 'standardDDSv5Family'; TargetVcpu = 4; IsAllocated = $false })
        $r = Measure-QuotaImpact -Moves $moves -Usage $usage -SafetyPct 20
        $r.FamilyRows[0].RequiredVcpu | Should -Be 4
        $r.FamilyRows[0].RequiredVcpuAllocatedOnly | Should -Be 0
        $r.RegionalRows[0].RequiredVcpu | Should -Be 4
        $r.ByVm['d'].Status | Should -Be 'Quota OK'
    }
}

Describe 'Release hygiene' {
    It 'keeps SKILL.md metadata.version in sync with the module version' {
        $skill = Get-Content (Join-Path $Root 'SKILL.md') -Raw
        $m = [regex]::Match($skill, '(?m)^\s+version:\s*"?([0-9]+\.[0-9]+\.[0-9]+)"?\s*$')
        $m.Success | Should -BeTrue
        $m.Groups[1].Value | Should -Be (Get-ToolVersion)
    }
    It 'uses only portable (forward-slash) relative paths in scripts' {
        $hits = Get-ChildItem (Join-Path $Root 'scripts'), (Join-Path $Root 'tests') -Recurse -Include *.ps1, *.psm1 |
            Select-String -Pattern "(['""])(scripts|modules|data|templates|tests|fixtures)\\"
        @($hits).Count | Should -Be 0
    }
    It 'keeps script sources ASCII-only (Windows PowerShell / non-BOM safe)' {
        $bad = Get-ChildItem (Join-Path $Root 'scripts'), (Join-Path $Root 'tests') -Recurse -Include *.ps1, *.psm1 |
            Where-Object { [IO.File]::ReadAllText($_.FullName) -match '[^\x00-\x7F]' }
        @($bad).Count | Should -Be 0
    }
}

Describe 'HTML report safety' {
    It 'HTML-encodes inventory values and emits no script or remote assets' {
        $out = Join-Path $TestDrive 'xss'; New-Item -ItemType Directory $out | Out-Null
        $vm = New-TestVm -Name '<script>alert(1)</script>' -Sku 'Standard_DS3_v2' -Gen 'V1'
        $vm.ResourceGroup = '"><img src=x onerror=alert(2)>'
        $a = Invoke-TestAssessment $vm
        $a.SubscriptionName = '<b>sub</b>'
        $sum = New-AssessmentSummary -Assessments @($a) -SubscriptionsScanned 1
        $run = [pscustomobject]@{ GeneratedUtc = 'now'; AsOf = $AsOf; Tenant = [pscustomobject]@{ Id = 't'; Name = '<i>tenant</i>' }; Account = 'x'; Parameters = @{}; Counts = @{} }
        Export-HtmlReports -OutDir $out -CssPath (Join-Path $Root 'templates/report.css') -Run $run -Summary $sum -Assessments @($a) -QuotaImpact $null -CatalogResult ([pscustomobject]@{ Catalog = $Catalog; Source = 'Live'; Warning = $null }) -ProcessorCatalog $Proc
        $html = (Get-ChildItem $out -Filter *.html | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
        $html | Should -Not -Match '<script'
        $html | Should -Not -Match '<img'
        $html | Should -Not -Match '<b>sub</b>|<i>tenant</i>'
        $html | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
        $html | Should -Not -Match '<(link|img|iframe)[^>]+(src|href)=["'']https?://'
    }

    Describe 'CSV and Markdown output safety' {
        It 'neutralizes spreadsheet formulas without changing ordinary or non-string values' {
            ConvertTo-SafeCsvValue '=cmd|calc' | Should -Be "'=cmd|calc"
            ConvertTo-SafeCsvValue '+1+1' | Should -Be "'+1+1"
            ConvertTo-SafeCsvValue '@SUM(A1)' | Should -Be "'@SUM(A1)"
            ConvertTo-SafeCsvValue 'normal' | Should -Be 'normal'
            ConvertTo-SafeCsvValue 42 | Should -Be 42
        }
        It 'escapes Markdown control characters and flattens line breaks' {
            ConvertTo-MarkdownText "a|b`n# c [d] *e*" | Should -Be 'a\|b \# c \[d\] \*e\*'
        }
    }

    It 'shows material changes and the full comparison instead of a disk capability column' {
        $out = Join-Path $TestDrive 'capabilities'; New-Item -ItemType Directory $out | Out-Null
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1')
        $sum = New-AssessmentSummary -Assessments @($a) -SubscriptionsScanned 1
        $run = [pscustomobject]@{ GeneratedUtc = 'now'; AsOf = $AsOf; Tenant = [pscustomobject]@{ Id = 't'; Name = 'tenant' }; Account = 'x'; Parameters = @{}; Counts = @{} }
        Export-HtmlReports -OutDir $out -CssPath (Join-Path $Root 'templates/report.css') -Run $run -Summary $sum -Assessments @($a) -QuotaImpact $null -CatalogResult ([pscustomobject]@{ Catalog = $Catalog; Source = 'Live'; Warning = $null }) -ProcessorCatalog $Proc
        $html = Get-Content (Get-ChildItem $out -Filter '*.html' | Where-Object Name -ne 'index.html' | Select-Object -First 1).FullName -Raw

        $html | Should -Match "<th rowspan='2'>Current size</th>"
        $html | Should -Match '<th>Microsoft status</th>'
        $html | Should -Match '<th>Retirement target</th>'
        $html | Should -Match '<th>Material changes</th>'
        $html | Should -Match '<th>Next step</th>'
        $html | Should -Not -Match "<th>Disk capabilities</th>|<th>Recommended size</th>|cap-summary|capability-summary|cap-label"
        $html | Should -Not -Match "Optional &middot; v6/v7 modernization|<th>Modernization target</th>"
        $html | Should -Match "class='group-head group-required'"
        $html | Should -Not -Match "class='chips'"
        $html | Should -Match '@media \(max-width: 1200px\)'
        $html | Should -Match '\.vm-table \{ min-width: 1260px;'
        $html | Should -Match '\.vm-table td\.retirement-target-cell \{ width: 195px; min-width: 195px;'
        $html | Should -Match '\.vm-table td:nth-child\(3\), \.vm-table td:nth-child\(6\) \{ min-width: 125px; \}'
        $html | Should -Not -Match '\.vm-table th, \.vm-table td \{ overflow-wrap: anywhere;'
        $html | Should -Match '\.vm-table thead th\.group-required'
        $html | Should -Match '<h4>What changes</h4>'
        $html | Should -Match "<details class='vd-more'><summary>Show all \d+ attributes</summary><div class='table-wrap compact'><table class='comparison-table'>"
        $html | Should -Match '\.table-wrap\.compact \{ width: fit-content; max-width: 100%; \}'
        $rowPattern = "(?s)<tr class='vm-summary-row[^']*'[^>]*>.*?</tr>"
        ([regex]::Matches($html, "<tr class='vm-summary-row[^']*'[^>]*>")).Count | Should -Be 1
        ([regex]::Matches([regex]::Match($html, $rowPattern).Value, '<td[ >]')).Count | Should -Be 7
        # Current size and retirement target use the same layout: size, then Vendor, vCPU, vRAM, VM Gen and Disk controller on separate lines.
        $cells = [regex]::Matches([regex]::Match($html, $rowPattern).Value, '(?s)<td[^>]*>.*?</td>')
        $rec = $a.Candidates.Primary.Record
        $targetGens = (@($rec.HyperVGenerations) | ForEach-Object { $_ -replace '^V', 'Gen' }) -join ', '
        $specOrder = { param($vendor, $vcpu, $mem, $gen, $ctl) "(?s)Vendor:</span> $vendor</div>.*?vCPU:</span> $vcpu vCPU</div>.*?vRAM:</span> $mem GB</div>.*?VM Gen:</span> $gen</div>.*?Disk controller:</span> $ctl</div>" }
        $cells[1].Value | Should -Match "<code>Standard_(<wbr>)?DS3_v2</code><div class='spec'>"
        $cells[1].Value | Should -Match (& $specOrder $a.Current.Vendor $a.Current.vCPUs $a.Current.MemoryGB 'Gen1' ($a.Vm.DiskControllerType))
        $cells[3].Value | Should -Match "<code>Standard_(<wbr>)?D4ds_v5</code><div class='spec'>"
        $cells[3].Value | Should -Match (& $specOrder $a.Candidates.Primary.CpuVendor $a.Candidates.Primary.vCPUs $a.Candidates.Primary.MemoryGB $targetGens (@($rec.DiskControllerTypes) -join ', '))
        $cells[3].Value | Should -Match "Score:</span> \d+</div>"
        $cells[3].Value | Should -Match "Quota:</span> <span class='tone-\w+'>"
        $cells[1].Value + $cells[3].Value | Should -Not -Match "<span class='badge"
        # Material changes: one "Attribute: current -> target" line each, coloured by severity, no pills.
        $arrow = [char]0x2192
        $cells[4].Value | Should -Not -Match "class='badge|class='chips"
        $cells[4].Value | Should -Match "<div class='spec' title='[^']+'><span class='spec-label'>Disk IOPS:</span> <span class='tone-red'>12800 $arrow 6400</span></div>"
        $cells[4].Value | Should -Match "<span class='spec-label'>Data disks:</span> <span class='tone-red'>16 $arrow 8</span>"
        # Next step: Readiness and Confidence lines in the same style, with the colour on the value. The Action line is not repeated here.
        $cells[5].Value | Should -Not -Match "class='badge"
        $cells[5].Value | Should -Not -Match "spec-label'>Action:|Migration Required Within 24 Months|Plan Migration"
        $cells[5].Value | Should -Match "<span class='spec-label'>Readiness:</span> <span class='tone-\w+'>[^<]+</span>"
        $expectedTone = @{ HIGH = 'green'; MEDIUM = 'yellow'; LOW = 'red' }[$a.Confidence.Level]
        $cells[5].Value | Should -Match "<span class='spec-label'>Confidence:</span> <span class='tone-$expectedTone'>$($a.Confidence.Level)</span>"
        $html | Should -Match ([regex]::Escape("$($a.Current.TempDiskGB) GB"))
        $html | Should -Match ([regex]::Escape(($a.Current.DiskControllerTypes -join ', ')))
        $html | Should -Match ([regex]::Escape([string]$a.Current.UncachedDiskIOPS))
        $html | Should -Match ([regex]::Escape([string]$a.Current.UncachedDiskMBps))
        $html | Should -Match ([regex]::Escape("$($a.Candidates.Primary.TempDiskGB) GB"))
        $html | Should -Match ([regex]::Escape(($a.Candidates.Primary.Record.DiskControllerTypes -join ', ')))
        $html | Should -Match ([regex]::Escape([string]$a.Candidates.Primary.Record.UncachedDiskIOPS))
        $html | Should -Match ([regex]::Escape([string]$a.Candidates.Primary.Record.UncachedDiskMBps))
    }

    It 'uses the Azure dashboard report shell and table treatment' {
        $out = Join-Path $TestDrive 'dashboard-theme'; New-Item -ItemType Directory $out | Out-Null
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1')
        $sum = New-AssessmentSummary -Assessments @($a) -SubscriptionsScanned 1
        $run = [pscustomobject]@{ GeneratedUtc = 'now'; AsOf = $AsOf; Tenant = [pscustomobject]@{ Id = 't'; Name = 'tenant' }; Account = 'x'; Parameters = @{}; Counts = @{} }
        Export-HtmlReports -OutDir $out -CssPath (Join-Path $Root 'templates/report.css') -Run $run -Summary $sum -Assessments @($a) -QuotaImpact $null -CatalogResult ([pscustomobject]@{ Catalog = $Catalog; Source = 'Live'; Warning = $null }) -ProcessorCatalog $Proc
        $html = Get-Content (Join-Path $out 'index.html') -Raw

        $html | Should -Match 'class="app-bar"'
        $html | Should -Match 'class="brand-mark"'
        $html | Should -Match 'VMSKURetirementReport'
        $html | Should -Match 'class="mode-pill">Read-only</span>'
        $html | Should -Match 'class="footer-status"'
        $html | Should -Match 'thead th \{ background: var\(--accent\); color: #fff;'
        $html | Should -Match 'tbody tr:nth-child\(even\)'
        $html | Should -Match '\.wrap \{ max-width: 1480px;'
        $html | Should -Match '\.quota-table \.quota-usage \{ min-width: 112px;'
        $html | Should -Not -Match 'Readiness and Confidence'
        $html | Should -Not -Match "id='readiness'|href='#readiness'"
        $html | Should -Match "<section id='subscriptions'"
        # The tenant index carries no quota table; quota actions live on the subscription pages.
        $html | Should -Not -Match "id='quota'|href='#quota'|<h2>Quota Actions</h2>|<table class='quota-table'>"
        # Migration Waves is collapsed by default and still comes before Subscriptions.
        $html | Should -Match "<details id='waves' class='card collapsible-section'>"
        $html | Should -Not -Match "<details id='waves'[^>]+open"
        $html | Should -Not -Match "<section id='waves'"
        $html.IndexOf("<details id='waves'") | Should -BeLessThan $html.IndexOf("<section id='subscriptions'")
        $html.IndexOf("href='#waves'") | Should -BeLessThan $html.IndexOf("href='#subscriptions'")
        $html | Should -Match "<div class='kpis kpis-index'>"
        $html | Should -Match '@media \(min-width: 900px\) and \(max-width: 1450px\) \{ \.kpis-index \{ grid-template-columns: repeat\(5,'
        # Gen1 VMs card: the test VM is Hyper-V generation 1 (1 of 1 VM).
        $html | Should -Match "<div class='kpi kpi-yellow'><div class='kpi-label'>Gen1 VMs</div><div class='kpi-value'>1</div><div class='kpi-hint'>of 1 VM</div></div>"
        foreach ($id in 'upgrade-guidance', 'cross-vendor', 'sku-families', 'cpu-vendor', 'limitations') {
            $html | Should -Match "<details id='$id' class='card collapsible-section'>"
            $html | Should -Not -Match "<details id='$id'[^>]+open"
        }
    }
}

Describe 'Cross-family generation comparison' {
    It 'prefers the exact-fit current B-series (B2ms -> B2s_v2) over a larger D size with a higher version number' {
        $vm = New-TestVm -Sku 'Standard_B2ms' -Gen 'V2' -Accel $false
        $a = Invoke-TestAssessment $vm
        $a.Candidates.Primary.SkuName | Should -Be 'Standard_B2s_v2'
        $a.Candidates.Primary.vCPUs | Should -Be 2
        ($a.ValidationItems -join ' ') | Should -Match 'Temp / Local Disk'
    }
}

Describe 'Microsoft Learn lifecycle parsing (September 2026 page format)' {
    BeforeAll {
        $fx2 = Join-Path $PSScriptRoot 'fixtures/2026-09'
        $base = 'https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/'
        $pages2 = @{
            RetiredList    = @{ Url = "${base}retirements-and-capacity-restrictions"; Html = (Get-Content (Join-Path $fx2 'retirements-and-capacity-restrictions.html') -Raw); RetrievedUtc = '2026-10-05T00:00:00Z' }
            PreviousGen    = @{ Url = "${base}end-of-life-sizes-list"; Html = (Get-Content (Join-Path $fx2 'end-of-life-sizes-list.html') -Raw); RetrievedUtc = '2026-10-05T00:00:00Z' }
            MigrationGuide = @{ Url = "${base}retirement/retired-sizes-modernization-guide"; Html = (Get-Content (Join-Path $fx2 'retired-sizes-modernization-guide.html') -Raw); RetrievedUtc = '2026-10-05T00:00:00Z' }
        }
        $script:Catalog2 = New-RetirementCatalog -Pages $pages2 -SeriesMap $SeriesMap
        $script:AsOf2 = [datetime]'2026-10-05'
    }
    It 'maps every listed VM series and keeps Dedicated Host SKUs out of VM-size mapping' {
        @(Get-UnmappedSeriesNames -Catalog $Catalog2).Count | Should -Be 0
        $adh = @(Get-NonVmSizeEntries -Catalog $Catalog2)
        $adh.Count | Should -Be 1
        $adh[0].Category | Should -Be 'ADH'
        $adh[0].Status | Should -Be 'Retired'
        $adh[0].PlannedRetirementDate | Should -Be '2023-06-30'
    }
    It 'reads the Modernization guide column and the End of Life stage' {
        $dsv3 = $Catalog2.series | Where-Object key -eq 'dsv3'
        $dsv3.retiredList.migrationGuideUrl | Should -Match 'retired-sizes-modernization-guide'
        $dsv3.previousGen.status | Should -Be 'End of Life'
    }
    It 'expands "v6 and v7 D-family series" into family/version targets' {
        ConvertTo-TargetSeriesKey 'v6 and v7 D-family series' | Should -Be @('d-family-v6', 'd-family-v7')
        ConvertTo-TargetSeriesKey 'Ddsv5' | Should -Be @('ddsv5')
        ($Catalog2.series | Where-Object key -eq 'dsv3').recommendedTargets | Should -Contain 'd-family-v7'
    }
    It '<Sku> -> <Class> (<Date>)' -ForEach @(
        @{ Sku = 'Standard_D4s_v3'; Class = 'Confirmed Retirement'; Date = '2029-11-15' }
        @{ Sku = 'Standard_DC2s_v2'; Class = 'Already Retired'; Date = '2026-06-30' }
        @{ Sku = 'Standard_DC8_v2'; Class = 'Already Retired'; Date = '2026-06-30' }
        @{ Sku = 'Standard_DC4ds_v3'; Class = 'Confirmed Retirement'; Date = '2029-10-31' }
        @{ Sku = 'Standard_DC96as_cc_v5'; Class = 'Already Retired'; Date = '2026-09-01' }
        @{ Sku = 'Standard_EC20ads_cc_v5'; Class = 'Already Retired'; Date = '2026-09-01' }
        @{ Sku = 'Standard_HC44-16rs'; Class = 'Confirmed Retirement'; Date = '2027-05-31' }
        @{ Sku = 'Standard_M192is_v2'; Class = 'Confirmed Retirement'; Date = '2027-03-31' }
    ) {
        $r = Resolve-SkuLifecycle -SkuName $Sku -Catalog $Catalog2 -AsOf $AsOf2
        $r.EvidenceClass | Should -Be $Class
        $r.RetirementDate | Should -Be $Date
    }
    It 'treats an End of Life series without a planned date as Retirement Announced and never invents a date' {
        $r = Resolve-SkuLifecycle -SkuName 'Standard_E8s_v4' -Catalog $Catalog2 -AsOf $AsOf2
        $r.EvidenceClass | Should -Be 'Retirement Announced'
        $r.RetirementDate | Should -BeNullOrEmpty
        $r.Urgency | Should -Be 'Unable to Determine'
        $r.DataQuality | Should -Be 'Partially Verified'
    }
    It 'admits v6 D-family sizes for Dsv3 through the family/version target' {
        $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_D4s_v3' -Controller 'NVMe') -RetirementCatalog $Catalog2 -AsOfDate $AsOf2
        $a.Candidates.Primary.SkuName | Should -Be 'Standard_D4s_v6'
        $a.Candidates.PermittedSeries | Should -Match 'd-family-v6'
    }
    It 'notes Dedicated Host SKU retirements for VMs on a dedicated host' {
        $vm = New-TestVm -Sku 'Standard_D4s_v3'
        $vm.DedicatedHostId = '/subscriptions/s1/resourcegroups/rg/providers/microsoft.compute/hostgroups/hg/hosts/h1'
        $a = Invoke-TestAssessment -Vm $vm -RetirementCatalog $Catalog2 -AsOfDate $AsOf2
        ($a.Lifecycle.Notes -join ' ') | Should -Match 'Dedicated Host SKU retirements \(Dsv3-Type1'
        $a2 = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_D4s_v3') -RetirementCatalog $Catalog2 -AsOfDate $AsOf2
        ($a2.Lifecycle.Notes -join ' ') | Should -Not -Match 'Dedicated Host'
    }
    It 'lists each unmapped Microsoft series once even when several pages report it' {
        $cat = [pscustomobject]@{ unmappedSeries = @(
                [pscustomobject]@{ Source = 'RetiredList'; SeriesName = 'HC-series' }
                [pscustomobject]@{ Source = 'PreviousGen'; SeriesName = 'HC-series' }
                [pscustomobject]@{ Source = 'PreviousGen'; SeriesName = 'Zz-series' }) }
        Get-UnmappedSeriesNames -Catalog $cat | Should -Be @('HC-series', 'Zz-series')
        @(Get-NonVmSizeEntries -Catalog $cat).Count | Should -Be 0
    }
}

Describe 'Planning horizon and candidate count' {
    It 'places dated retirements at or beyond -HorizonMonths in Beyond Horizon (<Urgency>, <Months> months, horizon <Horizon> -> <Wave>)' -ForEach @(
        @{ Urgency = '24-36 Months'; Months = 30; Horizon = 36; Wave = 'Wave 3 - Planned' }
        @{ Urgency = '24-36 Months'; Months = 30; Horizon = 24; Wave = 'Beyond Horizon' }
        @{ Urgency = '12-24 Months'; Months = 14; Horizon = 12; Wave = 'Beyond Horizon' }
        @{ Urgency = 'More than 36 Months'; Months = 40; Horizon = 48; Wave = 'Wave 3 - Planned' }
        @{ Urgency = 'More than 36 Months'; Months = 40; Horizon = 36; Wave = 'Beyond Horizon' }
        @{ Urgency = 'Less than 12 Months'; Months = 5; Horizon = 12; Wave = 'Wave 1 - Urgent' }
        @{ Urgency = 'Already Retired'; Months = 0; Horizon = 12; Wave = 'Wave 1 - Urgent' }
    ) {
        $lc = [pscustomobject]@{ EvidenceClass = 'Confirmed Retirement'; Urgency = $Urgency; MonthsRemaining = $Months }
        Get-MigrationWave -Lifecycle $lc -Action 'x' -HorizonMonths $Horizon | Should -Be $Wave
    }
    It 'keeps the default 36-month buckets when months remaining are not supplied' {
        Get-MigrationWave -Lifecycle ([pscustomobject]@{ EvidenceClass = 'Confirmed Retirement'; Urgency = '24-36 Months' }) -Action 'x' | Should -Be 'Wave 3 - Planned'
        Get-MigrationWave -Lifecycle ([pscustomobject]@{ EvidenceClass = 'Confirmed Retirement'; Urgency = 'More than 36 Months' }) -Action 'x' | Should -Be 'Beyond Horizon'
    }
    It 'applies -HorizonMonths through Complete-VmAssessment' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1')
        $a.Wave | Should -Be 'Wave 2 - Near Term'
        $q = [pscustomobject]@{ Status = 'Quota OK'; DataQuality = 'Verified'; Family = [pscustomobject]@{ MinimumIncrease = 0 }; Regional = [pscustomobject]@{ MinimumIncrease = 0 } }
        (Complete-VmAssessment -Assessment $a -QuotaResult $q -Usage @{} -HorizonMonths 12).Wave | Should -Be 'Beyond Horizon'
    }
    It 'returns only the primary recommendation when -MaxCandidates is 1' {
        $one = Invoke-TestAssessment (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1') -MaxCandidates 1
        $one.Candidates.Primary | Should -Not -BeNullOrEmpty
        $one.Candidates.Secondary | Should -BeNullOrEmpty
        $one.Candidates.Third | Should -BeNullOrEmpty
        $two = Invoke-TestAssessment (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1') -MaxCandidates 2
        $two.Candidates.Secondary | Should -Not -BeNullOrEmpty
        $two.Candidates.Third | Should -BeNullOrEmpty
    }
}

Describe 'Per-subscription quota actions' {
    It 'shows each subscription only its own quota actions and keeps quota off the tenant index' {
        $out = Join-Path $TestDrive 'sub-quota'; New-Item -ItemType Directory $out | Out-Null
        $a1 = Invoke-TestAssessment (New-TestVm -Name 'vm-a' -Sku 'Standard_DS3_v2' -Gen 'V1')
        $vmB = New-TestVm -Name 'vm-b' -Sku 'Standard_DS3_v2' -Gen 'V1'; $vmB.SubscriptionId = 's2'
        $a2 = Invoke-TestAssessment $vmB; $a2.SubscriptionName = 'sub2'
        $row = { param($sub, $name, $display, $status, $min)
            [pscustomobject]@{ Scope = 'Retirement'; SubscriptionId = $sub; Region = 'eastus2'; QuotaName = $name; QuotaDisplayName = $display; CurrentUsage = 95; Limit = 100
                RequiredVcpu = 8; MinimumIncrease = $min; RecommendedIncrease = $min + 2; Status = $status } }
        $quota = [pscustomobject]@{
            FamilyRows   = @((& $row 's1' 'standardddsv5family' 'Sub1 DDSv5 Family vCPUs' 'Quota Increase Required' 3), (& $row 's2' 'standardddsv5family' 'Sub2 DDSv5 Family vCPUs' 'Quota OK' 0))
            RegionalRows = @((& $row 's1' 'cores' 'Sub1 Total Regional vCPUs' 'Quota OK' 0), (& $row 's2' 'cores' 'Sub2 Total Regional vCPUs' 'Quota OK' 0))
        }
        $as = @($a1, $a2)
        $sum = New-AssessmentSummary -Assessments $as -SubscriptionsScanned 2
        $run = [pscustomobject]@{ GeneratedUtc = 'now'; AsOf = $AsOf; Tenant = [pscustomobject]@{ Id = 't'; Name = 'tenant' }; Account = 'x'; Parameters = @{}; Counts = @{} }
        Export-HtmlReports -OutDir $out -CssPath (Join-Path $Root 'templates/report.css') -Run $run -Summary $sum -Assessments $as -QuotaImpact $quota -CatalogResult ([pscustomobject]@{ Catalog = $Catalog; Source = 'Live'; Warning = $null }) -ProcessorCatalog $Proc

        $sub1 = Get-Content (Join-Path $out 'sub1-s1.html') -Raw
        $sub1 | Should -Match "<section id='quota' class='card'><h2>Quota Actions</h2>"
        $sub1 | Should -Match "href='#quota'"
        $sub1 | Should -Match 'Sub1 DDSv5 Family vCPUs'
        $sub1 | Should -Not -Match 'Sub2 DDSv5'
        $sub1 | Should -Not -Match '<th>Subscription</th>'
        $sub1.IndexOf("<section id='vms'") | Should -BeLessThan $sub1.IndexOf("<section id='quota'")

        $sub2 = Get-Content (Join-Path $out 'sub2-s2.html') -Raw
        $sub2 | Should -Match "<section id='quota'"
        $sub2 | Should -Match 'No quota increase is needed'
        $sub2 | Should -Not -Match 'Sub1 DDSv5'

        $idx = Get-Content (Join-Path $out 'index.html') -Raw
        # Quota actions are per subscription; the tenant index has no quota section, table or navigation link.
        $idx | Should -Not -Match "id='quota'|href='#quota'|<h2>Quota Actions</h2>|<table class='quota-table'>"
        $idx | Should -Not -Match 'Sub1 DDSv5'
        # Both VMs are Gen1: the Gen1 VMs card shows 2 on the index and 1 on each subscription page.
        $idx | Should -Match "<div class='kpi-label'>Gen1 VMs</div><div class='kpi-value'>2</div><div class='kpi-hint'>of 2 VMs</div>"
        $sub1 | Should -Match "<div class='kpi-label'>Gen1 VMs</div><div class='kpi-value'>1</div><div class='kpi-hint'>of 1 VM</div>"
        $sub2 | Should -Match "<div class='kpi-label'>Gen1 VMs</div><div class='kpi-value'>1</div><div class='kpi-hint'>of 1 VM</div>"
    }
}

Describe 'Gen1 VM count and size layout' {
    It 'counts only Hyper-V generation 1 VMs' {
        InModuleScope Output {
            $vm = { param($gen) [pscustomobject]@{ Vm = [pscustomobject]@{ HyperVGeneration = $gen } } }
            Get-Gen1VmCount -Assessments @((& $vm 'V1'), (& $vm 'V2'), (& $vm 'V1'), (& $vm $null)) | Should -Be 2
            Get-Gen1VmCount -Assessments @() | Should -Be 0
        }
    }
    It 'formats VM generations and lists the size attributes on separate lines' {
        InModuleScope Output {
            Format-VmGeneration 'V1' | Should -Be 'Gen1'
            Format-VmGeneration @('V1', 'V2') | Should -Be 'Gen1, Gen2'
            Format-VmGeneration $null | Should -Be 'Unknown'
            $html = New-SizeSpecHtml -SkuName 'Standard_D4s_v3' -Vendor 'AMD' -Vcpu 4 -MemoryGb 16 -Generation 'V2' -Controller @('SCSI', 'NVMe')
            $html | Should -Match '^<code>Standard_D4s_v3</code>'
            ([regex]::Matches($html, "<div class='spec'>")).Count | Should -Be 5
            $html | Should -Match "Vendor:</span> AMD</div>.*vCPU:</span> 4 vCPU</div>.*vRAM:</span> 16 GB</div>.*VM Gen:</span> Gen2</div>.*Disk controller:</span> SCSI, NVMe</div>"
            $unknown = New-SizeSpecHtml -SkuName 'Standard_X'
            ([regex]::Matches($unknown, '</span> Unknown</div>')).Count | Should -Be 5
        }
    }
    It 'maps status values to text colour classes the same way the badges are coloured' {
        InModuleScope Output {
            Get-ToneClass 'LOW' | Should -Be 'tone-red'
            Get-ToneClass 'Migration Required Within 24 Months' | Should -Be 'tone-orange'
            Get-ToneClass 'Manual Review Required' | Should -Be 'tone-yellow'
            Get-ToneClass 'Plan Migration' | Should -Be 'tone-purple'
            Get-ToneClass 'Ready' | Should -Be 'tone-green'
            Get-ToneClass 'Intel' | Should -Be ''
            Get-ToneClass 'Something else' | Should -Be ''
            Get-ToneClass '' | Should -Be ''
            New-SpecLineHtml -Label 'Quota' -Value 'Quota OK' -Tone 'tone-green' | Should -Be "<div class='spec'><span class='spec-label'>Quota:</span> <span class='tone-green'>Quota OK</span></div>"
            New-SpecLineHtml -Label 'Score' -Value '93' | Should -Be "<div class='spec'><span class='spec-label'>Score:</span> 93</div>"
            New-SpecLineHtml -Label 'X' -Value 'y' -Title "a'b" | Should -Match "title='a&#39;b'"
        }
    }
    It 'lists material changes as one coloured Attribute: current -> target line each, capped with a +N more line' {
        InModuleScope Output {
            $change = { param($attr, $cur, $tgt, $kind, $note = '') [pscustomobject]@{ Attribute = $attr; Current = $cur; RetirementTarget = $tgt; RetirementChange = $kind; RetirementNote = $note } }
            $strategy = [pscustomobject]@{ RetirementTarget = [pscustomobject]@{ SkuName = 'x' }; TargetComparison = @(
                    (& $change 'Uncached Disk IOPS' 12800 6400 'Reduced')
                    (& $change 'Temp / Local Disk' '28 GB' 'None' 'Changed' 'Temp disk removed - validate pagefile')
                    (& $change 'Hyper-V Generation' 'V1,V2' 'V2' 'Changed' 'Gen2 only')
                    (& $change 'Disk Controller' 'SCSI,NVMe' 'SCSI,NVMe,Other' 'Changed')
                    (& $change 'Processor' 'a' 'b' 'Changed')
                    (& $change 'Max NICs' 4 2 'Reduced')
                    (& $change 'Max Data Disks' 16 8 'Reduced')
                    (& $change 'vCPU' 4 4 'Same')) }
            $html = Get-MaterialChangeLinesHtml -Assessment ([pscustomobject]@{ Strategy = $strategy }) -Max 3
            $arrow = [string][char]0x2192
            $html | Should -Match "<span class='spec-label'>Disk IOPS:</span> <span class='tone-red'>12800 $arrow 6400</span>"
            $html | Should -Match "<span class='spec-label'>Temp disk:</span> <span class='tone-yellow'>28 GB $arrow None</span>"
            $html | Should -Match "<span class='spec-label'>VM Gen:</span> <span class='tone-yellow'>Gen1, Gen2 $arrow Gen2</span>"
            # Disk Controller without a note and Processor are not material; the fourth shown item is cut off by -Max.
            $html | Should -Not -Match 'Disk controller:|Processor|NICs:'
            $html | Should -Match "<div class='spec muted'>\+2 more</div>"
            $html | Should -Not -Match "badge|chips"
            Get-MaterialChangeLinesHtml -Assessment ([pscustomobject]@{ Strategy = [pscustomobject]@{ RetirementTarget = $null; TargetComparison = @() } }) | Should -Match 'ndash'
            Get-MaterialChangeLinesHtml -Assessment ([pscustomobject]@{ Strategy = [pscustomobject]@{ RetirementTarget = [pscustomobject]@{ SkuName = 'x' }; TargetComparison = @((& $change 'vCPU' 4 4 'Same')) } }) | Should -Match '>None<'
        }
    }
    It 'shows subscription names with the ID underneath when a name map is supplied, and the ID otherwise' {
        InModuleScope Output {
            $row = [pscustomobject]@{ Scope = 'Retirement'; SubscriptionId = 'AAAA-1111'; Region = 'eastus2'; QuotaName = 'standardddsv5family'; QuotaDisplayName = 'DDSv5'; CurrentUsage = 95; Limit = 100
                RequiredVcpu = 16; MinimumIncrease = 11; RecommendedIncrease = 15; Status = 'Quota Increase Required' }
            $named = New-QuotaActionsHtml -Rows @($row) -SubscriptionNames @{ 'aaaa-1111' = 'Contoso Prod' }
            $named | Should -Match "<th>Subscription</th>"
            $named | Should -Match "<span class='strong'>Contoso Prod</span><div class='sub'>AAAA-1111</div>"
            (New-QuotaActionsHtml -Rows @($row)) | Should -Match "<td class='sub'>AAAA-1111</td>"
            (New-QuotaActionsHtml -Rows @($row) -HideSubscription) | Should -Not -Match '<th>Subscription</th>'
        }
    }
}

Describe 'Quota table display' {
    It 'shows identical Retirement and Retirement+Modernization rows once, and keeps a differing optional scope' {
        InModuleScope Output {
            $row = { param($scope, $region, $required, $status = 'Quota Increase Required')
                [pscustomobject]@{ Scope = $scope; SubscriptionId = 's1'; Region = $region; QuotaName = 'standardddsv5family'; QuotaDisplayName = 'DDSv5 Family vCPUs'; CurrentUsage = 95; Limit = 100
                    RequiredVcpu = $required; MinimumIncrease = $required - 5; RecommendedIncrease = $required; Status = $status; VmCount = 2 } }
            $rows = @((& $row 'Retirement' 'eastus2' 16), (& $row 'Retirement+Modernization' 'eastus2' 16), (& $row 'Retirement' 'westus2' 8), (& $row 'Retirement+Modernization' 'westus2' 12))
            $shown = @(Get-QuotaDisplayRows -Rows $rows)
            $shown.Count | Should -Be 3
            @($shown | Where-Object { $_.Region -eq 'eastus2' }).Count | Should -Be 1
            @($shown | Where-Object { $_.Region -eq 'westus2' }).Scope | Should -Be 'Retirement', 'Retirement+Modernization'
            $rows.Count | Should -Be 4
            $html = New-QuotaActionsHtml -Rows $rows
            ([regex]::Matches($html, '<tr><td>')).Count | Should -Be 3
            $html | Should -Match 'Identical scopes are shown once'
        }
    }
    It 'points the tenant bottom line to the subscription reports for quota actions' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1') -QuotaStatus 'Quota Increase Required'
        InModuleScope Output -Parameters @{ A = $a } {
            @(Get-BottomLine -Assessments @($A) -TenantView) -join ' ' | Should -Match 'need a vCPU quota increase first \(see Quota Actions in the subscription reports\)'
            @(Get-BottomLine -Assessments @($A)) -join ' ' | Should -Match 'need a vCPU quota increase first \(see Quota Actions\)'
        }
    }
    It 'adds peak demand only when it differs, lists peak-only actions and keeps Modernization planning rows' {
        InModuleScope Output {
            $base = { param($scope, $name, $required, $peak, $status, $peakStatus, $model = 'InPlace')
                [pscustomobject]@{ Scope = $scope; SubscriptionId = 's1'; Region = 'eastus2'; QuotaName = $name; QuotaDisplayName = "$name vCPUs"; CurrentUsage = 40; Limit = 50
                    RequiredVcpu = $required; MinimumIncrease = 0; RecommendedIncrease = 0; Status = $status; VmCount = 3; SteadyStateRequiredVcpu = $required
                    PeakMigrationRequiredVcpu = $peak; PeakMinimumIncrease = 6; PeakRecommendedIncrease = 9; PeakStatus = $peakStatus; MigrationQuotaModel = $model; SideBySideVmCount = 2 } }
            $same = @((& $base 'Retirement' 'cores' 4 4 'Quota OK' 'Quota OK'), (& $base 'Retirement' 'standardbsv2family' 4 4 'Quota Increase Required' 'Quota Increase Required'))
            $htmlSame = New-QuotaActionsHtml -Rows $same
            $htmlSame | Should -Not -Match 'Peak needed'
            $htmlSame | Should -Match 'standardbsv2family vCPUs'
            $htmlSame | Should -Not -Match '>cores vCPUs<'

            $peak = @((& $base 'Retirement' 'cores' 4 4 'Quota OK' 'Quota OK'), (& $base 'Modernization' 'cores' 4 12 'Quota OK' 'Quota Increase Required' 'Mixed'), (& $base 'Modernization' 'standarddsv6family' 8 8 'Quota OK' 'Quota OK'))
            $shown = @(Get-QuotaDisplayRows -Rows $peak)
            $shown.Count | Should -Be 2
            @($shown.Scope | Select-Object -Unique) | Should -Be 'Modernization'
            $html = New-QuotaActionsHtml -Rows $peak
            $html | Should -Match "<th class='num'>Peak needed</th>"
            $html | Should -Match "class='sub'>Mixed \(2 side-by-side\)"
            $html | Should -Match "<div class='sub peak'>peak 6</div>"
            $html | Should -Match "Peak: <span"
            $html | Should -Not -Match 'No quota increase is needed'
        }
    }
    It 'says so when nothing needs action and tolerates rows without peak fields' {
        InModuleScope Output {
            $ok = [pscustomobject]@{ Scope = 'Retirement'; SubscriptionId = 's1'; Region = 'eastus2'; QuotaName = 'cores'; QuotaDisplayName = 'cores'; CurrentUsage = 1; Limit = 100; RequiredVcpu = 4; MinimumIncrease = 0; RecommendedIncrease = 0; Status = 'Quota OK' }
            @(Get-QuotaDisplayRows -Rows @($ok)).Count | Should -Be 0
            New-QuotaActionsHtml -Rows @($ok) | Should -Match 'No quota increase is needed'
            New-QuotaActionsHtml -Rows @() | Should -Match 'No quota increase is needed'
        }
    }
}

Describe 'Retail pricing completeness' {
    BeforeEach {
        Mock Start-Sleep -ModuleName SkuCatalog {}
    }
    It 'retrieves every page, excludes spot prices and preserves missing prices' {
        InModuleScope SkuCatalog {
            Mock Invoke-RestMethod {
                param($Uri)
                if ($Uri -eq 'https://prices.azure.com/next') {
                    return [pscustomobject]@{ Items = @(
                        [pscustomobject]@{ unitOfMeasure = '1 Hour'; armSkuName = 'Standard_D4s_v5'; skuName = 'D4s_v5'; productName = 'Windows'; retailPrice = 0.4 },
                        [pscustomobject]@{ unitOfMeasure = '1 Hour'; armSkuName = 'Standard_D4s_v5'; skuName = 'D4s_v5 Spot'; productName = 'Windows'; retailPrice = 0.01 }
                    ); NextPageLink = $null }
                }
                [pscustomobject]@{ Items = @([pscustomobject]@{ unitOfMeasure = '1 Hour'; armSkuName = 'Standard_D4s_v5'; skuName = 'D4s_v5'; productName = 'Linux'; retailPrice = 0.2 }); NextPageLink = 'https://prices.azure.com/next' }
            }
            $prices = Get-RetailPrices -Region eastus2 -SkuNames @('standard_d4s_v5', 'Standard_Missing')
            $prices['standard_d4s_v5|Linux'] | Should -Be 0.2
            $prices['standard_d4s_v5|Windows'] | Should -Be 0.4
            $prices.ContainsKey('standard_missing|Linux') | Should -BeFalse
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly
        }
    }
    It 'throws after three failures on the first page' {
        InModuleScope SkuCatalog {
            Mock Invoke-RestMethod { throw 'offline' }
            { Get-RetailPrices -Region eastus2 -SkuNames Standard_D4s_v5 } | Should -Throw '*eastus2*, page 1: offline'
            Should -Invoke Invoke-RestMethod -Times 3 -Exactly
            Should -Invoke Start-Sleep -Times 2 -Exactly
        }
    }
    It 'throws rather than returning partial prices after a later-page failure' {
        InModuleScope SkuCatalog {
            Mock Invoke-RestMethod {
                param($Uri)
                if ($Uri -eq 'https://prices.azure.com/next') { throw 'page unavailable' }
                [pscustomobject]@{ Items = @([pscustomobject]@{ unitOfMeasure = '1 Hour'; armSkuName = 'Standard_D4s_v5'; skuName = 'D4s_v5'; productName = 'Linux'; retailPrice = 0.2 }); NextPageLink = 'https://prices.azure.com/next' }
            }
            { Get-RetailPrices -Region eastus2 -SkuNames Standard_D4s_v5 } | Should -Throw '*eastus2*, page 2: page unavailable'
            Should -Invoke Invoke-RestMethod -Times 4 -Exactly
        }
    }
    It 'recovers from a transient retry without discarding complete prices' {
        InModuleScope SkuCatalog {
            $script:PriceAttempt = 0
            Mock Invoke-RestMethod {
                $script:PriceAttempt++
                if ($script:PriceAttempt -eq 1) { throw 'transient' }
                [pscustomobject]@{ Items = @(); NextPageLink = $null }
            }
            (Get-RetailPrices -Region eastus2 -SkuNames Standard_D4s_v5).Count | Should -Be 0
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly
            Should -Invoke Start-Sleep -Times 1 -Exactly
        }
    }
    It 'throws if the page cap is reached with more pages pending' {
        InModuleScope SkuCatalog {
            Mock Invoke-RestMethod { [pscustomobject]@{ Items = @(); NextPageLink = 'https://prices.azure.com/next' } }
            { Get-RetailPrices -Region eastus2 -SkuNames Standard_D4s_v5 } | Should -Throw '*page limit (200) reached with more pages pending*'
            Should -Invoke Invoke-RestMethod -Times 200 -Exactly
        }
    }
    It 'accepts a completed response on the last allowed page' {
        InModuleScope SkuCatalog {
            $script:PricePage = 0
            Mock Invoke-RestMethod {
                $script:PricePage++
                [pscustomobject]@{ Items = @(); NextPageLink = if ($script:PricePage -lt 200) { 'https://prices.azure.com/next' } else { $null } }
            }
            (Get-RetailPrices -Region eastus2 -SkuNames Standard_D4s_v5).Count | Should -Be 0
            Should -Invoke Invoke-RestMethod -Times 200 -Exactly
        }
    }
}

Describe 'HTML anchors and encoding' {
    It 'gives same-named VMs in different resource groups distinct detail anchors and encodes the zone' {
        $out = Join-Path $TestDrive 'anchors'; New-Item -ItemType Directory $out | Out-Null
        $vmA = New-TestVm -Name 'app01' -Sku 'Standard_DS3_v2' -Gen 'V1'; $vmA.ResourceGroup = 'rg-east'
        $vmB = New-TestVm -Name 'app01' -Sku 'Standard_DS3_v2' -Gen 'V1'; $vmB.ResourceGroup = 'rg-west'; $vmB.Zone = '1<b>'
        $as = @((Invoke-TestAssessment $vmA), (Invoke-TestAssessment $vmB))
        $as[0].Confidence.ValidationItems += "Owner's workload <script>alert(1)</script>"
        $sum = New-AssessmentSummary -Assessments $as -SubscriptionsScanned 1
        $run = [pscustomobject]@{ GeneratedUtc = 'now'; AsOf = $AsOf; Tenant = [pscustomobject]@{ Id = 't'; Name = 'tenant' }; Account = 'x'; Parameters = @{}; Counts = @{} }
        Export-HtmlReports -OutDir $out -CssPath (Join-Path $Root 'templates/report.css') -Run $run -Summary $sum -Assessments $as -QuotaImpact $null -CatalogResult ([pscustomobject]@{ Catalog = $Catalog; Source = 'Live'; Warning = $null }) -ProcessorCatalog $Proc
        $html = Get-Content (Get-ChildItem $out -Filter '*.html' | Where-Object Name -ne 'index.html' | Select-Object -First 1).FullName -Raw
        # Each VM has its own toggle and a detail row keyed by the resource-group-qualified anchor, so same-named VMs never collide.
        $html | Should -Match "<tr class='vm-summary-row[^']*' id='vm-rg-east-app01-[0-9a-f]{6}'>"
        $html | Should -Match "<tr class='vm-summary-row[^']*' id='vm-rg-west-app01-[0-9a-f]{6}'>"
        $html | Should -Match "<input type='checkbox' class='vm-toggle' id='tg-vm-rg-east-app01-[0-9a-f]{6}'"
        $html | Should -Match "<label class='vm-toggle-label' for='tg-vm-rg-west-app01-[0-9a-f]{6}'>Details</label>"
        $html | Should -Match "<tr class='vm-detail-row' id='vm-rg-east-app01-[0-9a-f]{6}-details'>"
        $html | Should -Match "<tr class='vm-detail-row' id='vm-rg-west-app01-[0-9a-f]{6}-details'>"
        @([regex]::Matches($html, "id='tg-[^']+'") | ForEach-Object Value | Select-Object -Unique).Count | Should -Be 2
        $html | Should -Match 'zone 1&lt;b&gt;'
        $html | Should -Not -Match 'zone 1<b>'
        $html | Should -Match 'Owner&#39;s workload &lt;script&gt;alert\(1\)&lt;/script&gt;'
        $html | Should -Not -Match '<script>'
    }
    It 'gives resource-group/name pairs that only differ by where the hyphen falls different ids' {
        InModuleScope Output {
            $a = Get-VmAnchorId ([pscustomobject]@{ ResourceGroup = 'app-prod'; Name = 'db' })
            $b = Get-VmAnchorId ([pscustomobject]@{ ResourceGroup = 'app'; Name = 'prod-db' })
            $a | Should -Not -Be $b
            $a | Should -Match '^vm-app-prod-db-[0-9a-f]{6}$'
            $b | Should -Match '^vm-app-prod-db-[0-9a-f]{6}$'
            # Deterministic and case-insensitive, like Azure resource names.
            Get-VmAnchorId ([pscustomobject]@{ ResourceGroup = 'APP-prod'; Name = 'DB' }) | Should -Be $a
            Get-VmAnchorId ([pscustomobject]@{ ResourceGroup = 'rg<script>'; Name = "x'y" }) | Should -Match "^[a-z0-9._-]+$"
        }
    }
    It 'labels the confidence and readiness badges, explains them on hover and encodes the hover text' {
        InModuleScope Output {
            $badge = New-Badge 'MEDIUM' -Label 'Confidence: MEDIUM' -Title "It's <b>"
            $badge | Should -Be "<span class='badge b-yellow' title='It&#39;s &lt;b&gt;'>Confidence: MEDIUM</span>"
            New-Badge 'Ready' | Should -Be "<span class='badge b-green'>Ready</span>"
            $tip = Get-ConfidenceTooltip ([pscustomobject]@{ Level = 'LOW'; LowReasons = @('CPU vendor change required'); ValidationItems = @('Temp Disk: target has no temp disk') })
            $tip | Should -Match '^Confidence in the recommended size: LOW\. Validate first:'
            $tip | Should -Match '- Blocker: CPU vendor change required'
            $tip | Should -Match '- Temp Disk: target has no temp disk'
            Get-ConfidenceTooltip ([pscustomobject]@{ Level = 'HIGH'; LowReasons = @(); ValidationItems = @() }) | Should -Match 'No outstanding items in the assessed evidence'
            $script:ReadinessMeaning['Ready'].Long | Should -Match 'does not guarantee hardware allocation or a successful resize'
            $script:ReadinessMeaning['Ready'].Long | Should -Match 'Validate guest OS, workload, licensing and capacity'
        }
        $html = Get-Content (Get-ChildItem (Join-Path $TestDrive 'anchors') -Filter '*.html' | Where-Object Name -ne 'index.html' | Select-Object -First 1).FullName -Raw
        $html | Should -Match "<span class='badge b-\w+' title='Confidence in the recommended size: \w+\.[^']*'>Confidence: (HIGH|MEDIUM|LOW)</span>"
        $html | Should -Match "<span class='badge b-\w+' title='Readiness of the recommended size: [^']+'>Readiness: [^<]+</span>"
        $html | Should -Match '<dt>Readiness<span class="legend-sub">checked platform prerequisites</span></dt>'
        $html | Should -Match '<dt>Confidence<span class="legend-sub">in the recommended size</span></dt>'
        $html | Should -Match 'Neither <em>Ready</em> nor <em>HIGH</em> guarantees hardware allocation or a successful resize'
        $html | Should -Not -Match 'can be deployed now|Can be resized in a change window|Everything verified'
        $html | Should -Match 'Hover over a confidence or readiness badge for its explanation'
        $html | Should -Match '<code>-ExtendedDetails</code>'
        # The arrows that show the upgrade sequence in the card header are bold green.
        $html | Should -Match "<span class='move-arrow'>&rarr;</span>"
        $html | Should -Match '\.move-arrow \{ color: #16a34a; font-weight: 900;'
        # The legend is one compact panel: a row per topic (status, confidence, readiness, score), a visible caveat and a
        # collapsed note, instead of four tall cards.
        $legend = [regex]::Match($html, '(?s)<div class="legend">.*?</details>\s*</div>').Value
        $legend | Should -Not -BeNullOrEmpty
        ([regex]::Matches($legend, '<div class="legend-row">')).Count | Should -Be 4
        $legend | Should -Match '<dt>Microsoft status</dt>'
        $legend | Should -Match '<dt>Score \(0&ndash;100\)</dt>'
        $legend | Should -Match '<p class="legend-note">'
        $legend | Should -Match '<details class="legend-more"><summary>'
        $legend | Should -Not -Match '<details class="legend-more"[^>]*open'
        $legend | Should -Not -Match '<h3>'
        $html | Should -Not -Match 'legend-list'
        foreach ($status in 'Retired', 'End of Life', 'Confirmed Retirement', 'Modernization Recommended', 'No Retirement Announced', 'HIGH', 'MEDIUM', 'LOW', 'Ready', 'Quota Increase Required', 'Capacity Validation Required', 'Manual Review Required', 'SKU Restricted', 'Regional Limitation') {
            $legend | Should -Match ("<span class='badge b-\w+'>" + [regex]::Escape($status) + '</span>')
        }
        $legend | Should -Match 'href=.https://learn\.microsoft\.com/[^>]+>End of Life list</a>'
        $html | Should -Match '\.legend-row \{ display: grid; grid-template-columns: 150px'
        $html | Should -Match '\.legend-row \{ grid-template-columns: minmax\(0, 1fr\); \}'
        $html | Should -Match 'details\.legend-more::details-content \{ content-visibility: visible; display: block; \}'
        # By default the card carries neither the long explanations nor the gate table; those need -ExtendedDetails.
        $html | Should -Not -Match '<h3>Assessment explanations</h3>'
        $html | Should -Not -Match '<dd class="assessment-explanation">'
        $html | Should -Not -Match '<h3>Mandatory requirement checks</h3>'
        $html | Should -Not -Match '<h4>Sizes evaluated</h4>'
        $html | Should -Match '<h4>Recommended sizes</h4>'
    }
    It 'shows explanations, requirement checks and every evaluated size only with -ExtendedDetails' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1')
        $sum = New-AssessmentSummary -Assessments @($a) -SubscriptionsScanned 1
        $render = {
            param($extended)
            $out = Join-Path $TestDrive "extended-$extended"; New-Item -ItemType Directory $out | Out-Null
            $run = [pscustomobject]@{ GeneratedUtc = 'now'; AsOf = $AsOf; Tenant = [pscustomobject]@{ Id = 't'; Name = 'tenant' }; Account = 'x'; Parameters = @{ ExtendedDetails = $extended }; Counts = @{} }
            Export-HtmlReports -OutDir $out -CssPath (Join-Path $Root 'templates/report.css') -Run $run -Summary $sum -Assessments @($a) -QuotaImpact $null -CatalogResult ([pscustomobject]@{ Catalog = $Catalog; Source = 'Live'; Warning = $null }) -ProcessorCatalog $Proc
            Get-Content (Get-ChildItem $out -Filter '*.html' | Where-Object Name -ne 'index.html' | Select-Object -First 1).FullName -Raw
        }
        $sizeRows = { param($html, $heading) ([regex]::Matches(([regex]::Match($html, "(?s)<h4>$heading</h4>.*?</section>").Value), '<tr><td>')).Count }
        $recommended = @(@($a.Candidates.Primary, $a.Candidates.Secondary, $a.Candidates.Third) | Where-Object { $_ } | ForEach-Object SkuName | Select-Object -Unique)
        $all = @($a.Candidates.Candidates).Count

        $default = & $render $false
        & $sizeRows $default 'Recommended sizes' | Should -Be $recommended.Count
        $default | Should -Not -Match '<h3>Assessment explanations</h3>|<h3>Mandatory requirement checks</h3>|<h4>Sizes evaluated</h4>|<h4>Extended details</h4>'
        $default | Should -Not -Match '<dl class="facts">|<dt>Recommended size</dt>|<dt>Candidate series</dt>'
        if ($all -gt $recommended.Count) { $default | Should -Match "<p class='note'>\d+ more evaluated sizes? (is|are) shown when the report is generated with <code>-ExtendedDetails</code>" }

        $extended = & $render $true
        $extended | Should -Match '<h4>Extended details</h4>'
        $extended | Should -Match '<h3>Assessment explanations</h3>'
        $extended | Should -Match '<dt>Microsoft status</dt>'
        $extended | Should -Match '<dt>Recommended size</dt>'
        $extended | Should -Match '<dt>Candidate series</dt>'
        $extended | Should -Match '<dd class="assessment-explanation">Confidence in the recommended size:'
        $extended | Should -Match '<dd class="assessment-explanation">Readiness of the recommended size:'
        $extended | Should -Match '<h3>Mandatory requirement checks</h3>'
        & $sizeRows $extended 'Sizes evaluated' | Should -Be $all
        $extended | Should -Not -Match '<h4>Recommended sizes</h4>|more evaluated sizes? (is|are) shown'
    }
}

Describe 'In-table collapsible VM details' {
    BeforeAll {
        $script:Pair = @((Invoke-TestAssessment (New-TestVm -Name 'a1' -Sku 'Standard_DS3_v2' -Gen 'V1')), (Invoke-TestAssessment (New-TestVm -Name 'b2' -Sku 'Standard_DS3_v2' -Gen 'V2')))
        $Pair[0].ValidationItems = @($Pair[0].ValidationItems) + 'Guest NVMe readiness: confirm the guest OS has NVMe drivers' + 'See https://learn.microsoft.com/azure/virtual-machines/sizes for the size list'
        $sum = New-AssessmentSummary -Assessments $Pair -SubscriptionsScanned 1
        $script:DetailOut = Join-Path $TestDrive 'detail-rows'; New-Item -ItemType Directory $DetailOut | Out-Null
        $run = [pscustomobject]@{ GeneratedUtc = 'now'; AsOf = $AsOf; Tenant = [pscustomobject]@{ Id = 't'; Name = 'tenant' }; Account = 'x'; Parameters = @{}; Counts = @{} }
        Export-HtmlReports -OutDir $DetailOut -CssPath (Join-Path $Root 'templates/report.css') -Run $run -Summary $sum -Assessments $Pair -QuotaImpact $null -CatalogResult ([pscustomobject]@{ Catalog = $Catalog; Source = 'Live'; Warning = $null }) -ProcessorCatalog $Proc
        $script:DetailHtml = Get-Content (Get-ChildItem $DetailOut -Filter '*.html' | Where-Object Name -ne 'index.html' | Select-Object -First 1).FullName -Raw
    }
    It 'puts a collapsed detail row under each VM and drops the separate details section' {
        ([regex]::Matches($DetailHtml, "(?s)<tr class='vm-summary-row[^']*'[^>]*>.*?</tr>\s*<tr class='vm-detail-row'")).Count | Should -Be 2
        $DetailHtml | Should -Match "<td colspan='7' class='vm-detail-cell'><div class=.vm-detail.>"
        $DetailHtml | Should -Not -Match "id='details'|<h2>VMs with Retiring SKUs details</h2>|href='#details'|<details class=.vm."
        $DetailHtml | Should -Not -Match '<script'
        # The checkbox sits directly before its label, which the CSS selectors rely on.
        $DetailHtml | Should -Match "<input type='checkbox' class='vm-toggle' id='tg-[^']+' aria-label='[^']+'><label class='vm-toggle-label' for='tg-"
        $DetailHtml | Should -Match "<input type='checkbox' class='vm-toggle-all' id='vm-expand-all'[^>]*><label class='vm-toggle-all-label' for='vm-expand-all'><span class='off'>Expand all details</span><span class='on'>Collapse all details</span></label>"
    }
    It 'styles the toggle with CSS only, with print and no-:has() fallbacks' {
        $DetailHtml | Should -Match '@supports selector\(:has\(\*\)\) \{'
        $DetailHtml | Should -Match '\.vm-table tr\.vm-detail-row \{ display: none; \}'
        $DetailHtml | Should -Match 'tr:has\(\.vm-toggle:checked\) \+ tr\.vm-detail-row'
        $DetailHtml | Should -Match '\.vm-table-block:has\(\.vm-toggle-all:checked\) tr\.vm-detail-row'
        $DetailHtml | Should -Match '@supports not selector\(:has\(\*\)\) \{ \.vm-toggle-label, \.vm-table-tools \{ display: none; \} \}'
        $DetailHtml | Should -Match '\.vm-table tr\.vm-detail-row \{ display: table-row !important; \}'
        $DetailHtml | Should -Match '--detail-bg: #eaf4f4; --detail-edge: #0f766e; --detail-on-edge: #ffffff;'
        # Dark mode: the checked pill uses dark text on the bright teal edge (white would be 1.9:1).
        $DetailHtml | Should -Match '--detail-edge: #2dd4bf; --detail-on-edge: #052e2a;'
        $DetailHtml | Should -Match '\.vm-detail \{ position: sticky; left: 0;'
    }
    It 'shows what to do, what changes, what to validate and the recommended sizes in that order' {
        $first = [regex]::Match($DetailHtml, "(?s)<tr class='vm-detail-row'.*?</div>\s*</td></tr>").Value
        $first | Should -Not -BeNullOrEmpty
        $order = '<div class="vd-head">', '<h4>What to do</h4>', '<h4>What changes</h4>', '<h4>Validate before resizing</h4>', '<h4>Recommended sizes</h4>'
        $last = -1
        foreach ($marker in $order) { $i = $first.IndexOf($marker); $i | Should -BeGreaterThan $last; $last = $i }
        $first | Should -Match "<ol class='vd-steps'><li>"
        $first | Should -Match "<span class='move-arrow'>&rarr;</span>"
        # "Topic: text" validation items get a bold topic; the compact table lists only differences and the full list is one click away.
        $first | Should -Match '<li><strong>[^<:]+:</strong> '
        $first | Should -Match "<details class='vd-more'><summary>Show all \d+ attributes</summary>"
        $compact = [regex]::Match($first, "(?s)<h4>What changes</h4>(.*?)<details class='vd-more'>").Groups[1].Value
        $full = [regex]::Match($first, "(?s)<details class='vd-more'>(.*?)</details>").Groups[1].Value
        ([regex]::Matches($compact, '<tr><td>')).Count | Should -BeLessThan ([regex]::Matches($full, '<tr><td>')).Count
        $compact | Should -Not -Match '<td>Processor</td>|<td>CPU Vendor</td>'
    }
    It 'bolds only real "Topic: text" prefixes, never part of a URL' {
        $first = [regex]::Match($DetailHtml, "(?s)<tr class='vm-detail-row'.*?</div>\s*</td></tr>").Value
        $first | Should -Match '<li><strong>Guest NVMe readiness:</strong> confirm the guest OS has NVMe drivers</li>'
        $first | Should -Match '<li>See https://learn\.microsoft\.com/azure/virtual-machines/sizes for the size list</li>'
        $first | Should -Not -Match '<strong>See https:</strong>'
    }
    It 'keeps text selectable, bounds the row overlay and opens "Show all attributes" in print' {
        $DetailHtml | Should -Match '\.vm-table-block \{ position: relative; \}'
        $DetailHtml | Should -Match 'td:first-child \.strong, \.vm-table \.vm-summary-row td:first-child \.sub \{ position: relative; z-index: 2; \}'
        $DetailHtml | Should -Match 'details\.vd-more::details-content \{ content-visibility: visible; display: block; \}'
    }
}

Describe 'Current Hyper-V generation in the comparison' {
    It 'shows the VM''s own generation, and compares it with what the target supports' {
        $v1 = Invoke-TestAssessment (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1')
        $v2 = Invoke-TestAssessment (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V2')
        $row = { param($a) @($(if ($a.Strategy) { $a.Strategy } else { Get-TargetStrategy -Assessment $a }).TargetComparison) | Where-Object Attribute -eq 'Hyper-V Generation' | Select-Object -First 1 }
        (& $row $v1).Current | Should -Be 'V1'
        (& $row $v2).Current | Should -Be 'V2'
        (& $row $v2).RetirementChange | Should -Be 'Same'
    }
    It 'shows the VM''s own disk controller as the current value' {
        $rec = $SkuCat['standard_d4s_v3']
        $proc = Get-ProcessorInfo 'Standard_D4s_v3' $Proc $rec
        $target = [pscustomobject]@{}
        foreach ($p in $rec.PSObject.Properties) { Add-Member -InputObject $target -NotePropertyName $p.Name -NotePropertyValue $p.Value }
        $procInfo = [pscustomobject]@{ Vendor = 'Intel'; Architecture = 'x64'; Processors = @() }
        $row = { param($cur, $tgt) @(Get-MaterialDifferences -Current $cur -Candidate $tgt -CandidateProc $procInfo) | Where-Object Attribute -eq 'Disk Controller' | Select-Object -First 1 }

        $nvmeOnly = $target.PSObject.Copy(); $nvmeOnly.DiskControllerTypes = @('NVMe')
        $both = $target.PSObject.Copy(); $both.DiskControllerTypes = @('SCSI', 'NVMe')
        $scsiVm = New-CurrentProfile -SkuName 'Standard_D4s_v3' -SkuRecord $rec -ProcessorInfo $proc -VmDiskController 'SCSI'
        $nvmeVm = New-CurrentProfile -SkuName 'Standard_D4s_v3' -SkuRecord $rec -ProcessorInfo $proc -VmDiskController 'NVMe'
        $unknownVm = New-CurrentProfile -SkuName 'Standard_D4s_v3' -SkuRecord $rec -ProcessorInfo $proc

        (& $row $scsiVm $nvmeOnly).Current | Should -Be 'SCSI'
        (& $row $scsiVm $nvmeOnly).Assessment | Should -Be 'Changed'
        (& $row $scsiVm $nvmeOnly).Note | Should -Be 'NVMe only'
        (& $row $scsiVm $both).Assessment | Should -Be 'Same'
        (& $row $nvmeVm $nvmeOnly).Current | Should -Be 'NVMe'
        (& $row $nvmeVm $nvmeOnly).Assessment | Should -Be 'Same'
        (& $row $nvmeVm $nvmeOnly).Note | Should -BeNullOrEmpty
        # No VM controller supplied: the size's supported set is compared, as before.
        (& $row $unknownVm $nvmeOnly).Current | Should -Be ($rec.DiskControllerTypes -join ',')
    }
}
