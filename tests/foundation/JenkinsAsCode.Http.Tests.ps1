<#
    Tests for the shared read-only HTTP layer.

    The retry policy is a pure function precisely so that it can be tested here
    rather than only observed during an outage.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
    . (Join-Path (Get-RepositoryRoot) 'foundation/Import-Foundation.ps1')
}

Describe 'Assert-HttpBaseUrl' {

    It 'removes a trailing slash so every derived URL has one shape' {
        Assert-HttpBaseUrl -Url 'https://example.com/' -VariableName 'TEST_URL' | Should -Be 'https://example.com'
    }

    It 'refuses a URL carrying a query string' {
        # A query on the base URL lands in the middle of every derived path, and
        # nothing complains - the requests just address the wrong thing.
        { Assert-HttpBaseUrl -Url 'https://example.com/?a=b' -VariableName 'TEST_URL' } | Should -Throw
    }

    It 'refuses a relative URL and names the variable to fix' {
        { Assert-HttpBaseUrl -Url 'example.com' -VariableName 'TEST_URL' } | Should -Throw -ExpectedMessage '*TEST_URL*'
    }

    It 'refuses a scheme that is not http or https' {
        { Assert-HttpBaseUrl -Url 'ftp://example.com' -VariableName 'TEST_URL' } | Should -Throw
    }

    It 'refuses an empty value and names the variable to set' {
        { Assert-HttpBaseUrl -Url '' -VariableName 'TEST_URL' } | Should -Throw -ExpectedMessage '*TEST_URL*'
    }
}

Describe 'New-HttpUri' {

    It 'joins base and path with exactly one slash' {
        New-HttpUri -BaseUrl 'https://example.com' -Path 'api/json' | Should -Be 'https://example.com/api/json'
        New-HttpUri -BaseUrl 'https://example.com/' -Path '/api/json' | Should -Be 'https://example.com/api/json'
    }

    It 'escapes a query value, so a caller never has to remember to' {
        $uri = New-HttpUri -BaseUrl 'https://example.com' -Path 'api/json' -Query @{ tree = 'jobs[name,_class]' }
        $uri | Should -Match 'tree=jobs%5Bname%2C_class%5D'
    }

    It 'omits a null query value rather than sending it empty' {
        # An empty JQL or tree expression is a different request from no expression,
        # and one of them returns everything.
        New-HttpUri -BaseUrl 'https://example.com' -Path 'x' -Query @{ a = $null } | Should -Be 'https://example.com/x'
    }

    It 'returns the base URL alone for an empty path' {
        New-HttpUri -BaseUrl 'https://example.com' -Path '' | Should -Be 'https://example.com'
    }
}

Describe 'New-BasicAuthorizationHeader' {

    It 'encodes as UTF-8, so a non-ASCII user name does not become a 401' {
        # ASCII encoding turns an accented character into a question mark, producing
        # a 401 that reads like a wrong token and sends the reader to the wrong place.
        $header = New-BasicAuthorizationHeader -UserName 'usuario' -Secret 'token'
        $header | Should -BeLike 'Basic *'
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($header.Substring(6)))
        $decoded | Should -Be 'usuario:token'
    }
}

Describe 'Get-HttpRetryDecision' {

    It 'retries a failure that carried no HTTP status at all' {
        # A DNS failure, a TLS reset or a timeout is the most transient failure there
        # is. Classifying it as non-retryable because there is no code to match
        # against is the common mistake, and it makes the tool give up on exactly the
        # conditions retry exists for.
        (Get-HttpRetryDecision -StatusCode 0 -Attempt 1 -MaximumRetryCount 3).ShouldRetry | Should -BeTrue
    }

    It 'retries every status code it declares retryable, and nothing else' {
        # Asserted against the module's own list rather than a copy of it, so the
        # test cannot drift from the code it checks.
        foreach ($code in (Get-HttpRetryableStatusCode)) {
            (Get-HttpRetryDecision -StatusCode $code -Attempt 1 -MaximumRetryCount 3).ShouldRetry | Should -BeTrue
        }
        foreach ($code in @(400, 401, 403, 404, 409)) {
            (Get-HttpRetryDecision -StatusCode $code -Attempt 1 -MaximumRetryCount 3).ShouldRetry | Should -BeFalse
        }
    }

    It 'stops once the attempt budget is spent' {
        (Get-HttpRetryDecision -StatusCode 503 -Attempt 3 -MaximumRetryCount 3).ShouldRetry | Should -BeFalse
    }

    It 'caps an absurd Retry-After instead of sleeping for days' {
        # A service or proxy answering Retry-After: 999999 would otherwise park the
        # run in Start-Sleep for eleven days.
        $decision = Get-HttpRetryDecision -StatusCode 429 -Attempt 1 -MaximumRetryCount 3 -RetryAfterSeconds 999999 -RetryAfterCapSeconds 120
        $decision.DelaySeconds | Should -Be 120
    }

    It 'honours a reasonable Retry-After in preference to its own backoff' {
        (Get-HttpRetryDecision -StatusCode 429 -Attempt 1 -MaximumRetryCount 5 -RetryAfterSeconds 7).DelaySeconds | Should -Be 7
    }

    It 'backs off further on each attempt when there is no Retry-After' {
        $first = (Get-HttpRetryDecision -StatusCode 503 -Attempt 1 -MaximumRetryCount 5).DelaySeconds
        $second = (Get-HttpRetryDecision -StatusCode 503 -Attempt 2 -MaximumRetryCount 5).DelaySeconds
        $second | Should -BeGreaterThan $first
    }
}

Describe 'Get-HttpResponseHeader' {

    It 'reads a header whose value is a bare string, as 5.1 returns it' {
        Get-HttpResponseHeader -Headers @{ 'X-Jenkins' = '2.440.3' } -Name 'X-Jenkins' | Should -Be '2.440.3'
    }

    It 'reads a header whose value is an array, as PowerShell 7 returns it' {
        # Code that assumes one shape works on one engine and returns
        # System.String[] on the other.
        Get-HttpResponseHeader -Headers @{ 'X-Jenkins' = @('2.440.3') } -Name 'X-Jenkins' | Should -Be '2.440.3'
    }

    It 'matches the name case-insensitively, as HTTP requires' {
        Get-HttpResponseHeader -Headers @{ 'x-jenkins' = '2.440.3' } -Name 'X-Jenkins' | Should -Be '2.440.3'
    }

    It 'returns empty for an absent header, and for no headers at all' {
        Get-HttpResponseHeader -Headers @{} -Name 'X-Jenkins' | Should -Be ''
        Get-HttpResponseHeader -Headers $null -Name 'X-Jenkins' | Should -Be ''
    }
}

Describe 'New-JenkinsJobPath' {

    It 'gives every folder level its own job segment' {
        # Joining the parts with a slash produces a URL the controller answers 404
        # to, and the caller concludes the job is missing rather than the URL wrong.
        New-JenkinsJobPath -Path 'FOLDER/Job' | Should -Be 'job/FOLDER/job/Job'
        New-JenkinsJobPath -Path 'A/B/C' | Should -Be 'job/A/job/B/job/C'
    }

    It 'escapes a name containing a space' {
        New-JenkinsJobPath -Path 'A/My Job' | Should -Be 'job/A/job/My%20Job'
    }

    It 'accepts a backslash as a separator, since a declaration may be typed either way' {
        New-JenkinsJobPath -Path 'A\B' | Should -Be 'job/A/job/B'
    }

    It 'returns empty for the controller root' {
        New-JenkinsJobPath -Path '' | Should -Be ''
    }

    It 'accepts a job whose own name is job, because the URL is not ambiguous' {
        # The URL alternates strictly between the literal separator and one encoded
        # name, so this names the job 'job' inside folder A. An earlier version
        # rejected it for an ambiguity that does not exist, and refused the ordinary
        # name 'Job' along with it, because PowerShell compares case-insensitively.
        New-JenkinsJobPath -Path 'A/job' | Should -Be 'job/A/job/job'
        New-JenkinsJobPath -Path 'FOLDER/Job' | Should -Be 'job/FOLDER/job/Job'
    }
}
