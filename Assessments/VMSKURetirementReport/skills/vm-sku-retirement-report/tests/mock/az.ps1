# Mock Azure CLI used by Integration.Tests.ps1. Returns API-shaped fixture data; never contacts Azure.
$ErrorActionPreference = 'Stop'
$a = @($args)
$joined = $a -join ' '
$fx = Join-Path (Split-Path $PSScriptRoot -Parent) 'fixtures'
$sub = '11111111-1111-1111-1111-111111111111'
$vmBase = "/subscriptions/$sub/resourcegroups/rg-app/providers/microsoft.compute/virtualmachines"

function Out-Json($o) { $o | ConvertTo-Json -Depth 20; exit 0 }
function Arg($name) { $i = [array]::IndexOf($a, $name); if ($i -ge 0 -and $i + 1 -lt $a.Count) { $a[$i + 1] } else { $null } }

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
if ($joined -match '^vm list-skus') { Get-Content (Join-Path $fx 'skus-eastus2.json') -Raw; exit 0 }
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
    $wrap = { param($rows) [pscustomobject]@{ count = @($rows).Count; data = @($rows); skip_token = $null; total_records = @($rows).Count } }
    if ($text -match 'advisorresources' -or $text -match 'servicehealthresources' -or $text -match 'virtualmachines/extensions') { Out-Json (& $wrap @()) }
    if ($text -match 'microsoft.network/networkinterfaces') {
        Out-Json (& $wrap @('ds3v2', 'dealloc', 'd4sv3', 'zonal', 'd4sv5', 'nc6', 'b2ms' | ForEach-Object { [pscustomobject]@{ id = "/nic/$_"; vmId = "$vmBase/vm-$_"; accelerated = ($_ -ne 'b2ms') } }))
    }
    if ($text -match 'microsoft.compute/disks') {
        Out-Json (& $wrap @([pscustomobject]@{ id = '/disk/os-ds3v2'; managedBy = "$vmBase/vm-ds3v2"; sku = 'Premium_LRS'; sizeGB = 128; zones = $null; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskIops = 500; diskMBps = 100; hyperVGen = 'V1' }))
    }
    if ($text -match "microsoft.compute/virtualmachines'" -and $env:MOCK_AZ_EMPTY -eq '1') { Out-Json (& $wrap @()) }
    if ($text -match "microsoft.compute/virtualmachines'") {
        $mk = { param($n, $size, $gen, $power = 'PowerState/running', $zones = $null, $os = 'Premium_LRS')
            [pscustomobject]@{ id = "$vmBase/vm-$n"; name = "vm-$n"; resourceGroup = 'rg-app'; subscriptionId = $sub; location = 'eastus2'; zones = $zones; vmSize = $size
                powerState = $power; osType = 'Windows'; osName = 'Windows Server 2022'; osVersion = '10.0'; hyperVGen = $gen; osDiskType = $os; osDiskId = "/disk/os-$n"
                osDiskDes = ''; osDiskSecurityDes = ''; ephemeral = ''; ephemeralPlacement = ''; osDiskWriteAccel = $false; diskController = ''; dataDisks = @()
                imagePublisher = 'MicrosoftWindowsServer'; imageOffer = 'WindowsServer'; imageSku = '2022-datacenter'; imageId = ''; sharedGalleryImageId = ''; communityGalleryImageId = ''
                nicIds = @(@{ id = "/nic/$n" }); ultraSsd = $false; hibernation = $false; securityType = ''; encryptionAtHost = $false; secureBoot = $false; vTpm = $false
                availabilitySetId = ''; ppgId = ''; hostId = ''; hostGroupId = ''; vmssId = ''; capacityReservationGroupId = ''; priority = ''; licenseType = ''; timeCreated = '' }
        }
        Out-Json (& $wrap @(
                (& $mk 'ds3v2' 'Standard_DS3_v2' 'V1'),
                (& $mk 'dealloc' 'Standard_DS3_v2' 'V1' 'PowerState/deallocated'),
                (& $mk 'd4sv3' 'Standard_D4s_v3' 'V2'),
                (& $mk 'zonal' 'Standard_D4s_v3' 'V1' 'PowerState/running' @('3')),
                (& $mk 'd4sv5' 'Standard_D4s_v5' 'V2'),
                (& $mk 'nc6' 'Standard_NC6s_v3' 'V1'),
                (& $mk 'b2ms' 'Standard_B2ms' 'V1' 'PowerState/running' $null 'StandardSSD_LRS')
            ))
    }
    Out-Json (& $wrap @())
}
[Console]::Error.WriteLine("mock az: unsupported command: $joined")
exit 1
