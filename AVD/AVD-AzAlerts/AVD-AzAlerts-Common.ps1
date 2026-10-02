#requires -Version 5.1
<#
==============================================================================
SHARED CONSTANTS AND HELPERS for AVD-AzAlerts scripts.
Dot-source from sibling scripts:
    . (Join-Path $PSScriptRoot 'AVD-AzAlerts-Common.ps1')

Centralises values that previously drifted between the deploy LogicApp script
and the Category-Alerts script.
==============================================================================
#>

# Minimum supported Windows AVD (MSRDC) client version.
# Versions older than this are flagged "(outdated)" in the email column.
# https://learn.microsoft.com/azure/virtual-desktop/whats-new-client-windows
$Script:AvdMinSupportedClientVersion = "1.2.5102"

# Action group short name used everywhere webhook is created/updated.
$Script:AvdActionGroupShortName = "AVDDetl"

# Cap on result rows surfaced in alert email body to avoid Office 365 size limits
# and unreadable wide tables.
$Script:AvdMaxResultRows = 50

# Cap on email recipients accepted via -SendToEmails / -SendToEmail to mitigate abuse.
$Script:AvdMaxRecipients = 50

# Email format validation regex (RFC 5321 simplified).
$Script:AvdEmailRegex = '^[^@\s]+@[^@\s]+\.[^@\s]+$'

function Get-AvdSeverityText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Severity
    )
    switch ($Severity) {
        0 { 'Critical' }
        1 { 'Error' }
        2 { 'Warning' }
        3 { 'Informational' }
        4 { 'Verbose' }
        default { "Severity-$Severity" }
    }
}

function Get-AvdLogAnalyticsAudience {
    <#
    Returns the Log Analytics REST audience for the current Azure cloud.
    Falls back to the public-cloud value if the cloud cannot be determined.
    #>
    [CmdletBinding()]
    param()
    try {
        $cloudName = & az cloud show --query name -o tsv 2>$null
        switch -Regex ($cloudName) {
            'AzureUSGovernment' { return 'https://api.loganalytics.us/' }
            'AzureChinaCloud'   { return 'https://api.loganalytics.azure.cn/' }
            default             { return 'https://api.loganalytics.io/' }
        }
    }
    catch {
        return 'https://api.loganalytics.io/'
    }
}

function ConvertTo-AvdHtmlEncoded {
    <#
    Minimal HTML entity encoding for substitution into the alert email template.
    Safer than blind .Replace() of resource names that may contain HTML-significant chars.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Text
    )
    process {
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        return ($Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace "'", '&#39;')
    }
}

function ConvertTo-AvdSafeFileName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    return ($Name -replace '[^\w\-\.]', '_')
}

# Reusable KQL `let` block that builds a per-CorrelationId enrichment table from WVDConnections.
# - Casts CorrelationId to string on both sides of any future lookup (B1).
# - parse_version-safe: non-semver client versions surface as the raw string (B2).
# - Caller is responsible for substituting time placeholders {0}/{1} when used at Logic App runtime,
#   or replacing them with `ago(15m)` for scheduled-query rule bodies.
$Script:AvdConnEnrichmentLetTemplate = @"
let MinSupportedClient = '{MIN_VERSION}';
let ConnEnrichment =
    WVDConnections
    | where TimeGenerated between (datetime({0}) .. datetime({1}))
    | summarize arg_max(TimeGenerated, ClientIPAddress, ClientOS, ClientType, ClientVersion, GatewayRegion, SessionHostName) by CorrelationId
    | extend Geo = geo_info_from_ip_address(ClientIPAddress)
    | extend ClientCity = tostring(Geo.city),
             ClientState = tostring(Geo.state),
             ClientCountry = tostring(Geo.country)
    | extend ParsedVer = parse_version(ClientVersion)
    | extend ClientVersionDisplay = case(
        isempty(ClientVersion), '(unknown)',
        isnull(ParsedVer), ClientVersion,
        ParsedVer < parse_version(MinSupportedClient), strcat(ClientVersion, ' (outdated)'),
        ClientVersion)
    | project CorrelationId = tostring(CorrelationId),
              ClientIPAddress, GatewayRegion,
              ClientCity, ClientState, ClientCountry,
              ClientOS, ClientType,
              ClientVersion = ClientVersionDisplay,
              ClientSessionHost = SessionHostName;
"@

function Get-AvdConnEnrichmentLet {
    <#
    Returns the ConnEnrichment KQL fragment with $MinSupportedClient interpolated.
    For scheduled-query rule bodies pass -UseAgo15m to swap the time-window placeholders.
    #>
    [CmdletBinding()]
    param(
        [switch]$UseAgo15m
    )
    $kql = $Script:AvdConnEnrichmentLetTemplate.Replace('{MIN_VERSION}', $Script:AvdMinSupportedClientVersion)
    if ($UseAgo15m) {
        # Replace `between (datetime({0}) .. datetime({1}))` with `> ago(15m)` for static-window rules.
        $kql = $kql -replace '\| where TimeGenerated between \(datetime\(\{0\}\) \.\. datetime\(\{1\}\)\)', '| where TimeGenerated > ago(15m)'
    }
    return $kql
}
