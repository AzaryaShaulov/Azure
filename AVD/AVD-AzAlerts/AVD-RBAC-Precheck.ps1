<#
.SYNOPSIS
    Validates required RBAC permissions for AVD alert deployment scripts.

.DESCRIPTION
    Evaluates whether the current or specified principal has the Azure RBAC actions
    required by AVD-Deploy-Alert-LogicApp.ps1 and
    AVD-Webhook-TestAlert.ps1 across resource group, workspace, and subscription scopes.

    Outputs a table and optional CSV report showing each required action, scope, and
    whether the principal is granted that action.

.PARAMETER SubscriptionId
    Target Azure subscription ID.

.PARAMETER ResourceGroupName
    Resource group where alert resources are deployed.

.PARAMETER WorkspaceName
    Log Analytics workspace name.

.PARAMETER WorkspaceResourceGroupName
    Resource group containing the Log Analytics workspace.

.PARAMETER Assignee
    Optional UPN or service principal appId to evaluate instead of the signed-in user.

.PARAMETER AssigneeObjectId
    Optional Entra ID object ID of the principal to evaluate.

.PARAMETER CsvPath
    Output path for the CSV permission report. Defaults to current directory.

.PARAMETER CustomRoleJsonPath
    Output path for the custom role action manifest when -EmitCustomRoleJson is used.

.PARAMETER RequireResourceGroupCreate
    Include the resource group create action in the check set.

.PARAMETER RequireRoleAssignmentWrite
    Include the role assignment write action in the check set.

.PARAMETER RequireWebhookTest
    Include the Logic App callback URL action needed by AVD-Webhook-TestAlert.ps1.

.PARAMETER EmitCustomRoleJson
    Export a JSON manifest of required and missing actions for custom role creation.

.EXAMPLE
    .\AVD-RBAC-Precheck.ps1 `
      -SubscriptionId "YOUR-SUB-ID" `
      -ResourceGroupName "rg-avd-prod" `
      -WorkspaceName "law-avd-prod" `
      -WorkspaceResourceGroupName "rg-avd-prod"

    Basic precheck for core alert deployment permissions.

.EXAMPLE
    .\AVD-RBAC-Precheck.ps1 `
      -SubscriptionId "YOUR-SUB-ID" `
      -ResourceGroupName "rg-avd-prod" `
      -WorkspaceName "law-avd-prod" `
      -WorkspaceResourceGroupName "rg-avd-prod" `
      -RequireRoleAssignmentWrite -RequireWebhookTest

    Full precheck including role assignment write and webhook test permissions.

.EXAMPLE
    .\AVD-RBAC-Precheck.ps1 `
      -SubscriptionId "YOUR-SUB-ID" `
      -ResourceGroupName "rg-avd-prod" `
      -WorkspaceName "law-avd-prod" `
      -WorkspaceResourceGroupName "rg-avd-prod" `
      -Assignee "deployer@contoso.com" -EmitCustomRoleJson

    Evaluate a specific user and export the action manifest for custom role creation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceResourceGroupName,

    [string]$Assignee,
    [string]$AssigneeObjectId,

    [string]$CsvPath,
    [string]$CustomRoleJsonPath,

    [switch]$RequireResourceGroupCreate,
    [switch]$RequireRoleAssignmentWrite,
    [switch]$RequireWebhookTest,
    [switch]$EmitCustomRoleJson
)

$ErrorActionPreference = 'Stop'

function Write-Section {
    param([string]$Message)
    Write-Output "`n=== $Message ==="
}

function Invoke-AzCliJson {
    param([Parameter(Mandatory = $true)][string[]]$CliArguments)
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $result = & az @CliArguments 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    if ($exitCode -ne 0) {
        throw "Azure CLI command failed: az $($CliArguments -join ' ')`n$($result | Out-String)"
    }
    $text = ($result | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    return ($text | ConvertFrom-Json)
}

function Invoke-AzCliText {
    param([Parameter(Mandatory = $true)][string[]]$CliArguments)
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $result = & az @CliArguments 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    if ($exitCode -ne 0) {
        throw "Azure CLI command failed: az $($CliArguments -join ' ')`n$($result | Out-String)"
    }
    return ($result | Out-String).Trim()
}

function Convert-WildcardToRegex {
    param([string]$Pattern)
    if ([string]::IsNullOrWhiteSpace($Pattern)) {
        return '^$'
    }
    return '^' + [Regex]::Escape($Pattern).Replace('\*', '.*') + '$'
}

function Test-PatternMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Value
    )
    $regex = Convert-WildcardToRegex -Pattern $Pattern
    return ($Value -match $regex)
}

function Resolve-Principal {
    param(
        [Parameter(Mandatory = $true)][psobject]$AccountInfo,
        [string]$Assignee,
        [string]$AssigneeObjectId
    )

    if (-not [string]::IsNullOrWhiteSpace($Assignee) -or -not [string]::IsNullOrWhiteSpace($AssigneeObjectId)) {
        $principalName = $Assignee
        $principalType = 'unknown'
        $principalObjectId = $AssigneeObjectId

        if ([string]::IsNullOrWhiteSpace($principalObjectId) -and -not [string]::IsNullOrWhiteSpace($Assignee)) {
            try {
                $principalObjectId = Invoke-AzCliText -CliArguments @('ad', 'user', 'show', '--id', $Assignee, '--query', 'id', '-o', 'tsv')
                if (-not [string]::IsNullOrWhiteSpace($principalObjectId)) {
                    $principalType = 'user'
                }
            }
            catch {
                Write-Verbose "Could not resolve assignee '$Assignee' as user: $($_.Exception.Message)"
            }

            if ([string]::IsNullOrWhiteSpace($principalObjectId)) {
                try {
                    $principalObjectId = Invoke-AzCliText -CliArguments @('ad', 'sp', 'show', '--id', $Assignee, '--query', 'id', '-o', 'tsv')
                    if (-not [string]::IsNullOrWhiteSpace($principalObjectId)) {
                        $principalType = 'servicePrincipal'
                    }
                }
                catch {
                    Write-Verbose "Could not resolve assignee '$Assignee' as service principal: $($_.Exception.Message)"
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($principalName) -and -not [string]::IsNullOrWhiteSpace($principalObjectId)) {
            $principalName = $principalObjectId
        }

        return [pscustomobject]@{
            PrincipalType = $principalType
            PrincipalName = $principalName
            PrincipalObjectId = $principalObjectId
        }
    }

    $principalType = $AccountInfo.user.type
    $principalName = $AccountInfo.user.name
    $principalObjectId = $null

    if ($principalType -eq 'user') {
        try {
            $principalObjectId = Invoke-AzCliText -CliArguments @('ad', 'signed-in-user', 'show', '--query', 'id', '-o', 'tsv')
        }
        catch {
            Write-Verbose "Could not resolve signed-in user object id: $($_.Exception.Message)"
        }
    }
    elseif ($principalType -eq 'servicePrincipal') {
        try {
            $principalObjectId = Invoke-AzCliText -CliArguments @('ad', 'sp', 'show', '--id', $principalName, '--query', 'id', '-o', 'tsv')
        }
        catch {
            Write-Verbose "Could not resolve service principal object id for '$principalName': $($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{
        PrincipalType = $principalType
        PrincipalName = $principalName
        PrincipalObjectId = $principalObjectId
    }
}

function Get-RoleAssignmentsForScope {
    param(
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][psobject]$Principal
    )

    try {
        if (-not [string]::IsNullOrWhiteSpace($Principal.PrincipalObjectId)) {
            $parsed = Invoke-AzCliJson -CliArguments @(
                'role', 'assignment', 'list',
                '--scope', $Scope,
                '--include-inherited',
                '--assignee-object-id', $Principal.PrincipalObjectId,
                '-o', 'json'
            )
        }
        else {
            $parsed = Invoke-AzCliJson -CliArguments @(
                'role', 'assignment', 'list',
                '--scope', $Scope,
                '--include-inherited',
                '--assignee', $Principal.PrincipalName,
                '-o', 'json'
            )
        }
    }
    catch {
        throw "Could not list role assignments at scope '$Scope'. Ensure you can read RBAC assignments on this scope.`n$($_.Exception.Message)"
    }

    if ($null -eq $parsed) {
        return @()
    }

    return @($parsed)
}

function Get-RolePermissionSet {
    param(
        [array]$RoleAssignments,
        [Parameter(Mandatory = $true)][hashtable]$RoleDefinitionCache
    )

    $permissionSets = @()

    if ($null -eq $RoleAssignments -or @($RoleAssignments).Count -eq 0) {
        return $permissionSets
    }

    foreach ($assignment in $RoleAssignments) {
        $roleName = $assignment.roleDefinitionName
        if ([string]::IsNullOrWhiteSpace($roleName)) {
            continue
        }

        if (-not $RoleDefinitionCache.ContainsKey($roleName)) {
            $def = Invoke-AzCliJson -CliArguments @('role', 'definition', 'list', '--name', $roleName)
            if ($def -and @($def).Count -gt 0) {
                $RoleDefinitionCache[$roleName] = $def[0]
            }
            else {
                $RoleDefinitionCache[$roleName] = $null
            }
        }

        $roleDef = $RoleDefinitionCache[$roleName]
        if ($null -eq $roleDef -or $null -eq $roleDef.permissions) {
            continue
        }

        foreach ($perm in $roleDef.permissions) {
            $permissionSets += [pscustomobject]@{
                RoleName = $roleName
                Actions = @($perm.actions)
                NotActions = @($perm.notActions)
            }
        }
    }

    return $permissionSets
}

function Test-ActionGranted {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][array]$PermissionSets
    )

    foreach ($permSet in $PermissionSets) {
        $isAllowed = $false
        foreach ($allow in $permSet.Actions) {
            if (Test-PatternMatch -Pattern $allow -Value $Action) {
                $isAllowed = $true
                break
            }
        }

        if (-not $isAllowed) {
            continue
        }

        $isDenied = $false
        foreach ($deny in $permSet.NotActions) {
            if (Test-PatternMatch -Pattern $deny -Value $Action) {
                $isDenied = $true
                break
            }
        }

        if (-not $isDenied) {
            return $true
        }
    }

    return $false
}

Write-Section 'Pre-flight'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI not found. Install from https://learn.microsoft.com/cli/azure/install-azure-cli"
}

$accountInfo = Invoke-AzCliJson -CliArguments @('account', 'show')
if ($null -eq $accountInfo) {
    throw "Not logged in. Run 'az login' first."
}

Invoke-AzCliText -CliArguments @('account', 'set', '--subscription', $SubscriptionId, '-o', 'none') | Out-Null
$accountInfo = Invoke-AzCliJson -CliArguments @('account', 'show')

$principal = Resolve-Principal -AccountInfo $accountInfo -Assignee $Assignee -AssigneeObjectId $AssigneeObjectId
Write-Output "Subscription: $($accountInfo.name) ($($accountInfo.id))"
Write-Output "Principal: $($principal.PrincipalName) [$($principal.PrincipalType)]"

Write-Section 'Resolve Scopes'
$rgScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
$workspace = Invoke-AzCliJson -CliArguments @(
    'monitor', 'log-analytics', 'workspace', 'show',
    '--resource-group', $WorkspaceResourceGroupName,
    '--workspace-name', $WorkspaceName
)
$workspaceScope = $workspace.id

Write-Output "Resource Group scope: $rgScope"
Write-Output "Workspace scope: $workspaceScope"

Write-Section 'Collect Role Assignments'
$roleDefinitionCache = @{}
$rgAssignments = @(Get-RoleAssignmentsForScope -Scope $rgScope -Principal $principal)
$workspaceAssignments = @(Get-RoleAssignmentsForScope -Scope $workspaceScope -Principal $principal)
$subscriptionScope = "/subscriptions/$SubscriptionId"
$subscriptionAssignments = @(Get-RoleAssignmentsForScope -Scope $subscriptionScope -Principal $principal)

$rgPermSets = Get-RolePermissionSet -RoleAssignments $rgAssignments -RoleDefinitionCache $roleDefinitionCache
$workspacePermSets = Get-RolePermissionSet -RoleAssignments $workspaceAssignments -RoleDefinitionCache $roleDefinitionCache
$subscriptionPermSets = Get-RolePermissionSet -RoleAssignments $subscriptionAssignments -RoleDefinitionCache $roleDefinitionCache

Write-Output "RG assignments found: $(@($rgAssignments).Count)"
Write-Output "Workspace assignments found: $(@($workspaceAssignments).Count)"
Write-Output "Subscription assignments found: $(@($subscriptionAssignments).Count)"

Write-Section 'Permission Checks'

if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    $subPrefix = if ($SubscriptionId.Length -ge 8) { $SubscriptionId.Substring(0, 8) } else { $SubscriptionId }
    $CsvPath = ".\\avd-roles-precheck-report-$subPrefix.csv"
}

$checks = @(
    [pscustomobject]@{ Script = 'AVD-Deploy-Alert-LogicApp.ps1'; ScopeName = 'ResourceGroup'; Scope = $rgScope; Action = 'Microsoft.Insights/actionGroups/read'; Why = 'Read action groups' },
    [pscustomobject]@{ Script = 'AVD-Deploy-Alert-LogicApp.ps1'; ScopeName = 'ResourceGroup'; Scope = $rgScope; Action = 'Microsoft.Insights/actionGroups/write'; Why = 'Create/update action groups' },
    [pscustomobject]@{ Script = 'AVD-Deploy-Alert-LogicApp.ps1'; ScopeName = 'ResourceGroup'; Scope = $rgScope; Action = 'Microsoft.Insights/scheduledQueryRules/read'; Why = 'Read scheduled query alerts' },
    [pscustomobject]@{ Script = 'AVD-Deploy-Alert-LogicApp.ps1'; ScopeName = 'ResourceGroup'; Scope = $rgScope; Action = 'Microsoft.Insights/scheduledQueryRules/write'; Why = 'Create/update scheduled query alerts' },
    [pscustomobject]@{ Script = 'AVD-Deploy-Alert-LogicApp.ps1, AVD-Webhook-TestAlert.ps1'; ScopeName = 'ResourceGroup'; Scope = $rgScope; Action = 'Microsoft.Logic/workflows/read'; Why = 'Read Logic App workflow' },
    [pscustomobject]@{ Script = 'AVD-Deploy-Alert-LogicApp.ps1'; ScopeName = 'ResourceGroup'; Scope = $rgScope; Action = 'Microsoft.Logic/workflows/write'; Why = 'Deploy/update Logic App workflow' },
    [pscustomobject]@{ Script = 'AVD-Deploy-Alert-LogicApp.ps1'; ScopeName = 'ResourceGroup'; Scope = $rgScope; Action = 'Microsoft.Web/connections/read'; Why = 'Read API connections' },
    [pscustomobject]@{ Script = 'AVD-Deploy-Alert-LogicApp.ps1'; ScopeName = 'ResourceGroup'; Scope = $rgScope; Action = 'Microsoft.Web/connections/write'; Why = 'Create/update Office 365 connection' },
    [pscustomobject]@{ Script = 'AVD-Deploy-Alert-LogicApp.ps1'; ScopeName = 'Workspace'; Scope = $workspaceScope; Action = 'Microsoft.OperationalInsights/workspaces/read'; Why = 'Resolve workspace details' }
)

if ($RequireResourceGroupCreate) {
    $checks += [pscustomobject]@{ Script = 'AVD-Deploy-Alert-LogicApp.ps1'; ScopeName = 'Subscription'; Scope = $subscriptionScope; Action = 'Microsoft.Resources/subscriptions/resourceGroups/write'; Why = 'Create resource group if missing' }
}

if ($RequireRoleAssignmentWrite) {
    $checks += [pscustomobject]@{ Script = 'AVD-Deploy-Alert-LogicApp.ps1'; ScopeName = 'Workspace'; Scope = $workspaceScope; Action = 'Microsoft.Authorization/roleAssignments/write'; Why = 'Assign Log Analytics Reader to Logic App MI' }
}

if ($RequireWebhookTest) {
    $checks += [pscustomobject]@{ Script = 'AVD-Webhook-TestAlert.ps1'; ScopeName = 'ResourceGroup'; Scope = $rgScope; Action = 'Microsoft.Logic/workflows/triggers/listCallbackUrl/action'; Why = 'Resolve Logic App callback URL for test payload' }
}

$results = @()
foreach ($check in $checks) {
    $permSets = switch ($check.ScopeName) {
        'ResourceGroup' { $rgPermSets }
        'Workspace' { $workspacePermSets + $rgPermSets + $subscriptionPermSets }
        'Subscription' { $subscriptionPermSets }
        default { @() }
    }

    $granted = Test-ActionGranted -Action $check.Action -PermissionSets $permSets
    $results += [pscustomobject]@{
        Script = $check.Script
        Scope = $check.ScopeName
        ScopeId = $check.Scope
        Action = $check.Action
        Purpose = $check.Why
        Granted = $granted
    }
}

$results | Format-Table Script, Scope, Action, Purpose, Granted -AutoSize -Wrap

try {
    $csvDirectory = Split-Path -Path $CsvPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($csvDirectory) -and -not (Test-Path -Path $csvDirectory)) {
        New-Item -Path $csvDirectory -ItemType Directory -Force | Out-Null
    }

    $results | Export-Csv -Path $CsvPath -NoTypeInformation -Force
    Write-Output "CSV report written: $CsvPath"
}
catch {
    Write-Warning "Failed to write CSV report to '$CsvPath': $($_.Exception.Message)"
}

if ($EmitCustomRoleJson) {
    if ([string]::IsNullOrWhiteSpace($CustomRoleJsonPath)) {
        $subPrefix = if ($SubscriptionId.Length -ge 8) { $SubscriptionId.Substring(0, 8) } else { $SubscriptionId }
        $CustomRoleJsonPath = ".\\avd-custom-rbac-actions-$subPrefix.json"
    }

    $byScope = @(
        $results |
            Group-Object { "$($_.Scope)|$($_.ScopeId)" } |
            ForEach-Object {
                $groupRows = $_.Group
                $sample = $groupRows[0]
                [pscustomobject]@{
                    Scope = $sample.Scope
                    ScopeId = $sample.ScopeId
                    RequiredActions = @($groupRows.Action | Sort-Object -Unique)
                    MissingActions = @($groupRows | Where-Object { -not $_.Granted } | Select-Object -ExpandProperty Action -Unique | Sort-Object)
                }
            }
    )

    $customRolePlan = [pscustomobject]@{
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        SubscriptionId = $SubscriptionId
        PrincipalName = $principal.PrincipalName
        PrincipalType = $principal.PrincipalType
        PrincipalObjectId = $principal.PrincipalObjectId
        Scopes = $byScope
    }

    try {
        $jsonDirectory = Split-Path -Path $CustomRoleJsonPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($jsonDirectory) -and -not (Test-Path -Path $jsonDirectory)) {
            New-Item -Path $jsonDirectory -ItemType Directory -Force | Out-Null
        }

        $customRolePlan | ConvertTo-Json -Depth 8 | Out-File -FilePath $CustomRoleJsonPath -Encoding utf8
        Write-Output "Custom RBAC action manifest written: $CustomRoleJsonPath"
    }
    catch {
        Write-Warning "Failed to write custom RBAC action manifest to '$CustomRoleJsonPath': $($_.Exception.Message)"
    }
}

$missing = @($results | Where-Object { -not $_.Granted })
Write-Output ""
if ($missing.Count -eq 0) {
    Write-Output "PASS: principal appears to have all required permissions for AVD deployment scripts."
    exit 0
}

Write-Output "FAIL: missing required permissions:"
$missing | ForEach-Object {
    Write-Output "- [$($_.Scope)] $($_.Action) ($($_.Purpose))"
}

Write-Output ""
Write-Output "Grant the missing action permissions via custom RBAC role(s) at the indicated scope(s):"
$missing | ForEach-Object {
    Write-Output "- [$($_.Scope)] $($_.Action)"
}

exit 2
