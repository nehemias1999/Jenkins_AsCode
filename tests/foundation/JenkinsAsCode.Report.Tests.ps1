<#
    Tests for the redaction layer of the report writer.

    This is the last thing that runs before a report is written, and a report is the
    artefact most likely to be pasted into a ticket or a chat window. Until now it
    had no tests at all, while PSScriptAnalyzerSettings.psd1 cites it as the reason
    three credential rules are suppressed - so static analysis was being waived on
    the strength of a function nothing verified.

    Two of the cases below are regressions that already happened in production. They
    are named after what went wrong, not after the function they call.

    Everything here is a pure function over objects and strings: no file system, no
    network, no controller.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
    . (Join-Path (Get-RepositoryRoot) 'foundation/Import-Foundation.ps1')
}

Describe 'Protect-SecretInText' {

    It 'masks the credentials in a URL and keeps the host' {
        # The host is the diagnostically useful half. A reason that says which
        # repository disagreed is the entire point of the message, so masking the
        # whole URL would trade one useless report for another.
        $masked = Protect-SecretInText -Text "remote is 'https://someone:ghp_examplevalue@example.com/org/repo.git'"
        $masked | Should -Be "remote is 'https://[redacted]@example.com/org/repo.git'"
    }

    It 'masks every URL in the text, not only the first' {
        # The drift reason names two repositories in one sentence. Masking one of
        # them would have looked like it worked.
        $text = "The job reads 'https://a:tok1@example.com/o/x.git' but the remote is 'https://b:tok2@example.com/o/y.git'."
        $masked = Protect-SecretInText -Text $text
        $masked | Should -Not -Match 'tok1'
        $masked | Should -Not -Match 'tok2'
        @([regex]::Matches($masked, '\[redacted\]')).Count | Should -Be 2
    }

    It 'masks the credentials git puts in its own error text' {
        # The exact shape of git stderr on a failed fetch, which is what reached the
        # report through Exception.Message.
        $masked = Protect-SecretInText -Text "fatal: Authentication failed for 'https://user:secretpat@example.com/o/r.git/'"
        $masked | Should -Not -Match 'secretpat'
        $masked | Should -Match 'example\.com'
    }

    It 'masks a Basic credential' {
        Protect-SecretInText -Text 'sent Basic dXNlcjp0b2tlbnZhbHVl' | Should -Be 'sent Basic [redacted]'
    }

    It 'leaves a URL with no credentials exactly as it was' {
        # Over-masking destroys the evidence the report exists to carry, which is not
        # failing safe - it is failing quietly.
        $url = 'https://example.com/example-org/example-pipeline.git'
        Protect-SecretInText -Text $url | Should -Be $url
    }

    It 'does not treat an e-mail address as URL credentials' {
        # The pattern requires a scheme for exactly this reason: an @ in free text is
        # usually an address, and a plan that redacted every address would be
        # redacting the answer.
        Protect-SecretInText -Text 'owner is persona@example.com' | Should -Be 'owner is persona@example.com'
    }

    It 'returns an empty value unchanged rather than failing' {
        Protect-SecretInText -Text '' | Should -Be ''
    }
}

Describe 'Remove-SensitiveValue' {

    It 'redacts a value whose property name looks like a credential' {
        $result = Remove-SensitiveValue -InputObject ([pscustomobject]@{ apiToken = 'plaintext-value' })
        $result.apiToken | Should -Be '[redacted]'
    }

    It 'redacts a weak value too, because matching is on the name' {
        # A bad password does not look like a secret. Its property name always does,
        # and that is the whole argument for name-based matching.
        $result = Remove-SensitiveValue -InputObject ([pscustomobject]@{ password = '1234' })
        $result.password | Should -Be '[redacted]'
    }

    It 'masks credentials inside a value whose name looks innocent' {
        # The gap name matching cannot see. A job configured with an embedded token
        # stores it under 'scmUrl', which no name pattern would flag, while
        # 'credentialsId' - a reference and no secret at all - was already redacted
        # because its name contains 'credential'. The name layer was protecting the
        # harmless field and passing the dangerous one.
        $result = Remove-SensitiveValue -InputObject ([pscustomobject]@{
            scmUrl        = 'https://user:ghp_examplevalue@example.com/o/r.git'
            credentialsId = 'example-credential-id'
        })
        $result.scmUrl | Should -Be 'https://[redacted]@example.com/o/r.git'
        $result.credentialsId | Should -Be '[redacted]'
    }

    It 'masks credentials in free text, which no property name describes' {
        # reason and failure carry git error output. Neither name matches any
        # pattern, so before value masking existed both went into the JSON and the
        # Markdown verbatim.
        $result = Remove-SensitiveValue -InputObject ([pscustomobject]@{
            reason  = "remote is 'https://u:tokenvalue@example.com/o/y.git'"
            failure = "fatal: Authentication failed for 'https://u:tokenvalue@example.com/o/y.git'"
        })
        $result.reason | Should -Not -Match 'tokenvalue'
        $result.failure | Should -Not -Match 'tokenvalue'
    }

    It 'does not redact a path property whose name merely contains pat' {
        # Regression. Unanchored, 'pat' matched areaPaths, iterationPaths, reportPath,
        # patch and compatible - so every inventory report replaced the very data it
        # exists to carry with the redaction marker. Redaction that destroys evidence
        # is not failing safe; it is failing quietly, which is worse.
        $result = Remove-SensitiveValue -InputObject ([pscustomobject]@{
            reportPath = 'artifacts/reports/example.json'
            areaPaths  = @('Example/Area')
            compatible = $true
        })
        $result.reportPath | Should -Be 'artifacts/reports/example.json'
        @($result.areaPaths)[0] | Should -Be 'Example/Area'
        $result.compatible | Should -BeTrue
    }

    It 'redacts pat as a whole segment, which is what the short pattern is for' {
        $result = Remove-SensitiveValue -InputObject ([pscustomobject]@{ azure_pat = 'value' })
        $result.azure_pat | Should -Be '[redacted]'
    }

    It 'keeps a one-element array an array' {
        # Regression. PowerShell enumerates a function output, so a single-element
        # array came back as the bare element and then serialised as a string instead
        # of an array. For whoever consumes the report, "one job" and "a job" are
        # different assertions about shape.
        $result = Remove-SensitiveValue -InputObject ([pscustomobject]@{ items = @('only') })
        @($result.items).Count | Should -Be 1
        @($result.items)[0] | Should -Be 'only'
    }

    It 'walks nested objects and arrays rather than only the top level' {
        $result = Remove-SensitiveValue -InputObject ([pscustomobject]@{
            operations = @([pscustomobject]@{ name = 'one'; secret = 'hidden' })
        })
        @($result.operations)[0].name | Should -Be 'one'
        @($result.operations)[0].secret | Should -Be '[redacted]'
    }

    It 'preserves property order, so a report does not reshuffle between runs' {
        $result = Remove-SensitiveValue -InputObject ([pscustomobject]@{ first = 1; second = 2; third = 3 })
        @($result.PSObject.Properties.Name) | Should -Be @('first', 'second', 'third')
    }

    It 'stops at the depth cap instead of hanging on a cyclic structure' {
        $result = Remove-SensitiveValue -InputObject ([pscustomobject]@{ value = 'deep' }) -Depth 1
        $result.value | Should -Be '[depth limit reached]'
    }

    It 'returns null for null rather than failing' {
        Remove-SensitiveValue -InputObject $null | Should -BeNullOrEmpty
    }
}

Describe 'Format-JenkinsAsCodeReportMarkdown' {

    BeforeAll {
        # Builds the smallest plan that renders one table row, so the assertions below
        # are about the cell text and nothing else.
        function Get-OneRowReport {
            param([string] $Resource = 'job', [string] $Name = 'job/x', [string] $Action = 'update', [string] $Reason = 'because')
            return [pscustomobject]@{
                module      = 'job-inventory'
                command     = 'plan'
                target      = 'https://jenkins.example.com'
                generatedAt = '2026-09-03T00:00:00.0000000Z'
                summary     = [pscustomobject]@{ total = 1; pending = 1 }
                operations  = @([pscustomobject]@{
                    resource = $Resource
                    name     = $Name
                    action   = $Action
                    status   = 'pending'
                    reason   = $Reason
                })
            }
        }
    }

    It 'escapes a pipe in every column, not only in the reason' {
        # A pipe ends a cell, so one in a job path grows the row an extra column and
        # the table stops lining up. Three of the four columns carry text the inspected
        # controller chooses, and only the reason used to be escaped.
        $markdown = Format-JenkinsAsCodeReportMarkdown -Report (Get-OneRowReport -Name 'job/a|b' -Reason 'c|d')
        $row = @($markdown -split "`n" | Where-Object { $_ -match 'job/a' })[0]
        $row | Should -Match 'job/a\\|b'
        $row | Should -Match 'c\\|d'
    }

    It 'keeps a value with a newline inside one row' {
        # A newline ends the row, so one value silently became two rows - and the
        # second one is not a row, so the table breaks from there down.
        $markdown = Format-JenkinsAsCodeReportMarkdown -Report (Get-OneRowReport -Reason "first`nsecond")
        $rows = @($markdown -split "`n" | Where-Object { $_ -match '^\| job ' })
        $rows.Count | Should -Be 1
        $rows[0] | Should -Match 'first second'
    }

    It 'neutralises markup that would inject a link or an element' {
        # The summary is what gets attached to a ticket, and a ticket renders Markdown.
        $markdown = Format-JenkinsAsCodeReportMarkdown -Report (Get-OneRowReport -Reason '[click](http://example.com) <b>x</b>')
        $markdown | Should -Not -Match '\[click\]\('
        $markdown | Should -Not -Match '<b>'
    }

    It 'renders an empty cell for a null value rather than the word null' {
        $markdown = Format-JenkinsAsCodeReportMarkdown -Report (Get-OneRowReport -Reason '')
        $markdown | Should -Not -Match '\bnull\b'
    }
}

Describe 'Get-JenkinsAsCodeProvenance' {

    BeforeAll {
        $script:ProvenanceArgument = @{
            Command         = 'plan'
            DeclarationPath = 'automations/job-inventory/config/jobs.json'
            DeclarationText = '{ "folders": ["EXAMPLE-FOLDER"] }'
            SchemaEngine    = 'reduced'
            Scope           = 'jobKey=example-pipeline'
            RepositoryRoot  = (Get-RepositoryRoot)
        }
    }

    It 'records the scope, which is what made pending zero ambiguous' {
        # A filtered run and a whole one differed only in a total, so a report saying
        # nothing is pending could equally mean everything is aligned or one item was
        # looked at. This is the field that tells them apart.
        (Get-JenkinsAsCodeProvenance @script:ProvenanceArgument).scope | Should -Be 'jobKey=example-pipeline'
    }

    It 'says all when nothing restricted the run' {
        $unfiltered = $script:ProvenanceArgument.Clone()
        $unfiltered.Scope = ''
        (Get-JenkinsAsCodeProvenance @unfiltered).scope | Should -Be 'all'
    }

    It 'fingerprints the declaration rather than storing its path alone' {
        # The active declaration is excluded from version control, so a path
        # identifies a file that may have changed since. The content does not.
        $result = Get-JenkinsAsCodeProvenance @script:ProvenanceArgument
        $result.declarationFingerprint | Should -Match '^sha256:[0-9a-f]{64}$'
    }

    It 'gives the same fingerprint for CRLF and LF' {
        # Same reasoning as Get-TextFingerprint: a declaration checked out on Windows
        # and the same declaration on Linux must not look like two different files.
        $lf = $script:ProvenanceArgument.Clone()
        $lf.DeclarationText = "line one`nline two"
        $crlf = $script:ProvenanceArgument.Clone()
        $crlf.DeclarationText = "line one`r`nline two"
        (Get-JenkinsAsCodeProvenance @lf).declarationFingerprint |
            Should -Be (Get-JenkinsAsCodeProvenance @crlf).declarationFingerprint
    }
    It 'records the engine that validated, because the two are not equivalent' {
        (Get-JenkinsAsCodeProvenance @script:ProvenanceArgument).schemaEngine | Should -Be 'reduced'
    }

    It 'gives every run its own correlation id' {
        # So an inventory and the plan from the same session can be tied together by
        # something better than adjacent timestamps.
        $first = (Get-JenkinsAsCodeProvenance @script:ProvenanceArgument).correlationId
        $second = (Get-JenkinsAsCodeProvenance @script:ProvenanceArgument).correlationId
        $first | Should -Not -Be $second
    }

    It 'reads the repository commit from this working copy' {
        (Get-JenkinsAsCodeProvenance @script:ProvenanceArgument).repositoryCommit | Should -Match '^[0-9a-f]{40}$'
    }

    It 'leaves the commit empty rather than failing outside a working copy' {
        # A tarball or a vendored copy is a legitimate way to run this, and a report
        # is more useful with an empty field than not written at all.
        $noGit = $script:ProvenanceArgument.Clone()
        $noGit.RepositoryRoot = [System.IO.Path]::GetTempPath()
        (Get-JenkinsAsCodeProvenance @noGit).repositoryCommit | Should -Be ''
    }

    It 'names who ran it and from where' {
        $result = Get-JenkinsAsCodeProvenance @script:ProvenanceArgument
        $result.runBy | Should -Not -BeNullOrEmpty
        $result.Keys -contains 'runOn' | Should -BeTrue
    }
}
