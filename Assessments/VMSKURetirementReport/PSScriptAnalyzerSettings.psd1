@{
    # PSScriptAnalyzer settings for VMSKURetirementReport. Used by build.ps1 -Task Lint and CI.
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # The assessment is an interactive CLI; Write-Host writes to the information stream (PS 5+) for progress output.
        'PSAvoidUsingWriteHost'
        # New-* helpers only construct in-memory objects / HTML strings and Update-VmAction mutates an in-memory record;
        # none changes system state, so ShouldProcess would add prompts without value. The tool is read-only by design.
        'PSUseShouldProcessForStateChangingFunctions'
        # Collection-returning helpers (Get-SkuCatalogs, Test-CandidateGates, ...) are named for what they return.
        'PSUseSingularNouns'
    )

    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('7.2')
        }
    }
}
