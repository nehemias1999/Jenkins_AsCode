@{
    RootModule        = 'JenkinsAsCode.Http.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '63e6b596-ca79-4dca-9836-0c696fb09b4b'
    Author            = 'nehemias1999'
    CompanyName       = 'Unspecified'
    Copyright         = '(c) 2026 nehemias1999. Released under the MIT License.'
    Description       = 'Read-only HTTP shared by every transport: URL construction, Basic credentials, retry and error translation. It knows nothing about Jenkins or Jira, and exposes no way to send anything but GET.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Assert-HttpBaseUrl',
        'ConvertFrom-JsonResponse',
        'New-HttpUri',
        'New-BasicAuthorizationHeader',
        'Get-HttpResponseHeader',
        'Get-HttpErrorStatusCode',
        'Get-HttpRetryAfterSecond',
        'Get-HttpRetryDecision',
        'Get-HttpRetryableStatusCode',
        'Invoke-ReadOnlyRequest'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Http', 'ReadOnly', 'Retry')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
