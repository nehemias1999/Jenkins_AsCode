@{
    RootModule        = 'JenkinsAsCode.Configuration.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = '031c694d-490c-4fad-8ae0-ab6a5db396af'
    Author            = 'nehemias1999'
    CompanyName       = 'Unspecified'
    Copyright         = '(c) 2026 nehemias1999. Released under the MIT License.'
    Description       = 'Loads declared state: .env files into the process environment, JSON configuration validated against the schema it declares, and membership lists resolved from environment variables rather than from Git.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Import-JenkinsAsCodeEnvironment',
        'Resolve-JenkinsAsCodePath',
        'Get-JenkinsAsCodeSchemaEngine',
        'Test-JenkinsAsCodeConfiguration',
        'Get-JenkinsAsCodeConfiguration',
        'Get-JenkinsAsCodeRequiredValue'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Configuration', 'JsonSchema', 'DotEnv')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
