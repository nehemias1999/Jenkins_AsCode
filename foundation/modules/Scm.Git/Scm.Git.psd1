@{
    RootModule        = 'Scm.Git.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b90cd7b7-9d3e-4020-aab2-d84978c4b4dd'
    Author            = 'nehemias1999'
    CompanyName       = 'Unspecified'
    Copyright         = '(c) 2026 nehemias1999. Released under the MIT License.'
    Description       = 'Resolves what a branch points at and reads a file at that commit, through the git command line, so any git remote takes one code path and no SCM token is needed.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Resolve-GitBranchName',
        'ConvertTo-ProcessArgumentString',
        'Get-TextFingerprint',
        'Compare-ScmText',
        'Invoke-GitCommand',
        'Test-GitWorkingCopy',
        'Get-GitRemoteBranchCommit',
        'Get-GitWorkingCopyCommit',
        'Get-GitFileAtCommit'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Git', 'GitHub', 'Jenkins', 'Drift')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
