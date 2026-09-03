<#
    Tests for branch resolution, fingerprinting and text comparison.

    These are the rules the drift verdict rests on, and all of them are pure
    functions over strings, so they are tested with no repository and no network.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
    . (Join-Path (Get-RepositoryRoot) 'foundation/Import-Foundation.ps1')
}

Describe 'Resolve-GitBranchName' {

    It 'resolves every spelling Jenkins accepts for the same branch' {
        # The result is fed to git ls-remote as refs/heads/<branch>. Leaving the
        # prefix on produces refs/heads/*/main, which matches nothing, and the
        # caller concludes the branch does not exist on a job configured correctly.
        foreach ($specifier in @('main', '*/main', 'origin/main', 'refs/heads/main')) {
            (Resolve-GitBranchName -BranchSpecifier $specifier).Branch | Should -Be 'main'
        }
    }

    It 'resolves the same spellings for a branch not named main' {
        # The function normalises the spelling, never the name. This is not a
        # duplicate of the case above: it is what proves the rule is about the
        # prefix and not about a hard-coded default branch. A job reading an older
        # repository still has to resolve correctly.
        foreach ($specifier in @('master', '*/master', 'origin/master', 'refs/heads/master')) {
            (Resolve-GitBranchName -BranchSpecifier $specifier).Branch | Should -Be 'master'
        }
    }

    It 'keeps the slashes inside a branch name' {
        (Resolve-GitBranchName -BranchSpecifier '*/feature/fase1-fase2').Branch | Should -Be 'feature/fase1-fase2'
    }

    It 'strips only the remote it was told about' {
        # Stripping any leading segment would turn a branch genuinely named
        # upstream/x into x, and report a commit from the wrong branch.
        (Resolve-GitBranchName -BranchSpecifier 'upstream/master' -RemoteName 'origin').Branch | Should -Be 'upstream/master'
        (Resolve-GitBranchName -BranchSpecifier 'upstream/master' -RemoteName 'upstream').Branch | Should -Be 'master'
    }

    It 'reports a wildcard as ambiguous instead of guessing a branch' {
        # A guess here produces a confident, wrong answer about which commit runs,
        # which is worse than no answer.
        foreach ($specifier in @('**', '*', 'feature/*')) {
            $result = Resolve-GitBranchName -BranchSpecifier $specifier
            $result.Ambiguous | Should -BeTrue
            $result.Reason | Should -Not -BeNullOrEmpty
        }
    }

    It 'reports a specifier built from a build parameter as ambiguous' {
        # Which branch runs depends on the build, so no single commit answer exists.
        (Resolve-GitBranchName -BranchSpecifier '${BRANCH_NAME}').Ambiguous | Should -BeTrue
        (Resolve-GitBranchName -BranchSpecifier '$BRANCH').Ambiguous | Should -BeTrue
    }

    It 'reports an empty specifier as ambiguous rather than as branch empty-string' {
        (Resolve-GitBranchName -BranchSpecifier '').Ambiguous | Should -BeTrue
        (Resolve-GitBranchName -BranchSpecifier '   ').Ambiguous | Should -BeTrue
    }
}

Describe 'Get-TextFingerprint' {

    It 'gives the same fingerprint for CRLF and LF' {
        # Without this, a file checked out on Windows never matches the same file
        # read from a commit, and every comparison reports drift forever.
        $crlf = "line one`r`nline two`r`n"
        $lf = "line one`nline two`n"
        Get-TextFingerprint -Text $crlf | Should -Be (Get-TextFingerprint -Text $lf)
    }

    It 'ignores a trailing newline' {
        Get-TextFingerprint -Text "content`n" | Should -Be (Get-TextFingerprint -Text 'content')
    }

    It 'gives different fingerprints for different content' {
        Get-TextFingerprint -Text 'a' | Should -Not -Be (Get-TextFingerprint -Text 'b')
    }
}

Describe 'Compare-ScmText' {

    It 'calls identical content identical across line endings' {
        (Compare-ScmText -Left "a`r`nb" -Right "a`nb").Verdict | Should -Be 'identical'
    }

    It 'calls a whitespace-only difference cosmetic, not drift' {
        # Reporting trailing whitespace as drift would make every run noisy and
        # train people to ignore the verdict that matters.
        (Compare-ScmText -Left "a   `nb" -Right "a`n`nb").Verdict | Should -Be 'cosmetic'
    }

    It 'calls a changed comment drift, because somebody edited the file' {
        # A deliberate departure from how a generated launcher is compared. Here the
        # two sides are the same file at two points in time, so a comment change is
        # a real edit - and deciding whether a // inside a string is a comment
        # cannot be done reliably line by line, so the question is never asked.
        (Compare-ScmText -Left '// old note' -Right '// new note').Verdict | Should -Be 'drift'
    }

    It 'calls changed code drift' {
        (Compare-ScmText -Left 'echo "one"' -Right 'echo "two"').Verdict | Should -Be 'drift'
    }

    It 'returns both fingerprints whatever the verdict, so a report can be re-checked' {
        # Checked by value, not merely for being non-empty. The purpose stated in the
        # test name is that a reader can re-derive the verdict from the report, and
        # two fingerprints that were both the letter x would satisfy "not empty"
        # while making that impossible.
        foreach ($pair in @(@('a', 'a'), @('a   ', 'a'), @('a', 'b'))) {
            $result = Compare-ScmText -Left $pair[0] -Right $pair[1]
            $result.LeftFingerprint | Should -Be (Get-TextFingerprint -Text $pair[0])
            $result.RightFingerprint | Should -Be (Get-TextFingerprint -Text $pair[1])
        }
    }
}

Describe 'ConvertTo-ProcessArgumentString' {

    It 'leaves a plain argument unquoted' {
        ConvertTo-ProcessArgumentString -Arguments @('rev-parse', 'HEAD') | Should -Be 'rev-parse HEAD'
    }

    It 'quotes an argument containing a space' {
        # ProcessStartInfo.ArgumentList, which removes the need to quote anything, is
        # .NET Core only and absent on Windows PowerShell 5.1 - the support floor.
        # Without quoting, a path with a space silently becomes two arguments and git
        # answers about something nobody asked for.
        ConvertTo-ProcessArgumentString -Arguments @('show', 'abc:My File.txt') | Should -Be 'show "abc:My File.txt"'
    }

    It 'represents an empty argument as an empty quoted string, not as nothing' {
        ConvertTo-ProcessArgumentString -Arguments @('a', '', 'b') | Should -Be 'a "" b'
    }

    It 'escapes an embedded quote' {
        ConvertTo-ProcessArgumentString -Arguments @('say "hi"') | Should -Be '"say \"hi\""'
    }

    It 'doubles trailing backslashes so the closing quote stays a delimiter' {
        # A Windows path ending in a backslash would otherwise escape the closing
        # quote and swallow the next argument.
        $result = ConvertTo-ProcessArgumentString -Arguments @('C:\Program Files\')
        $result | Should -Be '"C:\Program Files\\"'
    }
}

Describe 'Invoke-GitCommand' {

    It 'reports a non-zero exit code instead of throwing on it' {
        # A tool that must report faithfully cannot turn "the branch is not there"
        # into an exception three layers up.
        $result = Invoke-GitCommand -WorkingDirectory (Get-RepositoryRoot) -Arguments @('rev-parse', '--verify', 'refs/heads/branch-that-does-not-exist')
        $result.ExitCode | Should -Not -Be 0
    }

    It 'keeps stdout and stderr apart' {
        # git writes progress to stderr. Merging the streams corrupts the stdout this
        # module parses as a commit id.
        $result = Invoke-GitCommand -WorkingDirectory (Get-RepositoryRoot) -Arguments @('--version')
        $result.ExitCode | Should -Be 0
        $result.StandardOutput | Should -Match 'git version'
        $result.StandardError | Should -BeNullOrEmpty
    }

    It 'fails with a usable message when the working directory does not exist' {
        { Invoke-GitCommand -WorkingDirectory 'C:\directory-that-does-not-exist-here' -Arguments @('status') } | Should -Throw
    }
}

Describe 'Test-GitWorkingCopy' {

    It 'recognises this repository as a working copy' {
        Test-GitWorkingCopy -Path (Get-RepositoryRoot) | Should -BeTrue
    }

    It 'says no for a directory that is not one, rather than failing' {
        Test-GitWorkingCopy -Path (Join-Path (Get-RepositoryRoot) 'docs') | Should -BeFalse
    }

    It 'says no for a path that does not exist' {
        Test-GitWorkingCopy -Path 'C:\directory-that-does-not-exist-here' | Should -BeFalse
    }
}
