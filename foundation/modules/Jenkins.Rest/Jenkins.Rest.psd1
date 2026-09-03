@{
    RootModule        = 'Jenkins.Rest.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = 'e5930914-3c06-4eea-b6f7-de69c603735c'
    Author            = 'nehemias1999'
    CompanyName       = 'Unspecified'
    Copyright         = '(c) 2026 nehemias1999. Released under the MIT License.'
    Description       = 'What is Jenkins-specific about talking to a controller: folder paths as URLs, the config.xml endpoint, and the guidance behind a 401 or a 403. The generic HTTP half is in JenkinsAsCode.Http.'
    PowerShellVersion = '5.1'

    RequiredModules   = @('JenkinsAsCode.Configuration', 'JenkinsAsCode.Http')

    FunctionsToExport = @(
        'New-JenkinsJobPath',
        'Get-JenkinsContext',
        'Invoke-JenkinsRequest',
        'Get-JenkinsJson',
        'Get-JenkinsConfigXml',
        'Get-JenkinsControllerVersion'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Jenkins', 'REST', 'ReadOnly')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
