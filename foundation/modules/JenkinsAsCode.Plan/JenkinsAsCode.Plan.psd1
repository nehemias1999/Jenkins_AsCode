@{
    RootModule        = 'JenkinsAsCode.Plan.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '30aaa85f-d6c4-4487-83af-04e647c306a6'
    Author            = 'nehemias1999'
    CompanyName       = 'Unspecified'
    Copyright         = '(c) 2026 nehemias1999. Released under the MIT License.'
    Description       = 'The shared plan model: one flat list of operations with a closed action and status vocabulary, and the test that says whether anything in a plan could not be determined.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-PlanStatusName',
        'Get-PlanActionName',
        'New-Plan',
        'New-PlanOperation',
        'Add-PlanOperation',
        'Get-PlanSummary',
        'Test-PlanBlocked',
        'Write-PlanSummary'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Plan', 'InfrastructureAsCode', 'DryRun')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
