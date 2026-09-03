@{
    # Static analysis settings for this repository.
    #
    # The default rule set is kept, with a small number of documented exclusions.
    # An exclusion with no reason next to it becomes folklore, so each one says why.

    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # The automations are operator-facing command-line tools whose progress
        # output is part of what they do. Progress goes to the information stream
        # through Write-Information, never to the host - but the analyzer also flags
        # legitimate uses in that neighbourhood, and the codebase has no Write-Host.
        'PSAvoidUsingWriteHost',

        # Credential parameters here are environment-variable NAMES and resolved
        # values handed to an Authorization header. Converting them to SecureString
        # would mean unwrapping them again one line later, which adds ceremony
        # without adding protection.
        #
        # What protects them instead is two layers in the report writer, both tested:
        # Remove-SensitiveValue redacts by property NAME, and Protect-SecretInText
        # masks by VALUE - the second exists because the first cannot see a token
        # embedded in a URL or in an error message. See
        # foundation/modules/JenkinsAsCode.Report and its test file.
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingUserNameAndPasswordParams',
        'PSUsePSCredentialType',

        # Entry points are scripts, not modules, and their parameters are the
        # command-line contract. The analyzer's preference for singular nouns does
        # not apply to a script file name.
        'PSUseSingularNouns',

        # Excluded after measuring, not by preference. The rule misreads two
        # constructs this codebase uses throughout: a hashtable literal passed
        # directly as a method argument - $list.Add([pscustomobject]@{ ... }) - and
        # a backtick continuation inside a parenthesised call. Both are indented
        # consistently; the rule simply expects a different anchor for them, and
        # every one of the 198 findings was of those two shapes. Reformatting
        # working code to satisfy a misreading trades real risk for a clean report.
        # Layout is governed by .editorconfig and by review instead.
        'PSUseConsistentIndentation'
    )

    Rules = @{
        PSUseCompatibleSyntax = @{
            # The stated support floor is Windows PowerShell 5.1, because that is
            # what a locked-down workstation and a windows-latest agent both have
            # without being specially prepared. PowerShell 7 is also supported.
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }

        PSPlaceOpenBrace = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
    }
}
