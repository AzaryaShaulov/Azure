<#
.SYNOPSIS
    Build / quality tasks for VMSKURetirementReport.
.DESCRIPTION
    Tasks (run in order given):
      Bootstrap  Install and verify the exact locked Pester and PSScriptAnalyzer versions.
      Lint       PSScriptAnalyzer with PSScriptAnalyzerSettings.psd1 (fails on any Error/Warning finding).
      Version    Check the version is identical in Common.psm1, SKILL.md metadata and CHANGELOG.md.
      Test       Pester unit + end-to-end tests (mock Azure CLI, no Azure access). -CI writes JUnit XML.
      Sample     Regenerate examples/sample-report offline with --check-modernization (mock Azure CLI, cached catalog, fixed date, price snapshot).
      SampleDiff Build the same sample in a scratch folder and fail when it differs from the committed examples/sample-report
                 (generation timestamps and line endings are ignored). Does not change the repository.
      Package    Zip the skill (without its tests, plus README, CHANGELOG, LICENSE and third-party notices) into
                 dist/VMSKURetirementReport-v<version>.zip (+ .sha256), then check the ZIP's contents. -DistPath changes the folder.
      Clean      Remove test results.
.EXAMPLE
    ./build.ps1                          # Bootstrap, Lint, Version, Test
.EXAMPLE
    ./build.ps1 -Task Sample, Package
.EXAMPLE
    ./build.ps1 -Task Package -DistPath $env:TEMP\vmsku-package     # try the package without touching dist/
#>
[CmdletBinding()]
param(
    [ValidateSet('Bootstrap', 'Lint', 'Version', 'Test', 'Sample', 'SampleDiff', 'Package', 'Clean')]
    [string[]]$Task = @('Bootstrap', 'Lint', 'Version', 'Test'),
    [switch]$CI,
    [string]$DistPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = $PSScriptRoot
$skill = Join-Path $repo 'skills/vm-sku-retirement-report'
$dependencies = Import-PowerShellDataFile (Join-Path $repo 'dependencies.psd1')
# Fixed as-of date for the committed sample report; bump it when refreshing the sample against a new catalog.
$script:SampleAsOfDate = '2026-10-05'

function Get-RepoVersion {
    Import-Module (Join-Path $skill 'scripts/modules/Common.psm1') -Force -DisableNameChecking
    return (Get-ToolVersion)
}

# Files an installer adds beside a module: PowerShellGet's PSGetModuleInfo.xml, the repository signature and NuGet
# packaging parts. They differ between installers and operating systems and are not part of the module, so they are not hashed.
$script:ModuleHashExclude = '^(PSGetModuleInfo\.xml|\.signature\.p7s|\[Content_Types\]\.xml|[^/]+\.nuspec|_rels/.*|package/.*)$'

function Get-ModuleManifest {
    <# One "relative-path<TAB>sha256" line per module file, in ordinal path order; identical on every OS and installer. #>
    param([Parameter(Mandatory)][string]$ModuleBase)
    $base = (Resolve-Path -LiteralPath $ModuleBase).Path
    $files = @{}
    # -Force lists hidden files on every OS (a leading dot hides a file on Linux and macOS).
    foreach ($file in Get-ChildItem -LiteralPath $base -File -Recurse -Force) {
        $relative = $file.FullName.Substring($base.Length).TrimStart('\', '/').Replace('\', '/')
        if ($relative -notmatch $script:ModuleHashExclude) { $files[$relative] = $file.FullName }
    }
    $paths = [string[]]$files.Keys
    # Sort-Object FullName is culture-sensitive and orders paths differently on Windows and Linux; ordinal order does not.
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    foreach ($path in $paths) { "{0}`t{1}" -f $path, (Get-FileHash -LiteralPath $files[$path] -Algorithm SHA256).Hash.ToLowerInvariant() }
}

function Get-ModuleTreeHash {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Manifest)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((@($Manifest) -join "`n") + "`n"))).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-LockedModule {
    param([Parameter(Mandatory)][string]$Name)
    $lock = $dependencies[$Name]
    $module = Get-Module -ListAvailable $Name | Where-Object Version -eq ([version]$lock.Version) | Select-Object -First 1
    if (-not $module) { throw "$Name $($lock.Version) is not installed. Run ./build.ps1 -Task Bootstrap." }
    $manifest = @(Get-ModuleManifest -ModuleBase $module.ModuleBase)
    $actual = Get-ModuleTreeHash -Manifest $manifest
    if ($actual -ne $lock.TreeHash) {
        # Written to the host, not the error message, so a CI log keeps the whole manifest for comparison with a local run.
        Write-Host "$Name $($lock.Version) at $($module.ModuleBase): $($manifest.Count) hashed file(s)"
        $manifest | ForEach-Object { Write-Host "  $_" }
        throw "$Name $($lock.Version) failed integrity verification. Expected $($lock.TreeHash), got $actual."
    }
    return $module
}

function Invoke-Bootstrap {
    foreach ($name in @('Pester', 'PSScriptAnalyzer')) {
        $lock = $dependencies[$name]
        $module = Get-Module -ListAvailable $name | Where-Object Version -eq ([version]$lock.Version) | Select-Object -First 1
        if (-not $module) {
            Install-Module $name -RequiredVersion $lock.Version -Repository PSGallery -Scope CurrentUser -Force
        }
        [void](Get-LockedModule -Name $name)
    }
    Write-Host 'Bootstrap: exact locked Pester and PSScriptAnalyzer versions verified.'
}

function Invoke-Lint {
    $module = Get-LockedModule -Name PSScriptAnalyzer
    Import-Module $module.Path -Force
    $findings = @(Invoke-ScriptAnalyzer -Path $repo -Recurse -Settings (Join-Path $repo 'PSScriptAnalyzerSettings.psd1') |
            Where-Object { $_.ScriptPath -notmatch '[\\/](dist|examples|TestResults)[\\/]' })
    if ($findings.Count) {
        $findings | Format-Table Severity, RuleName, ScriptName, Line, Message -AutoSize -Wrap | Out-String -Width 220 | Write-Host
        throw "Lint: $($findings.Count) finding(s)."
    }
    Write-Host 'Lint: no findings.'
}

function Invoke-VersionCheck {
    $v = Get-RepoVersion
    $skillMd = Get-Content (Join-Path $skill 'SKILL.md') -Raw
    $m = [regex]::Match($skillMd, '(?m)^\s+version:\s*"?([0-9]+\.[0-9]+\.[0-9]+)"?\s*$')
    $changelog = Get-Content (Join-Path $repo 'CHANGELOG.md') -Raw
    $c = [regex]::Match($changelog, '(?m)^## \[([0-9]+\.[0-9]+\.[0-9]+)\]')
    $problems = @()
    if (-not $m.Success -or $m.Groups[1].Value -ne $v) { $problems += "SKILL.md metadata.version '$($m.Groups[1].Value)' <> module '$v'" }
    if (-not $c.Success -or $c.Groups[1].Value -ne $v) { $problems += "CHANGELOG.md latest '$($c.Groups[1].Value)' <> module '$v'" }
    if ($problems) { throw "Version: $($problems -join '; ')" }
    Write-Host "Version: $v consistent."
}

function Invoke-Test {
    param([switch]$CiMode)
    $module = Get-LockedModule -Name Pester
    Import-Module $module.Path -Force
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = Join-Path $skill 'tests'
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = if ($CiMode) { 'Detailed' } else { 'Normal' }
    if ($CiMode) {
        $out = Join-Path $repo 'TestResults'
        New-Item -ItemType Directory $out -Force | Out-Null
        $cfg.TestResult.Enabled = $true
        $cfg.TestResult.OutputFormat = 'JUnitXml'
        $cfg.TestResult.OutputPath = Join-Path $out 'pester.xml'
    }
    $r = Invoke-Pester -Configuration $cfg
    if ($r.FailedCount -gt 0 -or $r.Result -ne 'Passed') { throw "Test: $($r.FailedCount) failed." }
    Write-Host "Test: $($r.PassedCount) passed."
}

function New-SampleReport {
    <# Generates the sample report offline into a new scratch folder and returns the folder (run.log and data/ removed). #>
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("vmskuretirementreport-sample-" + [guid]::NewGuid().ToString('N'))
    $mock = Join-Path $skill 'tests/mock'
    $script = Join-Path $skill 'scripts/Invoke-VMSKURetirementReport.ps1'
    $prices = Join-Path $skill 'tests/fixtures/retail-prices-eastus2.json'
    $sep = [System.IO.Path]::PathSeparator
    # Reproducible and fully offline: mock Azure CLI, cached Microsoft evidence, a fixed as-of date and a retail-price
    # snapshot. The shim fails closed so any other outbound REST call aborts the build instead of reaching the network.
    $offlineRest = @"
function global:Invoke-RestMethod {
    param([string]`$Uri, [string]`$Method, `$Headers, [string]`$ContentType, `$Body, [int]`$TimeoutSec)
    if (`$Uri -like 'https://prices.azure.com/*') { return (Get-Content -LiteralPath '$prices' -Raw | ConvertFrom-Json) }
    throw "Sample build is offline; blocked request to `$Uri"
}
"@
    $cmd = "$offlineRest`n`$env:PATH = '$mock$sep' + `$env:PATH; & '$script' --check-modernization -OutputPath '$tmp' -OfflineCatalog -AsOfDate '$($script:SampleAsOfDate)' -ThrottleLimit 2"
    # Sent to the console: the function's output is the folder it returns.
    & pwsh -NoProfile -Command $cmd | Out-Host
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $tmp 'index.html'))) {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        throw 'Sample: generation failed.'
    }
    # Keep only portable report artifacts; run.log and data/ contain machine / user specific details.
    Remove-Item (Join-Path $tmp 'run.log'), (Join-Path $tmp 'data') -Recurse -Force -ErrorAction SilentlyContinue
    return $tmp
}

function Invoke-Sample {
    $dest = Join-Path $repo 'examples/sample-report'
    $tmp = New-SampleReport
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    New-Item -ItemType Directory (Split-Path $dest) -Force | Out-Null
    Move-Item $tmp $dest
    $user = if ($env:USERNAME) { $env:USERNAME } elseif ($env:USER) { $env:USER } else { $null }
    $patterns = @([regex]::Escape([System.IO.Path]::GetTempPath().TrimEnd('\', '/')))
    if ($user -and $user.Length -ge 4) { $patterns += "\b$([regex]::Escape($user))\b" }
    $leak = @(Get-ChildItem $dest -Recurse -File | Select-String -Pattern $patterns -List)
    if ($leak.Count) { throw "Sample: local user/path details found in $(($leak | ForEach-Object Path) -join ', ')" }
    Write-Host "Sample: written to $dest"
}

# The generation time is the only content that differs between two builds of the sample.
$script:SampleVolatileLine = '^\s*"generatedUtc":|^\| Generated \(UTC\) \|'

function Get-SampleLine {
    <# The lines of a sample file as they are compared: line endings normalised (git checks the files out as LF or CRLF) and the generation time replaced by a constant, so line numbers stay those of the file. #>
    param([Parameter(Mandatory)][string]$Path)
    $text = [System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
    @($text -split "`n" | ForEach-Object { if ($_ -match $script:SampleVolatileLine) { '<generation time>' } else { $_ } })
}

function Compare-SampleReport {
    <# Compares a freshly built sample with the committed one; returns one message per difference (none when they match). #>
    param([Parameter(Mandatory)][string]$ExpectedPath, [Parameter(Mandatory)][string]$ActualPath)
    $files = { param($root) @(Get-ChildItem -LiteralPath $root -File -Recurse -Force | ForEach-Object { $_.FullName.Substring((Resolve-Path -LiteralPath $root).Path.Length).TrimStart('\', '/').Replace('\', '/') } | Sort-Object) }
    $expectedFiles = & $files $ExpectedPath
    $actualFiles = & $files $ActualPath
    foreach ($name in $expectedFiles | Where-Object { $_ -notin $actualFiles }) { "$name is in the committed sample but a fresh build does not write it" }
    foreach ($name in $actualFiles | Where-Object { $_ -notin $expectedFiles }) { "$name is written by a fresh build but is not in the committed sample" }
    foreach ($name in $expectedFiles | Where-Object { $_ -in $actualFiles }) {
        $expected = @(Get-SampleLine -Path (Join-Path $ExpectedPath $name))
        $actual = @(Get-SampleLine -Path (Join-Path $ActualPath $name))
        $length = [math]::Max($expected.Count, $actual.Count)
        $differing = @(for ($i = 0; $i -lt $length; $i++) { if ($i -ge $expected.Count -or $i -ge $actual.Count -or $expected[$i] -cne $actual[$i]) { $i } })
        if ($differing.Count -eq 0) { continue }
        $first = $differing[0]
        $show = { param($lines, $i) if ($i -lt $lines.Count) { $t = $lines[$i].Trim(); if ($t.Length -gt 140) { $t.Substring(0, 140) + '...' } else { $t } } else { '(no such line)' } }
        "$name differs in $($differing.Count) line(s); the first is line $($first + 1): committed `"$(& $show $expected $first)`" but a fresh build gives `"$(& $show $actual $first)`""
    }
}

function Invoke-SampleDiff {
    $expected = Join-Path $repo 'examples/sample-report'
    if (-not (Test-Path -LiteralPath $expected)) { throw "SampleDiff: there is no committed sample at $expected. Run ./build.ps1 -Task Sample." }
    $actual = New-SampleReport
    try {
        $problems = @(Compare-SampleReport -ExpectedPath $expected -ActualPath $actual)
        if ($problems.Count) {
            $problems | ForEach-Object { Write-Host "  $_" }
            throw "SampleDiff: the committed sample differs from a fresh build ($($problems.Count) file(s)). If the change is intended, run ./build.ps1 -Task Sample, review the diff and commit it."
        }
        Write-Host 'SampleDiff: the committed sample matches a fresh build (generation time and line endings ignored).'
    }
    finally { Remove-Item $actual -Recurse -Force -ErrorAction SilentlyContinue }
}

# Files copied from the project root into the package (the README is part of the skill folder).
$script:PackageRootFiles = @('LICENSE', 'THIRD-PARTY-NOTICES.md', 'CHANGELOG.md')

function Get-PackageFilePath {
    <# The files a release ZIP must contain, as paths below its top-level skill folder: the skill folder without its tests, and the root files. #>
    param([Parameter(Mandatory)][string]$SkillPath)
    $base = (Resolve-Path -LiteralPath $SkillPath).Path
    foreach ($file in Get-ChildItem -LiteralPath $base -File -Recurse -Force) {
        $relative = $file.FullName.Substring($base.Length).TrimStart('\', '/').Replace('\', '/')
        # The tests, their fixtures and the mock Azure CLI are for contributors, not for a customer.
        if ($relative -notmatch '^tests/') { $relative }
    }
    $script:PackageRootFiles
}

function Test-PackageContent {
    <# Compares the entries of a release ZIP with what it must contain; returns one message per problem (none when it is correct). #>
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)][string]$SkillPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ZipPath).Path)
    try { $entries = @($archive.Entries | Where-Object { $_.Name } | ForEach-Object { $_.FullName.Replace('\', '/') }) }
    finally { $archive.Dispose() }
    $expected = @(Get-PackageFilePath -SkillPath $SkillPath | ForEach-Object { "vm-sku-retirement-report/$_" })
    foreach ($name in @($expected | Where-Object { $_ -notin $entries } | Sort-Object)) { "missing from the ZIP: $name" }
    foreach ($name in @($entries | Where-Object { $_ -notin $expected } | Sort-Object)) { "not expected in the ZIP: $name" }
}

function Invoke-Package {
    param([string]$DistPath)
    $v = Get-RepoVersion
    $dist = if ($DistPath) { $DistPath } else { Join-Path $repo 'dist' }
    New-Item -ItemType Directory $dist -Force | Out-Null
    $zip = Join-Path $dist "VMSKURetirementReport-v$v.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) ("vmskuretirementreport-pkg-" + [guid]::NewGuid().ToString('N'))
    $target = Join-Path $stage 'vm-sku-retirement-report'
    New-Item -ItemType Directory $target -Force | Out-Null
    try {
        foreach ($item in Get-ChildItem -LiteralPath $skill -Force | Where-Object Name -ne 'tests') { Copy-Item -LiteralPath $item.FullName -Destination $target -Recurse }
        foreach ($name in $script:PackageRootFiles) { Copy-Item -LiteralPath (Join-Path $repo $name) -Destination $target }
        Compress-Archive -Path $target -DestinationPath $zip
    }
    finally { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
    $problems = @(Test-PackageContent -ZipPath $zip -SkillPath $skill)
    if ($problems.Count) {
        Remove-Item $zip -Force
        throw "Package: the ZIP does not hold what it should: $($problems -join '; ')"
    }
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -Path "$zip.sha256" -Value "$hash  $(Split-Path $zip -Leaf)" -NoNewline
    Write-Host "Package: $zip ($hash)"
}

function Invoke-Clean {
    Remove-Item (Join-Path $repo 'TestResults') -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Clean: done.'
}

# Dot-sourced by the tests: define the functions only.
if ($MyInvocation.InvocationName -eq '.') { return }

foreach ($t in $Task) {
    Write-Host "==> $t" -ForegroundColor Cyan
    switch ($t) {
        'Bootstrap' { Invoke-Bootstrap }
        'Lint' { Invoke-Lint }
        'Version' { Invoke-VersionCheck }
        'Test' { Invoke-Test -CiMode:$CI }
        'Sample' { Invoke-Sample }
        'SampleDiff' { Invoke-SampleDiff }
        'Package' { Invoke-Package -DistPath $DistPath }
        'Clean' { Invoke-Clean }
    }
}
