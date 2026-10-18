<#
.SYNOPSIS
    Scans the tracked files of a git repository for personal data and secrets, and checks the identity of new commits.

.DESCRIPTION
    Rules (each finding names its rule):
      secret          private keys, cloud keys, tokens, SAS signatures, connection strings, literal passwords, signed webhook URLs
      email           an e-mail address outside the synthetic and placeholder domains
      tenant-domain   an *.onmicrosoft.com name other than contoso
      guid            a GUID that is not an obvious placeholder (11111111-..., aaaaaaaa-...) and is not on the allowlist
      local-path      a user profile path such as C:\Users\<name>, /Users/<name> or /home/<name>
      public-ip       a public IPv4 address (documentation, private and loopback ranges are fine)
      output-file     a tracked assessment output (run.log, assessment.json, snapshot.json, ...) outside examples/sample-report
      commit-identity with -BaseRef: a commit after it whose author or committer e-mail is not a GitHub noreply address
    With -BaseRef the script also warns (it does not fail) about added or changed images, which need a human look because
    no scan can tell whether a screenshot shows a real subscription or user name.

    Matches are masked in the output (first characters and length) so a finding does not republish the data. The scanner
    and its allowlist are excluded from the scan. The allowlist (.github/pii-allowlist.json) holds exact values with a reason.

.PARAMETER Root
    The repository root. Defaults to the repository that contains this script.
.PARAMETER AllowlistPath
    The allowlist file. Defaults to .github/pii-allowlist.json under the root.
.PARAMETER BaseRef
    A commit or branch. Enables the commit-identity rule and the image warning for the commits after it.
.PARAMETER SelfTest
    Builds a throw-away repository with planted violations and checks that every rule fires, that the allowlist works and that
    clean content passes. Does not scan the real repository.
#>
[CmdletBinding()]
param(
    [string]$Root,
    [string]$AllowlistPath,
    [string]$BaseRef,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ScannerExcludes = @('.github/scripts/Test-RepoPii.ps1', '.github/pii-allowlist.json')
$script:SampleReportPrefix = 'Assessments/VMSKURetirementReport/examples/sample-report/'
$script:EmailAllowed = '@(contoso\.(com|example)|example\.(com|org|net|example)|fabrikam\.(org|com)|users\.noreply\.github\.com|domain\.com|yourdomain\.com)$'
$script:PlaceholderGuid = '^(([0-9a-f])\2{7}|12345678)-'
$script:ImageExtensions = '\.(png|jpe?g|gif|webp|svg|bmp|ico)$'
$script:OutputFileNames = '(^|/)(run\.log|assessment\.json|snapshot\.json|vm-inventory\.json|vm-assessment\.csv|quota-impact\.csv|candidates\.csv|retirement-evidence\.json)$'

function Invoke-Git {
    param([string]$Root, [string[]]$Arguments)
    $out = & git -C $Root -c core.quotepath=false @Arguments 2>&1
    # git grep exits 1 when nothing matches; anything above that is an error.
    if ($LASTEXITCODE -gt 1) { throw "git $($Arguments -join ' ') failed: $($out -join ' ')" }
    @($out | ForEach-Object { "$_" })
}

function Get-MaskedMatch {
    param([string]$Text)
    if ($Text.Length -le 4) { return '****' }
    "$($Text.Substring(0, 4))*** ($($Text.Length) characters)"
}

function Find-Pattern {
    <# git grep with the pattern in a file (no shell quoting problems); returns file, line and the matched text. #>
    param([string]$Root, [string]$Pattern, [switch]$WholeLine)
    $patternFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($patternFile, $Pattern)
        $excludes = @($script:ScannerExcludes | ForEach-Object { ":(exclude)$_" })
        $grepOptions = if ($WholeLine) { @('-I', '-n', '-i', '-E') } else { @('-I', '-n', '-o', '-i', '-E') }
        $lines = Invoke-Git -Root $Root -Arguments (@('grep') + $grepOptions + @('-f', $patternFile, '--', '.') + $excludes)
    }
    finally { Remove-Item -LiteralPath $patternFile -ErrorAction SilentlyContinue }
    foreach ($line in $lines) {
        $m = [regex]::Match($line, '^(?<file>.+?):(?<line>\d+):(?<match>.*)$')
        if ($m.Success) { [pscustomobject]@{ File = $m.Groups['file'].Value; Line = [int]$m.Groups['line'].Value; Match = $m.Groups['match'].Value } }
    }
}

function Read-Allowlist {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    $doc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $entries = @($doc.entries)
    foreach ($e in $entries) {
        foreach ($field in 'rule', 'value', 'reason') {
            if (-not ($e.PSObject.Properties.Name -contains $field) -or [string]::IsNullOrWhiteSpace([string]$e.$field)) { throw "Allowlist entry without '$field': $($e | ConvertTo-Json -Compress)" }
        }
        if ($e.value -match '[*?]') { throw "Allowlist values are exact; no wildcards: $($e.value)" }
    }
    $entries
}

function Test-Allowed {
    param($Allowlist, [string]$Rule, [string]$Value, [string]$File)
    foreach ($e in $Allowlist) {
        if ($e.rule -ne $Rule -or $e.value -ine $Value) { continue }
        if ($e.PSObject.Properties.Name -contains 'file' -and $e.file -and $e.file -ne $File) { continue }
        return $true
    }
    $false
}

function Test-RepoPii {
    <# Returns findings (rule, file, line, masked match) and warnings (image review) for the repository at $Root. #>
    param([string]$Root, [string]$AllowlistPath, [string]$BaseRef)
    $allow = @(Read-Allowlist -Path $AllowlistPath)
    $findings = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[string]
    $add = { param($Rule, $File, $Line, $Text) $findings.Add([pscustomobject]@{ Rule = $Rule; File = $File; Line = $Line; Match = (Get-MaskedMatch $Text) }) }

    $secretPatterns = @(
        '-----BEGIN [A-Z ]*PRIVATE KEY-----'
        'AKIA[0-9A-Z]{16}'
        'gh[pousr]_[A-Za-z0-9]{30,}'
        'AccountKey=[A-Za-z0-9+/=]{20,}'
        'SharedAccessSignature=[^ ]{10,}'
        '[?&]sig=[A-Za-z0-9%]{30,}'
        'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}'
        '(password|passwd|client_?secret|api_?key)[[:space:]]*[:=][[:space:]]*["'']([^"''[:space:]]){8,}'
        'logic\.azure\.com[^ "'']*sig='
    )
    foreach ($p in $secretPatterns) { foreach ($f in @(Find-Pattern -Root $Root -Pattern $p)) { & $add 'secret' $f.File $f.Line $f.Match } }

    foreach ($f in @(Find-Pattern -Root $Root -Pattern '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')) {
        if ($f.Match -notmatch $script:EmailAllowed -and -not (Test-Allowed $allow 'email' $f.Match $f.File)) { & $add 'email' $f.File $f.Line $f.Match }
    }
    foreach ($f in @(Find-Pattern -Root $Root -Pattern '[A-Za-z0-9-]+\.onmicrosoft\.com')) {
        if ($f.Match -notmatch '^contoso' -and -not (Test-Allowed $allow 'tenant-domain' $f.Match $f.File)) { & $add 'tenant-domain' $f.File $f.Line $f.Match }
    }
    foreach ($f in @(Find-Pattern -Root $Root -Pattern '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')) {
        if ($f.Match.ToLowerInvariant() -match $script:PlaceholderGuid) { continue }
        # The allowlist never applies to the committed sample report, which must contain synthetic values only.
        $inSample = $f.File.StartsWith($script:SampleReportPrefix)
        if ($inSample -or -not (Test-Allowed $allow 'guid' $f.Match $f.File)) { & $add 'guid' $f.File $f.Line $f.Match }
    }
    foreach ($f in @(Find-Pattern -Root $Root -Pattern 'C:\\Users\\[A-Za-z0-9._-]+|/Users/[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+')) {
        $name = (($f.Match -split '[\\/]')[-1]).TrimEnd('.', '-', '_')
        if ($name -in 'Public', 'Default', 'user', 'username', 'you', 'name', 'me', 'runner', 'vsts', 'admin') { continue }
        if (-not (Test-Allowed $allow 'local-path' $f.Match $f.File)) { & $add 'local-path' $f.File $f.Line $f.Match }
    }
    foreach ($f in @(Find-Pattern -Root $Root -Pattern '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' -WholeLine)) {
        # Four-part version numbers (for example the contentVersion of an ARM template) look like addresses.
        if ($f.Match -match '(?i)version') { continue }
        $f = [pscustomobject]@{ File = $f.File; Line = $f.Line; Match = [regex]::Match($f.Match, '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b').Value }
        $o = @($f.Match -split '\.' | ForEach-Object { [int]$_ })
        if (@($o | Where-Object { $_ -gt 255 }).Count -gt 0) { continue }
        $nonPublic = ($o[0] -in 0, 10, 127, 255) -or ($o[0] -eq 192 -and $o[1] -eq 168) -or ($o[0] -eq 172 -and $o[1] -in 16..31) -or ($o[0] -eq 169 -and $o[1] -eq 254) `
            -or ($o[0] -eq 192 -and $o[1] -eq 0 -and $o[2] -eq 2) -or ($o[0] -eq 198 -and $o[1] -eq 51 -and $o[2] -eq 100) -or ($o[0] -eq 203 -and $o[1] -eq 0 -and $o[2] -eq 113)
        if (-not $nonPublic -and -not (Test-Allowed $allow 'public-ip' $f.Match $f.File)) { & $add 'public-ip' $f.File $f.Line $f.Match }
    }
    foreach ($file in @(Invoke-Git -Root $Root -Arguments @('ls-files'))) {
        if ($file -match $script:OutputFileNames -and -not $file.StartsWith($script:SampleReportPrefix) -and -not (Test-Allowed $allow 'output-file' $file $file)) { & $add 'output-file' $file 0 $file }
    }

    if ($BaseRef) {
        foreach ($row in @(Invoke-Git -Root $Root -Arguments @('log', '--format=%h|%ae|%ce', "$BaseRef..HEAD"))) {
            $parts = $row -split '\|'
            if ($parts.Count -lt 3) { continue }
            foreach ($mail in $parts[1], $parts[2]) {
                if ($mail -notmatch '@users\.noreply\.github\.com$' -and $mail -ne 'noreply@github.com' -and -not (Test-Allowed $allow 'commit-identity' $mail $parts[0])) {
                    & $add 'commit-identity' "commit $($parts[0])" 0 $mail
                }
            }
        }
        $images = @(Invoke-Git -Root $Root -Arguments @('diff', '--name-only', '--diff-filter=AM', "$BaseRef...HEAD") | Where-Object { $_ -match $script:ImageExtensions })
        foreach ($i in $images) { $warnings.Add("Image added or changed: $i. Check by eye that it shows no real subscription, tenant, user or server names.") }
    }
    [pscustomobject]@{ Findings = $findings.ToArray(); Warnings = $warnings.ToArray() }
}

function Invoke-SelfTest {
    $script:selfTestFailed = $false
    $check = { param($Name, $Condition) Write-Host ('  [{0}] {1}' -f $(if ($Condition) { 'PASS' } else { 'FAIL' }), $Name); if (-not $Condition) { $script:selfTestFailed = $true } }
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('pii-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir | Out-Null
    try {
        $git = { param([string[]]$a) & git -C $dir -c user.name=t -c user.email=t@users.noreply.github.com -c commit.gpgsign=false @a 2>&1 | Out-Null }
        & $git @('init', '-q')
        $good = "Contact jane.doe@contoso.com or noc@fabrikam.org.`nGUID 11111111-2222-3333-4444-555555555555 and aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.`nDocs address 203.0.113.9, private 10.1.2.3.`nPath C:\Users\<you>\x and C:\Users\Public.`nsecret = <your-secret>`n"
        Set-Content -LiteralPath (Join-Path $dir 'good.md') -Value $good
        & $git @('add', '-A'); & $git @('commit', '-q', '-m', 'good')
        $first = (& git -C $dir rev-parse HEAD).Trim()
        $clean = Test-RepoPii -Root $dir -AllowlistPath $null -BaseRef $first
        & $check 'clean content, with placeholders and documentation values, has no finding' (@($clean.Findings).Count -eq 0)

        $akia = 'AKIA' + 'A1B2C3D4E5F6G7H8'
        $bad = @(
            "key $akia"
            'password = "hunter2hunter2"'
            'contact real.person@gmail.com'
            'tenant corp123.onmicrosoft.com'
            'subscription 305f553d-016a-4e67-8701-47488e7b1437'
            'path C:\Users\realuser\Documents'
            'server 8.8.4.4'
        ) -join "`n"
        Set-Content -LiteralPath (Join-Path $dir 'bad.txt') -Value $bad
        New-Item -ItemType Directory -Path (Join-Path $dir 'x') | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'x/assessment.json') -Value '{}'
        $sampleDir = Join-Path $dir 'Assessments/VMSKURetirementReport/examples/sample-report'
        New-Item -ItemType Directory -Path $sampleDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sampleDir 'assessment.json') -Value '{ "id": "9c1c4a6e-1111-4222-8333-444455556666" }'
        & $git @('add', '-A'); & $git @('-c', 'user.email=person@example-personal.net', 'commit', '-q', '-m', 'bad')
        Set-Content -LiteralPath (Join-Path $dir 'pic.png') -Value 'x'
        & $git @('add', '-A'); & $git @('commit', '-q', '-m', 'image')
        $r = Test-RepoPii -Root $dir -AllowlistPath $null -BaseRef $first
        $rules = @($r.Findings | ForEach-Object Rule | Sort-Object -Unique)
        foreach ($rule in 'secret', 'email', 'tenant-domain', 'guid', 'local-path', 'public-ip', 'output-file', 'commit-identity') {
            & $check "rule '$rule' fires on planted data" ($rules -contains $rule)
        }
        & $check 'the planted values are masked, not republished' (@($r.Findings | Where-Object { $_.Match -match 'AKIAA1B2C3D4E5F6G7H8|hunter2hunter2|real\.person@gmail' }).Count -eq 0)
        & $check 'the sample report may hold only synthetic values' (@($r.Findings | Where-Object { $_.Rule -eq 'guid' -and $_.File -like '*sample-report*' }).Count -eq 1)
        & $check 'an added image gives a warning, not a finding' (@($r.Warnings | Where-Object { $_ -match 'pic\.png' }).Count -eq 1 -and @($r.Findings | Where-Object File -eq 'pic.png').Count -eq 0)
        & $check 'the output file inside the sample report is allowed, the other one is not' (@($r.Findings | Where-Object { $_.Rule -eq 'output-file' }).Count -eq 1)

        $allowFile = Join-Path $dir 'allow.json'
        $entries = @(@{ rule = 'guid'; value = '305f553d-016a-4e67-8701-47488e7b1437'; reason = 'self-test'; file = 'bad.txt' }, @{ rule = 'email'; value = 'real.person@gmail.com'; reason = 'self-test' })
        Set-Content -LiteralPath $allowFile -Value (@{ entries = $entries } | ConvertTo-Json -Depth 4)
        $r2 = Test-RepoPii -Root $dir -AllowlistPath $allowFile -BaseRef $first
        & $check 'allowlisted values are no longer findings' (@($r2.Findings | Where-Object { $_.Rule -eq 'email' }).Count -eq 0 -and @($r2.Findings | Where-Object { $_.Rule -eq 'guid' -and $_.File -eq 'bad.txt' }).Count -eq 0)
        & $check 'an allowlist entry is limited to its file when it names one' (@($r2.Findings | Where-Object { $_.Rule -eq 'guid' -and $_.File -like '*sample-report*' }).Count -eq 1)
        Set-Content -LiteralPath $allowFile -Value '{ "entries": [ { "rule": "guid", "value": "x" } ] }'
        & $check 'an allowlist entry without a reason is rejected' ($(try { [void](Read-Allowlist -Path $allowFile); $false } catch { $true }))
        Set-Content -LiteralPath $allowFile -Value '{ "entries": [ { "rule": "guid", "value": "abc*", "reason": "r" } ] }'
        & $check 'an allowlist wildcard is rejected' ($(try { [void](Read-Allowlist -Path $allowFile); $false } catch { $true }))
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($script:selfTestFailed) { Write-Host 'Self-test FAILED.'; exit 1 }
    Write-Host 'Self-test passed.'
}

if ($SelfTest) { Invoke-SelfTest; return }

if (-not $Root) { $Root = (& git -C $PSScriptRoot rev-parse --show-toplevel).Trim() }
if (-not $AllowlistPath) { $AllowlistPath = Join-Path $Root '.github/pii-allowlist.json' }
$result = Test-RepoPii -Root $Root -AllowlistPath $AllowlistPath -BaseRef $BaseRef
$inActions = [bool]$env:GITHUB_ACTIONS

foreach ($w in $result.Warnings) { if ($inActions) { Write-Host "::warning::$w" } else { Write-Warning $w } }
if ($result.Findings.Count -eq 0) {
    Write-Host "PII scan: no findings in $(@(Invoke-Git -Root $Root -Arguments @('ls-files')).Count) tracked files$(if ($BaseRef) { " and the commits after $BaseRef" }). Warnings: $($result.Warnings.Count)."
    return
}
foreach ($f in $result.Findings) {
    $where = if ($f.Line -gt 0) { "$($f.File):$($f.Line)" } else { $f.File }
    if ($inActions -and $f.Line -gt 0) { Write-Host "::error file=$($f.File),line=$($f.Line)::[$($f.Rule)] $($f.Match)" }
    else { Write-Host ('[{0}] {1}  {2}' -f $f.Rule, $where, $f.Match) }
}
if ($env:GITHUB_STEP_SUMMARY) {
    $rows = $result.Findings | ForEach-Object { "| $($_.Rule) | ``$($_.File)$(if ($_.Line -gt 0) { ":$($_.Line)" })`` | $($_.Match) |" }
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ((@('## PII scan findings', '', '| Rule | Where | Match (masked) |', '|---|---|---|') + $rows) -join "`n")
}
Write-Host "PII scan: $($result.Findings.Count) finding(s). Fix the content, or add an exact value with a reason to .github/pii-allowlist.json."
exit 1
