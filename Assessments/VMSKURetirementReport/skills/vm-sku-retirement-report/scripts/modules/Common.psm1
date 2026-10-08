Set-StrictMode -Version Latest

# Single source of truth for the tool version (kept in sync with SKILL.md metadata and CHANGELOG.md by tests/build).
$script:ToolVersion = '1.1.0'

function Get-ToolVersion { return $script:ToolVersion }

$script:LogPhaseStart = $null

function Write-Phase {
    param([Parameter(Mandatory)][string]$Name)
    $script:LogPhaseStart = Get-Date
    Write-Host "=== $Name ===" -ForegroundColor Cyan
}

function Write-PhaseDone {
    param([string]$Detail = '')
    $secs = if ($script:LogPhaseStart) { [math]::Round(((Get-Date) - $script:LogPhaseStart).TotalSeconds, 1) } else { 0 }
    Write-Host ("    done{0} ({1}s)" -f $(if ($Detail) { ": $Detail" } else { '' }), $secs) -ForegroundColor DarkGray
}

# -- Snapshot record / replay of Azure reads (-SaveSnapshot / -FromSnapshot) --
# Mode and folder live in process environment variables so parallel runspaces see them. Requests are keyed without
# credentials, access tokens are never written, and the signed-in account is masked before it is saved.

function Get-SnapshotMode {
    if ($env:VMSKU_SNAPSHOT_DIR -and $env:VMSKU_SNAPSHOT_MODE -in 'Record', 'Replay') { return $env:VMSKU_SNAPSHOT_MODE }
    return $null
}

function Get-SnapshotEntryPath {
    param([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Request)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = [Convert]::ToHexString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Kind`n$Request"))).ToLowerInvariant() }
    finally { $sha.Dispose() }
    return Join-Path (Join-Path $env:VMSKU_SNAPSHOT_DIR 'responses') "$hash.json"
}

function Save-SnapshotEntry {
    param([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Request, [AllowNull()][string]$Text, [switch]$Failed)
    $path = Get-SnapshotEntryPath -Kind $Kind -Request $Request
    New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
    [ordered]@{ Kind = $Kind; Request = $Request; Failed = [bool]$Failed; Text = $Text } | ConvertTo-Json -Depth 3 -Compress |
        Set-Content -LiteralPath $path -Encoding utf8
}

function Read-SnapshotEntry {
    param([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Request)
    $path = Get-SnapshotEntryPath -Kind $Kind -Request $Request
    if (-not (Test-Path -LiteralPath $path)) {
        throw "The snapshot has no recorded response for this $Kind request. Replay with the same tenant, subscription and region scope as the capture, or capture a new snapshot with -SaveSnapshot."
    }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 5)
}

function Get-AzSnapshotRequest {
    <# Stable request key for an az command: '@file' arguments are replaced by the file content (temp paths differ per run). #>
    param([Parameter(Mandatory)][string[]]$Arguments)
    $parts = foreach ($a in $Arguments) {
        if ($a -like '@*' -and (Test-Path -LiteralPath $a.Substring(1) -PathType Leaf)) { '@' + (Get-Content -LiteralPath $a.Substring(1) -Raw) } else { $a }
    }
    return ($parts -join ' ')
}

function Hide-SnapshotAccount {
    <# Masks user.name in 'az account show/list' output before it is written to a snapshot. #>
    param([Parameter(Mandatory)][string]$Text)
    $o = $Text | ConvertFrom-Json -Depth 64
    $changed = $false
    foreach ($item in @($o)) {
        if (-not $item -or $item.PSObject.Properties.Name -notcontains 'user' -or -not $item.user) { continue }
        if ($item.user -is [string]) { $item.user = Get-MaskedAccount $item.user; $changed = $true }
        elseif ($item.user.PSObject.Properties.Name -contains 'name' -and $item.user.name) { $item.user.name = Get-MaskedAccount $item.user.name; $changed = $true }
    }
    if (-not $changed) { return $Text }
    return (ConvertTo-Json -InputObject $o -Depth 64 -Compress)
}

function Invoke-SnapshotRest {
    <#
    .SYNOPSIS
        Wraps one read-only ARM REST call. Record mode saves the response; Replay mode returns the saved response without
        calling Azure; otherwise the call runs live. -Request is the credential-free key (method, URL, body).
    #>
    param([Parameter(Mandatory)][string]$Request, [Parameter(Mandatory)][scriptblock]$Live)
    $mode = Get-SnapshotMode
    if ($mode -eq 'Replay') {
        $entry = Read-SnapshotEntry -Kind 'rest' -Request $Request
        if ($entry.Failed) { throw 'This request failed when the snapshot was captured.' }
        if ($null -eq $entry.Text) { return $null }
        return ($entry.Text | ConvertFrom-Json -Depth 100)
    }
    try { $resp = & $Live }
    catch {
        if ($mode -eq 'Record') { Save-SnapshotEntry -Kind 'rest' -Request $Request -Text $null -Failed }
        throw
    }
    if ($mode -eq 'Record') { Save-SnapshotEntry -Kind 'rest' -Request $Request -Text $(if ($null -ne $resp) { ConvertTo-Json -InputObject $resp -Depth 100 -Compress } else { $null }) }
    return $resp
}

function Invoke-AzJson {
    <#
    .SYNOPSIS
        Runs an Azure CLI command (read-only) and returns parsed JSON, with retry on throttling/transient errors.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$MaxRetries = 3,
        [switch]$AllowFailure
    )
    $snapshotMode = Get-SnapshotMode
    $isToken = $Arguments -contains 'get-access-token'
    $request = if ($snapshotMode -and -not $isToken) { Get-AzSnapshotRequest -Arguments $Arguments } else { $null }
    if ($snapshotMode -eq 'Replay') {
        # Replay never calls Azure; REST calls that need a token are replayed as well.
        if ($isToken) { return [pscustomobject]@{ accessToken = 'snapshot-replay'; tokenType = 'Bearer' } }
        $entry = Read-SnapshotEntry -Kind 'az' -Request $request
        if ($entry.Failed) {
            if ($AllowFailure) { return $null }
            throw "az $($Arguments[0..([math]::Min(3,$Arguments.Count-1))] -join ' ') failed when the snapshot was captured."
        }
        if ([string]::IsNullOrWhiteSpace($entry.Text)) { return $null }
        return $entry.Text | ConvertFrom-Json -Depth 64
    }
    $attempt = 0
    while ($true) {
        $attempt++
        $errFile = [System.IO.Path]::GetTempFileName()
        try {
            $out = & az @Arguments -o json --only-show-errors 2> $errFile
            $code = $LASTEXITCODE
            $err = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
        } finally { Remove-Item $errFile -ErrorAction SilentlyContinue }
        if ($code -eq 0) {
            $text = ($out -join "`n")
            if ($snapshotMode -eq 'Record' -and -not $isToken) {
                $saved = if (-not [string]::IsNullOrWhiteSpace($text) -and $Arguments[0] -eq 'account' -and $Arguments[1] -in 'show', 'list') { Hide-SnapshotAccount -Text $text } else { $text }
                Save-SnapshotEntry -Kind 'az' -Request $request -Text $saved
            }
            if ([string]::IsNullOrWhiteSpace($text)) { return $null }
            return $text | ConvertFrom-Json -Depth 64
        }
        $transient = $err -match '(429|TooManyRequests|throttl|timed out|temporar|ServiceUnavailable|503|502|ConnectionReset)'
        if ($transient -and $attempt -le $MaxRetries) {
            Start-Sleep -Seconds ([math]::Pow(2, $attempt) + (Get-Random -Maximum 3))
            continue
        }
        if ($snapshotMode -eq 'Record' -and -not $isToken) { Save-SnapshotEntry -Kind 'az' -Request $request -Text $null -Failed }
        if ($AllowFailure) {
            Write-Verbose "az $($Arguments[0..([math]::Min(3,$Arguments.Count-1))] -join ' ') failed: $(ConvertTo-SafeCliMessage $err)"
            return $null
        }
        throw "az $($Arguments[0..([math]::Min(3,$Arguments.Count-1))] -join ' ') failed (exit $code): $(ConvertTo-SafeCliMessage $err)"
    }
}

function Test-AzAuthentication {
    <#
    .SYNOPSIS
        Verifies Azure CLI can obtain an ARM token (optionally for a specific tenant) within a timeout.
    .DESCRIPTION
        An expired cached token makes az wait for interactive sign-in (browser / WAM popup) indefinitely. The check runs
        in a background job so the assessment fails fast with sign-in guidance instead of hanging.
    #>
    param([string]$TenantId, [int]$TimeoutSec = 60)
    if ((Get-SnapshotMode) -eq 'Replay') { return [pscustomobject]@{ Ok = $true; Reason = $null } }
    $argList = @('account', 'get-access-token', '--resource', 'https://management.azure.com', '-o', 'json', '--only-show-errors')
    if ($TenantId) { $argList += @('--tenant', $TenantId) }
    $job = Start-Job -ScriptBlock {
        $azArgs = $using:argList
        $o = $null | & az @azArgs 2>&1
        [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($o | Out-String) }
    }
    try {
        if (-not (Wait-Job $job -Timeout $TimeoutSec)) {
            Stop-Job $job
            return [pscustomobject]@{ Ok = $false; Reason = "Timed out after $TimeoutSec s: the cached Azure CLI token is expired and az is waiting for interactive sign-in." }
        }
        $r = Receive-Job $job
        if ($r.Code -ne 0) { return [pscustomobject]@{ Ok = $false; Reason = (ConvertTo-SafeCliMessage $r.Out) } }
        return [pscustomobject]@{ Ok = $true; Reason = $null }
    }
    finally { Remove-Job $job -Force -ErrorAction SilentlyContinue }
}

function Get-SkuNameInfo {
    <#
    .SYNOPSIS
        Parses an Azure VM size name into its naming-convention components.
    .DESCRIPTION
        Follows the Azure VM naming convention documented on Microsoft Learn
        (https://learn.microsoft.com/azure/virtual-machines/vm-naming-conventions):
        [Family] + [Sub-family]* + [# of vCPUs] + [Constrained vCPUs]* + [Additive features] + [Accelerator type]* + [Version].
        CPU vendor derived here is a naming-convention hint only ('a' = AMD, 'p' = ARM, otherwise Intel)
        and must be superseded by the processor catalog when available.
    #>
    param([Parameter(Mandatory)][string]$SkuName)

    $tier = if ($SkuName -match '^Basic_') { 'Basic' } else { 'Standard' }
    $n = $SkuName -replace '^(Standard|Basic)_', ''
    $rx = '^(?<fam>[A-Z]+)(?<size>\d+)(?:-(?<constr>\d+))?(?<sub>[a-z]*)(?:_(?!v\d+(?:_Promo)?$)(?<acc>[A-Za-z0-9]+))?(?:_v(?<ver>\d+))?(?<promo>_Promo)?$'
    $m = [regex]::Match($n, $rx)
    if (-not $m.Success) {
        return [pscustomobject]@{
            SkuName = $SkuName; Parsed = $false; Tier = $tier; Family = ''; WorkloadFamily = ''; Size = 0; Constrained = $null
            Features = ''; Accelerator = ''; Version = 0; SeriesKey = ''; BaseKey = ''; VendorHint = 'Unknown'; IsPromo = $false
        }
    }
    $fam = $m.Groups['fam'].Value
    $sub = $m.Groups['sub'].Value
    # Legacy names such as DS2_v2 / GS1 fold the premium-storage 's' into the family letters.
    if ($fam -in @('DS', 'GS')) { $sub = 's' + $sub; $fam = $fam.Substring(0, 1) }
    $ver = if ($m.Groups['ver'].Success) { [int]$m.Groups['ver'].Value } else { 1 }
    $acc = $m.Groups['acc'].Value
    $seriesKey = ($fam + $sub + $acc + $(if ($m.Groups['ver'].Success) { 'v' + $ver } else { '' })).ToLowerInvariant()
    $baseKey = ($fam + $acc + $(if ($m.Groups['ver'].Success) { 'v' + $ver } else { '' })).ToLowerInvariant()
    $vendorHint = if ($sub -match 'p') { 'ARM' } elseif ($sub -match 'a') { 'AMD' } else { 'Intel' }
    [pscustomobject]@{
        SkuName        = $SkuName
        Parsed         = $true
        Tier           = $tier
        Family         = $fam
        WorkloadFamily = $fam
        Size           = [int]$m.Groups['size'].Value
        Constrained    = if ($m.Groups['constr'].Success) { [int]$m.Groups['constr'].Value } else { $null }
        Features       = $sub
        Accelerator    = $acc
        Version        = $ver
        SeriesKey      = $seriesKey
        BaseKey        = $baseKey
        VendorHint     = $vendorHint
        IsPromo        = $m.Groups['promo'].Success
    }
}

function ConvertTo-InvariantDate {
    <# Parses Microsoft Learn table dates (MM/dd/yy or MM/dd/yyyy). Returns $null if not a date. #>
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = ($Text -replace '<[^>]+>', '').Trim()
    $formats = @('MM/dd/yy', 'M/d/yy', 'MM/dd/yyyy', 'M/d/yyyy', 'yyyy-MM-dd', 'MMMM d, yyyy', 'MMMM dd, yyyy')
    foreach ($f in $formats) {
        $d = [datetime]::MinValue
        if ([datetime]::TryParseExact($t, $f, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$d)) {
            return $d.Date
        }
    }
    return $null
}

function Get-MonthsBetween {
    param([Parameter(Mandatory)][datetime]$From, [Parameter(Mandatory)][datetime]$To)
    $months = (($To.Year - $From.Year) * 12) + ($To.Month - $From.Month)
    if ($To.Day -lt $From.Day) { $months-- }
    return $months
}

function Get-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)
    return ($Name -replace '[^A-Za-z0-9._-]', '-')
}

function Get-DefaultAssessmentOutputPath {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$TenantName,
        [Parameter(Mandatory)][string]$RunStamp
    )
    return Join-Path $RepositoryRoot (Join-Path 'reports' (Join-Path (Get-SafeFileName $TenantName) "$RunStamp-VMSKURetirementReport"))
}

function ConvertTo-HtmlEncoded {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-MaskedAccount {
    <#
    .SYNOPSIS
        Masks a signed-in account for outputs: 'jane.doe@contoso.com' -> 'j****@contoso.com'. The domain is kept
        (organization context); the fixed-length mask does not reveal the name length. Non-email IDs keep 4 characters.
    #>
    param([AllowNull()][string]$Account)
    if ([string]::IsNullOrWhiteSpace($Account)) { return $null }
    $at = $Account.LastIndexOf('@')
    if ($at -gt 0) { return $Account.Substring(0, 1) + '****' + $Account.Substring($at) }
    if ($Account.Length -le 4) { return '****' }
    return $Account.Substring(0, 4) + '****'
}

function ConvertTo-DisplayPath {
    <# Replaces the user's home directory with '~' so console output and run.log do not reveal the local user name. #>
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    foreach ($h in @($HOME, $env:USERPROFILE) | Where-Object { $_ } | Sort-Object Length -Descending -Unique) {
        $Path = [regex]::Replace($Path, [regex]::Escape($h.TrimEnd('\', '/')), '~', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    return $Path
}

function ConvertTo-SafeCliMessage {
    <#
    .SYNOPSIS
        Sanitizes Azure CLI error text before it is shown, thrown or logged: masks email addresses, hides the home
        directory, collapses whitespace and truncates.
    #>
    param([AllowNull()][string]$Text, [int]$MaxLength = 400)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = ConvertTo-DisplayPath (($Text -replace '\s+', ' ').Trim())
    $t = $t -replace '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', { Get-MaskedAccount $_.Value }
    if ($t.Length -gt $MaxLength) { $t = $t.Substring(0, $MaxLength) + '...' }
    return $t
}

Export-ModuleMember -Function Get-ToolVersion, Write-Phase, Write-PhaseDone, Invoke-AzJson, Test-AzAuthentication, Get-SkuNameInfo, ConvertTo-InvariantDate, Get-MonthsBetween, Get-SafeFileName, Get-DefaultAssessmentOutputPath, ConvertTo-HtmlEncoded, `
    Get-MaskedAccount, ConvertTo-DisplayPath, ConvertTo-SafeCliMessage, Get-SnapshotMode, Invoke-SnapshotRest
