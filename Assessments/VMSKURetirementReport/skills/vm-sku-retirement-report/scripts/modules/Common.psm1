Set-StrictMode -Version Latest

# Single source of truth for the tool version (kept in sync with SKILL.md metadata and CHANGELOG.md by tests/build).
$script:ToolVersion = '1.0.0'

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
            if ([string]::IsNullOrWhiteSpace($text)) { return $null }
            return $text | ConvertFrom-Json -Depth 64
        }
        $transient = $err -match '(429|TooManyRequests|throttl|timed out|temporar|ServiceUnavailable|503|502|ConnectionReset)'
        if ($transient -and $attempt -le $MaxRetries) {
            Start-Sleep -Seconds ([math]::Pow(2, $attempt) + (Get-Random -Maximum 3))
            continue
        }
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
    Get-MaskedAccount, ConvertTo-DisplayPath, ConvertTo-SafeCliMessage
