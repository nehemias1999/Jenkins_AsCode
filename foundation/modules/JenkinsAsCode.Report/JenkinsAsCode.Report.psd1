@{
    RootModule        = 'JenkinsAsCode.Report.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '8aab5e90-5019-4987-8191-d5550ea5965d'
    Author            = 'nehemias1999'
    CompanyName       = 'Unspecified'
    Copyright         = '(c) 2026 nehemias1999. Released under the MIT License.'
    Description       = 'Evidence writing: plan reports as JSON and Markdown, with redaction by property name and masking by value applied at the writer rather than at each call site.'
    PowerShellVersion = '5.1'

    RequiredModules   = @('JenkinsAsCode.Plan')

    FunctionsToExport = @(
        'Protect-SecretInText',
        'Remove-SensitiveValue',
        'Get-JenkinsAsCodeProvenance',
        'Write-JenkinsAsCodeReport',
        'Format-JenkinsAsCodeReportMarkdown'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Reporting', 'Evidence', 'Redaction')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
