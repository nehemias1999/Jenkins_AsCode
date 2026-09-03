<#
    Scm.Git - resolving what a branch actually points at, and reading a file there.

    This module answers one question: the job says it reads branch X of repository Y,
    so what is the commit, and what does the Jenkinsfile look like at that commit?

    It goes through the git command line rather than through a hosting provider API,
    and that is a deliberate design decision worth stating.

    The GitHub REST API would answer both questions, but it would oblige this
    repository to hold a credential of its own: a PAT to declare, store, rotate and
    protect, scoped to read every repository the tool is pointed at.

    git is already a prerequisite, is already authenticated on the workstation, and
    behaves the same against any remote - github.com, GitHub Enterprise Server or
    anything else. So the rule is simple to state and to audit: if the person can
    clone, this can read. No SCM token is handled here at all.

    The comparison functions are pure and take strings, so the classification rules
    are tested offline against fixtures.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-GitBranchName {
    <#
    .SYNOPSIS
        Resolves a Jenkins branch specifier to a branch name.

    .DESCRIPTION
        Pure function, and the one place that knows the several spellings Jenkins
        accepts for the same branch. All of these mean main:

            main
            */main
            origin/main
            refs/heads/main

        Which matters because the answer is fed to git ls-remote, and
        'refs/heads/*/main' matches nothing - producing "branch not found" for a
        job that is configured perfectly well.

        Where the specifier genuinely does not name one branch, this returns
        ambiguous rather than a guess. A wildcard like '**' or a specifier built
        from a build parameter is a real configuration fact, and a plan reports it
        for a human to resolve instead of picking a branch and being confidently
        wrong about which commit runs.

    .PARAMETER BranchSpecifier
        The specifier as stored in config.xml.

    .PARAMETER RemoteName
        Remote whose name may prefix the specifier. Only this exact prefix is
        stripped, so a branch genuinely named after something else survives.

    .EXAMPLE
        Resolve-GitBranchName -BranchSpecifier '*/main'

    .EXAMPLE
        Resolve-GitBranchName -BranchSpecifier '**'

        Returns ambiguous, with the reason.

    .OUTPUTS
        An object with Branch, Ambiguous and Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $BranchSpecifier,
        # A remote name that begins with a dash is an option to git, not a value.
        # See the positional guard in Invoke-GitCommand for the whole reasoning.
        [ValidatePattern('^[A-Za-z0-9._][A-Za-z0-9._/-]*$')]
        [string] $RemoteName = 'origin'
    )

    $ambiguous = {
        param($reason)
        [pscustomobject]@{ Branch = ''; Ambiguous = $true; Reason = $reason }
    }

    $value = $BranchSpecifier.Trim()
    if (-not $value) {
        return (& $ambiguous 'The job declares no branch specifier.')
    }
    if ($value -match '\$\{|\$[A-Za-z_]') {
        return (& $ambiguous "The branch specifier '$value' is built from a variable, so which branch runs depends on the build.")
    }

    foreach ($prefix in @('refs/heads/', 'refs/remotes/', '*/', ($RemoteName + '/'))) {
        if ($value.StartsWith($prefix, [StringComparison]::Ordinal)) {
            $value = $value.Substring($prefix.Length)
            break
        }
    }

    if ($value -match '[\*\?\[]') {
        return (& $ambiguous "The branch specifier '$BranchSpecifier' contains a wildcard, so it does not name one branch.")
    }
    if (-not $value) {
        return (& $ambiguous "The branch specifier '$BranchSpecifier' resolves to an empty branch name.")
    }

    return [pscustomobject]@{ Branch = $value; Ambiguous = $false; Reason = '' }
}

function Get-TextFingerprint {
    <#
    .SYNOPSIS
        SHA-256 of a text, after normalizing line endings.

    .DESCRIPTION
        Pure function. CRLF is folded to LF and a trailing newline is dropped before
        hashing, so the same content checked out on Windows and read from a commit
        fingerprints identically. Without that, every comparison in this repository
        would report drift on every file, forever.

    .PARAMETER Text
        Text to fingerprint.

    .EXAMPLE
        Get-TextFingerprint -Text $jenkinsfile

    .OUTPUTS
        Lowercase hexadecimal digest.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text
    )

    $normalized = ($Text -replace "`r`n", "`n").TrimEnd("`n")
    $bytes = [Text.Encoding]::UTF8.GetBytes($normalized)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Compare-ScmText {
    <#
    .SYNOPSIS
        Classifies the difference between two versions of the same file.

    .DESCRIPTION
        Pure function. Three verdicts:

            identical - the same content once line endings are normalized.
            cosmetic  - differs only in trailing whitespace or blank lines.
            drift     - differs in something that changes what runs.

        Comments count as content here, and that is a deliberate departure from how
        a launcher baseline is usually compared. The two sides of this comparison are
        the same file at two points in time, not two files generated from one
        template: if a comment changed, somebody edited the file, and that is exactly
        what the caller wants to know. Stripping comments to be tolerant would also
        require deciding whether a // inside a string literal is a comment, which
        cannot be done reliably line by line - so the question is never asked.

        Both fingerprints are returned regardless of verdict, so a report is
        verifiable rather than just assertive.

    .PARAMETER Left
        First version, typically the content at the commit the job reads.

    .PARAMETER Right
        Second version, typically the local working copy.

    .EXAMPLE
        Compare-ScmText -Left $atCommit -Right $localCopy

    .OUTPUTS
        An object with Verdict, LeftFingerprint, RightFingerprint and Detail.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Left,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Right
    )

    $leftFingerprint = Get-TextFingerprint -Text $Left
    $rightFingerprint = Get-TextFingerprint -Text $Right

    if ($leftFingerprint -eq $rightFingerprint) {
        return [pscustomobject]@{
            Verdict          = 'identical'
            LeftFingerprint  = $leftFingerprint
            RightFingerprint = $rightFingerprint
            Detail           = ''
        }
    }

    $reduce = {
        param($text)
        $lines = ($text -replace "`r`n", "`n") -split "`n"
        $kept = $lines | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -ne '' }
        return (@($kept) -join "`n")
    }

    if ((& $reduce $Left) -eq (& $reduce $Right)) {
        return [pscustomobject]@{
            Verdict          = 'cosmetic'
            LeftFingerprint  = $leftFingerprint
            RightFingerprint = $rightFingerprint
            Detail           = 'Differs only in trailing whitespace or blank lines.'
        }
    }

    $leftLines = @((($Left -replace "`r`n", "`n") -split "`n"))
    $rightLines = @((($Right -replace "`r`n", "`n") -split "`n"))

    return [pscustomobject]@{
        Verdict          = 'drift'
        LeftFingerprint  = $leftFingerprint
        RightFingerprint = $rightFingerprint
        Detail           = "Content differs: $($leftLines.Count) line(s) against $($rightLines.Count)."
    }
}

function ConvertTo-ProcessArgumentString {
    <#
    .SYNOPSIS
        Joins arguments into a single Windows command line.

    .DESCRIPTION
        Pure function. It exists because ProcessStartInfo.ArgumentList - the API that
        removes the need to quote anything - is .NET Core only, and Windows
        PowerShell 5.1 runs on .NET Framework, where the property is simply absent.
        The support floor is 5.1, so the quoting has to be done here.

        The rules implemented are the ones CommandLineToArgvW applies, which is what
        git's own startup parses: quote an argument containing a space, a tab or a
        quote; double any run of backslashes that immediately precedes a quote or the
        closing quote; escape an embedded quote.

        Getting this wrong is not theoretical. A branch name with a space, or a
        Windows path ending in a backslash, silently becomes two arguments, and git
        answers about a ref nobody asked for.

    .PARAMETER Arguments
        Arguments to join.

    .EXAMPLE
        ConvertTo-ProcessArgumentString -Arguments @('show', 'abc:My File.txt')

    .OUTPUTS
        The command line string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # AllowEmptyString because git legitimately takes an empty argument, and
        # the default validation on a mandatory string collection rejects one.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]] $Arguments
    )

    $parts = New-Object System.Collections.ArrayList

    foreach ($argument in $Arguments) {
        if ($argument -eq '') {
            $null = $parts.Add('""')
            continue
        }
        if ($argument -notmatch '[ \t"]') {
            $null = $parts.Add($argument)
            continue
        }

        $builder = New-Object System.Text.StringBuilder
        $null = $builder.Append('"')

        $backslashes = 0
        foreach ($character in $argument.ToCharArray()) {
            if ($character -eq '\') {
                $backslashes++
                continue
            }
            if ($character -eq '"') {
                # Double the pending backslashes, then escape the quote itself.
                $null = $builder.Append('\', ($backslashes * 2) + 1)
                $null = $builder.Append('"')
                $backslashes = 0
                continue
            }
            if ($backslashes -gt 0) {
                $null = $builder.Append('\', $backslashes)
                $backslashes = 0
            }
            $null = $builder.Append($character)
        }

        # Backslashes before the closing quote are doubled, so the quote stays a
        # delimiter instead of being escaped by the last one.
        if ($backslashes -gt 0) { $null = $builder.Append('\', $backslashes * 2) }
        $null = $builder.Append('"')

        $null = $parts.Add($builder.ToString())
    }

    return (@($parts.ToArray()) -join ' ')
}

function Invoke-GitCommand {
    <#
    .SYNOPSIS
        Runs one git command and returns its exit code and both streams.

    .DESCRIPTION
        Through System.Diagnostics.Process rather than the call operator, for two
        reasons, and with a hand-built command line because
        ProcessStartInfo.ArgumentList does not exist on .NET Framework. Under $ErrorActionPreference = 'Stop', a native command writing to
        stderr can surface as a NativeCommandError even when it exited 0, which turns
        git's ordinary progress output into a failure. And the two streams have to
        stay apart: git writes progress to stderr, so merging them corrupts the
        stdout this module parses as a commit id.

        GIT_TERMINAL_PROMPT is disabled. Without it, git against a remote it cannot
        authenticate to sits waiting for a user name that will never arrive, and the
        run hangs with no output instead of failing with a message.

    .PARAMETER Arguments
        Arguments to pass to git.

    .PARAMETER WorkingDirectory
        Directory to run in.

    .PARAMETER TimeoutSeconds
        How long to wait before killing the process.

    .EXAMPLE
        Invoke-GitCommand -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $repo

    .OUTPUTS
        An object with ExitCode, StandardOutput and StandardError.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $WorkingDirectory,
        [int] $TimeoutSeconds = 120
    )

    if (-not (Test-Path -LiteralPath $WorkingDirectory)) {
        throw "The git working directory '$WorkingDirectory' does not exist."
    }

    # Only options this repository actually passes are allowed through. Correct
    # quoting is not enough on its own: ConvertTo-ProcessArgumentString guarantees
    # that an argument arrives as ONE argument, and git then still reads a leading
    # dash as an option. A remote name of '--upload-pack=<binary>' is a binary git
    # executes, and both ls-remote and fetch document that option, so a value taken
    # from a declaration file would otherwise be a code execution path.
    #
    # An allowlist, not a denylist of dangerous options: a denylist of git's options
    # is a list that goes stale as git grows. This list is this repository's own
    # vocabulary, so anything outside it is by definition an option no call site here
    # meant to pass.
    #
    # Note this cannot be a positional rule. git is invoked as
    # <subcommand> [options] <operands>, so the subcommand is always the first
    # non-option argument and every legitimate option follows it - 'rev-parse
    # --verify <ref>' and 'cat-file -e <object>' are both that shape. A rule that
    # forbade options after the first operand would reject those and was the first
    # version of this guard.
    $allowedOption = @('--exit-code', '--no-tags', '--depth', '-e', '--verify', '--version')
    foreach ($argument in $Arguments) {
        if ($argument -like '-*' -and $allowedOption -notcontains $argument) {
            throw "Refusing to run git: '$argument' begins with a dash and is not one of the options this repository passes ($($allowedOption -join ', ')). git would read it as an option rather than as a value, which is what a hostile remote name or path looks like."
        }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'git'
    $startInfo.WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8

    # Configuration hardening, injected here rather than accepted from callers - which
    # is why it goes in after the allowlist above and not through it. Git honours
    # settings from the .git/config of whatever repository it is run in, and this is a
    # tool pointed at repositories it does not control: core.fsmonitor and
    # core.hooksPath both name programs git executes.
    #
    # core.sshCommand is deliberately NOT overridden. It is the same class of vector,
    # but -c has the highest precedence in git, so overriding it would also override
    # the legitimate one a person has configured - and ambient authentication is this
    # tool's whole premise. Closing that hole properly needs a way to ignore
    # repository-local config alone, which git does not offer.
    $hardenedArguments = @(
        '-c', 'core.fsmonitor=',
        '-c', 'core.hooksPath='
    ) + $Arguments
    $startInfo.Arguments = ConvertTo-ProcessArgumentString -Arguments $hardenedArguments

    $startInfo.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $startInfo.EnvironmentVariables['GCM_INTERACTIVE'] = 'never'
    # System-wide config is not needed to read a remote, and it is one less file whose
    # contents decide what this process executes.
    $startInfo.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'

    # git needs no credential of this tool's, so it is not given one. Without this the
    # child inherits the whole process environment, tokens included, and every git
    # invocation hands them to a program chosen by the repository being inspected.
    #
    # Matched by SHAPE rather than by name, because this module carries no domain
    # rules: it does not know that this repository's secrets are called JENKINS_ or
    # JIRA_ anything, and it should not have to.
    # Names git legitimately needs to authenticate, kept whatever they look like.
    # SSH_AUTH_SOCK matches the pattern below on its AUTH segment, and removing it
    # disconnects the ssh agent - breaking the ambient authentication this tool
    # depends on, and breaking it as a "repository not found" that reads like a
    # permissions problem. This keep-list is why the pattern stays conservative.
    $keepEnvironmentName = @('SSH_AUTH_SOCK', 'SSH_AGENT_PID', 'SSH_ASKPASS', 'GIT_SSH', 'GIT_SSH_COMMAND', 'GIT_ASKPASS')
    $secretEnvironmentName = '(?i)(password|passwd|pwd|passphrase|secret|token|credential|apikey|api_key|accesskey|access_token|privatekey|private_key|(^|[_-])(pat|bearer)([_-]|$))'
    foreach ($name in @($startInfo.EnvironmentVariables.Keys)) {
        if ($keepEnvironmentName -contains $name) { continue }
        if ($name -match $secretEnvironmentName) {
            $null = $startInfo.EnvironmentVariables.Remove($name)
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        $null = $process.Start()

        # Read both streams before waiting. A process that fills a redirected pipe
        # blocks on the write while the parent blocks on WaitForExit - a deadlock
        # that only appears once output grows past the buffer, so it looks
        # intermittent.
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            # Kill throws when the process exited between the timeout and this call,
            # which is the ordinary race, not a problem worth surfacing.
            try { $process.Kill() } catch { Write-Verbose "git had already exited: $($_.Exception.Message)" }
            throw "git $($Arguments -join ' ') did not finish within $TimeoutSeconds seconds in $WorkingDirectory."
        }

        return [pscustomobject]@{
            ExitCode       = $process.ExitCode
            StandardOutput = $standardOutput.Result
            StandardError  = $standardError.Result
        }
    }
    finally {
        $process.Dispose()
    }
}

function Test-GitWorkingCopy {
    <#
    .SYNOPSIS
        Says whether a path is the root of a git working copy.

    .PARAMETER Path
        Directory to test.

    .EXAMPLE
        Test-GitWorkingCopy -Path 'C:/repos/example'

    .OUTPUTS
        $true when the path contains a .git directory or file.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Path '.git'))
}

function Get-GitRemoteBranchCommit {
    <#
    .SYNOPSIS
        Returns the commit a branch points at on the remote.

    .DESCRIPTION
        Through git ls-remote, which asks the remote and reads nothing local. This is
        the value the whole drift comparison rests on: the commit Jenkins would check
        out on its next run.

        The branch is queried as an exact ref, refs/heads/<branch>, rather than by
        name. Given a name, ls-remote also matches tags, and a repository holding a
        tag and a branch with the same name would return two lines and the first one
        picked would be a coin toss.

    .PARAMETER RepositoryPath
        Working copy whose remote is queried. Its configured credentials are used.

    .PARAMETER Branch
        Branch name, already resolved by Resolve-GitBranchName.

    .PARAMETER RemoteName
        Remote to ask.

    .EXAMPLE
        Get-GitRemoteBranchCommit -RepositoryPath $repo -Branch 'main'

    .OUTPUTS
        The 40-character commit id, or an empty string when the branch is absent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $RepositoryPath,
        [Parameter(Mandatory)] [string] $Branch,
        # A remote name that begins with a dash is an option to git, not a value.
        # See the positional guard in Invoke-GitCommand for the whole reasoning.
        [ValidatePattern('^[A-Za-z0-9._][A-Za-z0-9._/-]*$')]
        [string] $RemoteName = 'origin'
    )

    $result = Invoke-GitCommand -WorkingDirectory $RepositoryPath -Arguments @(
        'ls-remote', '--exit-code', $RemoteName, ('refs/heads/' + $Branch)
    )

    # 2 is ls-remote's documented "no matching ref", which is an answer rather than
    # a failure: the branch does not exist on the remote.
    if ($result.ExitCode -eq 2) { return '' }

    if ($result.ExitCode -ne 0) {
        throw "git ls-remote failed for branch '$Branch' in $RepositoryPath (exit $($result.ExitCode)): $($result.StandardError.Trim())"
    }

    $firstLine = @($result.StandardOutput -split "`n" | Where-Object { $_.Trim() })[0]
    if (-not $firstLine) { return '' }

    return ($firstLine -split "`t")[0].Trim()
}

function Get-GitWorkingCopyCommit {
    <#
    .SYNOPSIS
        Returns the commit the local working copy is on.

    .PARAMETER RepositoryPath
        Working copy.

    .EXAMPLE
        Get-GitWorkingCopyCommit -RepositoryPath $repo

    .OUTPUTS
        The commit id, or an empty string in a repository with no commits.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $RepositoryPath
    )

    $result = Invoke-GitCommand -WorkingDirectory $RepositoryPath -Arguments @('rev-parse', 'HEAD')
    if ($result.ExitCode -ne 0) { return '' }
    return $result.StandardOutput.Trim()
}

function Get-GitFileAtCommit {
    <#
    .SYNOPSIS
        Returns the content of one file at one commit, fetching it if needed.

    .DESCRIPTION
        Reads through git show. When the commit is not present locally - the usual
        case, since the point is to inspect a commit newer than the working copy -
        a shallow fetch of that one branch brings the objects in first.

        What this does to the local repository, exactly: it adds objects and moves
        FETCH_HEAD. It never checks anything out, never moves a branch, never touches
        the working tree and never merges. Running it against somebody's clone leaves
        their checked-out files and their current branch exactly as they were. That
        boundary is the reason there is no -Pull or -Checkout anywhere in this module.

    .PARAMETER RepositoryPath
        Working copy to read and, if necessary, fetch into.

    .PARAMETER Commit
        Commit id.

    .PARAMETER FilePath
        Path of the file within the repository, with forward slashes.

    .PARAMETER Branch
        Branch to shallow-fetch when the commit is missing locally.

    .PARAMETER RemoteName
        Remote to fetch from.

    .EXAMPLE
        Get-GitFileAtCommit -RepositoryPath $repo -Commit $sha -FilePath 'Jenkinsfile' -Branch 'main'

    .OUTPUTS
        The file content, or an empty string when the file does not exist there.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $RepositoryPath,
        [Parameter(Mandatory)] [string] $Commit,
        [Parameter(Mandatory)] [string] $FilePath,
        [string] $Branch = '',
        # A remote name that begins with a dash is an option to git, not a value.
        # See the positional guard in Invoke-GitCommand for the whole reasoning.
        [ValidatePattern('^[A-Za-z0-9._][A-Za-z0-9._/-]*$')]
        [string] $RemoteName = 'origin'
    )

    $have = Invoke-GitCommand -WorkingDirectory $RepositoryPath -Arguments @('cat-file', '-e', ($Commit + '^{commit}'))
    if ($have.ExitCode -ne 0) {
        if (-not $Branch) {
            throw "Commit $Commit is not present in $RepositoryPath and no branch was given to fetch it from."
        }
        $fetch = Invoke-GitCommand -WorkingDirectory $RepositoryPath -Arguments @(
            'fetch', '--no-tags', '--depth', '1', $RemoteName, ('refs/heads/' + $Branch)
        )
        if ($fetch.ExitCode -ne 0) {
            throw "git fetch of branch '$Branch' failed in $RepositoryPath (exit $($fetch.ExitCode)): $($fetch.StandardError.Trim())"
        }
    }

    $show = Invoke-GitCommand -WorkingDirectory $RepositoryPath -Arguments @('show', ($Commit + ':' + $FilePath))
    if ($show.ExitCode -ne 0) {
        # git reports a missing path and a missing commit the same way. The commit
        # was just proven present, so this is a missing path - an answer, not an error.
        return ''
    }

    return $show.StandardOutput
}

Export-ModuleMember -Function @(
    'Resolve-GitBranchName',
    'ConvertTo-ProcessArgumentString',
    'Get-TextFingerprint',
    'Compare-ScmText',
    'Invoke-GitCommand',
    'Test-GitWorkingCopy',
    'Get-GitRemoteBranchCommit',
    'Get-GitWorkingCopyCommit',
    'Get-GitFileAtCommit'
)
