@{
    RootModule        = 'Jenkins.Jobs.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '82d5bdf9-c6c5-45c3-aa5a-f57c7caee034'
    Author            = 'nehemias1999'
    CompanyName       = 'Unspecified'
    Copyright         = '(c) 2026 nehemias1999. Released under the MIT License.'
    Description       = 'Reads Jenkins folders and job definitions. The config.xml parser is a pure function over a string, so every rule it applies is testable against a fixture with no controller.'
    PowerShellVersion = '5.1'

    RequiredModules   = @('Jenkins.Rest')

    FunctionsToExport = @(
        'Get-JenkinsJobTypeName',
        'ConvertTo-Xml10Text',
        'Test-JenkinsContainerClass',
        'Get-XmlNodeText',
        'Get-JenkinsJobParameter',
        'Get-JenkinsJobTrigger',
        'Get-JenkinsJobScm',
        'ConvertFrom-JenkinsJobConfigXml',
        'Get-JenkinsFolderChild',
        'Get-JenkinsJobTree',
        'Get-JenkinsJobDefinition'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Jenkins', 'ConfigXml', 'Inventory')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
