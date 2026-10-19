#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Tests of the build tasks that decide what a customer receives (Package) and whether the committed sample is current
    (SampleDiff). build.ps1 is dot-sourced, which defines its functions without running a task.
#>
BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:ProjectRoot = Split-Path (Split-Path $SkillRoot -Parent) -Parent
    . (Join-Path $ProjectRoot 'build.ps1')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $script:ZipEntries = {
        param([string]$Zip)
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Zip)
        try { @($archive.Entries | Where-Object { $_.Name } | ForEach-Object { $_.FullName.Replace('\', '/') } | Sort-Object) }
        finally { $archive.Dispose() }
    }
}

Describe 'Release package' {
    BeforeAll {
        $script:Dist = Join-Path $TestDrive 'dist'
        Invoke-Package -DistPath $Dist *> $null
        $script:Zip = Join-Path $Dist "VMSKURetirementReport-v$(Get-RepoVersion).zip"
        $script:Entries = & $ZipEntries $Zip
    }

    It 'is written, with a checksum file that matches it, to the folder it is given' {
        $Zip | Should -Exist
        "$Zip.sha256" | Should -Exist
        $hash = (Get-FileHash $Zip -Algorithm SHA256).Hash.ToLowerInvariant()
        Get-Content "$Zip.sha256" -Raw | Should -Be "$hash  $(Split-Path $Zip -Leaf)"
    }

    It 'holds the skill without its tests, fixtures or mock Azure CLI' {
        @($Entries | Where-Object { $_ -match '/tests/' }).Count | Should -Be 0
        @($Entries | Where-Object { $_ -match 'fixtures|mock|\.Tests\.ps1$|[\\/]az\.ps1$' }).Count | Should -Be 0
    }

    It 'holds every other file of the skill, and the README, changelog, license and third-party notices' {
        $expected = @(Get-PackageFilePath -SkillPath $SkillRoot | ForEach-Object { "vm-sku-retirement-report/$_" } | Sort-Object)
        $Entries | Should -Be $expected
        foreach ($name in 'SKILL.md', 'README.md', 'CHANGELOG.md', 'LICENSE', 'THIRD-PARTY-NOTICES.md', 'scripts/Invoke-VMSKURetirementReport.ps1', 'scripts/Update-Catalogs.ps1', 'templates/report.css', 'data/retirement-catalog.json', 'references/methodology.md') {
            $Entries | Should -Contain "vm-sku-retirement-report/$name"
        }
        foreach ($module in Get-ChildItem (Join-Path $SkillRoot 'scripts/modules') -Filter '*.psm1') { $Entries | Should -Contain "vm-sku-retirement-report/scripts/modules/$($module.Name)" }
    }

    It 'has the same CHANGELOG as the repository' {
        $extract = Join-Path $TestDrive 'extract-changelog'
        Expand-Archive -LiteralPath $Zip -DestinationPath $extract
        (Get-Content (Join-Path $extract 'vm-sku-retirement-report/CHANGELOG.md') -Raw) | Should -Be (Get-Content (Join-Path $ProjectRoot 'CHANGELOG.md') -Raw)
    }

    It 'has a README with the disclaimer that lists everything at the top level of the package' {
        $readme = Get-Content (Join-Path $SkillRoot 'README.md') -Raw
        $readme | Should -Match 'provided "AS IS," without warranties or guarantees'
        $readme | Should -Match 'not an\s+(>\s+)?official Microsoft product'
        $readme | Should -Match 'Reader'
        $top = @($Entries | ForEach-Object { ($_ -replace '^vm-sku-retirement-report/', '') -split '/' | Select-Object -First 1 } | Sort-Object -Unique | Where-Object { $_ -ne 'README.md' })
        foreach ($name in $top) { $readme | Should -Match ([regex]::Escape($name)) -Because "the README lists what is in the folder, and $name is in it" }
    }

    It 'leaves the repository dist folder alone when it builds elsewhere' {
        $before = @(Get-ChildItem (Join-Path $ProjectRoot 'dist') -File | ForEach-Object { "$($_.Name) $($_.LastWriteTimeUtc.Ticks)" })
        $other = Join-Path $TestDrive 'other-dist'
        Invoke-Package -DistPath $other *> $null
        @(Get-ChildItem (Join-Path $ProjectRoot 'dist') -File | ForEach-Object { "$($_.Name) $($_.LastWriteTimeUtc.Ticks)" }) | Should -Be $before
    }

    Context 'the check of a finished ZIP' {
        BeforeAll {
            # A copy of the expected package tree that a test can damage.
            $script:NewTree = {
                param([string]$Name)
                $root = Join-Path $TestDrive $Name
                $skillCopy = Join-Path $root 'vm-sku-retirement-report'
                New-Item -ItemType Directory $skillCopy -Force | Out-Null
                foreach ($relative in Get-PackageFilePath -SkillPath $SkillRoot) {
                    $source = if ($relative -in $script:PackageRootFiles) { Join-Path $ProjectRoot $relative } else { Join-Path $SkillRoot $relative }
                    $destination = Join-Path $skillCopy $relative
                    New-Item -ItemType Directory (Split-Path $destination) -Force | Out-Null
                    Copy-Item -LiteralPath $source -Destination $destination
                }
                $root
            }
            $script:ZipOf = { param([string]$Root, [string]$Name) $z = Join-Path $TestDrive "$Name.zip"; Compress-Archive -Path (Join-Path $Root 'vm-sku-retirement-report') -DestinationPath $z; $z }
        }

        It 'accepts a package that holds exactly the expected files' {
            $root = & $NewTree 'tree-ok'
            @(Test-PackageContent -ZipPath (& $ZipOf $root 'ok') -SkillPath $SkillRoot).Count | Should -Be 0
        }

        It 'reports tests that were packaged by mistake' {
            $root = & $NewTree 'tree-tests'
            New-Item -ItemType Directory (Join-Path $root 'vm-sku-retirement-report/tests/mock') -Force | Out-Null
            Set-Content (Join-Path $root 'vm-sku-retirement-report/tests/mock/az.ps1') 'exit 0'
            @(Test-PackageContent -ZipPath (& $ZipOf $root 'with-tests') -SkillPath $SkillRoot) | Should -Be @('not expected in the ZIP: vm-sku-retirement-report/tests/mock/az.ps1')
        }

        It 'reports a file that is missing' {
            $root = & $NewTree 'tree-missing'
            Remove-Item (Join-Path $root 'vm-sku-retirement-report/README.md')
            Remove-Item (Join-Path $root 'vm-sku-retirement-report/templates/report.css')
            @(Test-PackageContent -ZipPath (& $ZipOf $root 'missing') -SkillPath $SkillRoot) | Should -Be @('missing from the ZIP: vm-sku-retirement-report/README.md', 'missing from the ZIP: vm-sku-retirement-report/templates/report.css')
        }
    }
}

Describe 'Release package, extracted' {
    It 'runs an assessment although it has no tests folder' {
        $extract = Join-Path $TestDrive 'extracted'
        $dist = Join-Path $TestDrive 'dist-run'
        Invoke-Package -DistPath $dist *> $null
        Expand-Archive -LiteralPath (Get-ChildItem $dist -Filter '*.zip').FullName -DestinationPath $extract
        $packaged = Join-Path $extract 'vm-sku-retirement-report'
        Join-Path $packaged 'tests' | Should -Not -Exist
        $out = Join-Path $TestDrive 'packaged-run'
        # The mock Azure CLI is not part of the package; borrow the repository's.
        $mock = Join-Path $PSScriptRoot 'mock'
        $log = & pwsh -NoProfile -Command "`$env:PATH='$mock$([System.IO.Path]::PathSeparator)' + `$env:PATH; & '$(Join-Path $packaged 'scripts/Invoke-VMSKURetirementReport.ps1')' -OutputPath '$out' -OfflineCatalog -AsOfDate '2026-09-24' -ThrottleLimit 2 -SkipPricing" 2>&1 | Out-String
        $log | Should -Match 'Outputs:'
        foreach ($file in 'assessment.json', 'vm-assessment.csv', 'executive-summary.md', 'index.html') { Join-Path $out $file | Should -Exist }
        (Get-Content (Join-Path $out 'assessment.json') -Raw | ConvertFrom-Json).summary.TotalVmsScanned | Should -Be 7
    }
}

Describe 'Sample comparison' {
    BeforeAll {
        $script:Pair = {
            param([hashtable]$Expected, [hashtable]$Actual, [string]$Name)
            $root = Join-Path $TestDrive $Name
            foreach ($side in @(@{ Dir = 'expected'; Files = $Expected }, @{ Dir = 'actual'; Files = $Actual })) {
                $dir = Join-Path $root $side.Dir
                New-Item -ItemType Directory $dir -Force | Out-Null
                foreach ($file in $side.Files.Keys) { [System.IO.File]::WriteAllText((Join-Path $dir $file), $side.Files[$file]) }
            }
            @{ Expected = (Join-Path $root 'expected'); Actual = (Join-Path $root 'actual') }
        }
        $script:Json = "{`n  `"generatedUtc`": `"2026-10-05T01:00:00.1234567Z`",`n  `"total`": 7,`n  `"name`": `"Contoso`"`n}`n"
        $script:Md = "# Summary`n`n| Item | Value |`n|---|---|`n| Generated (UTC) | 2026-10-05T01:00:00.1234567Z |`n| VMs | 7 |`n"
    }

    It 'finds no difference when only the generation time and the line endings differ' {
        $p = & $Pair @{ 'a.json' = $Json; 'b.md' = $Md } @{ 'a.json' = ($Json -replace '2026-10-05T01:00:00.1234567Z', '2026-10-09T17:30:12.9999999Z' -replace "`n", "`r`n"); 'b.md' = ($Md -replace 'T01:00:00.1234567Z', 'T23:59:59.0000001Z' -replace "`n", "`r`n") } 'same'
        @(Compare-SampleReport -ExpectedPath $p.Expected -ActualPath $p.Actual).Count | Should -Be 0
    }

    It 'names the file, the line and both texts when a value differs' {
        $p = & $Pair @{ 'a.json' = $Json; 'b.md' = $Md } @{ 'a.json' = ($Json -replace '"total": 7', '"total": 6'); 'b.md' = $Md } 'value'
        $problems = @(Compare-SampleReport -ExpectedPath $p.Expected -ActualPath $p.Actual)
        $problems.Count | Should -Be 1
        $problems[0] | Should -Be ('a.json differs in 1 line(s); the first is line 3: committed "{0}" but a fresh build gives "{1}"' -f '"total": 7,', '"total": 6,')
    }

    It 'counts every differing line and compares case-sensitively' {
        $p = & $Pair @{ 'b.md' = $Md } @{ 'b.md' = ($Md -replace '\| VMs \| 7 \|', '| vms | 8 |' -replace '# Summary', '# SUMMARY') } 'count'
        @(Compare-SampleReport -ExpectedPath $p.Expected -ActualPath $p.Actual)[0] | Should -Match '^b\.md differs in 2 line\(s\); the first is line 1: committed "# Summary" but a fresh build gives "# SUMMARY"$'
    }

    It 'reports a line that exists on one side only' {
        $p = & $Pair @{ 'b.md' = $Md.TrimEnd() } @{ 'b.md' = ($Md.TrimEnd() + "`n| Extra | 1 |") } 'longer'
        @(Compare-SampleReport -ExpectedPath $p.Expected -ActualPath $p.Actual)[0] | Should -Match 'the first is line 7: committed "\(no such line\)" but a fresh build gives "\| Extra \| 1 \|"'
    }

    It 'reports a file that only one side has' {
        $p = & $Pair @{ 'a.json' = $Json; 'old.md' = $Md } @{ 'a.json' = $Json; 'new.html' = '<p>x</p>' } 'files'
        @(Compare-SampleReport -ExpectedPath $p.Expected -ActualPath $p.Actual) | Should -Be @('old.md is in the committed sample but a fresh build does not write it', 'new.html is written by a fresh build but is not in the committed sample')
    }

    It 'treats an empty file as equal to an empty file' {
        $p = & $Pair @{ 'empty.csv' = '' } @{ 'empty.csv' = '' } 'empty'
        @(Compare-SampleReport -ExpectedPath $p.Expected -ActualPath $p.Actual).Count | Should -Be 0
    }

    It 'shortens a long differing line' {
        $long = 'x' * 300
        $p = & $Pair @{ 'a.md' = "$long`n" } @{ 'a.md' = "${long}y`n" } 'long'
        @(Compare-SampleReport -ExpectedPath $p.Expected -ActualPath $p.Actual)[0] | Should -Match ('committed "x{140}\.\.\." but a fresh build gives "x{140}\.\.\."')
    }

    It 'ignores only the generation time lines of the files the build writes' {
        '  "generatedUtc": "2026-10-05T01:00:00Z",' | Should -Match $script:SampleVolatileLine
        '| Generated (UTC) | 2026-10-05T01:00:00Z |' | Should -Match $script:SampleVolatileLine
        '| Assessment date (as of) | 2026-10-05 |' | Should -Not -Match $script:SampleVolatileLine
        '  "asOfDate": "2026-10-05",' | Should -Not -Match $script:SampleVolatileLine
    }
}
