<#
    Tests for the pure decision functions inside the pipeline-drift entry point.

    They are extracted from the script with a regular expression and dot-sourced, so
    they can be exercised in isolation without turning a one-module rule into a shared
    module it does not belong in. The rules of one automation live in that automation
    (see ADR 0003), and this is how they still get unit tested.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')

    $entryPoint = Join-Path (Get-RepositoryRoot) 'automations/pipeline-drift/Invoke-PipelineDrift.ps1'
    $source = Get-Content -LiteralPath $entryPoint -Raw

    foreach ($name in @('Get-JenkinsfileAgentLabel', 'Get-CommitAlignmentStatus', 'Get-JenkinsfileDriftStatus')) {
        $match = [regex]::Match($source, "(?ms)^function $name \{.*?^\}")
        if (-not $match.Success) { throw "Could not extract $name from $entryPoint." }
        . ([scriptblock]::Create($match.Value))
    }
}

Describe 'Get-JenkinsfileAgentLabel' {

    It 'finds a literal agent label' {
        $jenkinsfile = "pipeline { agent { label 'EXAMPLE-AGENT-1' } }"
        Get-JenkinsfileAgentLabel -Jenkinsfile $jenkinsfile | Should -Be 'EXAMPLE-AGENT-1'
    }

    It 'returns a parameter reference as found, without pretending it is a label' {
        # The first real Jenkinsfile this ran against declared its agent this way.
        # Which agent runs is decided per build, so the caller reports it as such.
        $jenkinsfile = 'pipeline { agent { label "${params.ExampleAgent}" } }'
        Get-JenkinsfileAgentLabel -Jenkinsfile $jenkinsfile | Should -Be '${params.ExampleAgent}'
    }

    It 'returns every distinct label, so the caller can report an ambiguity' {
        # Read lexically, so a label inside a comment matches too. Returning all of
        # them and stating the count is honest about a regex reading a language it
        # does not parse; returning the first would assert an answer it cannot have.
        $jenkinsfile = "// label 'OLD-AGENT'`npipeline { agent { label 'NEW-AGENT' } }"
        @(Get-JenkinsfileAgentLabel -Jenkinsfile $jenkinsfile).Count | Should -Be 2
    }

    It 'returns nothing for agent any, rather than inventing a label' {
        @(Get-JenkinsfileAgentLabel -Jenkinsfile 'pipeline { agent any }').Count | Should -Be 0
    }

    It 'returns nothing for an empty file rather than failing' {
        @(Get-JenkinsfileAgentLabel -Jenkinsfile '').Count | Should -Be 0
    }
}

Describe 'Get-CommitAlignmentStatus' {

    It 'calls equal commits ok' {
        $sha = '4fe66d5000000000000000000000000000000000'
        (Get-CommitAlignmentStatus -RemoteCommit $sha -LocalCommit $sha).Status | Should -Be 'ok'
    }

    It 'calls a stale clone a warning, not an error' {
        # A clone being behind the remote is the normal state of a clone. Reporting it
        # as a failure would make every run noisy and train people to ignore it.
        $status = Get-CommitAlignmentStatus -RemoteCommit ('a' * 40) -LocalCommit ('b' * 40)
        $status.Status | Should -Be 'warning'
        $status.Reason | Should -Match 'different commits'
    }

    It 'blocks when the branch does not exist on the remote' {
        (Get-CommitAlignmentStatus -RemoteCommit '' -LocalCommit ('b' * 40)).Status | Should -Be 'blocked'
    }

    It 'blocks when the working copy has no commit' {
        (Get-CommitAlignmentStatus -RemoteCommit ('a' * 40) -LocalCommit '').Status | Should -Be 'blocked'
    }
}

Describe 'Get-JenkinsfileDriftStatus' {

    It 'treats identical and cosmetic as ok, and says which it was' {
        (Get-JenkinsfileDriftStatus -Verdict 'identical' -Detail '').Status | Should -Be 'ok'
        $cosmetic = Get-JenkinsfileDriftStatus -Verdict 'cosmetic' -Detail 'Whitespace only.'
        $cosmetic.Status | Should -Be 'ok'
        $cosmetic.Reason | Should -Match 'Whitespace only'
    }

    It 'treats drift as pending, which here means a person acts on it' {
        (Get-JenkinsfileDriftStatus -Verdict 'drift' -Detail 'Content differs.').Status | Should -Be 'pending'
    }

    It 'rejects a verdict outside the closed set' {
        # A free-text verdict is how a plan becomes prose nothing can enforce.
        { Get-JenkinsfileDriftStatus -Verdict 'probably-fine' -Detail '' } | Should -Throw
    }
}

Describe 'The extracted functions run under the same rules as production' {

    It 'has StrictMode in force, so a test cannot pass on something production would reject' {
        # Recorded as a finding, and it was wrong: StrictMode IS in force here.
        # TestHelpers sets it, BeforeAll dot-sources TestHelpers, and both the It
        # bodies and a function built with [scriptblock]::Create inherit it from the
        # invoking scope - verified before writing this.
        #
        # The test stays anyway, because the claim was plausible enough to reach a
        # report: production runs these functions with Set-StrictMode -Version
        # Latest, this repository carries three long comments about specific
        # StrictMode traps, and nothing here said whether the semantics matched. Now
        # something does.
        $probe = [pscustomobject]@{ present = 1 }
        { $null = $probe.Absent.Length } | Should -Throw
    }

    It 'reaches inside a function extracted by regex and dot-sourced' {
        # The exact shape this file uses to load the pure functions out of the entry
        # point. Verified inside Pester, not only in a bare shell: if a future Pester
        # or PowerShell stopped propagating StrictMode into it, these tests would
        # quietly start accepting what production rejects.
        . ([scriptblock]::Create('function Test-StrictProbe { param($o) return $o.Absent }'))
        { $null = Test-StrictProbe -o ([pscustomobject]@{ present = 1 }) } | Should -Throw
    }
}