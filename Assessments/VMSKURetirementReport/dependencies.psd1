# Locked build tools. TreeHash is the SHA-256 of the module's file manifest ("relative path<TAB>file SHA-256" in ordinal
# path order, installer metadata such as PSGetModuleInfo.xml excluded; see Get-ModuleManifest in build.ps1), so it is
# the same on every operating system and for every installer. PackageHash is recorded for reference; the build does not
# verify it.
@{
    Pester = @{
        Version     = '6.2.0'
        PackageHash = 'e6ac7418d4f12500269aaca58ae56cf1caafbbf1afa2cec334e289d1cf50a239'
        TreeHash    = '6bb5c35a5cdac12f97df05b4ccd886a77950a0e1fdf5eb8fe1954b30917b58e1'
    }
    PSScriptAnalyzer = @{
        Version     = '1.24.0'
        PackageHash = 'e86c97d44bb1bc8a1de35e753b85ea1d938f6f9f881639a181507e079bca4556'
        TreeHash    = 'e575faa8b28975d5f7cbe6f8be554d10237628a2bc5262a49907e67121f1a33b'
    }
}
