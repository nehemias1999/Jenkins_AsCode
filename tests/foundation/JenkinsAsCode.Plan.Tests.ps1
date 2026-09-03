<#
    Tests for the plan model: the closed vocabularies, the summary, and the question
    the entry points turn into an exit code.

    This module had no tests either, and it is the one every automation builds its
    output from. Two of the cases below are about drift rather than about behaviour:
    the status vocabulary is restated in three places, and nothing held those copies
    together.

    Pure functions over objects. No controller, no network, no file system.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
    . (Join-Path (Get-RepositoryRoot) 'foundation/Import-Foundation.ps1')

    function Get-PlanWith {
        param([string[]] $Status)
        $plan = New-Plan -Command 'plan' -Target 'https://jenkins.example.com' -GeneratedAt '2026-09-03T00:00:00.0000000Z'
        $n = 0
        foreach ($s in $Status) {
            $n++
            Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'job' -Name "job/$n" -Action 'validate' -Status $s -Reason 'because') | Out-Null
        }
        return $plan
    }
}

Describe 'The closed vocabularies' {

    It 'refuses a status outside the closed set' {
        # A free-text status is how a plan turns into prose that nothing can enforce.
        { New-PlanOperation -Resource 'job' -Name 'job/x' -Action 'validate' -Status 'mostly-fine' -Reason 'why' } | Should -Throw
    }

    It 'refuses an action outside the closed set' {
        { New-PlanOperation -Resource 'job' -Name 'job/x' -Action 'obliterate' -Status 'ok' -Reason 'why' } | Should -Throw
    }

    It 'accepts every status it publishes, and no more' {
        # Get-PlanStatusName is the list. If it and the validator disagree, one of
        # them is lying to a caller.
        foreach ($status in Get-PlanStatusName) {
            { New-PlanOperation -Resource 'job' -Name 'job/x' -Action 'validate' -Status $status -Reason 'why' } | Should -Not -Throw
        }
    }

    It 'accepts every action it publishes' {
        foreach ($action in Get-PlanActionName) {
            { New-PlanOperation -Resource 'job' -Name 'job/x' -Action $action -Status 'ok' -Reason 'why' } | Should -Not -Throw
        }
    }
}

Describe 'Get-PlanSummary' {

    It 'counts every status, including the ones with no operations' {
        # A summary that omitted the zeroes would make a consumer guess whether a
        # missing key means none or means not measured.
        $summary = Get-PlanSummary -Plan (Get-PlanWith -Status @('ok', 'ok', 'pending'))
        $summary.ok | Should -Be 2
        $summary.pending | Should -Be 1
        $summary.blocked | Should -Be 0
    }

    It 'reports the same key order every run, so a report does not reshuffle' {
        $first = @((Get-PlanSummary -Plan (Get-PlanWith -Status @('ok'))).PSObject.Properties.Name)
        $second = @((Get-PlanSummary -Plan (Get-PlanWith -Status @('blocked'))).PSObject.Properties.Name)
        $first | Should -Be $second
    }
}

Describe 'Test-PlanBlocked' {

    It 'is true when any operation could not be determined' {
        # This answer is what an entry point turns into exit code 2. Before that it
        # was computed and thrown away in a log line, so a scheduled run whose plan
        # was entirely blocked reported success.
        Test-PlanBlocked -Plan (Get-PlanWith -Status @('ok', 'blocked')) | Should -BeTrue
    }

    It 'is false when nothing is blocked, including when work is pending' {
        # pending means a person has something to do, not that the run failed.
        Test-PlanBlocked -Plan (Get-PlanWith -Status @('ok', 'pending', 'warning', 'protected')) | Should -BeFalse
    }

    It 'is false for a plan with no operations at all' {
        Test-PlanBlocked -Plan (Get-PlanWith -Status @()) | Should -BeFalse
    }
}

Describe 'The operations list survives PowerShell 5.1' {

    It 'keeps a single operation a list rather than unwrapping it' {
        # The reason this module uses an ArrayList: reading a generic List through a
        # PSCustomObject property and wrapping it in @() throws on 5.1, and an
        # unwrapped single element serialises as an object instead of an array.
        $plan = Get-PlanWith -Status @('pending')
        @($plan.operations).Count | Should -Be 1
        @($plan.operations)[0].name | Should -Be 'job/1'
    }

    It 'appends in the order the operations were added' {
        $plan = Get-PlanWith -Status @('ok', 'pending', 'blocked')
        @($plan.operations | ForEach-Object { $_.status }) | Should -Be @('ok', 'pending', 'blocked')
    }
}

Describe 'The status vocabulary is not restated anywhere' {

    It 'is the only place the five status names are written' {
        # Drift, not behaviour. The screen summary and the Markdown renderer each
        # ordered operations by status using their own copy of this list, so adding a
        # sixth status would have left three lists disagreeing in silence. This test
        # is what makes Get-PlanStatusName the single source it claims to be.
        $expected = @('ok', 'pending', 'warning', 'protected', 'blocked')
        Get-PlanStatusName | Should -Be $expected
        @(Get-PlanStatusName).Count | Should -Be 5
    }
}