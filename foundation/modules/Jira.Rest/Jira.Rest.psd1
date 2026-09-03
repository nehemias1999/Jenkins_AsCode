@{
    RootModule        = 'Jira.Rest.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = '3beef8b3-4092-4b9e-9173-16d017b96412'
    Author            = 'nehemias1999'
    CompanyName       = 'Unspecified'
    Copyright         = '(c) 2026 nehemias1999. Released under the MIT License.'
    Description       = 'Reads Jira: fields, issues, JQL searches and change history. It has no write path at all, because pipelines commonly transition issues themselves and two writers produce double transitions.'
    PowerShellVersion = '5.1'

    RequiredModules   = @('JenkinsAsCode.Configuration', 'JenkinsAsCode.Http')

    FunctionsToExport = @(
        'Get-JiraContext',
        'Invoke-JiraRequest',
        'Get-JiraField',
        'Find-JiraFieldByName',
        'Get-JiraIssue',
        'Search-JiraIssue',
        'Get-JiraIssueChangelog'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Jira', 'ReadOnly', 'CustomFields')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
