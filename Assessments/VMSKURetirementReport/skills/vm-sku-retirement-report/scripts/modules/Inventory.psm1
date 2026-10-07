Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

function Invoke-ArgQuery {
    <#
    .SYNOPSIS
        Runs an Azure Resource Graph query across subscriptions with chunking (subscriptions) and paging (skip token).
    .PARAMETER TenantId
        When set, queries the Resource Graph REST API with a token for this tenant (does not require the tenant to be
        the Azure CLI default; az graph query only sees subscriptions of the default tenant).
    #>
    param(
        [Parameter(Mandatory)][string]$Query,
        [string[]]$SubscriptionIds,
        [string]$TenantId,
        [int]$ChunkSize = 200,
        [int]$PageSize = 1000,
        [switch]$AllowFailure
    )
    $rows = New-Object System.Collections.Generic.List[object]
    $chunks = @()
    if ($SubscriptionIds -and $SubscriptionIds.Count -gt 0) {
        for ($i = 0; $i -lt $SubscriptionIds.Count; $i += $ChunkSize) {
            $chunks += , @($SubscriptionIds[$i..([math]::Min($i + $ChunkSize - 1, $SubscriptionIds.Count - 1))])
        }
    }
    else { $chunks = @(, @()) }

    if ($TenantId) {
        foreach ($chunk in $chunks) {
            $skip = $null
            do {
                $token = (Invoke-AzJson -Arguments @('account', 'get-access-token', '--tenant', $TenantId, '--resource', 'https://management.azure.com')).accessToken
                $options = @{ '$top' = $PageSize; resultFormat = 'objectArray' }
                if ($skip) { $options['$skipToken'] = $skip }
                $body = @{ subscriptions = @($chunk); query = $Query; options = $options } | ConvertTo-Json -Depth 6
                $resp = $null
                for ($attempt = 1; $attempt -le 4 -and -not $resp; $attempt++) {
                    try {
                        $resp = Invoke-RestMethod -Method Post -Uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' `
                            -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' -Body $body -TimeoutSec 120
                    }
                    catch {
                        $status = if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                        if ($status -in 429, 500, 502, 503, 504 -and $attempt -lt 4) { Start-Sleep -Seconds ([math]::Pow(2, $attempt)); continue }
                        if ($AllowFailure) { Write-Verbose "ARG REST query failed: $($_.Exception.Message)"; return $rows.ToArray() }
                        throw "Resource Graph query failed for tenant ${TenantId}: $($_.Exception.Message)"
                    }
                }
                if (-not $resp) { break }
                foreach ($d in @($resp.data)) { if ($d) { $rows.Add($d) } }
                $skip = if ($resp.PSObject.Properties.Name -contains '$skipToken') { $resp.'$skipToken' } else { $null }
            } while ($skip)
        }
        return $rows.ToArray()
    }

    $qFile = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -Path $qFile -Value $Query -NoNewline
        foreach ($chunk in $chunks) {
            $skip = $null
            do {
                $argList = @('graph', 'query', '-q', "@$qFile", '--first', "$PageSize")
                if ($chunk.Count -gt 0) { $argList += '--subscriptions'; $argList += $chunk }
                if ($skip) { $argList += @('--skip-token', $skip) }
                $r = Invoke-AzJson -Arguments $argList -AllowFailure:$AllowFailure
                if (-not $r) { break }
                foreach ($d in @($r.data)) { if ($d) { $rows.Add($d) } }
                $skip = if ($r.PSObject.Properties.Name -contains 'skip_token') { $r.skip_token } else { $null }
            } while ($skip)
        }
    }
    finally { Remove-Item $qFile -ErrorAction SilentlyContinue }
    return $rows.ToArray()
}

$script:VmQuery = @'
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| extend p = properties
| project id = tolower(id), name, resourceGroup, subscriptionId, location = tolower(location), zones,
    vmSize = tostring(p.hardwareProfile.vmSize),
    powerState = tostring(p.extended.instanceView.powerState.code),
    osType = tostring(p.storageProfile.osDisk.osType),
    osName = tostring(p.extended.instanceView.osName),
    osVersion = tostring(p.extended.instanceView.osVersion),
    hyperVGen = tostring(p.extended.instanceView.hyperVGeneration),
    osDiskType = tostring(p.storageProfile.osDisk.managedDisk.storageAccountType),
    osDiskId = tolower(tostring(p.storageProfile.osDisk.managedDisk.id)),
    osDiskDes = tostring(p.storageProfile.osDisk.managedDisk.diskEncryptionSet.id),
    osDiskSecurityDes = tostring(p.storageProfile.osDisk.managedDisk.securityProfile.diskEncryptionSet.id),
    ephemeral = tostring(p.storageProfile.osDisk.diffDiskSettings.option),
    ephemeralPlacement = tostring(p.storageProfile.osDisk.diffDiskSettings.placement),
    osDiskWriteAccel = tobool(p.storageProfile.osDisk.writeAcceleratorEnabled),
    diskController = tostring(p.storageProfile.diskControllerType),
    dataDisks = p.storageProfile.dataDisks,
    imagePublisher = tostring(p.storageProfile.imageReference.publisher),
    imageOffer = tostring(p.storageProfile.imageReference.offer),
    imageSku = tostring(p.storageProfile.imageReference.sku),
    imageId = tostring(p.storageProfile.imageReference.id),
    sharedGalleryImageId = tostring(p.storageProfile.imageReference.sharedGalleryImageId),
    communityGalleryImageId = tostring(p.storageProfile.imageReference.communityGalleryImageId),
    nicIds = p.networkProfile.networkInterfaces,
    ultraSsd = tobool(p.additionalCapabilities.ultraSSDEnabled),
    hibernation = tobool(p.additionalCapabilities.hibernationEnabled),
    securityType = tostring(p.securityProfile.securityType),
    encryptionAtHost = tobool(p.securityProfile.encryptionAtHost),
    secureBoot = tobool(p.securityProfile.uefiSettings.secureBootEnabled),
    vTpm = tobool(p.securityProfile.uefiSettings.vTpmEnabled),
    availabilitySetId = tolower(tostring(p.availabilitySet.id)),
    ppgId = tolower(tostring(p.proximityPlacementGroup.id)),
    hostId = tolower(tostring(p.host.id)),
    hostGroupId = tolower(tostring(p.hostGroup.id)),
    vmssId = tolower(tostring(p.virtualMachineScaleSet.id)),
    capacityReservationGroupId = tolower(tostring(p.capacityReservation.capacityReservationGroup.id)),
    priority = tostring(p.priority),
    licenseType = tostring(p.licenseType),
    timeCreated = tostring(p.timeCreated)
'@

$script:NicQuery = @'
Resources
| where type =~ 'microsoft.network/networkinterfaces'
| project id = tolower(id), vmId = tolower(tostring(properties.virtualMachine.id)),
    accelerated = tobool(properties.enableAcceleratedNetworking)
| where isnotempty(vmId)
'@

$script:DiskQuery = @'
Resources
| where type =~ 'microsoft.compute/disks'
| where isnotempty(managedBy)
| project id = tolower(id), managedBy = tolower(managedBy), sku = tostring(sku.name),
    sizeGB = toint(properties.diskSizeGB), zones, encryptionType = tostring(properties.encryption.type),
    diskIops = toint(properties.diskIOPSReadWrite), diskMBps = toint(properties.diskMBpsReadWrite),
    hyperVGen = tostring(properties.hyperVGeneration)
'@

$script:AdeQuery = @'
Resources
| where type =~ 'microsoft.compute/virtualmachines/extensions'
| where tostring(properties.type) in~ ('AzureDiskEncryption', 'AzureDiskEncryptionForLinux')
| project vmId = tolower(substring(id, 0, indexof(id, '/extensions/')))
'@

$script:AdvisorQuery = @'
advisorresources
| where type =~ 'microsoft.advisor/recommendations'
| extend ep = properties.extendedProperties
| where tostring(ep.recommendationSubCategory) =~ 'ServiceUpgradeAndRetirement'
| project resourceId = tolower(tostring(properties.resourceMetadata.resourceId)),
    retirementDate = tostring(ep.retirementDate), feature = tostring(ep.retirementFeatureName),
    problem = tostring(properties.shortDescription.problem), impact = tostring(properties.impact)
| where resourceId contains '/providers/microsoft.compute/virtualmachines/'
'@

$script:ServiceHealthQuery = @'
servicehealthresources
| where type =~ 'microsoft.resourcehealth/events'
| extend p = properties
| where tostring(p.EventType) =~ 'HealthAdvisory' and tostring(p.EventSubType) =~ 'Retirement'
| project trackingId = name, subscriptionId, title = tostring(p.Title),
    impactStart = tostring(p.ImpactStartTime), impactMitigation = tostring(p.ImpactMitigationTime),
    lastUpdate = tostring(p.LastUpdateTime)
'@

function Get-EstateInventory {
    <#
    .SYNOPSIS
        Collects VM inventory plus NIC, disk, ADE, Advisor-retirement and Service Health retirement context (read-only).
    #>
    param([Parameter(Mandatory)][string[]]$SubscriptionIds, [string[]]$Regions, [string]$TenantId)
    Write-Phase 'Inventory: virtual machines (Azure Resource Graph)'
    $vms = @(Invoke-ArgQuery -Query $script:VmQuery -TenantId $TenantId -SubscriptionIds $SubscriptionIds)
    if ($Regions -and $Regions.Count -gt 0) {
        $rset = @($Regions | ForEach-Object { $_.ToLowerInvariant() })
        $vms = @($vms | Where-Object { $rset -contains $_.location })
    }
    Write-PhaseDone "$($vms.Count) VMs"

    $subsWithVms = @($vms | ForEach-Object subscriptionId | Sort-Object -Unique)
    $nics = @(); $disks = @(); $ade = @(); $advisor = @(); $sh = @()
    if ($subsWithVms.Count -gt 0) {
        Write-Phase 'Inventory: NICs, disks, disk-encryption extensions'
        $nics = @(Invoke-ArgQuery -Query $script:NicQuery -TenantId $TenantId -SubscriptionIds $subsWithVms)
        $disks = @(Invoke-ArgQuery -Query $script:DiskQuery -TenantId $TenantId -SubscriptionIds $subsWithVms)
        $ade = @(Invoke-ArgQuery -Query $script:AdeQuery -TenantId $TenantId -SubscriptionIds $subsWithVms -AllowFailure)
        Write-PhaseDone "$($nics.Count) NICs, $($disks.Count) attached disks, $($ade.Count) ADE extensions"

        Write-Phase 'Corroborating evidence: Azure Advisor + Service Health retirement signals'
        $advisor = @(Invoke-ArgQuery -Query $script:AdvisorQuery -TenantId $TenantId -SubscriptionIds $subsWithVms -AllowFailure)
        $sh = @(Invoke-ArgQuery -Query $script:ServiceHealthQuery -TenantId $TenantId -SubscriptionIds $subsWithVms -AllowFailure)
        foreach ($e in $sh) {
            foreach ($p in 'impactStart', 'impactMitigation', 'lastUpdate') {
                $v = if ($e.PSObject.Properties.Name -contains $p) { [string]$e.$p } else { '' }
                if ($v -match '^\d{17,19}$') { $e.$p = ([datetime]::new([long]$v, [DateTimeKind]::Utc)).ToString('yyyy-MM-dd') }
            }
        }
        Write-PhaseDone "$($advisor.Count) Advisor retirement recommendations, $($sh.Count) Service Health retirement events"
    }

    $nicByVm = @{}
    foreach ($n in $nics) { if (-not $nicByVm.ContainsKey($n.vmId)) { $nicByVm[$n.vmId] = @() }; $nicByVm[$n.vmId] += $n }
    $diskById = @{}; $diskByVm = @{}
    foreach ($d in $disks) {
        $diskById[$d.id] = $d
        if (-not $diskByVm.ContainsKey($d.managedBy)) { $diskByVm[$d.managedBy] = @() }
        $diskByVm[$d.managedBy] += $d
    }
    $adeSet = @{}; foreach ($a in $ade) { $adeSet[$a.vmId] = $true }
    $advByVm = @{}
    foreach ($a in $advisor) { if (-not $advByVm.ContainsKey($a.resourceId)) { $advByVm[$a.resourceId] = @() }; $advByVm[$a.resourceId] += $a }

    $records = foreach ($vm in $vms) { ConvertTo-VmRecord -Vm $vm -Nics @($nicByVm[$vm.id] | Where-Object { $_ }) -Disks @($diskByVm[$vm.id] | Where-Object { $_ }) -HasAde $adeSet.ContainsKey($vm.id) -Advisor @($advByVm[$vm.id] | Where-Object { $_ }) }
    [pscustomobject]@{
        Vms                  = @($records)
        ServiceHealthEvents  = $sh
        AdvisorSignals       = $advisor
        Counts               = [pscustomobject]@{ Vms = $vms.Count; Nics = $nics.Count; Disks = $disks.Count; AdeExtensions = $ade.Count; AdvisorRetirement = $advisor.Count; ServiceHealthRetirement = $sh.Count }
    }
}

function Get-PropOrNull {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}

function ConvertTo-VmRecord {
    <#
    .SYNOPSIS
        Normalizes an ARG VM row (plus joined NIC/disk data) into the assessment's VM record and requirement profile.
    #>
    param([Parameter(Mandatory)]$Vm, [object[]]$Nics = @(), [object[]]$Disks = @(), [bool]$HasAde = $false, [object[]]$Advisor = @())
    $dataDisks = @(Get-PropOrNull $Vm 'dataDisks' | Where-Object { $_ })
    $nicIds = @(Get-PropOrNull $Vm 'nicIds' | Where-Object { $_ })
    $zones = @(Get-PropOrNull $Vm 'zones' | Where-Object { $_ })

    $diskSkus = New-Object System.Collections.Generic.List[string]
    $osType = Get-PropOrNull $Vm 'osDiskType'
    if ($osType) { $diskSkus.Add($osType) }
    $waCount = 0
    if (Get-PropOrNull $Vm 'osDiskWriteAccel') { $waCount++ }
    foreach ($dd in $dataDisks) {
        $md = Get-PropOrNull $dd 'managedDisk'
        $t = Get-PropOrNull $md 'storageAccountType'
        if ($t) { $diskSkus.Add($t) }
        if (Get-PropOrNull $dd 'writeAcceleratorEnabled') { $waCount++ }
    }
    foreach ($d in $Disks) { if ($d.sku) { $diskSkus.Add($d.sku) } }
    $skuSet = @($diskSkus | Where-Object { $_ } | Sort-Object -Unique)
    $usesPremium = [bool]($skuSet | Where-Object { $_ -match '^(Premium_|PremiumV2_|UltraSSD_)' })
    $usesUltra = [bool](Get-PropOrNull $Vm 'ultraSsd') -or [bool]($skuSet | Where-Object { $_ -match '^UltraSSD_' })
    $usesPv2 = [bool]($skuSet | Where-Object { $_ -match '^PremiumV2_' })
    $cmk = [bool]((Get-PropOrNull $Vm 'osDiskDes') -or ($Disks | Where-Object { $_.encryptionType -match 'CustomerKey' }))

    $accelNics = @($Nics | Where-Object { $_.accelerated -eq $true }).Count
    $hvGen = Get-PropOrNull $Vm 'hyperVGen'
    if (-not $hvGen) {
        $osDisk = $Disks | Where-Object { $_.id -eq (Get-PropOrNull $Vm 'osDiskId') } | Select-Object -First 1
        if ($osDisk -and $osDisk.hyperVGen) { $hvGen = $osDisk.hyperVGen }
    }
    $powerCode = [string](Get-PropOrNull $Vm 'powerState')
    $powerState = switch -Regex ($powerCode) { 'running' { 'Running' } 'deallocat' { 'Deallocated' } 'stopped' { 'Stopped' } 'starting' { 'Starting' } default { if ($powerCode) { $powerCode -replace '^PowerState/', '' } else { 'Unknown' } } }
    $galleryImage = @((Get-PropOrNull $Vm 'imageId'), (Get-PropOrNull $Vm 'sharedGalleryImageId'), (Get-PropOrNull $Vm 'communityGalleryImageId')) | Where-Object { $_ -and $_ -match 'galleries|sharedGalleries|communityGalleries' } | Select-Object -First 1
    $controller = Get-PropOrNull $Vm 'diskController'
    $ephemeral = (Get-PropOrNull $Vm 'ephemeral') -eq 'Local'
    $imageRef = (@((Get-PropOrNull $Vm 'imagePublisher'), (Get-PropOrNull $Vm 'imageOffer'), (Get-PropOrNull $Vm 'imageSku')) | Where-Object { $_ }) -join '/'

    [pscustomobject]@{
        Id                      = $Vm.id
        Name                    = $Vm.name
        SubscriptionId          = $Vm.subscriptionId
        ResourceGroup           = $Vm.resourceGroup
        Region                  = $Vm.location
        Zone                    = if ($zones.Count -gt 0) { ($zones -join ',') } else { $null }
        AvailabilitySetId       = Get-PropOrNull $Vm 'availabilitySetId'
        ProximityPlacementGroup = Get-PropOrNull $Vm 'ppgId'
        DedicatedHostId         = Get-PropOrNull $Vm 'hostId'
        DedicatedHostGroupId    = Get-PropOrNull $Vm 'hostGroupId'
        VmssId                  = Get-PropOrNull $Vm 'vmssId'
        CapacityReservationGroup = Get-PropOrNull $Vm 'capacityReservationGroupId'
        SkuName                 = $Vm.vmSize
        PowerState              = $powerState
        IsAllocated             = $powerState -ne 'Deallocated'
        OsType                  = Get-PropOrNull $Vm 'osType'
        OsName                  = Get-PropOrNull $Vm 'osName'
        OsVersion               = Get-PropOrNull $Vm 'osVersion'
        HyperVGeneration        = if ($hvGen) { $hvGen.ToUpperInvariant() } else { $null }
        HyperVGenerationSource  = if (Get-PropOrNull $Vm 'hyperVGen') { 'InstanceView' } elseif ($hvGen) { 'OsDisk' } else { $null }
        DiskControllerType      = if ($controller) { $controller } else { 'SCSI' }
        DiskControllerReported  = [bool]$controller
        NicCount                = [math]::Max($nicIds.Count, $Nics.Count)
        AcceleratedNetworking   = $accelNics -gt 0
        AcceleratedNicCount     = $accelNics
        DataDiskCount           = $dataDisks.Count
        DiskSkus                = $skuSet
        UsesPremiumStorage      = $usesPremium
        UsesUltraDisk           = $usesUltra
        UsesPremiumV2           = $usesPv2
        WriteAcceleratorDisks   = $waCount
        EphemeralOsDisk         = $ephemeral
        EphemeralPlacement      = if ($ephemeral) { $(if (Get-PropOrNull $Vm 'ephemeralPlacement') { Get-PropOrNull $Vm 'ephemeralPlacement' } else { 'CacheDisk' }) } else { $null }
        SecurityType            = if (Get-PropOrNull $Vm 'securityType') { Get-PropOrNull $Vm 'securityType' } else { 'Standard' }
        EncryptionAtHost        = [bool](Get-PropOrNull $Vm 'encryptionAtHost')
        CustomerManagedKeys     = $cmk
        AzureDiskEncryption     = $HasAde
        Hibernation             = [bool](Get-PropOrNull $Vm 'hibernation')
        Priority                = if (Get-PropOrNull $Vm 'priority') { Get-PropOrNull $Vm 'priority' } else { 'Regular' }
        IsSpot                  = (Get-PropOrNull $Vm 'priority') -eq 'Spot'
        LicenseType             = Get-PropOrNull $Vm 'licenseType'
        ImageReference          = $imageRef
        GalleryImageId          = $galleryImage
        NestedVirtualization    = 'Unknown'
        TempDiskRequirement     = 'Unknown'
        AdvisorRetirement       = @($Advisor)
    }
}

Export-ModuleMember -Function Invoke-ArgQuery, Get-EstateInventory, ConvertTo-VmRecord, Get-PropOrNull
