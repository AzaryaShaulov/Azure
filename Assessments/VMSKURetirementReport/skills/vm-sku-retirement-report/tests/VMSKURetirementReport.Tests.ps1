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
            [string]$QuotaStatus = 'Quota OK',
            $ScoringWeights = $script:Weights
        )
        $lc = Resolve-SkuLifecycle -SkuName $Vm.SkuName -Catalog $RetirementCatalog -AsOf $AsOfDate
        $a = New-VmAssessment -Vm $Vm -Lifecycle $lc -RegionCatalog $Catalog -ProcessorCatalog $script:Proc -RetirementCatalog $RetirementCatalog `
            -LifecycleCache @{} -CandidateCache @{} -Weights $ScoringWeights -AsOf $AsOfDate -SubscriptionName 'sub1' -MaxCandidates $MaxCandidates `
            -CheckModernization:$CheckModernization
        $q = [pscustomobject]@{ Status = $QuotaStatus; DataQuality = 'Verified'; Family = [pscustomobject]@{ QuotaDisplayName = 'x'; MinimumIncrease = 0; RecommendedIncrease = 0; CurrentUsage = 0; Limit = 100; RequiredVcpu = 4 }; Regional = [pscustomobject]@{ MinimumIncrease = 0 } }
        Complete-VmAssessment -Assessment $a -QuotaResult $q -Usage @{}
    }
    function script:Export-TestOutput {
        param([object[]]$Assessments, $QuotaImpact = $null, [object[]]$CollectionIssues = @(), [switch]$Html, [hashtable]$ExtraParameters = @{})
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $dir | Out-Null
        $parameters = [ordered]@{ IncludePricing = $false; HorizonMonths = 36 }
        foreach ($key in $ExtraParameters.Keys) { $parameters[$key] = $ExtraParameters[$key] }
        $run = [pscustomobject]@{ GeneratedUtc = '2026-09-24T00:00:00Z'; AsOf = $AsOf; Tenant = [pscustomobject]@{ Id = 't'; Name = 'n' }; Account = 'a'; Parameters = $parameters
            Counts = [pscustomobject]@{ Vms = @($Assessments).Count; Nics = 0; Disks = 0; AdeExtensions = 0; AdvisorRetirement = 0; ServiceHealthRetirement = 0 } }
        $summary = New-AssessmentSummary -Assessments $Assessments -SubscriptionsScanned 1
        $catalogResult = [pscustomobject]@{ Source = 'Fixture'; Warning = $null; Catalog = $Catalog }
        [void](Export-AssessmentData -OutDir $dir -Run $run -Assessments $Assessments -Summary $summary -QuotaImpact $QuotaImpact -CatalogResult $catalogResult -Inventory $null -CollectionIssues $CollectionIssues)
        if ($Html) {
            Export-ExecutiveSummaryMarkdown -Path (Join-Path $dir 'executive-summary.md') -Run $run -Summary $summary -Rows @() -QuotaImpact $QuotaImpact -CatalogResult $catalogResult -CollectionIssues $CollectionIssues
            Export-HtmlReports -OutDir $dir -CssPath (Join-Path $Root 'templates/report.css') -Run $run -Summary $summary -Assessments $Assessments -QuotaImpact $QuotaImpact -CatalogResult $catalogResult -ProcessorCatalog $Proc -CollectionIssues $CollectionIssues
        }
        $dir
    }
    function script:Read-TestJson { param([string]$Dir) Get-Content (Join-Path $Dir 'assessment.json') -Raw | ConvertFrom-Json -Depth 40 }
    # A fake Azure CLI on PATH for the duration of -Action: a script named az.ps1 whose stderr (Write-Error) reaches the caller's 2> redirection.
    function script:Use-FakeAz {
        param([Parameter(Mandatory)][string]$Body, [Parameter(Mandatory)][scriptblock]$Action)
        $dir = Join-Path $TestDrive ('fake-az-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $dir | Out-Null
        Set-Content (Join-Path $dir 'az.ps1') -Value $Body
        $savedPath = $env:PATH
        try { $env:PATH = "$dir$([System.IO.Path]::PathSeparator)$env:PATH"; & $Action }
        finally { $env:PATH = $savedPath }
    }
    $script:Denied = "Write-Error `"ERROR: (AuthorizationFailed) The client 'jane.doe@contoso.com' with object id '11111111-2222-3333-4444-555555555555' does not have authorization to perform action 'X' over scope '/subscriptions/s1'.`" -ErrorAction Continue; exit 1"
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
    It 'masks the account and the object id in "<Name>"' -ForEach @(
        @{ Name = 'quoted text'; Text = "The client 'jane.doe@contoso.com' with object id '11111111-2222-3333-4444-555555555555' cannot act."; Expected = "The client 'j****@contoso.com' with object id '****' cannot act." }
        @{ Name = 'unquoted text'; Text = 'object id 11111111-2222-3333-4444-555555555555 belongs to jane.doe@contoso.com'; Expected = 'object id **** belongs to j****@contoso.com' }
        @{ Name = 'double quotes in any case'; Text = 'Object ID "11111111-2222-3333-4444-555555555555"'; Expected = 'Object ID "****"' }
        @{ Name = 'a JSON error body that PowerShell re-serialized'; Text = 'The client \u0027jane.doe@contoso.com\u0027 with object id \u002711111111-2222-3333-4444-555555555555\u0027 cannot act.'; Expected = 'The client \u0027j****@contoso.com\u0027 with object id \u0027****\u0027 cannot act.' }
        @{ Name = 'text that has already been masked'; Text = "The client 'j****@contoso.com' with object id '****' cannot act."; Expected = "The client 'j****@contoso.com' with object id '****' cannot act." }
        @{ Name = 'text with a subscription id'; Text = "scope '/subscriptions/66666666-7777-8888-9999-000000000000' for jane.doe@contoso.com"; Expected = "scope '/subscriptions/66666666-7777-8888-9999-000000000000' for j****@contoso.com" }
        @{ Name = 'several lines'; Text = "first jane.doe@contoso.com`r`nsecond john@fabrikam.org`r`n"; Expected = "first j****@contoso.com`r`nsecond j****@fabrikam.org`r`n" }
    ) {
        Hide-Identity $Text | Should -Be $Expected
    }
    It 'keeps the accounts it is told to keep, and still masks the others' {
        Hide-Identity 'jane.doe@contoso.com and john@fabrikam.org' -Keep 'JANE.DOE@contoso.com' | Should -Be 'jane.doe@contoso.com and j****@fabrikam.org'
        Hide-Identity $null | Should -BeNullOrEmpty
        Hide-Identity '' | Should -Be ''
    }
    It 'shows the quote of a re-serialized JSON error body as a quote and still masks the object id' {
        $raw = "{`n  `"error`": {`n    `"code`": `"AuthorizationFailed`",`n    `"message`": `"The client \u0027jane.doe@contoso.com\u0027 with object id \u002711111111-2222-3333-4444-555555555555\u0027 does not have authorization.`"`n  }`n}"
        $safe = ConvertTo-SafeCliMessage $raw
        $safe | Should -Match "The client 'j\*\*\*\*@contoso\.com' with object id '\*\*\*\*' does not have authorization"
        $safe | Should -Not -Match 'jane\.doe|11111111-2222'
        $safe | Should -Not -Match '\\u0027'
    }
}

Describe 'Protecting run.log' {
    BeforeAll {
        # What PowerShell wrote to a real transcript for a caught Invoke-RestMethod 403 (checked against a local HTTP listener).
        $script:LeakedTranscript = @'
**********************
PowerShell transcript start
**********************
=== Rightsizing telemetry (Azure Monitor, 30 days): 4 VMs ===
PS>TerminatingError(Invoke-RestMethod): "
{
  "error": {
    "code": "AuthorizationFailed",
    "message": "The client \u0027admin@contoso.example\u0027 with object id \u002799999999-9999-9999-9999-999999999999\u0027 does not have authorization to perform action \u0027microsoft.insights/metrics/read\u0027."
  }
}"
Account: a****@contoso.example
**********************
PowerShell transcript end
**********************
'@
    }

    It 'masks the account and the object id that a caught REST error left in the transcript, and changes nothing else' {
        $path = Join-Path $TestDrive 'leaked.log'
        [System.IO.File]::WriteAllText($path, $LeakedTranscript, [System.Text.UTF8Encoding]::new($false))
        Protect-RunLog -Path $path
        $text = [System.IO.File]::ReadAllText($path)
        $text | Should -Not -Match 'admin@contoso\.example|99999999-9999'
        $text | Should -Match 'The client \\u0027a\*\*\*\*@contoso\.example\\u0027 with object id \\u0027\*\*\*\*\\u0027 does not have authorization to perform action \\u0027microsoft\.insights/metrics/read\\u0027'
        $restored = $text.Replace('a****@contoso.example\u0027 with', 'admin@contoso.example\u0027 with').Replace('object id \u0027****', 'object id \u002799999999-9999-9999-9999-999999999999')
        $restored | Should -BeExactly $LeakedTranscript
    }

    It 'keeps the account the operator asked to see and masks the object id' {
        $path = Join-Path $TestDrive 'kept.log'
        [System.IO.File]::WriteAllText($path, $LeakedTranscript, [System.Text.UTF8Encoding]::new($false))
        Protect-RunLog -Path $path -Keep 'admin@contoso.example'
        $text = [System.IO.File]::ReadAllText($path)
        $text | Should -Match 'The client \\u0027admin@contoso\.example\\u0027 with object id \\u0027\*\*\*\*\\u0027'
        $text | Should -Not -Match '99999999-9999'
    }

    It 'leaves a transcript that names no account exactly as it was' {
        $path = Join-Path $TestDrive 'clean.log'
        [System.IO.File]::WriteAllBytes($path, [System.Text.Encoding]::UTF8.GetBytes("Tenant: Contoso  Account: j****@contoso.com`r`nScope: 1 subscription(s)`r`n"))
        $before = (Get-FileHash -LiteralPath $path).Hash
        Protect-RunLog -Path $path
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $before
    }

    It 'does nothing when there is no transcript' {
        { Protect-RunLog -Path (Join-Path $TestDrive 'missing.log') } | Should -Not -Throw
        Join-Path $TestDrive 'missing.log' | Should -Not -Exist
    }

    It 'warns instead of failing when the transcript cannot be rewritten' {
        $path = Join-Path $TestDrive 'locked.log'
        [System.IO.File]::WriteAllText($path, $LeakedTranscript)
        $stream = [System.IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
        try { $warnings = @(Protect-RunLog -Path $path 3>&1) }
        finally { $stream.Dispose() }
        $warnings.Count | Should -Be 1
        $warnings[0].Message | Should -Match '^run\.log could not be checked for account names and object ids: '
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

Describe 'Candidate cache key' {
    BeforeAll {
        function script:Invoke-SharedCacheAssessment {
            param([object[]]$Vms, [hashtable]$Region = $SkuCat)
            $cache = @{}
            $result = @{}
            foreach ($vm in $Vms) {
                $lc = Resolve-SkuLifecycle -SkuName $vm.SkuName -Catalog $Catalog -AsOf $AsOf
                $result[$vm.Name] = New-VmAssessment -Vm $vm -Lifecycle $lc -RegionCatalog $Region -ProcessorCatalog $Proc -RetirementCatalog $Catalog `
                    -LifecycleCache @{} -CandidateCache $cache -Weights $Weights -AsOf $AsOf -SubscriptionName 'sub1'
            }
            [pscustomobject]@{ Cache = $cache; Result = $result }
        }
    }

    It 'gives a VM on a dedicated host group its own Dedicated Host review whichever VM is assessed first' -ForEach @(@{ Reverse = $false }, @{ Reverse = $true }) {
        $plain = New-TestVm -Name 'plain' -Sku 'Standard_DS3_v2' -Gen 'V1'
        $grouped = New-TestVm -Name 'grouped' -Sku 'Standard_DS3_v2' -Gen 'V1'
        $grouped.DedicatedHostGroupId = '/subscriptions/s1/resourceGroups/rg/providers/Microsoft.Compute/hostGroups/hg1'
        $run = Invoke-SharedCacheAssessment -Vms $(if ($Reverse) { @($grouped, $plain) } else { @($plain, $grouped) })
        $run.Cache.Count | Should -Be 2
        $run.Result['grouped'].Candidates.Primary.ReviewGates | Should -Contain 'Dedicated Host'
        $run.Result['plain'].Candidates.Primary.ReviewGates | Should -Not -Contain 'Dedicated Host'
    }

    It 'keeps "controller not reported" on the VM that did not report one whichever VM is assessed first' -ForEach @(@{ Reverse = $false }, @{ Reverse = $true }) {
        $reported = New-TestVm -Name 'reported' -Sku 'Standard_DS3_v2' -Gen 'V1' -Controller 'SCSI'
        $default = New-TestVm -Name 'default' -Sku 'Standard_DS3_v2' -Gen 'V1'
        $run = Invoke-SharedCacheAssessment -Vms $(if ($Reverse) { @($default, $reported) } else { @($reported, $default) })
        $run.Cache.Count | Should -Be 2
        $detail = { param($a) (@($a.Candidates.Primary.Gates) | Where-Object Gate -eq 'Disk Controller').Detail }
        & $detail $run.Result['default'] | Should -Match 'not reported'
        & $detail $run.Result['reported'] | Should -Not -Match 'not reported'
    }

    It 'reports each VM''s own count of Accelerated Networking NICs whichever VM is assessed first' -ForEach @(@{ Reverse = $false }, @{ Reverse = $true }) {
        $noAccel = @{ 'standard_d4s_v3' = $SkuCat['standard_d4s_v3']; 'standard_d4s_v5' = $SkuCat['standard_d4s_v5'].PSObject.Copy() }
        $noAccel['standard_d4s_v5'].AcceleratedNetworking = $false
        $both = New-TestVm -Name 'both' -Sku 'Standard_D4s_v3' -Nics 2
        $one = New-TestVm -Name 'one' -Sku 'Standard_D4s_v3' -Nics 2
        $one.AcceleratedNicCount = 1
        $run = Invoke-SharedCacheAssessment -Vms $(if ($Reverse) { @($one, $both) } else { @($both, $one) }) -Region $noAccel
        $run.Cache.Count | Should -Be 2
        $reason = { param($a) @($a.Candidates.Candidates)[0].RejectionReason }
        & $reason $run.Result['both'] | Should -Match '^Accelerated Networking: 2 NIC'
        & $reason $run.Result['one'] | Should -Match '^Accelerated Networking: 1 NIC'
    }

    It 'still shares one evaluation between VMs that are identical for the search' {
        $run = Invoke-SharedCacheAssessment -Vms @((New-TestVm -Name 'a' -Sku 'Standard_DS3_v2' -Gen 'V1'), (New-TestVm -Name 'b' -Sku 'Standard_DS3_v2' -Gen 'V1'))
        $run.Cache.Count | Should -Be 1
    }

    It 'includes in the key every VM property that candidate selection and scoring read' {
        $parse = { param($p) [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$null) }
        $isVmRead = { param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Expression.VariablePath.UserPath -eq 'Vm' -and $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] }
        $reads = foreach ($f in 'Candidates.psm1', 'Scoring.psm1') {
            (& $parse (Join-Path $Root "scripts/modules/$f")).FindAll($isVmRead, $true) | ForEach-Object { $_.Member.Value }
        }
        $keyAssignment = (& $parse (Join-Path $Root 'scripts/modules/Assessment.psm1')).FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$sig' }, $true) | Select-Object -First 1
        $keyAssignment | Should -Not -BeNullOrEmpty
        $inKey = @([regex]::Matches($keyAssignment.Right.Extent.Text, '\$Vm\.(\w+)') | ForEach-Object { $_.Groups[1].Value })
        $missing = @($reads | Sort-Object -Unique | Where-Object { $_ -notin $inKey })
        ($missing -join ', ') | Should -BeNullOrEmpty
    }
}

Describe 'JSON and CSV output shapes' {
    BeforeAll {
        function script:Get-BuilderColumns {
            param([string]$File, [string]$Function)
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root "scripts/modules/$File"), [ref]$null, [ref]$null)
            $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object Name -eq $Function)[0]
            $row = @($fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true) | Sort-Object { $_.KeyValuePairs.Count } -Descending)[0]
            @($row.KeyValuePairs | ForEach-Object { $_.Item1.Value })
        }
        $script:ShapeCatalog = @{ 'standard_d4s_v3' = $SkuCat['standard_d4s_v3']; 'standard_d4s_v6' = $SkuCat['standard_d4s_v6'] }
        $shapeV7 = $SkuCat['standard_d4s_v6'].PSObject.Copy(); $shapeV7.Name = 'Standard_D4s_v7'; $shapeV7.Family = 'standardDSv7Family'
        $script:ShapeCatalog['standard_d4s_v7'] = $shapeV7
    }

    It 'writes every summary grouping as an array whether there are no, one or several groups' -ForEach @(
        @{ Case = 'no VMs'; Skus = @() }
        @{ Case = 'one VM'; Skus = @('Standard_DS3_v2') }
        @{ Case = 'two VMs'; Skus = @('Standard_DS3_v2', 'Standard_D4s_v3') }
    ) {
        $set = @(for ($i = 0; $i -lt $Skus.Count; $i++) { Invoke-TestAssessment -Vm (New-TestVm -Name "vm$i" -Sku $Skus[$i] -Gen 'V1') })
        $by = @((Read-TestJson (Export-TestOutput -Assessments $set)).summary.PSObject.Properties | Where-Object Name -like 'By*')
        $by.Count | Should -BeGreaterOrEqual 12
        foreach ($p in $by) { ($p.Value -is [System.Array]) | Should -BeTrue -Because "summary.$($p.Name) must be an array ($Case)" }
    }

    It 'writes the top-level quota lists as arrays whether they hold no or one row' -ForEach @(
        @{ Case = 'no quota impact'; Rows = $null; Expected = 0 }
        @{ Case = 'empty quota impact'; Rows = @(); Expected = 0 }
        @{ Case = 'one row each'; Rows = @([pscustomobject]@{ SubscriptionId = 's1'; Region = 'eastus2'; QuotaName = 'q'; Status = 'Quota OK' }); Expected = 1 }
    ) {
        $impact = if ($null -eq $Rows) { $null } else { [pscustomobject]@{ FamilyRows = $Rows; RegionalRows = $Rows } }
        $j = Read-TestJson (Export-TestOutput -Assessments @((Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1'))) -QuotaImpact $impact)
        foreach ($list in 'family', 'regional') {
            ($j.quota.$list -is [System.Array]) | Should -BeTrue -Because "quota.$list must be an array ($Case)"
            @($j.quota.$list).Count | Should -Be $Expected
        }
    }

    It 'writes strategy.ValidationItems and TargetComparison as arrays for zero, one and several items' {
        $none = Invoke-TestAssessment -Vm (New-TestVm -Name 'none' -Sku 'Standard_D4s_v5')
        $one = Invoke-TestAssessment -Vm (New-TestVm -Name 'one' -Sku 'Standard_D4s_v3' -Controller 'NVMe' -Accel $false) -Catalog $ShapeCatalog -CheckModernization
        $many = Invoke-TestAssessment -Vm (New-TestVm -Name 'many' -Sku 'Standard_D4s_v3' -Controller 'NVMe') -Catalog $ShapeCatalog -CheckModernization
        @($one.Strategy.ValidationItems).Count | Should -Be 1
        @($many.Strategy.ValidationItems).Count | Should -BeGreaterThan 1
        $byName = @{}
        foreach ($vm in (Read-TestJson (Export-TestOutput -Assessments @($none, $one, $many))).vms) { $byName[$vm.row.VM] = $vm }
        foreach ($name in 'none', 'one', 'many') {
            ($byName[$name].strategy.ValidationItems -is [System.Array]) | Should -BeTrue -Because "$name ValidationItems"
            ($byName[$name].strategy.TargetComparison -is [System.Array]) | Should -BeTrue -Because "$name TargetComparison"
        }
        @($byName['none'].strategy.ValidationItems).Count | Should -Be 0
        @($byName['one'].strategy.ValidationItems).Count | Should -Be 1
        @($byName['one'].strategy.ValidationItems)[0] | Should -Be $one.Strategy.ValidationItems[0]
    }

    It 'gives every CSV the same header row whether or not there is anything to write' {
        $expected = @{
            'vm-assessment' = Get-BuilderColumns 'Assessment.psm1' 'ConvertTo-AssessmentRow'
            'candidates'    = Get-BuilderColumns 'Output.psm1' 'Export-AssessmentData'
            'quota-impact'  = Get-BuilderColumns 'Quota.psm1' 'New-QuotaImpactRow'
        }
        $empty = Export-TestOutput -Assessments @()
        $populated = Export-TestOutput -Assessments @((Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1')))
        foreach ($name in $expected.Keys) {
            $header = '"' + ($expected[$name] -join '","') + '"'
            $lines = @(Get-Content (Join-Path $empty "$name.csv"))
            $lines.Count | Should -Be 1 -Because "$name.csv without rows is only the header"
            $lines[0] | Should -Be $header
        }
        foreach ($name in 'vm-assessment', 'candidates') {
            @(Get-Content (Join-Path $populated "$name.csv"))[0] | Should -Be ('"' + ($expected[$name] -join '","') + '"')
            @(Import-Csv (Join-Path $populated "$name.csv")).Count | Should -BeGreaterThan 0
        }
    }
}

Describe 'Estate summary counters' {
    BeforeAll {
        # One VM per modernization path (direct v7 resize, Gen1 conversion to v6, already modern) and one assessed without the check.
        function script:New-ModernizationMix {
            $v7 = $SkuCat['standard_d4s_v6'].PSObject.Copy()
            $v7.Name = 'Standard_D4s_v7'; $v7.Family = 'standardDSv7Family'
            $direct = @{ 'standard_d4s_v3' = $SkuCat['standard_d4s_v3']; 'standard_d4s_v6' = $SkuCat['standard_d4s_v6']; 'standard_d4s_v7' = $v7 }
            @(
                (Invoke-TestAssessment (New-TestVm -Name 'direct' -Sku 'Standard_D4s_v3' -Controller 'NVMe') -Catalog $direct -CheckModernization)
                (Invoke-TestAssessment (New-TestVm -Name 'gen1' -Sku 'Standard_D4s_v3' -Gen 'V1') -CheckModernization)
                (Invoke-TestAssessment (New-TestVm -Name 'modern' -Sku 'Standard_D4s_v6' -Controller 'NVMe') -Catalog $direct -CheckModernization)
                (Invoke-TestAssessment (New-TestVm -Name 'unchecked' -Sku 'Standard_D4s_v3' -Gen 'V1'))
            )
        }
    }

    It 'counts every v6/v7 modernization target, not only the direct resizes' {
        $mix = New-ModernizationMix
        $mix[0].Modernization.Status | Should -Be 'Modernize to v7'
        $mix[1].Strategy.ModernizationTargetSource | Should -Be 'Convertible'
        $s = New-AssessmentSummary -Assessments $mix -SubscriptionsScanned 1
        $s.ModernizeToV7 | Should -Be 1
        $s.ModernizeToV6 | Should -Be 0
        $s.ModernizationTargetV7 | Should -Be 1
        $s.ModernizationTargetV6 | Should -Be 1
        $s.ConvertibleToV7 | Should -Be 0
        $s.ConvertibleToV6 | Should -Be 1
        $s.AlreadyOnModernGeneration | Should -Be 1
    }

    It 'counts nothing as a modernization target when the check did not run or the VM is already modern' {
        $mix = New-ModernizationMix
        $s = New-AssessmentSummary -Assessments @($mix[2], $mix[3]) -SubscriptionsScanned 1
        $s.ModernizationTargetV7 | Should -Be 0
        $s.ModernizationTargetV6 | Should -Be 0
        $s.ConvertibleToV7 | Should -Be 0
        $s.ConvertibleToV6 | Should -Be 0
    }

    It 'reconciles every grouping with the VM counts it is documented to cover' {
        $set = @(
            (Invoke-TestAssessment (New-TestVm -Name 'a' -Sku 'Standard_DS3_v2' -Gen 'V1'))
            (Invoke-TestAssessment (New-TestVm -Name 'b' -Sku 'Standard_DS3_v2' -Gen 'V1'))
            (Invoke-TestAssessment (New-TestVm -Name 'c' -Sku 'Standard_D4s_v5'))
        )
        $s = New-AssessmentSummary -Assessments $set -SubscriptionsScanned 1
        $s.TotalVmsScanned | Should -Be 3
        $s.ActionableVms | Should -Be 2
        $s.AffectedVms | Should -Be 2
        $total = { param($Group) (@($s.$Group) | Measure-Object -Property Count -Sum).Sum }
        foreach ($group in 'ByEvidenceClass', 'ByWave', 'ByMigrationPriority') { & $total $group | Should -Be 3 -Because "$group covers every VM" }
        foreach ($group in 'BySubscription', 'ByRegion', 'ByCurrentSku', 'ByCurrentSkuFamily', 'ByRecommendedSku', 'ByRecommendedSkuFamily', 'ByCpuVendor', 'ByDeploymentReadiness') {
            & $total $group | Should -Be 2 -Because "$group covers only the VMs with an action"
        }
        & $total 'ByRetirementDate' | Should -Be 2 -Because 'ByRetirementDate covers only the VMs on retiring sizes'
    }

    It 'prints the counters and says what each grouping counts in the executive summary' {
        $dir = Export-TestOutput -Assessments (New-ModernizationMix) -Html -ExtraParameters @{ CheckModernization = $true }
        $md = Get-Content (Join-Path $dir 'executive-summary.md') -Raw
        $md | Should -Match '\| v7 modernization target, any path \| 1 \|'
        $md | Should -Match '\| v6 modernization target, any path \| 1 \|'
        $md | Should -Match '\| of which need Gen1 / NVMe conversion first: v7 \| 0 \|'
        $md | Should -Match '\| of which need Gen1 / NVMe conversion first: v6 \| 1 \|'
        $md | Should -Match '\| Direct resize to v7 \(every check passes\) \| 1 \|'
        $md | Should -Match '\| Direct resize to v6 \(every check passes\) \| 0 \|'
        $md | Should -Match '\| VMs With an Action \| \d+ \|'
        $md | Should -Match '(?m)^## Groupings\r?$'
        $md | Should -Match 'each table counts only the VMs that have an action \(\d+ of 4 VMs\)'
        $md | Should -Match '(?m)^### By subscription\r?$'
        $md | Should -Match '(?m)^### By retirement date - the \d+ VMs on retiring sizes\r?$'
        $md | Should -Match '(?m)^### By migration priority \(action\) - all 4 VMs\r?$'
    }

    It 'does not print v6/v7 counts as zero when the modernization check did not run' {
        $dir = Export-TestOutput -Assessments @((New-ModernizationMix)[3]) -Html
        $md = Get-Content (Join-Path $dir 'executive-summary.md') -Raw
        foreach ($label in 'v7 modernization target, any path', 'v6 modernization target, any path', 'of which need Gen1 / NVMe conversion first: v6', 'Direct resize to v6 \(every check passes\)', 'Already on v6/v7') {
            $md | Should -Match "\| $label \| not evaluated \|"
        }
    }

    It 'uses one Wave 4 count for the modernization tile, the subscriptions table, the subscription page and the bottom line' {
        $optional = Invoke-TestAssessment (New-TestVm -Name 'optional' -Sku 'Standard_D4ds_v4')
        $retiring = Invoke-TestAssessment (New-TestVm -Name 'retiring' -Sku 'Standard_DS3_v2' -Gen 'V1')
        $optional.Wave | Should -Be 'Wave 4 - Modernization'
        $retiring.Wave | Should -Not -Be 'Wave 4 - Modernization'
        $dir = Export-TestOutput -Assessments @($optional, $retiring) -Html
        $tile = "<div class='kpi kpi-purple'><div class='kpi-label'>Modernization \(Wave 4\)</div><div class='kpi-value'>1</div><div class='kpi-hint'>Older, not retiring</div></div>"
        $index = Get-Content (Join-Path $dir 'index.html') -Raw
        $index | Should -Match $tile
        $index | Should -Match "<th class='num'>Wave 1</th><th class='num'>Wave 4</th>"
        $index | Should -Not -Match 'Optional modernization</div>'
        $index | Should -Match '1 VM\(s\) run on an older generation that is <em>not</em> retiring \(Wave 4 modernization\); no retirement deadline applies\.'
        $subscriptionPage = Get-ChildItem $dir -Filter '*.html' | Where-Object Name -ne 'index.html' | Select-Object -First 1
        (Get-Content $subscriptionPage.FullName -Raw) | Should -Match $tile
    }
}

Describe 'Next step for a VM that is ready to resize' {
    BeforeAll {
        $script:AvailabilitySetId = '/subscriptions/s1/resourceGroups/rg/providers/Microsoft.Compute/availabilitySets/as1'
        $script:ScaleSetId = '/subscriptions/s1/resourceGroups/rg/providers/Microsoft.Compute/virtualMachineScaleSets/vmss1'
    }

    It 'says to proceed only when nothing is left to validate' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_D4s_v3')
        $a.Readiness | Should -Be 'Ready'
        $a.Confidence.Level | Should -Be 'HIGH'
        $a.NextStep | Should -Be 'Proceed with Resize (change window)'
    }

    It 'asks to validate first for <Case>' -ForEach @(
        @{ Case = 'an availability set member'; InSet = $true; InScaleSet = $false; Level = 'MEDIUM'; Item = 'Availability Set: ' }
        @{ Case = 'a scale set member'; InSet = $false; InScaleSet = $true; Level = 'MEDIUM'; Item = 'VM Scale Set \(Flexible\): ' }
        @{ Case = 'both an availability set and a scale set'; InSet = $true; InScaleSet = $true; Level = 'LOW'; Item = 'Availability Set: ' }
    ) {
        $vm = New-TestVm -Sku 'Standard_D4s_v3'
        if ($InSet) { $vm.AvailabilitySetId = $AvailabilitySetId }
        if ($InScaleSet) { $vm.VmssId = $ScaleSetId }
        $a = Invoke-TestAssessment $vm
        $a.Readiness | Should -Be 'Ready'
        $a.Confidence.Level | Should -Be $Level
        $a.NextStep | Should -Be 'Validate Before Resize'
        ($a.ValidationItems -join ' | ') | Should -Match $Item
    }

    It 'keeps the blocking steps ahead of the validation step' {
        $vm = New-TestVm -Sku 'Standard_D4s_v3'
        $vm.AvailabilitySetId = $AvailabilitySetId
        $a = Invoke-TestAssessment $vm -QuotaStatus 'Quota Increase Required'
        $a.Readiness | Should -Be 'Quota Increase Required'
        $a.NextStep | Should -Be 'Request Quota Increase'
    }
}

Describe 'Primary older than the newest valid generation' {
    BeforeAll {
        $script:RestrictedCatalog = @{}
        foreach ($key in $SkuCat.Keys) { $RestrictedCatalog[$key] = $SkuCat[$key] }
        # Every v5 size that could replace D4s_v3 is restricted, including the larger D8s_v5, so no v5 size is deployable.
        foreach ($key in 'standard_d4ds_v5', 'standard_d4s_v5', 'standard_d8s_v5', 'standard_d4s_v6', 'standard_d4as_v5') {
            $restricted = $SkuCat[$key].PSObject.Copy()
            $restricted.LocationRestricted = $true
            $restricted.RestrictionReasons = @('NotAvailableForSubscription')
            $RestrictedCatalog[$key] = $restricted
        }
    }

    It 'names the restricted newer generation, lowers confidence and asks to validate' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_D4s_v3') -Catalog $RestrictedCatalog
        $a.Candidates.Primary.SkuName | Should -Be 'Standard_D4ds_v4'
        $a.Readiness | Should -Be 'Ready'
        $a.Confidence.Level | Should -Be 'MEDIUM'
        $a.NextStep | Should -Be 'Validate Before Resize'
        $item = @($a.ValidationItems | Where-Object { $_ -like 'Newer generation unavailable:*' })
        $item.Count | Should -Be 1
        $item[0] | Should -Match 'Standard_D4ds_v5 \(v5\) meets the mandatory checks but is Restricted for this VM in eastus2'
        $item[0] | Should -Match 'older generation Standard_D4ds_v4 \(v4\) is recommended'
    }

    It 'lists only newer sizes of the same family and CPU vendor that pass every mandatory check' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_D4s_v3') -Catalog $RestrictedCatalog
        # D4s_v6 is NVMe only (rejected for this SCSI VM) and D4as_v5 is AMD; both are restricted but are not the reason for an older target.
        @($a.Candidates.NewerGenerationUnavailable | ForEach-Object SkuName) | Should -Be @('Standard_D4ds_v5', 'Standard_D4s_v5')
    }

    It 'adds nothing when the primary is the newest valid generation' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_D4s_v3')
        $a.Candidates.Primary.SkuName | Should -Be 'Standard_D4ds_v5'
        $a.Candidates.PSObject.Properties.Name | Should -Contain 'NewerGenerationUnavailable'
        @($a.Candidates.NewerGenerationUnavailable).Count | Should -Be 0
        @($a.ValidationItems | Where-Object { $_ -like 'Newer generation unavailable:*' }).Count | Should -Be 0
    }
}

Describe 'Larger sizes of a series' {
    BeforeAll {
        # One series (Ddsv5) whose NIC and data disk limits grow with the size, so the closest size is not always the first that fits.
        function script:New-DdsV5Size {
            param([string]$Name, [int]$Vcpu, [int]$Nics, [int]$Disks)
            $size = $SkuCat['standard_d4ds_v5'].PSObject.Copy()
            $size.Name = $Name; $size.vCPUs = $Vcpu; $size.vCPUsAvailable = $Vcpu; $size.MemoryGB = 4 * $Vcpu; $size.MaxNICs = $Nics; $size.MaxDataDisks = $Disks
            $size
        }
        function script:New-SeriesCatalog {
            $catalog = @{ 'standard_d4s_v3' = $SkuCat['standard_d4s_v3'] }
            foreach ($size in @((New-DdsV5Size 'Standard_D4ds_v5' 4 2 8), (New-DdsV5Size 'Standard_D8ds_v5' 8 4 16), (New-DdsV5Size 'Standard_D16ds_v5' 16 8 32), (New-DdsV5Size 'Standard_D32ds_v5' 32 8 32))) {
                $catalog[$size.Name.ToLowerInvariant()] = $size
            }
            $catalog
        }
        function script:New-WeightsWithSteps {
            param($Steps)
            $copy = $Weights | ConvertTo-Json -Depth 5 | ConvertFrom-Json
            if ($null -eq $Steps) { $copy.primarySelection.PSObject.Properties.Remove('maxLargerSizeSteps') } else { $copy.primarySelection.maxLargerSizeSteps = $Steps }
            $copy
        }
    }

    It 'ships a bound of two larger sizes' {
        $Weights.primarySelection.maxLargerSizeSteps | Should -Be 2
    }

    It 'keeps the closest size, and evaluates no larger one, when the closest size qualifies' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_D4s_v3') -Catalog (New-SeriesCatalog)
        $a.Candidates.Primary.SkuName | Should -Be 'Standard_D4ds_v5'
        $a.Candidates.Primary.Variant | Should -Be 'Closest size'
        $a.Candidates.Primary.ClosestSizeSku | Should -BeNullOrEmpty
        @($a.Candidates.Candidates | ForEach-Object SkuName) | Should -Be @('Standard_D4ds_v5')
        @($a.ValidationItems | Where-Object { $_ -like 'Larger size:*' }).Count | Should -Be 0
    }

    It 'recommends the next size, never a smaller one, when the closest size fails on <Case>' -ForEach @(
        @{ Case = 'the NIC limit'; Nics = 3; Disks = 0; Zone = $null; Restrict = $false; Issue = 'NIC Count: VM has 3 NICs; target max 2' }
        @{ Case = 'the data disk limit'; Nics = 1; Disks = 12; Zone = $null; Restrict = $false; Issue = 'Data Disk Count: VM has 12 data disks; target max 8' }
        @{ Case = 'a subscription restriction'; Nics = 1; Disks = 0; Zone = $null; Restrict = $true; Issue = 'availability: Restricted' }
        @{ Case = 'zone availability'; Nics = 1; Disks = 0; Zone = '1'; Restrict = $false; Issue = 'Region / Zone: Not Available in zone 1' }
    ) {
        $catalog = New-SeriesCatalog
        if ($Restrict) { $catalog['standard_d4ds_v5'].LocationRestricted = $true }
        if ($Zone) { $catalog['standard_d4ds_v5'].Zones = @('2', '3') }
        $vmArgs = @{ Sku = 'Standard_D4s_v3'; Nics = $Nics }
        if ($Zone) { $vmArgs.Zones = @($Zone) }
        $vm = New-TestVm @vmArgs
        $vm.DataDiskCount = $Disks
        $a = Invoke-TestAssessment $vm -Catalog $catalog
        $primary = $a.Candidates.Primary
        $primary.SkuName | Should -Be 'Standard_D8ds_v5'
        $primary.Variant | Should -Be 'Larger size'
        $primary.ClosestSizeSku | Should -Be 'Standard_D4ds_v5'
        $primary.vCPUs | Should -BeGreaterThan 4
        $a.Candidates.NoCandidateReason | Should -BeNullOrEmpty
        $a.Readiness | Should -Be 'Ready'
        $a.NextStep | Should -Be 'Validate Before Resize'
        ($a.ValidationItems -join ' | ') | Should -Match ([regex]::Escape("Larger size: Standard_D8ds_v5 (8 vCPU / 32 GB) is larger than the closest fit Standard_D4ds_v5, which does not qualify ($Issue); validate licensing and cost impact"))
        # Sizes after the first one that qualifies are not evaluated.
        @($a.Candidates.Candidates | ForEach-Object SkuName) | Should -Not -Contain 'Standard_D16ds_v5'
    }

    It 'tries up to two larger sizes by default' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_D4s_v3' -Nics 5) -Catalog (New-SeriesCatalog)
        $a.Candidates.Primary.SkuName | Should -Be 'Standard_D16ds_v5'
        $a.Candidates.Primary.ClosestSizeSku | Should -Be 'Standard_D4ds_v5'
    }

    It 'falls back to two larger sizes when the weights file does not set the bound' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_D4s_v3' -Nics 5) -Catalog (New-SeriesCatalog) -ScoringWeights (New-WeightsWithSteps $null)
        $a.Candidates.Primary.SkuName | Should -Be 'Standard_D16ds_v5'
    }

    It 'stops at the configured bound and says the larger sizes beyond it were not evaluated' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_D4s_v3' -Nics 5) -Catalog (New-SeriesCatalog) -ScoringWeights (New-WeightsWithSteps 1)
        $a.Candidates.Primary | Should -BeNullOrEmpty
        $a.Candidates.NoCandidateReason | Should -Be 'All candidates fail mandatory requirements: Standard_D4ds_v5 [NIC Count: VM has 5 NICs; target max 2]. Up to 1 larger size per series was also evaluated and none qualified: Standard_D8ds_v5 [NIC Count: VM has 5 NICs; target max 4]. Larger sizes beyond that were not evaluated.'
    }

    It 'is switched off by a bound of 0, which restores the closest-size-only search' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_D4s_v3' -Nics 5) -Catalog (New-SeriesCatalog) -ScoringWeights (New-WeightsWithSteps 0)
        $a.Candidates.Primary | Should -BeNullOrEmpty
        $a.Candidates.NoCandidateReason | Should -Be 'All candidates fail mandatory requirements: Standard_D4ds_v5 [NIC Count: VM has 5 NICs; target max 2]'
        @($a.Candidates.Candidates | ForEach-Object SkuName) | Should -Be @('Standard_D4ds_v5')
    }

    It 'names every larger size that was tried when none qualifies' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_D4s_v3' -Nics 9) -Catalog (New-SeriesCatalog)
        $a.Candidates.Primary | Should -BeNullOrEmpty
        $reason = $a.Candidates.NoCandidateReason
        $reason | Should -Match '^All candidates fail mandatory requirements: Standard_D4ds_v5 \[NIC Count: VM has 9 NICs; target max 2\]\. Up to 2 larger sizes per series were also evaluated and none qualified: '
        $reason | Should -Match 'Standard_D8ds_v5 \[NIC Count: VM has 9 NICs; target max 4\]'
        $reason | Should -Match 'Standard_D16ds_v5 \[NIC Count: VM has 9 NICs; target max 8\]'
        $reason | Should -Match 'Larger sizes beyond that were not evaluated\.$'
        $reason | Should -Not -Match 'Standard_D32ds_v5'
        $a.Readiness | Should -Be 'Manual Review Required'
        $a.Confidence.Level | Should -Be 'LOW'
    }

    It 'does not try larger sizes when the closest size fails a gate that no size of the series can pass' {
        $catalog = @{ 'standard_d4s_v3' = $SkuCat['standard_d4s_v3']; 'standard_d4s_v6' = $SkuCat['standard_d4s_v6'] }
        $larger = $SkuCat['standard_d4s_v6'].PSObject.Copy()
        $larger.Name = 'Standard_D8s_v6'; $larger.vCPUs = 8; $larger.vCPUsAvailable = 8; $larger.MemoryGB = 32
        $catalog['standard_d8s_v6'] = $larger
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_D4s_v3' -Gen 'V1') -Catalog $catalog
        $a.Candidates.Primary | Should -BeNullOrEmpty
        @($a.Candidates.Candidates | ForEach-Object SkuName) | Should -Be @('Standard_D4s_v6')
        @($a.Candidates.Candidates)[0].FailedGates | Should -Contain 'VM Generation'
        $a.Candidates.NoCandidateReason | Should -Not -Match 'larger size'
    }

    It 'explains a larger alternative as well as a larger primary' {
        $catalog = New-SeriesCatalog
        $catalog['standard_d4s_v5'] = $SkuCat['standard_d4s_v5']
        $catalog['standard_d8s_v5'] = $SkuCat['standard_d8s_v5']
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_D4s_v3' -Nics 3) -Catalog $catalog
        $a.Candidates.Primary.SkuName | Should -Be 'Standard_D8ds_v5'
        $a.Candidates.Secondary.SkuName | Should -Be 'Standard_D8s_v5'
        $a.SecondaryReason | Should -Match 'Larger size: the closest fit Standard_D4s_v5 does not qualify'
    }

    It 'explains a larger size that is also the capability-preserving size' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_DS3_v2' -Nics 3)
        $a.Candidates.Primary.SkuName | Should -Be 'Standard_D8s_v5'
        $a.Candidates.Primary.Variant | Should -Be 'Capability-preserving'
        ($a.ValidationItems -join ' | ') | Should -Match 'Larger size: Standard_D8s_v5 \(8 vCPU / 32 GB\) is larger than the closest fit Standard_D4s_v5, which does not qualify \(NIC Count: VM has 3 NICs; target max 2\)'
    }

    It 'carries a larger v6 size into the modernization recommendation and says why' {
        $closest = $SkuCat['standard_d4s_v6'].PSObject.Copy()
        $larger = $SkuCat['standard_d4s_v6'].PSObject.Copy()
        $larger.Name = 'Standard_D8s_v6'; $larger.vCPUs = 8; $larger.vCPUsAvailable = 8; $larger.MemoryGB = 32; $larger.MaxNICs = 4
        $catalog = @{ 'standard_d4s_v3' = $SkuCat['standard_d4s_v3']; 'standard_d4s_v6' = $closest; 'standard_d8s_v6' = $larger }
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_D4s_v3' -Controller 'NVMe' -Nics 3) -Catalog $catalog -CheckModernization
        $a.Modernization.Status | Should -Be 'Modernize to v6'
        $a.Candidates.Primary.SkuName | Should -Be 'Standard_D8s_v6'
        $a.Modernization.Reason | Should -Match 'Standard_D8s_v6 \(8 vCPU / 32 GB\) is larger than the closest fit Standard_D4s_v6, which does not qualify \(NIC Count: VM has 3 NICs; target max 2\)\.'
    }

    It 'adds no note for a candidate without a failed closest size' {
        Get-LargerSizeNote $null | Should -BeNullOrEmpty
        Get-LargerSizeNote ([pscustomobject]@{ SkuName = 'Standard_D4ds_v5' }) | Should -BeNullOrEmpty
        Get-LargerSizeNote ([pscustomobject]@{ SkuName = 'Standard_D4ds_v5'; ClosestSizeSku = $null }) | Should -BeNullOrEmpty
    }

    It 'exports the larger size with its variant' {
        $a = Invoke-TestAssessment (New-TestVm -Sku 'Standard_D4s_v3' -Nics 3) -Catalog (New-SeriesCatalog)
        $dir = Export-TestOutput -Assessments @($a)
        @(Import-Csv (Join-Path $dir 'candidates.csv') | Where-Object { $_.CandidateSku -eq 'Standard_D8ds_v5' -and $_.Variant -eq 'Larger size' -and $_.Role -eq 'Primary' }).Count | Should -Be 1
        $json = Read-TestJson $dir
        $json.vms[0].recommendation.primary.sku | Should -Be 'Standard_D8ds_v5'
        $json.vms[0].recommendation.primary.variant | Should -Be 'Larger size'
    }
}

Describe 'Data-collection issues: recording' {
    It 'masks the object id of the signed-in identity but keeps the subscription in the scope' {
        $safe = ConvertTo-SafeCliMessage "(AuthorizationFailed) The client 'jane.doe@contoso.com' with object id '11111111-2222-3333-4444-555555555555' cannot act over scope '/subscriptions/66666666-7777-8888-9999-000000000000'."
        $safe | Should -Match "object id '\*\*\*\*'"
        $safe | Should -Match "j\*\*\*\*@contoso\.com"
        $safe | Should -Not -Match '11111111-2222'
        $safe | Should -Match '66666666-7777-8888-9999-000000000000'
    }

    It 'keeps recorded problems in a stable order and writes a warning when there is no sink' {
        $sink = New-CollectionIssueSink
        $sink.GetType().Name | Should -BeLike 'ConcurrentQueue*'
        Add-CollectionIssue -Sink $sink -Api 'Resource SKUs' -SubscriptionId 's2' -Region 'westus2' -Message 'm2' -Effect 'e'
        Add-CollectionIssue -Sink $sink -Api 'Compute usage' -SubscriptionId 's1' -Region 'eastus2' -Message 'm1'
        Add-CollectionIssue -Sink $sink -Api 'Resource SKUs' -SubscriptionId 's1' -Region 'eastus2' -Message 'm0'
        @(Get-CollectionIssue -Sink $sink | ForEach-Object { "$($_.Api)|$($_.SubscriptionId)" }) | Should -Be @('Compute usage|s1', 'Resource SKUs|s1', 'Resource SKUs|s2')
        @(Get-CollectionIssue -Sink $null).Count | Should -Be 0
        $warnings = @(Add-CollectionIssue -Api 'Resource SKUs' -SubscriptionId 's1' -Region 'eastus2' -Message 'boom' -Effect 'Nothing is recommended.' 3>&1)
        "$($warnings[0])" | Should -Be 'Resource SKUs (eastus2, subscription s1): boom Nothing is recommended.'
    }

    It 'gives Invoke-AzJson the sanitized reason of a tolerated failure' {
        Use-FakeAz -Body $Denied -Action {
            $failure = $null
            Invoke-AzJson -Arguments @('vm', 'list-usage') -MaxRetries 0 -AllowFailure -Failure ([ref]$failure) | Should -BeNullOrEmpty
            $failure | Should -Match 'AuthorizationFailed'
            $failure | Should -Match "object id '\*\*\*\*'"
            $failure | Should -Not -Match 'jane\.doe'
        }
        Use-FakeAz -Body "Write-Output '[1]'; exit 0" -Action {
            $failure = $null
            @(Invoke-AzJson -Arguments @('vm', 'list-usage') -AllowFailure -Failure ([ref]$failure)).Count | Should -Be 1
            $failure | Should -BeNullOrEmpty
        }
    }

    It 'records why quota could not be read, per subscription and region' -ForEach @(
        @{ Case = 'denied'; Body = 'DENIED'; Message = 'AuthorizationFailed' }
        @{ Case = 'empty'; Body = "Write-Output '[]'; exit 0"; Message = 'returned no quota data' }
    ) {
        $sink = New-CollectionIssueSink
        $script = if ($Body -eq 'DENIED') { $Denied } else { $Body }
        # An empty JSON list reads back as nothing, so both cases leave the quota of the scope unknown ($null).
        $usage = Use-FakeAz -Body $script -Action { Get-QuotaUsage -SubscriptionId 's1' -Region 'eastus2' -IssueSink $sink }
        $usage | Should -BeNullOrEmpty
        $issues = @(Get-CollectionIssue -Sink $sink)
        $issues.Count | Should -Be 1
        $issues[0].Api | Should -BeLike 'Compute usage*'
        $issues[0].SubscriptionId | Should -Be 's1'
        $issues[0].Region | Should -Be 'eastus2'
        $issues[0].Message | Should -Match $Message
        $issues[0].Effect | Should -Match 'Quota cannot be verified'
        ($issues[0].Message + $issues[0].Effect) | Should -Not -Match 'jane\.doe|11111111-2222'
    }

    It 'reports malformed JSON from a successful az call instead of throwing from a tolerated call' {
        Use-FakeAz -Body "Write-Output 'this-is-not-json'; exit 0" -Action {
            $failure = $null
            Invoke-AzJson -Arguments @('vm', 'list-usage', '--location', 'eastus2') -AllowFailure -Failure ([ref]$failure) | Should -BeNullOrEmpty
            $failure | Should -Match '^The answer is not valid JSON: '
            { Invoke-AzJson -Arguments @('vm', 'list-usage', '--location', 'eastus2') } | Should -Throw 'az vm list-usage --location eastus2 failed: The answer is not valid JSON*'
            Invoke-AzJson -Arguments @('vm', 'list-usage') -AllowFailure | Should -BeNullOrEmpty
        }
    }

    It 'records a quota answer that is not JSON or cannot be read' -ForEach @(
        @{ Case = 'not JSON'; Body = "Write-Output '{ not valid json'; exit 0"; Message = '^The answer is not valid JSON' }
        @{ Case = 'a row without a name value'; Body = "Write-Output '[{`"name`":{},`"currentValue`":1,`"limit`":2}]'; exit 0"; Message = '^The answer could not be read' }
        @{ Case = 'a non-numeric limit'; Body = "Write-Output '[{`"name`":{`"value`":`"cores`"},`"currentValue`":1,`"limit`":`"many`"}]'; exit 0"; Message = '^The answer could not be read' }
    ) {
        $sink = New-CollectionIssueSink
        $usage = Use-FakeAz -Body $Body -Action { Get-QuotaUsage -SubscriptionId 's1' -Region 'eastus2' -IssueSink $sink }
        $usage | Should -BeNullOrEmpty
        $issues = @(Get-CollectionIssue -Sink $sink)
        $issues.Count | Should -Be 1
        $issues[0].Api | Should -BeLike 'Compute usage*'
        $issues[0].Message | Should -Match $Message
    }

    It 'records nothing when quota is read' {
        $sink = New-CollectionIssueSink
        $body = "Write-Output '[{`"name`":{`"value`":`"cores`"},`"localName`":`"Total Regional vCPUs`",`"currentValue`":4,`"limit`":100}]'; exit 0"
        $usage = Use-FakeAz -Body $body -Action { Get-QuotaUsage -SubscriptionId 's1' -Region 'eastus2' -IssueSink $sink }
        $usage['cores'].Limit | Should -Be 100
        @(Get-CollectionIssue -Sink $sink).Count | Should -Be 0
    }

    It 'shares one sink across the parallel quota runspaces' {
        $sink = New-CollectionIssueSink
        $pairs = @(1..4 | ForEach-Object { [pscustomobject]@{ SubscriptionId = "s$_"; Region = 'eastus2' } })
        $usage = Use-FakeAz -Body $Denied -Action { Get-QuotaUsages -Pairs $pairs -ThrottleLimit 3 -IssueSink $sink }
        $usage.Count | Should -Be 4
        @(Get-CollectionIssue -Sink $sink | ForEach-Object SubscriptionId) | Should -Be @('s1', 's2', 's3', 's4')
    }

    It 'records a Resource Graph query that stops part-way and says how many rows it had' {
        $body = "if (@(`$args) -contains '--skip-token') { Write-Error `"ERROR: (Forbidden) access denied`" -ErrorAction Continue; exit 1 }; Write-Output '{`"data`":[{`"id`":1},{`"id`":2}],`"skip_token`":`"t1`"}'; exit 0"
        Use-FakeAz -Body $body -Action {
            $failure = $null
            $rows = @(Invoke-ArgQuery -Query 'Resources' -AllowFailure -Failure ([ref]$failure))
            $rows.Count | Should -Be 2
            $failure | Should -Match 'Forbidden'
            $failure | Should -Match 'stopped after 2 rows'
        }
    }
}

Describe 'Data-collection issues: Resource SKU collection' {
    BeforeAll {
        $script:SkuFixture = @(Get-Content (Join-Path $PSScriptRoot 'fixtures/skus-eastus2.json') -Raw | ConvertFrom-Json)
        $script:SkuJson = (Join-Path $PSScriptRoot 'fixtures/skus-eastus2.json')
        # The token is available, so the REST call is attempted first.
        $script:TokenOk = "if (`"`$args`" -match 'get-access-token') { Write-Output '{`"accessToken`":`"t`"}'; exit 0 }"
    }
    BeforeEach {
        Mock Start-Sleep -ModuleName SkuCatalog {}
    }

    It 'records both causes when the REST call and the az fallback fail' {
        $sink = New-CollectionIssueSink
        Mock Invoke-RestMethod -ModuleName SkuCatalog { throw 'Response status code does not indicate success: 403 (Forbidden).' }
        $cat = Use-FakeAz -Body ("$TokenOk`n" + "if (`"`$args`" -match 'vm list-skus') { $Denied }") -Action { Get-RegionSkuCatalog -SubscriptionId 's1' -Region 'eastus2' -IssueSink $sink }
        $cat.Count | Should -Be 0
        $issue = @(Get-CollectionIssue -Sink $sink)
        $issue.Count | Should -Be 1
        $issue[0].Api | Should -Be 'Resource SKUs'
        $issue[0].Region | Should -Be 'eastus2'
        $issue[0].Message | Should -Match 'REST call failed: .*403'
        $issue[0].Message | Should -Match 'az vm list-skus failed: .*AuthorizationFailed'
        $issue[0].Message | Should -Not -Match 'jane\.doe|11111111-2222'
        $issue[0].Effect | Should -Match 'No replacement size'
    }

    It 'says that az returned no sizes when it succeeds with an empty list' {
        $sink = New-CollectionIssueSink
        Mock Invoke-RestMethod -ModuleName SkuCatalog { [pscustomobject]@{ value = @() } }
        $cat = Use-FakeAz -Body ("$TokenOk`n" + "if (`"`$args`" -match 'vm list-skus') { Write-Output '[]'; exit 0 }") -Action { Get-RegionSkuCatalog -SubscriptionId 's1' -Region 'eastus2' -IssueSink $sink }
        $cat.Count | Should -Be 0
        @(Get-CollectionIssue -Sink $sink)[0].Message | Should -Match 'az vm list-skus returned no VM sizes'
    }

    It 'records nothing, and logs the fallback, when az supplies the sizes after the REST call failed' {
        $sink = New-CollectionIssueSink
        Mock Invoke-RestMethod -ModuleName SkuCatalog { throw 'Response status code does not indicate success: 500.' }
        $body = "$TokenOk`n" + "if (`"`$args`" -match 'vm list-skus') { Get-Content -LiteralPath '$SkuJson' -Raw; exit 0 }"
        $out = @(Use-FakeAz -Body $body -Action { Get-RegionSkuCatalog -SubscriptionId 's1' -Region 'eastus2' -IssueSink $sink 6>&1 })
        $cat = @($out | Where-Object { $_ -is [hashtable] })[0]
        $cat.Count | Should -BeGreaterThan 5
        @(Get-CollectionIssue -Sink $sink).Count | Should -Be 0
        ($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" }) -join "`n" | Should -Match 'REST failed for eastus2.*used az vm list-skus instead'
    }

    It 'records malformed JSON from az vm list-skus as the cause' {
        $sink = New-CollectionIssueSink
        Mock Invoke-RestMethod -ModuleName SkuCatalog { throw 'Response status code does not indicate success: 500.' }
        $body = "$TokenOk`n" + "if (`"`$args`" -match 'vm list-skus') { Write-Output 'this-is-not-json'; exit 0 }"
        $cat = Use-FakeAz -Body $body -Action { Get-RegionSkuCatalog -SubscriptionId 's1' -Region 'eastus2' -IssueSink $sink }
        $cat.Count | Should -Be 0
        @(Get-CollectionIssue -Sink $sink)[0].Message | Should -Match 'az vm list-skus failed: The answer is not valid JSON'
    }

    It 'records a size list that was cut off after 50 pages' {
        $sink = New-CollectionIssueSink
        $items = $SkuFixture
        $page = { [pscustomobject]@{ value = $items; nextLink = 'https://management.azure.com/next' } }.GetNewClosure()
        Mock Invoke-RestMethod -ModuleName SkuCatalog -MockWith $page
        $cat = Use-FakeAz -Body $TokenOk -Action { Get-RegionSkuCatalog -SubscriptionId 's1' -Region 'eastus2' -IssueSink $sink }
        Should -Invoke Invoke-RestMethod -ModuleName SkuCatalog -Times 50 -Exactly
        $cat.Count | Should -BeGreaterThan 5
        $issue = @(Get-CollectionIssue -Sink $sink)
        $issue.Count | Should -Be 1
        $issue[0].Api | Should -Be 'Resource SKUs (REST)'
        $issue[0].Message | Should -Match 'stopped after 50 pages'
    }

    It 'records nothing when the REST call returns the sizes' {
        $sink = New-CollectionIssueSink
        $items = $SkuFixture
        $page = { [pscustomobject]@{ value = $items } }.GetNewClosure()
        Mock Invoke-RestMethod -ModuleName SkuCatalog -MockWith $page
        $cat = Use-FakeAz -Body $TokenOk -Action { Get-RegionSkuCatalog -SubscriptionId 's1' -Region 'eastus2' -IssueSink $sink }
        $cat.Count | Should -BeGreaterThan 5
        @(Get-CollectionIssue -Sink $sink).Count | Should -Be 0
    }
}

Describe 'Resource SKUs over REST' {
    BeforeAll {
        $script:SkuItems = @(Get-Content (Join-Path $PSScriptRoot 'fixtures/skus-eastus2.json') -Raw | ConvertFrom-Json)
        # A fake az that logs every call and hands out a token.
        $script:TokenAz = { param([string]$Log) "Add-Content -LiteralPath '$Log' -Value (`$args -join ' ')`nWrite-Output '{`"accessToken`":`"t`"}'`nexit 0" }
    }
    BeforeEach {
        Mock Start-Sleep -ModuleName SkuCatalog {}
        $env:VMSKU_TEST_CALLS = '0'
    }
    AfterEach { Remove-Item Env:\VMSKU_TEST_CALLS -ErrorAction SilentlyContinue }

    It 'asks for the subscription''s own token and reads the sizes of the region with it' {
        $items = $SkuItems
        Mock Invoke-RestMethod -ModuleName SkuCatalog -MockWith { [pscustomobject]@{ value = $items } }.GetNewClosure()
        $log = Join-Path $TestDrive 'token.log'
        $catalog = Use-FakeAz -Body (& $TokenAz $log) -Action { Get-RegionSkuCatalog -SubscriptionId 's1' -Region 'eastus2' }
        $catalog.Count | Should -Be $SkuItems.Count
        $catalog.ContainsKey('standard_d4s_v5') | Should -BeTrue
        @(Get-Content $log) | Should -Be @('account get-access-token --subscription s1 --resource https://management.azure.com -o json --only-show-errors')
        Should -Invoke Invoke-RestMethod -ModuleName SkuCatalog -Times 1 -Exactly -ParameterFilter {
            $Uri -eq "https://management.azure.com/subscriptions/s1/providers/Microsoft.Compute/skus?api-version=2021-07-01&`$filter=location eq 'eastus2'" -and $Headers.Authorization -eq 'Bearer t'
        }
    }

    It 'follows nextLink and merges the sizes of every page' {
        $first = $SkuItems[0..7]; $second = $SkuItems[8..($SkuItems.Count - 1)]
        # A closure does not see the parameters of the mocked command, so the pages are told apart by the order of the calls.
        $page = {
            $env:VMSKU_TEST_CALLS = 1 + [int]$env:VMSKU_TEST_CALLS
            if ([int]$env:VMSKU_TEST_CALLS -eq 1) { [pscustomobject]@{ value = $first; nextLink = 'https://management.azure.com/next-page' } }
            else { [pscustomobject]@{ value = $second } }
        }.GetNewClosure()
        Mock Invoke-RestMethod -ModuleName SkuCatalog -MockWith $page
        $sink = New-CollectionIssueSink
        $catalog = Use-FakeAz -Body (& $TokenAz (Join-Path $TestDrive 'next.log')) -Action { Get-RegionSkuCatalog -SubscriptionId 's1' -Region 'eastus2' -IssueSink $sink }
        $catalog.Count | Should -Be $SkuItems.Count
        Should -Invoke Invoke-RestMethod -ModuleName SkuCatalog -Times 2 -Exactly
        Should -Invoke Invoke-RestMethod -ModuleName SkuCatalog -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://management.azure.com/next-page' }
        @(Get-CollectionIssue -Sink $sink).Count | Should -Be 0
    }

    It 'retries a page that fails and does not fall back to az when a retry succeeds' {
        $items = $SkuItems
        Mock Invoke-RestMethod -ModuleName SkuCatalog -MockWith {
            $env:VMSKU_TEST_CALLS = 1 + [int]$env:VMSKU_TEST_CALLS
            if ([int]$env:VMSKU_TEST_CALLS -lt 3) { throw 'Response status code does not indicate success: 429 (Too Many Requests).' }
            [pscustomobject]@{ value = $items }
        }.GetNewClosure()
        $sink = New-CollectionIssueSink
        $log = Join-Path $TestDrive 'retry.log'
        $catalog = Use-FakeAz -Body (& $TokenAz $log) -Action { Get-RegionSkuCatalog -SubscriptionId 's1' -Region 'eastus2' -IssueSink $sink }
        $catalog.Count | Should -Be $SkuItems.Count
        Should -Invoke Invoke-RestMethod -ModuleName SkuCatalog -Times 3 -Exactly
        Should -Invoke Start-Sleep -ModuleName SkuCatalog -Times 2 -Exactly
        @(Get-Content $log | Where-Object { $_ -match 'list-skus' }).Count | Should -Be 0
        @(Get-CollectionIssue -Sink $sink).Count | Should -Be 0
    }

    It 'falls back to az vm list-skus after three failed attempts at the same page' {
        Mock Invoke-RestMethod -ModuleName SkuCatalog { throw 'Response status code does not indicate success: 503.' }
        $log = Join-Path $TestDrive 'fallback.log'
        $fixture = Join-Path $PSScriptRoot 'fixtures/skus-eastus2.json'
        $body = "Add-Content -LiteralPath '$log' -Value (`$args -join ' ')`nif (`"`$args`" -match 'get-access-token') { Write-Output '{`"accessToken`":`"t`"}'; exit 0 }`nGet-Content -LiteralPath '$fixture' -Raw; exit 0"
        $catalog = Use-FakeAz -Body $body -Action { Get-RegionSkuCatalog -SubscriptionId 's1' -Region 'eastus2' 6>$null }
        $catalog.Count | Should -Be $SkuItems.Count
        Should -Invoke Invoke-RestMethod -ModuleName SkuCatalog -Times 3 -Exactly
        $calls = @(Get-Content $log)
        $calls.Count | Should -Be 2
        $calls[1] | Should -Match '^vm list-skus --location eastus2 --resource-type virtualMachines --all --subscription s1'
    }
}

Describe 'Data-collection issues: effect on assessments and outputs' {
    BeforeAll {
        $script:SkuIssue = [pscustomobject]@{ SubscriptionId = 's1'; Region = 'eastus2'; Api = 'Resource SKUs'; Message = 'az vm list-skus failed: (AuthorizationFailed) access denied'; Effect = 'No replacement size can be recommended for VMs in this scope.' }
        $script:QuotaIssue = [pscustomobject]@{ SubscriptionId = 's1'; Region = 'eastus2'; Api = 'Compute usage (az vm list-usage)'; Message = 'returned no quota data'; Effect = 'Quota cannot be verified.' }
        function script:New-AssessmentWithoutSkuData {
            param([string]$Name = 'nocat', [object[]]$Issues = @($SkuIssue), [string]$Sku = 'Standard_DS3_v2')
            $vm = New-TestVm -Name $Name -Sku $Sku -Gen 'V1'
            $lc = Resolve-SkuLifecycle -SkuName $vm.SkuName -Catalog $Catalog -AsOf $AsOf
            $a = New-VmAssessment -Vm $vm -Lifecycle $lc -RegionCatalog $null -ProcessorCatalog $Proc -RetirementCatalog $Catalog -LifecycleCache @{} -CandidateCache @{} -Weights $Weights -AsOf $AsOf -SubscriptionName 'sub1'
            Complete-VmAssessment -Assessment $a -QuotaResult $null -Usage @{} -CollectionIssues $Issues
        }
        # HTML pages for a catalog that has no unmapped series unless asked (the fixture catalog has some, and the index counts them).
        function script:Export-FooterPages {
            param([object[]]$Assessments, [object[]]$Issues = @(), [string]$EvidenceWarning, $SnapshotAgeDays, [string]$UnmappedSeries)
            $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory $dir | Out-Null
            $catalog = $Catalog.PSObject.Copy()
            $catalog | Add-Member -NotePropertyName unmappedSeries -NotePropertyValue @(if ($UnmappedSeries) { [pscustomobject]@{ SeriesName = $UnmappedSeries } }) -Force
            $run = [pscustomobject]@{ GeneratedUtc = 'now'; AsOf = $AsOf; Tenant = [pscustomobject]@{ Id = 't'; Name = 'tenant' }; Account = 'x'; Parameters = @{}; Counts = @{} }
            if ($null -ne $SnapshotAgeDays) {
                $run | Add-Member -NotePropertyName DataSource -NotePropertyValue 'Snapshot captured 2026-09-01 00:00 UTC'
                $run | Add-Member -NotePropertyName SnapshotAgeDays -NotePropertyValue $SnapshotAgeDays
            }
            $summary = New-AssessmentSummary -Assessments $Assessments -SubscriptionsScanned 1
            $catalogResult = [pscustomobject]@{ Catalog = $catalog; Source = 'Live'; Warning = $(if ($EvidenceWarning) { $EvidenceWarning }) }
            Export-HtmlReports -OutDir $dir -CssPath (Join-Path $Root 'templates/report.css') -Run $run -Summary $summary -Assessments $Assessments -QuotaImpact $null -CatalogResult $catalogResult -ProcessorCatalog $Proc -CollectionIssues $Issues
            $dir
        }
    }

    It 'states the cause in the low-confidence reasons and the recommendation reason of a VM without SKU data' {
        $a = New-AssessmentWithoutSkuData
        $a.Candidates | Should -BeNullOrEmpty
        $a.Readiness | Should -Be 'Manual Review Required'
        $a.Confidence.Level | Should -Be 'LOW'
        $a.Confidence.LowReasons | Should -Contain 'Data not collected (Resource SKUs): az vm list-skus failed: (AuthorizationFailed) access denied'
        (Get-NoRecommendationReason -Assessment $a) | Should -Match '^Data could not be collected - Resource SKUs: az vm list-skus failed'
        (ConvertTo-AssessmentRow $a).RecommendationReason | Should -Match '^Data could not be collected - Resource SKUs'
    }

    It 'keeps the previous reason when there is no recorded cause' {
        $a = New-AssessmentWithoutSkuData -Issues @()
        $a.Confidence.LowReasons.Count | Should -Be 0
        (Get-NoRecommendationReason -Assessment $a) | Should -Be 'Size characteristics or region catalog unavailable'
    }

    It 'adds nothing for a VM that needs no action' {
        $a = New-AssessmentWithoutSkuData -Name 'fine' -Sku 'Standard_D4s_v5'
        $a.Action | Should -Be 'No Action Required'
        $a.Confidence.Level | Should -Be 'N/A'
        $a.Confidence.LowReasons.Count | Should -Be 0
        (Get-NoRecommendationReason -Assessment $a) | Should -BeNullOrEmpty
    }

    It 'names the reason quota could not be verified' {
        $vm = New-TestVm -Name 'q' -Sku 'Standard_DS3_v2' -Gen 'V1'
        $lc = Resolve-SkuLifecycle -SkuName $vm.SkuName -Catalog $Catalog -AsOf $AsOf
        $a = New-VmAssessment -Vm $vm -Lifecycle $lc -RegionCatalog $SkuCat -ProcessorCatalog $Proc -RetirementCatalog $Catalog -LifecycleCache @{} -CandidateCache @{} -Weights $Weights -AsOf $AsOf -SubscriptionName 'sub1'
        $a = Complete-VmAssessment -Assessment $a -QuotaResult $null -Usage @{} -CollectionIssues @($QuotaIssue)
        $a.Confidence.Level | Should -Be 'LOW'
        $a.Confidence.LowReasons | Should -Contain 'Quota could not be validated'
        $a.Confidence.LowReasons | Should -Contain 'Data not collected (Compute usage (az vm list-usage)): returned no quota data'
    }

    It 'writes collectionIssues as an array in assessment.json for none, one and several problems' -ForEach @(
        @{ Case = 'none'; Count = 0 }
        @{ Case = 'one'; Count = 1 }
        @{ Case = 'two'; Count = 2 }
    ) {
        $issues = @(@($SkuIssue, $QuotaIssue) | Select-Object -First $Count)
        $j = Read-TestJson (Export-TestOutput -Assessments @((Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1'))) -CollectionIssues $issues)
        ($j.collectionIssues -is [System.Array]) | Should -BeTrue -Because "collectionIssues must be an array ($Case)"
        @($j.collectionIssues).Count | Should -Be $Count
        if ($Count -gt 0) {
            $first = @($j.collectionIssues)[0]
            $first.PSObject.Properties.Name | Should -Be @('subscriptionId', 'region', 'api', 'message', 'effect')
            $first.api | Should -Be 'Resource SKUs'
        }
    }

    It 'lists the problems in the executive summary only when there are some' {
        $a = @((Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1')))
        $with = Get-Content (Join-Path (Export-TestOutput -Assessments $a -CollectionIssues @($SkuIssue, $QuotaIssue) -Html) 'executive-summary.md') -Raw
        $with | Should -Match '(?m)^## Data collection issues'
        $with | Should -Match '\| Data \| Subscription \| Region \| Problem \| Effect \|'
        $with | Should -Match 'Resource SKUs'
        $without = Get-Content (Join-Path (Export-TestOutput -Assessments $a -Html) 'executive-summary.md') -Raw
        $without | Should -Not -Match 'Data collection issues'
    }

    It 'shows the problems on the pages of the affected subscription and a panel for every listed VM without a recommendation' {
        $withoutData = New-AssessmentWithoutSkuData
        $other = $SkuIssue.PSObject.Copy(); $other.SubscriptionId = 'other-subscription'; $other.Message = 'unrelated problem elsewhere'
        $dir = Export-TestOutput -Assessments @($withoutData) -CollectionIssues @($SkuIssue, $other) -Html
        $index = Get-Content (Join-Path $dir 'index.html') -Raw
        $index | Should -Match 'Some data could not be collected \(2\)'
        $sub = Get-Content (Get-ChildItem $dir -Filter '*.html' | Where-Object Name -ne 'index.html' | Select-Object -First 1).FullName -Raw
        $sub | Should -Match 'Some data could not be collected \(1\)'
        $sub | Should -Match 'AuthorizationFailed'
        $sub | Should -Not -Match 'unrelated problem elsewhere'
        ([regex]::Matches($sub, "<tr class='vm-summary-row")).Count | Should -Be 1
        ([regex]::Matches($sub, "<tr class='vm-detail-row'")).Count | Should -Be 1
        $sub | Should -Match 'Why there is no recommendation'
        $sub | Should -Match 'Data could not be collected - Resource SKUs'
        $sub | Should -Not -Match 'Why there is no recommendation</h4><p>Size characteristics'
    }

    It 'adds no callout when nothing went wrong' {
        $a = @((Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1')))
        $dir = Export-TestOutput -Assessments $a -Html
        foreach ($page in Get-ChildItem $dir -Filter '*.html') { (Get-Content $page.FullName -Raw) | Should -Not -Match 'Some data could not be collected' }
    }

    It 'does not call a report successful when it has no warnings' {
        $dir = Export-FooterPages -Assessments @((Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1')))
        $pages = @(Get-ChildItem $dir -Filter '*.html')
        $pages.Count | Should -BeGreaterThan 1
        foreach ($page in $pages) {
            $html = Get-Content $page.FullName -Raw
            $html | Should -Match '<span class="footer-status"><span aria-hidden="true"></span>Report generated</span>' -Because $page.Name
            $html | Should -Not -Match 'successfully|footer-status warn' -Because $page.Name
        }
    }

    It 'states in the footer how many warnings the page shows, counting the problems of its own scope' {
        $other = $SkuIssue.PSObject.Copy(); $other.SubscriptionId = 'other-subscription'; $other.Message = 'unrelated problem elsewhere'
        $dir = Export-FooterPages -Assessments @((New-AssessmentWithoutSkuData)) -Issues @($SkuIssue, $other)
        $index = Get-Content (Join-Path $dir 'index.html') -Raw
        $index | Should -Match '<span class="footer-status warn"><span aria-hidden="true"></span>Report generated with 2 warnings</span>'
        $sub = Get-Content (Get-ChildItem $dir -Filter '*.html' | Where-Object Name -ne 'index.html' | Select-Object -First 1).FullName -Raw
        $sub | Should -Match '<span class="footer-status warn"><span aria-hidden="true"></span>Report generated with 1 warning</span>'
        $sub | Should -Not -Match 'with 1 warnings|successfully'
    }

    It 'counts a stale snapshot, the evidence warning and unmapped series with the problems, on the pages that show them' {
        $a = New-AssessmentWithoutSkuData
        # The index shows the stale snapshot, the problem and the evidence warning; a subscription page shows the first two.
        $dir = Export-FooterPages -Assessments @($a) -Issues @($SkuIssue) -EvidenceWarning 'The cached evidence is 120 days older than the assessment date.' -SnapshotAgeDays 10
        (Get-Content (Join-Path $dir 'index.html') -Raw) | Should -Match 'Report generated with 3 warnings</span>'
        $sub = Get-Content (Get-ChildItem $dir -Filter '*.html' | Where-Object Name -ne 'index.html' | Select-Object -First 1).FullName -Raw
        $sub | Should -Match 'Report generated with 2 warnings</span>'
        # A series without a size mapping is one more warning on the index.
        $withUnmapped = Export-FooterPages -Assessments @($a) -UnmappedSeries 'Zzz-series'
        (Get-Content (Join-Path $withUnmapped 'index.html') -Raw) | Should -Match 'Report generated with 1 warning</span>'
    }
}

Describe 'Retirement catalog currency' {
    BeforeAll {
        $script:SeriesMapPath = Join-Path $Root 'data/series-map.json'
        $learn = @{
            'retirements-and-capacity-restrictions' = (Get-Content (Join-Path $PSScriptRoot 'fixtures/retired-sizes-list.html') -Raw)
            'end-of-life-sizes-list'                = (Get-Content (Join-Path $PSScriptRoot 'fixtures/previous-gen-sizes-list.html') -Raw)
            'retired-sizes-modernization-guide'     = (Get-Content (Join-Path $PSScriptRoot 'fixtures/migration-guide.html') -Raw)
        }
        $script:LivePages = {
            param($Uri)
            $key = @($learn.Keys | Where-Object { "$Uri" -like "*$_*" })[0]
            [pscustomobject]@{ Content = $learn[$key] }
        }.GetNewClosure()
        function script:Write-TestCache {
            param([Parameter(Mandatory)]$Catalog)
            $path = Join-Path $TestDrive ('cache-' + [guid]::NewGuid().ToString('N') + '.json')
            $Catalog | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path
            $path
        }
        function script:New-ExtraSeries {
            param([string]$Key = 'fakeseries', $RetiredList = $true)
            [pscustomobject]@{ key = $Key; learnNames = @('Fake series'); patterns = @('^Standard_Fake'); retiredList = $(if ($RetiredList) { [pscustomobject]@{ status = 'Retired' } } else { $null }); previousGen = $null; guideFaq = $null; recommendedTargets = @(); guideDifferences = @(); notes = @() }
        }
    }

    It 'returns live evidence without a warning when it has everything the cache has' {
        Mock Invoke-WebRequest -ModuleName Retirement -MockWith $LivePages
        $r = Get-RetirementCatalog -SeriesMapPath $SeriesMapPath -CachePath (Write-TestCache $Catalog)
        $r.Source | Should -Be 'Live'
        $r.Warning | Should -BeNullOrEmpty
    }

    It 'warns when the live parse lost a series, and does not overwrite the cache with it' {
        Mock Invoke-WebRequest -ModuleName Retirement -MockWith $LivePages
        $cached = $Catalog.PSObject.Copy(); $cached.series = @($Catalog.series) + (New-ExtraSeries)
        $path = Write-TestCache $cached
        $before = (Get-FileHash $path).Hash
        $r = Get-RetirementCatalog -SeriesMapPath $SeriesMapPath -CachePath $path -UpdateCache
        $r.Source | Should -Be 'Live'
        $r.Warning | Should -Match '1 of the \d+ series in the cached catalog are missing \(fakeseries\)'
        $r.Warning | Should -Match 'The cache was not updated\.$'
        (Get-FileHash $path).Hash | Should -Be $before
    }

    It 'warns when list rows were lost although every series is still there' -ForEach @(
        @{ List = 'retiredList'; Text = 'the retired-sizes list now covers' }
        @{ List = 'previousGen'; Text = 'the previous-generation list now covers' }
    ) {
        Mock Invoke-WebRequest -ModuleName Retirement -MockWith $LivePages
        $cached = $Catalog | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
        $without = @($cached.series | Where-Object { -not $_.$List })
        $without.Count | Should -BeGreaterThan 0 -Because 'the fixture needs a series without this list for the check'
        $without[0].$List = [pscustomobject]@{ status = 'Retired' }
        $r = Get-RetirementCatalog -SeriesMapPath $SeriesMapPath -CachePath (Write-TestCache $cached)
        $r.Warning | Should -Match $Text
        $r.Warning | Should -Not -Match 'series in the cached catalog are missing'
    }

    It 'refreshes the cache when nothing was lost' {
        Mock Invoke-WebRequest -ModuleName Retirement -MockWith $LivePages
        $path = Write-TestCache $Catalog
        $before = (Get-FileHash $path).Hash
        $r = Get-RetirementCatalog -SeriesMapPath $SeriesMapPath -CachePath $path -UpdateCache
        $r.Warning | Should -BeNullOrEmpty
        (Get-FileHash $path).Hash | Should -Not -Be $before
    }

    It 'warns about a cached catalog that is more than 90 days older than the assessment date (<Case>)' -ForEach @(
        @{ Case = '120 days'; Days = 120; Age = $true }
        @{ Case = 'exactly 90 days'; Days = 90; Age = $false }
        @{ Case = 'assessment date before the retrieval'; Days = -10; Age = $false }
    ) {
        $path = Write-TestCache $Catalog
        $r = Get-RetirementCatalog -SeriesMapPath $SeriesMapPath -CachePath $path -Offline -AsOf ([datetime]'2026-09-24').AddDays($Days)
        $r.Source | Should -Be 'Cached (2026-09-24 00:00 UTC)'
        $r.Warning | Should -Match '^Offline mode requested\.'
        if ($Age) { $r.Warning | Should -Match 'retrieved 2026-09-24, 120 days before the assessment date' } else { $r.Warning | Should -Not -Match 'days before the assessment date' }
    }

    It 'reports the failed live fetch together with the age of the cache it falls back to' {
        Mock Invoke-WebRequest -ModuleName Retirement -MockWith { throw 'network down' }
        $r = Get-RetirementCatalog -SeriesMapPath $SeriesMapPath -CachePath (Write-TestCache $Catalog) -AsOf ([datetime]'2027-03-01') 3>$null
        $r.Source | Should -BeLike 'Cached (*'
        $r.Warning | Should -Match '^Live fetch failed: network down '
        $r.Warning | Should -Match '158 days before the assessment date'
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

Describe 'Report name and table columns' {
    BeforeAll {
        $a = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1')
        $script:ReportDir = Export-TestOutput -Assessments @($a) -Html
        $script:ReportIndex = Get-Content (Join-Path $ReportDir 'index.html') -Raw
        $script:ReportSub = Get-Content (Get-ChildItem $ReportDir -Filter '*.html' | Where-Object Name -ne 'index.html' | Select-Object -First 1).FullName -Raw
    }

    It 'calls the report "Azure VM SKU Retirement Report" in the header, title and footer of every page' {
        foreach ($html in $ReportIndex, $ReportSub) {
            $html | Should -Match '<strong>Azure VM SKU Retirement Report</strong><small>Assessment report v\d+\.\d+\.\d+</small>'
            $html | Should -Match '<title>Azure VM SKU Retirement Report - '
            $html | Should -Match '<footer>.*Azure VM SKU Retirement Report v\d+\.\d+\.\d+'
            $html | Should -Not -Match 'VMSKURetirementReport v\d|<strong>VMSKURetirementReport</strong>|<title>VMSKURetirementReport'
        }
        $ReportIndex | Should -Match '<span class="report-context">Azure VM SKU Retirement Report</span>'
    }

    It 'names the report in the Markdown titles and keeps the tool name in assessment.json' {
        (Get-Content (Join-Path $ReportDir 'executive-summary.md') -Raw) | Should -Match '(?m)^# Azure VM SKU Retirement Report - Executive Summary'
        (Get-Content (Join-Path $ReportDir 'executive-summary.md') -Raw) | Should -Match '\| Azure VM SKU Retirement Report v\d'
        (Read-TestJson $ReportDir).tool | Should -Be 'VMSKURetirementReport'
    }

    It 'has no Retirement date column in the tenant page''s Migration Waves table, and no date in its rows' {
        $waves = [regex]::Match($ReportIndex, "(?s)<details id='waves'.*?</details>").Value
        $waves | Should -Match '<th>Microsoft status</th><th class=''num''>VMs</th><th>Recommended size</th>'
        $waves | Should -Not -Match 'Retirement date|No date|\d{4}-\d{2}-\d{2}'
        $waves | Should -Match "<span class='badge [^']+'>End of Life</span>"
    }

    It 'keeps the retirement date in the VM details and the quota status in the details and the quota table' {
        $row = [regex]::Match($ReportSub, "(?s)<tr class='vm-summary-row[^']*'[^>]*>.*?</tr>").Value
        $row | Should -Not -Match '2028-05-01'
        $detail = [regex]::Match($ReportSub, "(?s)<tr class='vm-detail-row'.*?</tr>").Value
        $detail | Should -Match '2028-05-01'
        $ReportSub | Should -Match '<h2>Quota Actions</h2>'
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
    It 'uses the safety percentage (<Pct>) only to enlarge the recommended increase, never to change the status (used <Used>)' -ForEach @(
        @{ Used = 80; Pct = 0; Status = 'Quota OK'; Min = 0; Rec = 0 }
        @{ Used = 80; Pct = 20; Status = 'Quota OK'; Min = 0; Rec = 0 }
        @{ Used = 80; Pct = 200; Status = 'Quota OK'; Min = 0; Rec = 0 }
        @{ Used = 81; Pct = 0; Status = 'Quota Increase Required'; Min = 1; Rec = 1 }
        @{ Used = 81; Pct = 20; Status = 'Quota Increase Required'; Min = 1; Rec = 5 }
        @{ Used = 81; Pct = 200; Status = 'Quota Increase Required'; Min = 1; Rec = 41 }
    ) {
        # 20 vCPUs required against a limit of 100: used 80 fits exactly, used 81 is 1 over.
        $usage = @{ 's1|eastus2' = @{ 'standarddsv5family' = [pscustomobject]@{ Name = 'standardDSv5Family'; LocalName = 'DSv5'; Used = $Used; Limit = 100 }; 'cores' = [pscustomobject]@{ Name = 'cores'; LocalName = 'Regional'; Used = 10; Limit = 1000 } } }
        $moves = @([pscustomobject]@{ SubscriptionId = 's1'; Region = 'eastus2'; VmId = 'x'; CurrentFamily = 'standardDSv2Family'; CurrentVcpu = 4; TargetSku = 'Standard_D20s_v5'; TargetFamily = 'standardDSv5Family'; TargetVcpu = 20; IsAllocated = $true })
        $r = Measure-QuotaImpact -Moves $moves -Usage $usage -SafetyPct $Pct
        $r.FamilyRows[0].RequiredVcpu | Should -Be 20
        $r.FamilyRows[0].MinimumIncrease | Should -Be $Min
        $r.FamilyRows[0].RecommendedIncrease | Should -Be $Rec
        $r.ByVm['x'].Status | Should -Be $Status
    }
    It 'has no safety percentage on the modernization quota choice, which depends only on whether the demand fits' {
        (Get-Command Resolve-ModernizationQuotaChoices).Parameters.Keys | Should -Not -Contain 'SafetyPct'
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
    It 'redeploys a Gen1 VM whose <Where> is "<Value>", an exclusion Microsoft names for the Trusted launch upgrade' -ForEach @(
        @{ Where = 'OS name'; Property = 'OsName'; Value = 'Windows Server 2016 Datacenter' }
        @{ Where = 'OS name'; Property = 'OsName'; Value = 'Debian GNU/Linux 12' }
        @{ Where = 'OS name'; Property = 'OsName'; Value = 'Azure Linux 3.0' }
        @{ Where = 'OS name'; Property = 'OsName'; Value = 'CBL-Mariner/Linux' }
        @{ Where = 'image'; Property = 'ImageReference'; Value = 'MicrosoftWindowsServer/WindowsServer/2016-Datacenter' }
        @{ Where = 'image'; Property = 'ImageReference'; Value = 'debian/debian-11/11-gen2' }
        @{ Where = 'image'; Property = 'ImageReference'; Value = 'MicrosoftCBLMariner/cbl-mariner/cbl-mariner-2' }
    ) {
        $vm = New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1'
        $vm.$Property = $Value
        (Invoke-TestAssessment -Vm $vm -CheckModernization).Strategy.RedeployReview | Should -BeTrue
    }
    It 'keeps a Gen1 VM on the upgrade path when its <Where> is "<Value>", which Microsoft lists as supported' -ForEach @(
        @{ Where = 'OS name'; Property = 'OsName'; Value = 'Windows Server 2019 Datacenter' }
        @{ Where = 'OS name'; Property = 'OsName'; Value = 'Windows Server 2022 Datacenter' }
        @{ Where = 'OS name'; Property = 'OsName'; Value = 'Red Hat Enterprise Linux 9.4' }
        @{ Where = 'image'; Property = 'ImageReference'; Value = 'MicrosoftWindowsServer/WindowsServer/2019-Datacenter' }
        @{ Where = 'image'; Property = 'ImageReference'; Value = 'Canonical/0001-com-ubuntu-server-jammy/22_04-lts' }
    ) {
        $vm = New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1'
        $vm.$Property = $Value
        $s = (Invoke-TestAssessment -Vm $vm -CheckModernization).Strategy
        $s.RedeployReview | Should -BeFalse
        $s.RequiresGenerationChange | Should -BeTrue
    }
    It 'states the whole rule in the Gen1 validation item: the named exclusions, any OS not on the supported list and Marketplace images' {
        $vm = New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1'
        $vm.OsName = 'Oracle Linux 8'
        $items = ((Invoke-TestAssessment -Vm $vm -CheckModernization).Strategy.ValidationItems -join ' ')
        $items | Should -Match 'Gen1 to Gen2: Validation Required'
        $items | Should -Match 'Windows Server 2016, Debian, Azure Linux and any OS that is not on Microsoft''s Trusted launch supported list are excluded'
        $items | Should -Match 'Linux VM must come from a supported Azure Marketplace image'
        $items | Should -Not -Match 'Guest OS not reported' -Because 'the OS name is known'
    }
    It 'says in the NVMe readiness item that the controller was assumed when Azure did not report it, and the assumption never lowers the confidence' {
        $unreported = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1') -CheckModernization
        $reported = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1' -Controller 'SCSI') -CheckModernization
        ($unreported.Strategy.ValidationItems -join ' ') | Should -Match "Guest NVMe readiness: Validation Required.*The VM's disk controller is not reported by Azure; SCSI \(the Azure default\) was assumed, so confirm it\."
        ($reported.Strategy.ValidationItems -join ' ') | Should -Match 'Guest NVMe readiness: Validation Required'
        ($reported.Strategy.ValidationItems -join ' ') | Should -Not -Match 'disk controller is not reported'
        $unreported.Confidence.Level | Should -Be $reported.Confidence.Level
        @($unreported.Confidence.ValidationItems).Count | Should -Be @($reported.Confidence.ValidationItems).Count
    }
    It 'lists the disk-controller assumption only where a SCSI to NVMe conversion rests on it' {
        $unreported = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1') -CheckModernization
        $reported = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_DS3_v2' -Gen 'V1' -Controller 'SCSI') -CheckModernization
        $noAction = Invoke-TestAssessment -Vm (New-TestVm -Sku 'Standard_D4s_v5')
        InModuleScope Output -Parameters @{ U = $unreported; R = $reported; N = $noAction } {
            @(Get-ConfidenceAssumption -Assessment $U -Strategy $U.Strategy).Count | Should -Be 1
            (Get-ConfidenceAssumption -Assessment $U -Strategy $U.Strategy) | Should -Match 'SCSI \(the Azure default\) was assumed'
            @(Get-ConfidenceAssumption -Assessment $R -Strategy $R.Strategy).Count | Should -Be 0
            @(Get-ConfidenceAssumption -Assessment $N -Strategy $N.Strategy).Count | Should -Be 0
        }
    }
    It 'shows the disk-controller assumption on the confidence badge of the VM that did not report a controller, and only there' {
        $unreported = Invoke-TestAssessment -Vm (New-TestVm -Name 'unreported' -Sku 'Standard_DS3_v2' -Gen 'V1') -CheckModernization
        $reported = Invoke-TestAssessment -Vm (New-TestVm -Name 'reported' -Sku 'Standard_DS3_v2' -Gen 'V1' -Controller 'SCSI') -CheckModernization
        $dir = Export-TestOutput -Assessments @($unreported, $reported) -Html -ExtraParameters @{ CheckModernization = $true }
        $html = Get-Content (Get-ChildItem $dir -Filter '*.html' | Where-Object Name -ne 'index.html' | Select-Object -First 1).FullName -Raw
        ([regex]::Matches($html, '(?s)title=''Confidence in the recommended size: [^'']*Assumed, without changing the level:[^'']*SCSI \(the Azure default\) was assumed')).Count | Should -Be 1
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
        $p = [pscustomobject]@{ Availability = 'Available'; SkuName = 'Standard_D4s_v5'; CpuVendor = 'Intel'; VendorQuality = 'Verified' }
        $cur = [pscustomobject]@{ CapsKnown = $true; SkuName = 'Standard_D4s_v3'; Vendor = 'Intel'; VendorQuality = 'Verified' }
        (Get-MigrationConfidence -Lifecycle $lc -Primary $p -Current $cur -VendorChangeRequired $false -QuotaStatus 'Quota OK').Level | Should -Be 'HIGH'
        (Get-MigrationConfidence -Lifecycle $lc -Primary $p -Current $cur -VendorChangeRequired $false -QuotaStatus 'Quota Increase Required').Level | Should -Be 'MEDIUM'
        (Get-MigrationConfidence -Lifecycle $lc -Primary $p -Current $cur -VendorChangeRequired $true -QuotaStatus 'Quota OK').Level | Should -Be 'LOW'
        (Get-MigrationConfidence -Lifecycle $lc -Primary $p -Current $cur -VendorChangeRequired $false -QuotaStatus 'Quota Information Unavailable').Level | Should -Be 'LOW'
    }
    It 'asks to confirm a CPU vendor that is not verified against the Microsoft processor tables' -ForEach @(
        @{ Case = 'the current size'; CurrentQuality = 'Partially Verified'; TargetQuality = 'Verified'; Level = 'MEDIUM'; Named = @('current size Standard_HB60rs (Intel)'); NotNamed = @('target size') }
        @{ Case = 'the target size'; CurrentQuality = 'Verified'; TargetQuality = 'Partially Verified'; Level = 'MEDIUM'; Named = @('target size Standard_D4s_v5 (Intel)'); NotNamed = @('current size') }
        @{ Case = 'both sizes (one item)'; CurrentQuality = 'Partially Verified'; TargetQuality = 'Partially Verified'; Level = 'MEDIUM'; Named = @('current size Standard_HB60rs (Intel) and target size Standard_D4s_v5 (Intel)'); NotNamed = @() }
        @{ Case = 'neither size'; CurrentQuality = 'Verified'; TargetQuality = 'Verified'; Level = 'HIGH'; Named = @(); NotNamed = @('CPU vendor not verified') }
    ) {
        $lc = [pscustomobject]@{ EvidenceClass = 'Confirmed Retirement'; DataQuality = 'Verified' }
        $p = [pscustomobject]@{ Availability = 'Available'; SkuName = 'Standard_D4s_v5'; CpuVendor = 'Intel'; VendorQuality = $TargetQuality }
        $cur = [pscustomobject]@{ CapsKnown = $true; SkuName = 'Standard_HB60rs'; Vendor = 'Intel'; VendorQuality = $CurrentQuality }
        $c = Get-MigrationConfidence -Lifecycle $lc -Primary $p -Current $cur -VendorChangeRequired $false -QuotaStatus 'Quota OK'
        $c.Level | Should -Be $Level
        $vendorItems = @($c.ValidationItems | Where-Object { $_ -like 'CPU vendor not verified*' })
        @($Named).Count | Should -Be @($vendorItems).Count -Because 'a single combined item is expected when a vendor is unverified'
        foreach ($text in $Named) { $vendorItems[0] | Should -BeLike "*$text*" }
        foreach ($text in $NotNamed) { ($c.ValidationItems -join ' | ') | Should -Not -BeLike "*$text*" }
    }
    It 'counts an unverified CPU vendor like any other open validation item' {
        $lc = [pscustomobject]@{ EvidenceClass = 'Confirmed Retirement'; DataQuality = 'Verified' }
        $p = [pscustomobject]@{ Availability = 'Available'; SkuName = 'Standard_D4s_v5'; CpuVendor = 'Intel'; VendorQuality = 'Verified' }
        $cur = [pscustomobject]@{ CapsKnown = $true; SkuName = 'Standard_HB60rs'; Vendor = 'Intel'; VendorQuality = 'Partially Verified' }
        (Get-MigrationConfidence -Lifecycle $lc -Primary $p -Current $cur -VendorChangeRequired $false -QuotaStatus 'Quota Increase Required').Level | Should -Be 'LOW'
        (Get-MigrationConfidence -Lifecycle $lc -Primary $null -Current $cur -VendorChangeRequired $false -QuotaStatus 'Quota OK').ValidationItems | Should -BeLike 'CPU vendor not verified for current size*'
    }
    It 'keeps a VM whose CPU vendor comes only from the size name out of "Proceed with Resize"' {
        $noDsv3 = $Proc | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
        [void]$noDsv3.series.PSObject.Properties.Remove('dsv3')
        $vm = New-TestVm -Sku 'Standard_D4s_v3'
        $lc = Resolve-SkuLifecycle -SkuName $vm.SkuName -Catalog $Catalog -AsOf $AsOf
        $a = New-VmAssessment -Vm $vm -Lifecycle $lc -RegionCatalog $SkuCat -ProcessorCatalog $noDsv3 -RetirementCatalog $Catalog -LifecycleCache @{} -CandidateCache @{} -Weights $Weights -AsOf $AsOf -SubscriptionName 'sub1'
        $quota = [pscustomobject]@{ Status = 'Quota OK'; DataQuality = 'Verified'; Family = [pscustomobject]@{ QuotaDisplayName = 'x'; MinimumIncrease = 0; RecommendedIncrease = 0; CurrentUsage = 0; Limit = 100; RequiredVcpu = 4 }; Regional = [pscustomobject]@{ MinimumIncrease = 0 } }
        $a = Complete-VmAssessment -Assessment $a -QuotaResult $quota -Usage @{}
        $a.Current.VendorQuality | Should -Be 'Partially Verified'
        $a.Readiness | Should -Be 'Ready'
        $a.Confidence.Level | Should -Be 'MEDIUM'
        $a.NextStep | Should -Be 'Validate Before Resize'
        @($a.ValidationItems | Where-Object { $_ -like 'CPU vendor not verified for current size Standard_D4s_v3 (Intel)*' }).Count | Should -Be 1
        (Invoke-TestAssessment (New-TestVm -Sku 'Standard_D4s_v3')).Confidence.Level | Should -Be 'HIGH'
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

Describe 'Rightsizing' {
    BeforeAll {
        $script:LowUse = [pscustomobject]@{ CpuP95 = 7; CpuMax = 85; MemAvailP05Bytes = 28GB; Samples = 720 }
        $script:RsPrimary = [pscustomobject]@{ SkuName = 'Standard_D8s_v5'; vCPUs = 8 }
        # D8s_v5 is the recommended size and D4s_v5 its half size (fixture records, copied because tests change them).
        function script:New-HalfSizeCatalog {
            @{ 'standard_d8s_v5' = $SkuCat['standard_d8s_v5'].PSObject.Copy(); 'standard_d4s_v5' = $SkuCat['standard_d4s_v5'].PSObject.Copy() }
        }
        function script:Add-ConstrainedSize {
            param([hashtable]$Catalog, [string]$Name, [int]$Vcpu, [int]$Active, [double]$MemoryGB)
            $size = $SkuCat['standard_d4s_v5'].PSObject.Copy()
            $size.Name = $Name; $size.vCPUs = $Vcpu; $size.vCPUsAvailable = $Active; $size.MemoryGB = $MemoryGB
            $Catalog[$Name.ToLowerInvariant()] = $size
        }
        function script:Get-RightsizingContext {
            param([int]$Nics = 1, [string[]]$Zones, [int]$DataDisks = 0)
            $vmArgs = @{ Name = 'rs'; Sku = 'Standard_D4s_v3'; Nics = $Nics }
            if ($Zones) { $vmArgs.Zones = $Zones }
            $vm = New-TestVm @vmArgs
            $vm.DataDiskCount = $DataDisks
            $record = $SkuCat['standard_d4s_v3']
            $processor = Get-ProcessorInfo -SkuName 'Standard_D4s_v3' -ProcessorCatalog $Proc -SkuRecord $record
            @{ Vm = $vm; Current = (New-CurrentProfile -SkuName 'Standard_D4s_v3' -SkuRecord $record -ProcessorInfo $processor -VmGeneration $vm.HyperVGeneration -VmDiskController $vm.DiskControllerType); ProcessorCatalog = $Proc }
        }
    }

    Describe 'Percentiles' {
        It 'returns the nearest-rank percentile of <Values> at <Percentile>' -ForEach @(
            @{ Values = @(1..100); Percentile = 95; Expected = 95 }
            @{ Values = @(1..100); Percentile = 5; Expected = 5 }
            @{ Values = @(100..1); Percentile = 50; Expected = 50 }
            @{ Values = @(4.2); Percentile = 95; Expected = 4.2 }
            @{ Values = @(1, 2, 3, 4); Percentile = 95; Expected = 4 }
            @{ Values = @(1.234, 5.678); Percentile = 5; Expected = 1.23 }
        ) {
            Get-Percentile $Values $Percentile | Should -Be $Expected
        }
        It 'returns nothing for an empty series' {
            Get-Percentile @() 95 | Should -BeNullOrEmpty
        }
    }

    Describe 'Azure Monitor metrics' {
        BeforeAll {
            # 200 hourly points: CPU average 1..200 (maximum average + 10) and available memory 1..200 MB; the resource id comes back upper case.
            $script:SeriesMock = {
                $ids = @(($Body | ConvertFrom-Json).resourceids)
                $cpu = @(1..200 | ForEach-Object { [pscustomobject]@{ timeStamp = 't'; average = [double]$_; maximum = [double]($_ + 10) } })
                $mem = @(1..200 | ForEach-Object { [pscustomobject]@{ timeStamp = 't'; average = [double]($_ * 1MB) } })
                [pscustomobject]@{ values = @($ids | ForEach-Object {
                            [pscustomobject]@{ resourceid = $_.ToUpperInvariant(); value = @(
                                    [pscustomobject]@{ name = [pscustomobject]@{ value = 'Percentage CPU' }; timeseries = @([pscustomobject]@{ data = $cpu }) }
                                    [pscustomobject]@{ name = [pscustomobject]@{ value = 'Available Memory Bytes' }; timeseries = @([pscustomobject]@{ data = $mem }) }) }
                        }) }
            }
            $script:MetricVm = { param($Index, $Region) [pscustomobject]@{ Id = "/subscriptions/s1/resourcegroups/rg/providers/microsoft.compute/virtualmachines/vm$Index"; SubscriptionId = 's1'; Region = $Region } }
        }
        BeforeEach {
            Mock Invoke-AzJson -ModuleName Rightsizing { [pscustomobject]@{ accessToken = 'token' } }
            Mock Start-Sleep -ModuleName Rightsizing { }
        }

        It 'reads the CPU and memory percentiles of each VM, keyed by lower-case resource id' {
            Mock Invoke-RestMethod -ModuleName Rightsizing -MockWith $SeriesMock
            $vm = & $MetricVm 1 'eastus2'
            $u = Get-VmUtilization -Vms @($vm) -LookbackDays 30
            @($u.Keys) | Should -Be @($vm.Id.ToLowerInvariant())
            $u[$vm.Id].CpuP95 | Should -Be 190
            $u[$vm.Id].CpuMax | Should -Be 210
            $u[$vm.Id].MemAvailP05Bytes | Should -Be (10MB)
            $u[$vm.Id].Samples | Should -Be 200
        }

        It 'asks for at most 50 VMs per call, separately for each subscription and region' {
            Mock Invoke-RestMethod -ModuleName Rightsizing -MockWith $SeriesMock
            $vms = @(1..60 | ForEach-Object { & $MetricVm $_ 'eastus2' }) + @(61..120 | ForEach-Object { & $MetricVm $_ 'westus2' })
            $u = Get-VmUtilization -Vms $vms -LookbackDays 7
            @($u.Keys).Count | Should -Be 120
            Should -Invoke Invoke-RestMethod -ModuleName Rightsizing -Times 4 -Exactly
            Should -Invoke Invoke-RestMethod -ModuleName Rightsizing -Times 2 -Exactly -ParameterFilter { $Uri -like 'https://eastus2.metrics.monitor.azure.com/subscriptions/s1/metrics:getBatch?*' }
            Should -Invoke Invoke-RestMethod -ModuleName Rightsizing -Times 2 -Exactly -ParameterFilter { $Uri -like 'https://westus2.metrics.monitor.azure.com/subscriptions/s1/metrics:getBatch?*' }
            Should -Invoke Invoke-RestMethod -ModuleName Rightsizing -Times 2 -Exactly -ParameterFilter { @(($Body | ConvertFrom-Json).resourceids).Count -eq 50 }
            Should -Invoke Invoke-RestMethod -ModuleName Rightsizing -Times 0 -Exactly -ParameterFilter { @(($Body | ConvertFrom-Json).resourceids).Count -gt 50 }
        }

        It 'sends the tenant to the token request when one is given' {
            Mock Invoke-RestMethod -ModuleName Rightsizing -MockWith $SeriesMock
            [void](Get-VmUtilization -Vms @(& $MetricVm 1 'eastus2') -TenantId 'tenant-1')
            Should -Invoke Invoke-AzJson -ModuleName Rightsizing -Times 1 -Exactly -ParameterFilter { $Arguments -contains '--tenant' -and $Arguments -contains 'tenant-1' -and $Arguments -contains 'https://metrics.monitor.azure.com' }
        }

        It 'retries a call that fails and uses the answer of the later attempt' {
            # Mock bodies do not keep script-scope state between calls; a process variable counts the attempts.
            $env:RIGHTSIZING_TEST_ATTEMPTS = '0'
            try {
                Mock Invoke-RestMethod -ModuleName Rightsizing -MockWith {
                    $env:RIGHTSIZING_TEST_ATTEMPTS = 1 + [int]$env:RIGHTSIZING_TEST_ATTEMPTS
                    if ([int]$env:RIGHTSIZING_TEST_ATTEMPTS -lt 3) { throw 'The request was throttled (429)' }
                    $ids = @(($Body | ConvertFrom-Json).resourceids)
                    [pscustomobject]@{ values = @($ids | ForEach-Object { [pscustomobject]@{ resourceid = $_; value = @([pscustomobject]@{ name = [pscustomobject]@{ value = 'Percentage CPU' }; timeseries = @([pscustomobject]@{ data = @([pscustomobject]@{ average = 3.0; maximum = 9.0 }) }) }) } }) }
                }
                $vm = & $MetricVm 1 'eastus2'
                $u = Get-VmUtilization -Vms @($vm)
                Should -Invoke Invoke-RestMethod -ModuleName Rightsizing -Times 3 -Exactly
                $u[$vm.Id].CpuP95 | Should -Be 3
                $u[$vm.Id].Samples | Should -Be 1
            }
            finally { Remove-Item Env:\RIGHTSIZING_TEST_ATTEMPTS -ErrorAction SilentlyContinue }
        }

        It 'gives up on a call after three attempts and returns no data for its VMs' {
            Mock Invoke-RestMethod -ModuleName Rightsizing { throw 'The request was throttled (429)' }
            $u = Get-VmUtilization -Vms @((& $MetricVm 1 'eastus2'))
            Should -Invoke Invoke-RestMethod -ModuleName Rightsizing -Times 3 -Exactly
            @($u.Keys).Count | Should -Be 0
        }

        It 'leaves a metric empty when the answer has no points for it' {
            Mock Invoke-RestMethod -ModuleName Rightsizing {
                $ids = @(($Body | ConvertFrom-Json).resourceids)
                [pscustomobject]@{ values = @($ids | ForEach-Object { [pscustomobject]@{ resourceid = $_; value = @([pscustomobject]@{ name = [pscustomobject]@{ value = 'Percentage CPU' }; timeseries = @([pscustomobject]@{ data = @([pscustomobject]@{ average = 4.0; maximum = 8.0 }) }) }) } }) }
            }
            $vm = & $MetricVm 1 'eastus2'
            $u = Get-VmUtilization -Vms @($vm)
            $u[$vm.Id].CpuP95 | Should -Be 4
            $u[$vm.Id].MemAvailP05Bytes | Should -BeNullOrEmpty
        }

        Context 'when a call still fails after its retries' {
            BeforeAll {
                $script:Forbidden = {
                    $record = [System.Management.Automation.ErrorRecord]::new([System.Net.Http.HttpRequestException]::new('Response status code does not indicate success: 403 (Forbidden).'), 'Forbidden', [System.Management.Automation.ErrorCategory]::PermissionDenied, $null)
                    $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"error":{"code":"AuthorizationFailed","message":"The client ''jane.doe@contoso.com'' with object id ''11111111-2222-3333-4444-555555555555'' does not have authorization to perform action ''microsoft.insights/metrics/read'' over scope ''/subscriptions/s1''."}}')
                    throw $record
                }
            }

            It 'records it once per subscription and region with the number of VMs that get no data, and keeps the other scopes' {
                Mock Invoke-RestMethod -ModuleName Rightsizing -MockWith $SeriesMock
                Mock Invoke-RestMethod -ModuleName Rightsizing -MockWith $Forbidden -ParameterFilter { $Uri -like 'https://eastus2.*' }
                $vms = @(1..60 | ForEach-Object { & $MetricVm $_ 'eastus2' }) + @(61..65 | ForEach-Object { & $MetricVm $_ 'westus2' })
                $sink = New-CollectionIssueSink
                $u = Get-VmUtilization -Vms $vms -IssueSink $sink
                @($u.Keys).Count | Should -Be 5
                @($u.Keys | Where-Object { $_ -match 'vm6[1-5]$' }).Count | Should -Be 5
                # Two failing batches (50 and 10 VMs) of three attempts each, and one batch that works.
                Should -Invoke Invoke-RestMethod -ModuleName Rightsizing -Times 7 -Exactly
                $issues = @(Get-CollectionIssue -Sink $sink)
                $issues.Count | Should -Be 1
                $issues[0].Api | Should -Be 'Azure Monitor metrics (rightsizing)'
                $issues[0].SubscriptionId | Should -Be 's1'
                $issues[0].Region | Should -Be 'eastus2'
                $issues[0].Effect | Should -Be 'Rightsizing shows Insufficient Data for 60 VM(s) in this scope.'
            }

            It 'gives the reason that the body of the answer states, with the identity masked' {
                Mock Invoke-RestMethod -ModuleName Rightsizing -MockWith $Forbidden
                $sink = New-CollectionIssueSink
                [void](Get-VmUtilization -Vms @(& $MetricVm 1 'eastus2') -IssueSink $sink)
                $message = @(Get-CollectionIssue -Sink $sink)[0].Message
                $message | Should -Match '403 \(Forbidden\)'
                $message | Should -Match 'AuthorizationFailed'
                $message | Should -Match 'microsoft\.insights/metrics/read'
                $message | Should -Match "object id '\*\*\*\*'"
                $message | Should -Match 'j\*\*\*\*@contoso\.com'
                $message | Should -Not -Match 'jane\.doe|11111111-2222'
            }

            It 'records an answer that is empty' {
                Mock Invoke-RestMethod -ModuleName Rightsizing { $null }
                $sink = New-CollectionIssueSink
                $u = Get-VmUtilization -Vms @(& $MetricVm 1 'eastus2') -IssueSink $sink
                @($u.Keys).Count | Should -Be 0
                @(Get-CollectionIssue -Sink $sink)[0].Message | Should -Be 'The call returned no data.'
            }

            It 'writes a warning when it has no sink to record to' {
                Mock Invoke-RestMethod -ModuleName Rightsizing -MockWith $Forbidden
                $output = @(Get-VmUtilization -Vms @(& $MetricVm 1 'eastus2') 3>&1)
                $warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
                $warnings.Count | Should -Be 1
                "$($warnings[0])" | Should -Match '^Azure Monitor metrics \(rightsizing\) \(eastus2, subscription s1\): .*AuthorizationFailed.* Rightsizing shows Insufficient Data for 1 VM\(s\) in this scope\.$'
            }

            It 'records a replayed call that the snapshot has no answer for, without calling Azure' {
                Mock Invoke-RestMethod -ModuleName Rightsizing -MockWith $SeriesMock
                $snapshot = Join-Path $TestDrive 'empty-snapshot'
                New-Item -ItemType Directory $snapshot -Force | Out-Null
                $env:VMSKU_SNAPSHOT_DIR = $snapshot; $env:VMSKU_SNAPSHOT_MODE = 'Replay'
                try {
                    $sink = New-CollectionIssueSink
                    $u = Get-VmUtilization -Vms @(& $MetricVm 1 'eastus2') -IssueSink $sink
                }
                finally { Remove-Item Env:\VMSKU_SNAPSHOT_DIR, Env:\VMSKU_SNAPSHOT_MODE -ErrorAction SilentlyContinue }
                @($u.Keys).Count | Should -Be 0
                Should -Invoke Invoke-RestMethod -ModuleName Rightsizing -Times 0 -Exactly
                @(Get-CollectionIssue -Sink $sink).Count | Should -Be 1
                @(Get-CollectionIssue -Sink $sink)[0].Message | Should -Match 'The snapshot has no recorded response'
            }
        }
    }

    Describe 'Opportunity' {
        It 'flags low utilization and suggests the half size that passes every check, without touching the primary' {
            $ctx = Get-RightsizingContext
            $r = Get-RightsizingOpportunity -Utilization $LowUse -Primary $RsPrimary -RegionCatalog (New-HalfSizeCatalog) -MemoryGB 32 @ctx
            $r.Status | Should -Be 'Potential Rightsizing Opportunity'
            $r.SuggestedSku | Should -Be 'Standard_D4s_v5'
            $r.MemUsedP95Pct | Should -Be 12.5
            $r.Note | Should -Match '^P95 of hourly average CPU 7%, highest hourly maximum 85% / memory used 12\.5%\. Evaluate after migration; not applied to the retirement recommendation\.$'
            $RsPrimary.SkuName | Should -Be 'Standard_D8s_v5'
        }

        It 'does not suggest a half size that fails a check for the VM: <Case>' -ForEach @(
            @{ Case = 'the NIC limit'; Nics = 3; Disks = 0; Zones = $null; Restrict = $false; Reason = 'Standard_D4s_v5: NIC Count: VM has 3 NICs; target max 2' }
            @{ Case = 'the data disk limit'; Nics = 1; Disks = 12; Zones = $null; Restrict = $false; Reason = 'Standard_D4s_v5: Data Disk Count: VM has 12 data disks; target max 8' }
            @{ Case = 'a subscription restriction'; Nics = 1; Disks = 0; Zones = $null; Restrict = $true; Reason = 'Standard_D4s_v5: availability: Restricted' }
            @{ Case = 'zone availability'; Nics = 1; Disks = 0; Zones = @('1'); Restrict = $false; Reason = 'Standard_D4s_v5: Region / Zone: Not Available in zone 1' }
        ) {
            $catalog = New-HalfSizeCatalog
            if ($Restrict) { $catalog['standard_d4s_v5'].LocationRestricted = $true }
            if ($Zones) { $catalog['standard_d4s_v5'].Zones = @('2', '3') }
            $ctx = Get-RightsizingContext -Nics $Nics -Zones $Zones -DataDisks $Disks
            $r = Get-RightsizingOpportunity -Utilization $LowUse -Primary $RsPrimary -RegionCatalog $catalog -MemoryGB 32 @ctx
            $r.Status | Should -Be 'Potential Rightsizing Opportunity'
            $r.SuggestedSku | Should -BeNullOrEmpty
            $r.Note | Should -Match ([regex]::Escape("No smaller size is suggested: no 4-vCPU size passes the mandatory checks for this VM ($Reason)."))
        }

        It 'never suggests a constrained-vCPU size, however the catalog is built' {
            foreach ($order in 1..6) {
                $catalog = New-HalfSizeCatalog
                Add-ConstrainedSize $catalog 'Standard_D8-4s_v5' 8 4 32
                Add-ConstrainedSize $catalog 'Standard_D16-4s_v5' 16 4 64
                Add-ConstrainedSize $catalog 'Standard_D32-4s_v5' 32 4 128
                $shuffled = @{}
                foreach ($key in ($catalog.Keys | Sort-Object { Get-Random })) { $shuffled[$key] = $catalog[$key] }
                $ctx = Get-RightsizingContext
                (Get-RightsizingOpportunity -Utilization $LowUse -Primary $RsPrimary -RegionCatalog $shuffled -MemoryGB 32 @ctx).SuggestedSku | Should -Be 'Standard_D4s_v5'
            }
        }

        It 'suggests nothing when only constrained-vCPU sizes have the half vCPU count' {
            $catalog = @{ 'standard_d8s_v5' = $SkuCat['standard_d8s_v5'] }
            Add-ConstrainedSize $catalog 'Standard_D8-4s_v5' 8 4 32
            $ctx = Get-RightsizingContext
            $r = Get-RightsizingOpportunity -Utilization $LowUse -Primary $RsPrimary -RegionCatalog $catalog -MemoryGB 32 @ctx
            $r.SuggestedSku | Should -BeNullOrEmpty
            $r.Note | Should -Match "No smaller size is suggested: the dsv5 series has no unconstrained 4-vCPU size for this VM's region and subscription\."
        }

        It 'suggests nothing for <Case>' -ForEach @(
            @{ Case = 'a constrained-vCPU recommended size'; Sku = 'Standard_D16-8s_v5'; Vcpu = 8; Reason = 'the recommended size is a constrained-vCPU size' }
            @{ Case = 'a recommended size with 2 vCPUs'; Sku = 'Standard_D2s_v5'; Vcpu = 2; Reason = 'the recommended size has 2 vCPUs or fewer' }
        ) {
            $ctx = Get-RightsizingContext
            $r = Get-RightsizingOpportunity -Utilization $LowUse -Primary ([pscustomobject]@{ SkuName = $Sku; vCPUs = $Vcpu }) -RegionCatalog (New-HalfSizeCatalog) -MemoryGB 32 @ctx
            $r.Status | Should -Be 'Potential Rightsizing Opportunity'
            $r.SuggestedSku | Should -BeNullOrEmpty
            $r.Note | Should -Match ([regex]::Escape("No smaller size is suggested: $Reason."))
        }

        It 'still flags the signal but suggests no size when the VM details are not given' {
            $r = Get-RightsizingOpportunity -Utilization $LowUse -Primary $RsPrimary -RegionCatalog (New-HalfSizeCatalog) -MemoryGB 32
            $r.Status | Should -Be 'Potential Rightsizing Opportunity'
            $r.SuggestedSku | Should -BeNullOrEmpty
            $r.Note | Should -Match 'the VM details needed to check a smaller size were not provided'
        }

        It 'reports no opportunity when <Case>' -ForEach @(
            @{ Case = 'CPU is busy'; Use = [pscustomobject]@{ CpuP95 = 60; CpuMax = 95; MemAvailP05Bytes = 28GB; Samples = 720 }; MemUsed = 12.5 }
            @{ Case = 'memory is in use'; Use = [pscustomobject]@{ CpuP95 = 7; CpuMax = 30; MemAvailP05Bytes = 17GB; Samples = 720 }; MemUsed = 46.9 }
            @{ Case = 'no memory is left at the 5th percentile'; Use = [pscustomobject]@{ CpuP95 = 7; CpuMax = 30; MemAvailP05Bytes = 0; Samples = 720 }; MemUsed = 100 }
        ) {
            $ctx = Get-RightsizingContext
            $r = Get-RightsizingOpportunity -Utilization $Use -Primary $RsPrimary -RegionCatalog (New-HalfSizeCatalog) -MemoryGB 32 @ctx
            $r.Status | Should -Be 'No Opportunity'
            $r.SuggestedSku | Should -BeNullOrEmpty
            $r.MemUsedP95Pct | Should -Be $MemUsed
        }

        It 'judges on CPU alone, and says so, when the guest reports no memory metric' {
            $use = [pscustomobject]@{ CpuP95 = 7; CpuMax = 30; MemAvailP05Bytes = $null; Samples = 720 }
            $ctx = Get-RightsizingContext
            $r = Get-RightsizingOpportunity -Utilization $use -Primary $RsPrimary -RegionCatalog (New-HalfSizeCatalog) -MemoryGB 32 @ctx
            $r.Status | Should -Be 'Potential Rightsizing Opportunity'
            $r.MemUsedP95Pct | Should -BeNullOrEmpty
            $r.Note | Should -Match 'memory used n/a \(guest metric unavailable\)'
        }

        It 'reports insufficient data without metrics or with less than seven days of them' {
            (Get-RightsizingOpportunity -Utilization $null -Primary $null -RegionCatalog @{} -MemoryGB 8).Status | Should -Be 'Insufficient Data'
            $short = [pscustomobject]@{ CpuP95 = 7; CpuMax = 30; MemAvailP05Bytes = 28GB; Samples = 167 }
            (Get-RightsizingOpportunity -Utilization $short -Primary $RsPrimary -RegionCatalog (New-HalfSizeCatalog) -MemoryGB 32).Status | Should -Be 'Insufficient Data'
        }
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

Describe 'Azure CLI calls: retries and failures' {
    BeforeAll {
        # A fake az that answers the first $FailFirst calls with an error and then prints $Output. Every call is a new process,
        # so the number of calls is kept in a file.
        function script:New-FlakyAz {
            param([int]$FailFirst, [string]$ErrorText, [string]$Output = '[{"n":1}]')
            $counter = Join-Path $TestDrive ('flaky-' + [guid]::NewGuid().ToString('N') + '.txt')
            $body = @"
`$counter = '$counter'
`$seen = if (Test-Path -LiteralPath `$counter) { [int](Get-Content -LiteralPath `$counter -Raw) } else { 0 }
Set-Content -LiteralPath `$counter -Value (`$seen + 1)
if (`$seen -lt $FailFirst) { Write-Error '$ErrorText' -ErrorAction Continue; exit 1 }
Write-Output '$Output'
exit 0
"@
            [pscustomobject]@{ Counter = $counter; Body = $body }
        }
        function script:Get-FakeAzCalls { param($Az) [int](Get-Content -LiteralPath $Az.Counter -Raw) }
        $script:SleepLog = Join-Path $TestDrive 'sleeps.txt'
        function script:Get-Sleeps { if (Test-Path -LiteralPath $script:SleepLog) { @(Get-Content -LiteralPath $script:SleepLog | ForEach-Object { [double]$_ }) } else { @() } }
    }
    BeforeEach {
        Remove-Item -LiteralPath $SleepLog -ErrorAction SilentlyContinue
        $env:VMSKU_TEST_SLEEP_LOG = $SleepLog
        Mock Start-Sleep -ModuleName Common { Add-Content -LiteralPath $env:VMSKU_TEST_SLEEP_LOG -Value $Seconds }
    }
    AfterEach { Remove-Item Env:\VMSKU_TEST_SLEEP_LOG -ErrorAction SilentlyContinue }

    It 'retries a throttled call with a growing pause and returns the answer of the call that succeeds' {
        $az = New-FlakyAz -FailFirst 2 -ErrorText 'ERROR: (429) Too Many Requests.'
        $result = Use-FakeAz -Body $az.Body -Action { Invoke-AzJson -Arguments @('vm', 'list-usage') }
        @($result)[0].n | Should -Be 1
        Get-FakeAzCalls $az | Should -Be 3
        $sleeps = @(Get-Sleeps)
        $sleeps.Count | Should -Be 2
        # 2^attempt seconds plus up to two seconds of jitter.
        $sleeps[0] | Should -BeGreaterOrEqual 2
        $sleeps[0] | Should -BeLessOrEqual 4
        $sleeps[1] | Should -BeGreaterOrEqual 4
        $sleeps[1] | Should -BeLessOrEqual 6
    }

    It 'treats "<Text>" as a temporary failure' -ForEach @(
        @{ Text = 'ERROR: (TooManyRequests) The request was throttled.' }
        @{ Text = 'ERROR: The service is temporarily unavailable (503).' }
        @{ Text = 'ERROR: ServiceUnavailable' }
        @{ Text = 'ERROR: ConnectionReset by the remote host' }
        @{ Text = 'ERROR: The operation timed out.' }
    ) {
        $az = New-FlakyAz -FailFirst 1 -ErrorText $Text
        @(Use-FakeAz -Body $az.Body -Action { Invoke-AzJson -Arguments @('vm', 'list-usage') }).Count | Should -Be 1
        Get-FakeAzCalls $az | Should -Be 2
        @(Get-Sleeps).Count | Should -Be 1
    }

    It 'does not retry a failure that is not temporary' {
        $az = New-FlakyAz -FailFirst 5 -ErrorText 'ERROR: (AuthorizationFailed) The client does not have authorization.'
        { Use-FakeAz -Body $az.Body -Action { Invoke-AzJson -Arguments @('vm', 'list-usage') } } | Should -Throw '*az vm list-usage failed (exit 1)*AuthorizationFailed*'
        Get-FakeAzCalls $az | Should -Be 1
        @(Get-Sleeps).Count | Should -Be 0
    }

    It 'gives up after the retries and throws the reason with the identity masked' {
        $az = New-FlakyAz -FailFirst 99 -ErrorText 'ERROR: (429) Too Many Requests for jane.doe@contoso.com.'
        $message = try { Use-FakeAz -Body $az.Body -Action { Invoke-AzJson -Arguments @('vm', 'list-usage') }; $null } catch { $_.Exception.Message }
        $message | Should -Match 'az vm list-usage failed \(exit 1\)'
        $message | Should -Match '429'
        $message | Should -Match 'j\*\*\*\*@contoso\.com'
        $message | Should -Not -Match 'jane\.doe'
        # One call and three retries, with pauses of about 2, 4 and 8 seconds.
        Get-FakeAzCalls $az | Should -Be 4
        $sleeps = @(Get-Sleeps)
        $sleeps.Count | Should -Be 3
        $sleeps[2] | Should -BeGreaterOrEqual 8
        $sleeps[2] | Should -BeLessOrEqual 10
    }

    It 'retries as often as -MaxRetries says' -ForEach @(
        @{ Retries = 0; Calls = 1 }
        @{ Retries = 1; Calls = 2 }
        @{ Retries = 2; Calls = 3 }
    ) {
        $az = New-FlakyAz -FailFirst 99 -ErrorText 'ERROR: (429) Too Many Requests.'
        { Use-FakeAz -Body $az.Body -Action { Invoke-AzJson -Arguments @('vm', 'list-usage') -MaxRetries $Retries } } | Should -Throw
        Get-FakeAzCalls $az | Should -Be $Calls
        @(Get-Sleeps).Count | Should -Be $Retries
    }

    It 'with -AllowFailure returns nothing and the reason once the retries are used up' {
        $az = New-FlakyAz -FailFirst 99 -ErrorText 'ERROR: (429) Too Many Requests.'
        $result = Use-FakeAz -Body $az.Body -Action {
            $failure = $null
            $answer = Invoke-AzJson -Arguments @('vm', 'list-usage') -AllowFailure -Failure ([ref]$failure)
            [pscustomobject]@{ Answer = $answer; Failure = $failure }
        }
        $result.Answer | Should -BeNullOrEmpty
        $result.Failure | Should -Match '429'
        Get-FakeAzCalls $az | Should -Be 4
    }

    It 'with -AllowFailure still returns the answer when a retry succeeds' {
        $az = New-FlakyAz -FailFirst 1 -ErrorText 'ERROR: (429) Too Many Requests.'
        $result = Use-FakeAz -Body $az.Body -Action {
            $failure = $null
            $answer = Invoke-AzJson -Arguments @('vm', 'list-usage') -AllowFailure -Failure ([ref]$failure)
            [pscustomobject]@{ Answer = $answer; Failure = $failure }
        }
        @($result.Answer)[0].n | Should -Be 1
        $result.Failure | Should -BeNullOrEmpty
    }
}

Describe 'Resource Graph queries through az: pages, chunks and failures' {
    BeforeAll {
        # A fake az that answers a query in three pages of two, two and one rows, chained by skip tokens, and writes each call to a
        # log. $FailAt names the skip token whose page answers with an error.
        $script:PagingAz = {
            param([string]$Log, [string]$FailAt = '__none__')
            @"
`$log = '$Log'
Add-Content -LiteralPath `$log -Value (`$args -join ' ')
`$i = [array]::IndexOf(@(`$args), '--skip-token')
`$token = if (`$i -ge 0) { @(`$args)[`$i + 1] } else { '' }
if (`$token -eq '$FailAt') { Write-Error 'ERROR: (Forbidden) access denied' -ErrorAction Continue; exit 1 }
switch (`$token) {
    '' { Write-Output '{"data":[{"id":"a"},{"id":"b"}],"skip_token":"t1"}' }
    't1' { Write-Output '{"data":[{"id":"c"},{"id":"d"}],"skip_token":"t2"}' }
    't2' { Write-Output '{"data":[{"id":"e"}],"skip_token":null}' }
}
exit 0
"@
        }
    }

    It 'follows the skip token through every page and asks for the page size it was given' {
        $log = Join-Path $TestDrive 'pages.log'
        $rows = Use-FakeAz -Body (& $PagingAz $log) -Action { Invoke-ArgQuery -Query 'Resources' -PageSize 2 }
        @($rows | ForEach-Object id) | Should -Be @('a', 'b', 'c', 'd', 'e')
        $calls = @(Get-Content $log)
        $calls.Count | Should -Be 3
        $calls[0] | Should -Match '--first 2'
        $calls[0] | Should -Not -Match '--skip-token'
        $calls[1] | Should -Match '--skip-token t1'
        $calls[2] | Should -Match '--skip-token t2'
    }

    It 'sends no subscription filter when no subscription is given' {
        $log = Join-Path $TestDrive 'nofilter.log'
        [void](Use-FakeAz -Body (& $PagingAz $log) -Action { Invoke-ArgQuery -Query 'Resources' })
        @(Get-Content $log) | ForEach-Object { $_ | Should -Not -Match '--subscriptions' }
    }

    It 'splits the subscriptions into chunks and pages each chunk' {
        $log = Join-Path $TestDrive 'chunks.log'
        $rows = Use-FakeAz -Body (& $PagingAz $log) -Action { Invoke-ArgQuery -Query 'Resources' -SubscriptionIds @('s1', 's2', 's3', 's4', 's5') -ChunkSize 2 -PageSize 2 }
        @($rows).Count | Should -Be 15
        $calls = @(Get-Content $log)
        $calls.Count | Should -Be 9
        @($calls | Where-Object { $_ -match '--subscriptions s1 s2( |$)' }).Count | Should -Be 3
        @($calls | Where-Object { $_ -match '--subscriptions s3 s4( |$)' }).Count | Should -Be 3
        @($calls | Where-Object { $_ -match '--subscriptions s5( |$)' }).Count | Should -Be 3
    }

    It 'stops with the failure of a later page instead of returning the rows it has' {
        $log = Join-Path $TestDrive 'later-page.log'
        { Use-FakeAz -Body (& $PagingAz $log 't1') -Action { Invoke-ArgQuery -Query 'Resources' -PageSize 2 } } | Should -Throw '*az graph query*failed (exit 1)*Forbidden*'
        @(Get-Content $log).Count | Should -Be 2
    }

    It 'returns the rows it has, and says where it stopped, when the failure is tolerated' {
        $log = Join-Path $TestDrive 'tolerated.log'
        $result = Use-FakeAz -Body (& $PagingAz $log 't2') -Action {
            $failure = $null
            $rows = @(Invoke-ArgQuery -Query 'Resources' -PageSize 2 -AllowFailure -Failure ([ref]$failure))
            [pscustomobject]@{ Rows = $rows; Failure = $failure }
        }
        @($result.Rows | ForEach-Object id) | Should -Be @('a', 'b', 'c', 'd')
        $result.Failure | Should -Match 'Forbidden'
        $result.Failure | Should -Match 'stopped after 4 rows'
    }
}

Describe 'Resource Graph queries over REST: retries, chunks and failures' {
    BeforeEach {
        Mock -ModuleName Inventory Invoke-AzJson { [pscustomobject]@{ accessToken = 'tok' } }
        Mock -ModuleName Inventory Start-Sleep {}
        # The answer of the mocked REST call comes from process variables because a mock keeps no state of its own: the first
        # VMSKU_TEST_FAIL_FIRST calls fail with the HTTP status VMSKU_TEST_STATUS, and a request that continues a query
        # (it has a $skipToken) fails when VMSKU_TEST_FAIL_PAGE2 is set.
        $env:VMSKU_TEST_CALLS = '0'; $env:VMSKU_TEST_FAIL_FIRST = '0'; $env:VMSKU_TEST_STATUS = '429'; $env:VMSKU_TEST_FAIL_PAGE2 = ''
        Mock -ModuleName Inventory Invoke-RestMethod {
            $env:VMSKU_TEST_CALLS = 1 + [int]$env:VMSKU_TEST_CALLS
            $options = ($Body | ConvertFrom-Json).options
            $continues = $options.PSObject.Properties.Name -contains '$skipToken'
            if ([int]$env:VMSKU_TEST_CALLS -le [int]$env:VMSKU_TEST_FAIL_FIRST -or ($continues -and $env:VMSKU_TEST_FAIL_PAGE2)) {
                $status = if ($continues -and $env:VMSKU_TEST_FAIL_PAGE2) { [int]$env:VMSKU_TEST_FAIL_PAGE2 } else { [int]$env:VMSKU_TEST_STATUS }
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]$status)
                throw ([Microsoft.PowerShell.Commands.HttpResponseException]::new("Response status code does not indicate success: $status.", $response))
            }
            if (-not $continues -and $env:VMSKU_TEST_FAIL_PAGE2) { [pscustomobject]@{ data = @([pscustomobject]@{ id = 'a' }, [pscustomobject]@{ id = 'b' }); '$skipToken' = 'page2' } }
            else { [pscustomobject]@{ data = @([pscustomobject]@{ id = 'a' }) } }
        }
    }
    AfterEach { Remove-Item Env:\VMSKU_TEST_CALLS, Env:\VMSKU_TEST_FAIL_FIRST, Env:\VMSKU_TEST_STATUS, Env:\VMSKU_TEST_FAIL_PAGE2 -ErrorAction SilentlyContinue }

    It 'retries HTTP <Status> once and returns the rows of the call that succeeds' -ForEach @(
        @{ Status = '429' }, @{ Status = '500' }, @{ Status = '502' }, @{ Status = '503' }, @{ Status = '504' }
    ) {
        $env:VMSKU_TEST_FAIL_FIRST = '1'; $env:VMSKU_TEST_STATUS = $Status
        @(Invoke-ArgQuery -Query 'Resources' -SubscriptionIds @('s1') -TenantId 't-other').Count | Should -Be 1
        Should -Invoke Invoke-RestMethod -ModuleName Inventory -Times 2 -Exactly
        Should -Invoke Start-Sleep -ModuleName Inventory -Times 1 -Exactly -ParameterFilter { $Seconds -eq 2 }
    }

    It 'gives up after four attempts, pausing 2, 4 and 8 seconds, and throws the reason' {
        $env:VMSKU_TEST_FAIL_FIRST = '99'; $env:VMSKU_TEST_STATUS = '503'
        { Invoke-ArgQuery -Query 'Resources' -SubscriptionIds @('s1') -TenantId 't-other' } | Should -Throw 'Resource Graph query failed for tenant t-other: Response status code does not indicate success: 503.'
        Should -Invoke Invoke-RestMethod -ModuleName Inventory -Times 4 -Exactly
        Should -Invoke Start-Sleep -ModuleName Inventory -Times 3 -Exactly
        foreach ($expected in 2, 4, 8) { Should -Invoke Start-Sleep -ModuleName Inventory -Times 1 -Exactly -ParameterFilter { $Seconds -eq $expected } }
    }

    It 'does not retry HTTP <Status>' -ForEach @(
        @{ Status = '400' }, @{ Status = '401' }, @{ Status = '403' }, @{ Status = '404' }
    ) {
        $env:VMSKU_TEST_FAIL_FIRST = '99'; $env:VMSKU_TEST_STATUS = $Status
        { Invoke-ArgQuery -Query 'Resources' -SubscriptionIds @('s1') -TenantId 't-other' } | Should -Throw "Resource Graph query failed for tenant t-other: Response status code does not indicate success: $Status."
        Should -Invoke Invoke-RestMethod -ModuleName Inventory -Times 1 -Exactly
        Should -Invoke Start-Sleep -ModuleName Inventory -Times 0 -Exactly
    }

    It 'returns the rows it has and says where it stopped when a later page fails and the failure is tolerated' {
        $env:VMSKU_TEST_FAIL_PAGE2 = '403'
        $failure = $null
        $rows = @(Invoke-ArgQuery -Query 'Resources' -SubscriptionIds @('s1') -TenantId 't-other' -AllowFailure -Failure ([ref]$failure))
        @($rows | ForEach-Object id) | Should -Be @('a', 'b')
        $failure | Should -Be 'Response status code does not indicate success: 403. (the query stopped after 2 rows)'
    }

    It 'stops with the failure of a later page when it is not tolerated' {
        $env:VMSKU_TEST_FAIL_PAGE2 = '403'
        { Invoke-ArgQuery -Query 'Resources' -SubscriptionIds @('s1') -TenantId 't-other' } | Should -Throw '*Response status code does not indicate success: 403.*'
    }

    It 'sends one request per chunk of subscriptions, each asking for the page size it was given' {
        [void](Invoke-ArgQuery -Query 'Resources' -SubscriptionIds @('s1', 's2', 's3', 's4', 's5') -TenantId 't-other' -ChunkSize 2 -PageSize 500)
        Should -Invoke Invoke-RestMethod -ModuleName Inventory -Times 3 -Exactly
        Should -Invoke Invoke-RestMethod -ModuleName Inventory -Times 2 -Exactly -ParameterFilter { @(($Body | ConvertFrom-Json).subscriptions).Count -eq 2 }
        Should -Invoke Invoke-RestMethod -ModuleName Inventory -Times 1 -Exactly -ParameterFilter { @(($Body | ConvertFrom-Json).subscriptions).Count -eq 1 }
        Should -Invoke Invoke-RestMethod -ModuleName Inventory -Times 3 -Exactly -ParameterFilter { (($Body | ConvertFrom-Json).options.'$top') -eq 500 }
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
        # The retirement target no longer repeats the quota status (it is in the details and the quota table); the Microsoft status shows no date.
        $cells[3].Value | Should -Not -Match 'Quota'
        $cells[2].Value | Should -Match "<span class='badge [^']+'>End of Life</span><div class='sub'>"
        $cells[2].Value | Should -Not -Match '\d{4}-\d{2}-\d{2}|remaining|&middot;'
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
        $html | Should -Match 'class="footer-status( warn)?"'
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
            $assumed = Get-ConfidenceTooltip ([pscustomobject]@{ Level = 'HIGH'; LowReasons = @(); ValidationItems = @() }) -Assumptions @('The disk controller was assumed to be SCSI.')
            $assumed | Should -Match '^Confidence in the recommended size: HIGH\. No outstanding items'
            $assumed | Should -Match "Assumed, without changing the level:`n- The disk controller was assumed to be SCSI\.$"
            (Get-ConfidenceTooltip ([pscustomobject]@{ Level = 'LOW'; LowReasons = @('x'); ValidationItems = @() }) -Assumptions @('assumed y')) | Should -Match "Validate first:`n- Blocker: x`nAssumed, without changing the level:`n- assumed y$"
            Get-ConfidenceTooltip ([pscustomobject]@{ Level = 'HIGH'; LowReasons = @(); ValidationItems = @() }) | Should -Not -Match 'Assumed'
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
