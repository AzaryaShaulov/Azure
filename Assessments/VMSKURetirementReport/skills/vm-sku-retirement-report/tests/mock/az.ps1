# Mock Azure CLI used by Integration.Tests.ps1. Returns API-shaped fixture data; never contacts Azure.
$ErrorActionPreference = 'Stop'
$a = @($args)
$joined = $a -join ' '
$fx = Join-Path (Split-Path $PSScriptRoot -Parent) 'fixtures'
$sub = '11111111-1111-1111-1111-111111111111'
$vmBase = "/subscriptions/$sub/resourcegroups/rg-app/providers/microsoft.compute/virtualmachines"

function Out-Json($o) { $o | ConvertTo-Json -Depth 20; exit 0 }
function Arg($name) { $i = [array]::IndexOf($a, $name); if ($i -ge 0 -and $i + 1 -lt $a.Count) { $a[$i + 1] } else { $null } }

# Fault injection for the diagnostics tests: MOCK_AZ_FAULT=<skus|usage>-<denied|garbage|empty> breaks only that call.
# Write-Error (not [Console]::Error) so the text reaches the caller's 2> redirection like the stderr of a real az process.
$denied = "ERROR: (AuthorizationFailed) The client 'admin@contoso.example' with object id '99999999-9999-9999-9999-999999999999' does not have authorization to perform action '{0}'."
switch ($env:MOCK_AZ_FAULT) {
    'skus-denied' { if ($joined -match '^vm list-skus') { Write-Error ($denied -f 'Microsoft.Compute/skus/read') -ErrorAction Continue; exit 1 } }
    'skus-garbage' { if ($joined -match '^vm list-skus') { Write-Output 'this-is-not-json'; exit 0 } }
    'skus-empty' { if ($joined -match '^vm list-skus') { Write-Output '[]'; exit 0 } }
    'usage-denied' { if ($joined -match '^vm list-usage') { Write-Error ($denied -f 'Microsoft.Compute/locations/usages/read') -ErrorAction Continue; exit 1 } }
    'usage-garbage' { if ($joined -match '^vm list-usage') { Write-Output '{ not valid json'; exit 0 } }
    'usage-empty' { if ($joined -match '^vm list-usage') { Write-Output '[]'; exit 0 } }
}

# Resource Graph calls are logged (one line per call) when MOCK_AZ_CALL_LOG names a file. Only these calls are logged: they are
# sequential, while the SKU and usage calls come from parallel runspaces and would write to the file at the same time.
if ($env:MOCK_AZ_CALL_LOG -and $joined -match '^graph query') { Add-Content -LiteralPath $env:MOCK_AZ_CALL_LOG -Value $joined }

# Throttling: MOCK_AZ_THROTTLE='<command prefix>=<n>' answers the first n calls that start with the prefix with HTTP 429 and then
# behaves normally. Every az call is a new process, so the count is kept in a file under MOCK_AZ_STATE_DIR.
if ($env:MOCK_AZ_THROTTLE -and $env:MOCK_AZ_STATE_DIR) {
    $throttlePrefix, $throttleLimit = $env:MOCK_AZ_THROTTLE -split '=', 2
    if ($joined.StartsWith($throttlePrefix)) {
        $counter = Join-Path $env:MOCK_AZ_STATE_DIR 'throttle-count.txt'
        $seen = if (Test-Path -LiteralPath $counter) { [int](Get-Content -LiteralPath $counter -Raw) } else { 0 }
        if ($seen -lt [int]$throttleLimit) {
            Set-Content -LiteralPath $counter -Value ($seen + 1)
            Write-Error 'ERROR: (429) Too Many Requests. Retry after 1 second.' -ErrorAction Continue
            exit 1
        }
    }
}

if ($joined -match '^account show') {
    Out-Json ([pscustomobject]@{ id = $sub; name = 'contoso-prod'; tenantId = '22222222-2222-2222-2222-222222222222'; tenantDisplayName = 'Contoso (Sample)'; user = @{ name = 'admin@contoso.example' } })
}
if ($joined -match '^account get-access-token') {
    if ($env:MOCK_AZ_TOKEN_HANG -eq '1') { Start-Sleep -Seconds 300 }
    # Subscription-scoped tokens are only used for direct ARM REST calls (Compute SKUs). Refusing them keeps the mock fully
    # offline: callers fall back to the mocked 'az vm list-skus' instead of calling management.azure.com with a fake token.
    if ($a -contains '--subscription') { [Console]::Error.WriteLine('mock az: subscription-scoped tokens are not available offline'); exit 1 }
    Out-Json ([pscustomobject]@{ accessToken = 'mock-token'; expiresOn = '2099-01-01 00:00:00.000000'; tenant = '22222222-2222-2222-2222-222222222222' })
}
if ($joined -match '^extension show') { Out-Json ([pscustomobject]@{ name = 'resource-graph'; version = '2.1.1' }) }
if ($joined -match '^account list') { Out-Json @([pscustomobject]@{ id = $sub; name = 'contoso-prod'; tenantDisplayName = 'Contoso (Sample)'; user = 'admin@contoso.example' }) }
if ($joined -match '^vm list-skus') { Get-Content $(if ($env:MOCK_AZ_SKUS_FILE) { $env:MOCK_AZ_SKUS_FILE } else { Join-Path $fx 'skus-eastus2.json' }) -Raw; exit 0 }
if ($joined -match '^vm list-usage') {
    Out-Json @(
        [pscustomobject]@{ name = @{ value = 'cores'; localizedValue = 'Total Regional vCPUs' }; localName = 'Total Regional vCPUs'; currentValue = 40; limit = 350 }
        [pscustomobject]@{ name = @{ value = 'standardDDSv5Family'; localizedValue = 'Standard DDSv5 Family vCPUs' }; localName = 'Standard DDSv5 Family vCPUs'; currentValue = 95; limit = 100 }
        [pscustomobject]@{ name = @{ value = 'standardDSv5Family'; localizedValue = 'Standard DSv5 Family vCPUs' }; localName = 'Standard DSv5 Family vCPUs'; currentValue = 4; limit = 100 }
        [pscustomobject]@{ name = @{ value = 'standardDSv3Family'; localizedValue = 'Standard DSv3 Family vCPUs' }; localName = 'Standard DSv3 Family vCPUs'; currentValue = 8; limit = 100 }
    )
}
if ($joined -match '^graph query') {
    $q = Arg '-q'
    $text = if ($q -and $q.StartsWith('@')) { Get-Content $q.Substring(1) -Raw } else { $q }
    # Graph faults: graph-page2-denied fails every call that continues a query (it has a --skip-token), and graph-optional-denied
    # fails the optional queries (disk-encryption extensions, Advisor, Service Health) while the inventory still works.
    if ($env:MOCK_AZ_FAULT -eq 'graph-page2-denied' -and (Arg '--skip-token')) { Write-Error ($denied -f 'Microsoft.ResourceGraph/resources/read') -ErrorAction Continue; exit 1 }
    if ($env:MOCK_AZ_FAULT -eq 'graph-optional-denied' -and $text -match 'advisorresources|servicehealthresources|virtualmachines/extensions') { Write-Error ($denied -f 'Microsoft.ResourceGraph/resources/read') -ErrorAction Continue; exit 1 }
    # Paging: MOCK_AZ_GRAPH_PAGE_SIZE=n answers n rows per call plus a skip token (the offset of the next row), like the service.
    $wrap = {
        param($rows)
        $rows = @($rows)
        $size = [int]$env:MOCK_AZ_GRAPH_PAGE_SIZE
        $offset = [int](Arg '--skip-token')
        $page = @(if ($size -gt 0) { $rows | Select-Object -Skip $offset -First $size } else { $rows })
        $next = if ($size -gt 0 -and ($offset + $size) -lt $rows.Count) { [string]($offset + $size) } else { $null }
        [pscustomobject]@{ count = $page.Count; data = $page; skip_token = $next; total_records = $rows.Count }
    }
    # MOCK_AZ_EXTRA_VMS='name:Standard_Size:Gen,name2:Standard_Size2:Gen2' adds VMs (each with a NIC) to the estate.
    $extraVms = @($env:MOCK_AZ_EXTRA_VMS -split ',' | Where-Object { $_ } | ForEach-Object { , ($_ -split ':') })
    if ($text -match 'advisorresources' -or $text -match 'servicehealthresources' -or $text -match 'virtualmachines/extensions') { Out-Json (& $wrap @()) }
    if ($text -match 'microsoft.network/networkinterfaces') {
        $nicVms = @('ds3v2', 'dealloc', 'd4sv3', 'zonal', 'd4sv5', 'nc6', 'b2ms') + @($extraVms | ForEach-Object { $_[0] })
        Out-Json (& $wrap @($nicVms | ForEach-Object { [pscustomobject]@{ id = "/nic/$_"; vmId = "$vmBase/vm-$_"; accelerated = ($_ -ne 'b2ms') } }))
    }
    if ($text -match 'microsoft.compute/disks') {
        Out-Json (& $wrap @([pscustomobject]@{ id = '/disk/os-ds3v2'; managedBy = "$vmBase/vm-ds3v2"; sku = 'Premium_LRS'; sizeGB = 128; zones = $null; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskIops = 500; diskMBps = 100; hyperVGen = 'V1' }))
    }
    if ($text -match "microsoft.compute/virtualmachines'" -and $env:MOCK_AZ_EMPTY -eq '1') { Out-Json (& $wrap @()) }
    if ($text -match "microsoft.compute/virtualmachines'") {
        $mk = { param($n, $size, $gen, $power = 'PowerState/running', $zones = $null, $os = 'Premium_LRS')
            [pscustomobject]@{ id = "$vmBase/vm-$n"; name = "vm-$n"; resourceGroup = 'rg-app'; subscriptionId = $sub; location = $(if ($env:MOCK_AZ_MULTI_REGION -eq '1' -and $n -eq 'b2ms') { 'westus3' } elseif ($env:MOCK_AZ_MULTI_REGION -eq '1' -and $n -in 'd4sv3', 'd4sv5') { 'westus2' } else { 'eastus2' }); zones = $zones; vmSize = $size
                powerState = $power; osType = 'Windows'; osName = 'Windows Server 2022'; osVersion = '10.0'; hyperVGen = $gen; osDiskType = $os; osDiskId = "/disk/os-$n"
                osDiskDes = ''; osDiskSecurityDes = ''; ephemeral = ''; ephemeralPlacement = ''; osDiskWriteAccel = $false; diskController = ''; dataDisks = @()
                imagePublisher = 'MicrosoftWindowsServer'; imageOffer = 'WindowsServer'; imageSku = '2022-datacenter'; imageId = ''; sharedGalleryImageId = ''; communityGalleryImageId = ''
                nicIds = @(@{ id = "/nic/$n" }); ultraSsd = $false; hibernation = $false; securityType = ''; encryptionAtHost = $false; secureBoot = $false; vTpm = $false
                availabilitySetId = ''; ppgId = ''; hostId = ''; hostGroupId = ''; vmssId = ''; capacityReservationGroupId = ''; priority = ''; licenseType = ''; timeCreated = '' }
        }
        $estate = @(
            (& $mk 'ds3v2' 'Standard_DS3_v2' 'V1'),
            (& $mk 'dealloc' 'Standard_DS3_v2' 'V1' 'PowerState/deallocated'),
            (& $mk 'd4sv3' 'Standard_D4s_v3' 'V2'),
            (& $mk 'zonal' 'Standard_D4s_v3' 'V1' 'PowerState/running' @('3')),
            (& $mk 'd4sv5' 'Standard_D4s_v5' 'V2'),
            (& $mk 'nc6' 'Standard_NC6s_v3' 'V1'),
            (& $mk 'b2ms' 'Standard_B2ms' 'V1' 'PowerState/running' $null 'StandardSSD_LRS')
        ) + @($extraVms | ForEach-Object { & $mk $_[0] $_[1] $_[2] })
        Out-Json (& $wrap $estate)
    }
    Out-Json (& $wrap @())
}
[Console]::Error.WriteLine("mock az: unsupported command: $joined")
exit 1
