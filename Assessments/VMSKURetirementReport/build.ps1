<#
.SYNOPSIS
    Build / quality tasks for VMSKURetirementReport.
.DESCRIPTION
    Tasks (run in order given):
      Bootstrap  Install and verify the exact locked Pester and PSScriptAnalyzer versions.
      Lint       PSScriptAnalyzer with PSScriptAnalyzerSettings.psd1 (fails on any Error/Warning finding).
      Version    Check the version is identical in Common.psm1, SKILL.md metadata and CHANGELOG.md.
      Test       Pester unit + end-to-end tests (mock Azure CLI, no Azure access). -CI writes JUnit XML.
      Sample     Regenerate examples/sample-report offline (mock Azure CLI, cached catalog, fixed date, price snapshot).
      Package    Zip the skill into dist/VMSKURetirementReport-v<version>.zip (+ .sha256).
      Clean      Remove test results.
.EXAMPLE
    ./build.ps1                          # Bootstrap, Lint, Version, Test
.EXAMPLE
    ./build.ps1 -Task Sample, Package
#>
[CmdletBinding()]
param(
    [ValidateSet('Bootstrap', 'Lint', 'Version', 'Test', 'Sample', 'Package', 'Clean')]
    [string[]]$Task = @('Bootstrap', 'Lint', 'Version', 'Test'),
    [switch]$CI
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

function Get-ModuleTreeHash {
    param([Parameter(Mandatory)][string]$ModuleBase)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        foreach ($file in Get-ChildItem -LiteralPath $ModuleBase -File -Recurse | Sort-Object FullName) {
            $relative = $file.FullName.Substring($ModuleBase.Length).TrimStart('\', '/').Replace('\', '/')
            $relativeBytes = [Text.Encoding]::UTF8.GetBytes($relative)
            [void]$sha.TransformBlock($relativeBytes, 0, $relativeBytes.Length, $null, 0)
            $content = [IO.File]::ReadAllBytes($file.FullName)
            [void]$sha.TransformBlock($content, 0, $content.Length, $null, 0)
        }
        [void]$sha.TransformFinalBlock([byte[]]::new(0), 0, 0)
        return [Convert]::ToHexString($sha.Hash).ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-LockedModule {
    param([Parameter(Mandatory)][string]$Name)
    $lock = $dependencies[$Name]
    $module = Get-Module -ListAvailable $Name | Where-Object Version -eq ([version]$lock.Version) | Select-Object -First 1
    if (-not $module) { throw "$Name $($lock.Version) is not installed. Run ./build.ps1 -Task Bootstrap." }
    $actual = Get-ModuleTreeHash -ModuleBase $module.ModuleBase
    if ($actual -ne $lock.TreeHash) { throw "$Name $($lock.Version) failed integrity verification. Expected $($lock.TreeHash), got $actual." }
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

function Invoke-Sample {
    $dest = Join-Path $repo 'examples/sample-report'
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
    $cmd = "$offlineRest`n`$env:PATH = '$mock$sep' + `$env:PATH; & '$script' -OutputPath '$tmp' -OfflineCatalog -AsOfDate '$($script:SampleAsOfDate)' -IncludePricing -ThrottleLimit 2"
    & pwsh -NoProfile -Command $cmd
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $tmp 'index.html'))) { throw 'Sample: generation failed.' }
    # Keep only portable report artifacts; run.log and data/ contain machine / user specific details.
    Remove-Item (Join-Path $tmp 'run.log'), (Join-Path $tmp 'data') -Recurse -Force -ErrorAction SilentlyContinue
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

function Invoke-Package {
    $v = Get-RepoVersion
    $dist = Join-Path $repo 'dist'
    New-Item -ItemType Directory $dist -Force | Out-Null
    $zip = Join-Path $dist "VMSKURetirementReport-v$v.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) ("vmskuretirementreport-pkg-" + [guid]::NewGuid().ToString('N'))
    $target = Join-Path $stage 'vm-sku-retirement-report'
    New-Item -ItemType Directory $stage -Force | Out-Null
    Copy-Item $skill $target -Recurse
    Copy-Item (Join-Path $repo 'LICENSE') $target
    Copy-Item (Join-Path $repo 'THIRD-PARTY-NOTICES.md') $target
    Compress-Archive -Path $target -DestinationPath $zip
    Remove-Item $stage -Recurse -Force
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -Path "$zip.sha256" -Value "$hash  $(Split-Path $zip -Leaf)" -NoNewline
    Write-Host "Package: $zip ($hash)"
}

function Invoke-Clean {
    Remove-Item (Join-Path $repo 'TestResults') -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Clean: done.'
}

foreach ($t in $Task) {
    Write-Host "==> $t" -ForegroundColor Cyan
    switch ($t) {
        'Bootstrap' { Invoke-Bootstrap }
        'Lint' { Invoke-Lint }
        'Version' { Invoke-VersionCheck }
        'Test' { Invoke-Test -CiMode:$CI }
        'Sample' { Invoke-Sample }
        'Package' { Invoke-Package }
        'Clean' { Invoke-Clean }
    }
}
