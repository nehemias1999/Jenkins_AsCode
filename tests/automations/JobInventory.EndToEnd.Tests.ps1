<#
    End to end exercise of an entry point with the transport doubled.

    Until now the only test that ran an entry point ran it with validate, so
    inventory, plan and smoke - roughly the last 40% of each file, including all of
    the report writing - were never executed by the suite. The two report-writing
    bugs this repository records, the byte order mark and the path that produced no
    file at all, were both found in production for that reason.

    There is no live controller here. The transport is replaced, and the job
    definition is built by the real parser from the real fixture, so the shapes are
    the ones production sees rather than shapes invented to suit the test.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
    . (Join-Path (Get-RepositoryRoot) 'foundation/Import-Foundation.ps1')

    $script:Entry = Join-Path (Get-RepositoryRoot) 'automations/job-inventory/Invoke-JobInventory.ps1'
    $script:Template = Join-Path (Get-RepositoryRoot) 'automations/job-inventory/config/jobs.example.json'
    $script:DeclaredPath = 'EXAMPLE-FOLDER/example-pipeline'

    function Get-FakeContext {
        # The shape Get-JenkinsContext really returns, minus the credential: nothing
        # here reaches the network, so the header only has to exist.
        return [pscustomobject]@{
            BaseUrl              = 'https://jenkins.example.com'
            UserName             = 'example-user'
            Headers              = @{ Accept = 'application/json' }
            TimeoutSeconds       = 5
            MaximumRetryCount    = 1
            RetryAfterCapSeconds = 1
        }
    }

    function Get-FakeDefinition {
        # Parsed from the fixture by the real parser, so the declaration in the
        # template and the definition the run sees agree the way they would live.
        return ConvertFrom-JenkinsJobConfigXml -Xml (Get-FixtureXml -Name 'pipeline-from-scm.config.xml')
    }

    function Get-TemporaryReportPath {
        return Join-Path ([System.IO.Path]::GetTempPath()) ('jenkinsascode-e2e-' + [guid]::NewGuid().ToString('N') + '.json')
    }
}

Describe 'job-inventory plan, with the controller doubled' {

    BeforeEach {
        $env:JENKINS_URL = 'https://jenkins.example.com'
        $env:JENKINS_USER = 'example-user'
        $env:JENKINS_API_TOKEN = 'example-token'
        $script:Report = Get-TemporaryReportPath
    }

    AfterEach {
        Remove-Item Env:JENKINS_URL, Env:JENKINS_USER, Env:JENKINS_API_TOKEN -ErrorAction SilentlyContinue
        Remove-Assertedly -Path $script:Report
        $markdown = [System.IO.Path]::ChangeExtension($script:Report, '.md')
        Remove-Assertedly -Path $markdown
    }

    It 'writes a report that parses, which is what the byte order mark bug broke' {
        Mock Get-JenkinsContext { Get-FakeContext }
        Mock Get-JenkinsControllerVersion { '2.999.example' }
        Mock Get-JenkinsJobTree { @([pscustomobject]@{ name = 'example-pipeline'; path = 'EXAMPLE-FOLDER/example-pipeline'; className = 'org.jenkinsci.plugins.workflow.job.WorkflowJob'; isContainer = $false; depth = 1; truncated = $false }) }
        Mock Get-JenkinsJobDefinition { Get-FakeDefinition }

        & $script:Entry -Command plan -ConfigurationPath $script:Template -ReportPath $script:Report | Out-Null

        Test-Path -LiteralPath $script:Report | Should -BeTrue
        # Parsed rather than merely present: a report nobody can parse is not evidence.
        { Get-Content -LiteralPath $script:Report -Raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'records who ran it, against what, and at what scope' {
        Mock Get-JenkinsContext { Get-FakeContext }
        Mock Get-JenkinsControllerVersion { '2.999.example' }
        Mock Get-JenkinsJobTree { @() }
        Mock Get-JenkinsJobDefinition { Get-FakeDefinition }

        & $script:Entry -Command plan -ConfigurationPath $script:Template -ReportPath $script:Report | Out-Null

        $report = Get-Content -LiteralPath $script:Report -Raw | ConvertFrom-Json
        $report.detail.provenance.scope | Should -Be 'all'
        $report.detail.provenance.toolVersion | Should -Not -BeNullOrEmpty
        $report.detail.provenance.declarationFingerprint | Should -Match '^sha256:'
        $report.detail.provenance.schemaEngine | Should -BeIn @('Test-Json', 'reduced')
        $report.detail.controllerVersion | Should -Be '2.999.example'
    }

    It 'names the filtered scope, so pending zero cannot be read as everything is aligned' {
        Mock Get-JenkinsContext { Get-FakeContext }
        Mock Get-JenkinsControllerVersion { '2.999.example' }
        Mock Get-JenkinsJobTree { @() }
        Mock Get-JenkinsJobDefinition { Get-FakeDefinition }

        & $script:Entry -Command plan -ConfigurationPath $script:Template -ReportPath $script:Report -JobKey 'example-pipeline' | Out-Null

        $report = Get-Content -LiteralPath $script:Report -Raw | ConvertFrom-Json
        $report.detail.provenance.scope | Should -Be 'jobKey=example-pipeline'
    }

    It 'writes the Markdown summary beside the JSON' {
        Mock Get-JenkinsContext { Get-FakeContext }
        Mock Get-JenkinsControllerVersion { '2.999.example' }
        Mock Get-JenkinsJobTree { @() }
        Mock Get-JenkinsJobDefinition { Get-FakeDefinition }

        & $script:Entry -Command plan -ConfigurationPath $script:Template -ReportPath $script:Report | Out-Null

        $markdown = [System.IO.Path]::ChangeExtension($script:Report, '.md')
        Test-Path -LiteralPath $markdown | Should -BeTrue
        (Get-Content -LiteralPath $markdown -Raw) | Should -Match 'job-inventory'
    }

    It 'blocks the job it could not read instead of omitting it' {
        # The failure path: one unreadable job must not end the walk, and must not
        # vanish either. It becomes a blocked operation with the reason attached.
        Mock Get-JenkinsContext { Get-FakeContext }
        Mock Get-JenkinsControllerVersion { '2.999.example' }
        Mock Get-JenkinsJobTree { @() }
        Mock Get-JenkinsJobDefinition { throw 'GET /job/EXAMPLE-FOLDER/job/example-pipeline/config.xml answered 403.' }

        & $script:Entry -Command plan -ConfigurationPath $script:Template -ReportPath $script:Report | Out-Null

        $report = Get-Content -LiteralPath $script:Report -Raw | ConvertFrom-Json
        $blocked = @($report.operations | Where-Object { $_.status -eq 'blocked' })
        $blocked.Count | Should -BeGreaterThan 0
        ($blocked | ForEach-Object { $_.reason }) -join ' ' | Should -Match '403'
    }
}