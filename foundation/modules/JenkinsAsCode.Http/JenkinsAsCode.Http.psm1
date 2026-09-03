<#
    JenkinsAsCode.Http - read-only HTTP, shared by every transport.

    This module exists because there are two external systems here, Jenkins and
    Jira, and a retry policy implemented twice is a retry policy that drifts. It
    knows what a request, a retry and a Basic credential are, and nothing about
    either system: no URL, no endpoint, no permission name appears in it.

    READ ONLY BY CONSTRUCTION. There is no -Method parameter and no code path that
    sends anything but GET. Raising that is an ADR, not an edit. See
    docs/adr/0001-read-only-by-construction.md.

    Because every request is a GET, and a GET is idempotent, retrying is always
    safe. A module that also wrote could not use this list: a POST retried after the
    server had already committed manufactures a duplicate.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RetryableStatusCode = @(408, 429, 500, 502, 503, 504)

function Assert-HttpBaseUrl {
    <#
    .SYNOPSIS
        Validates and normalizes a base URL.

    .DESCRIPTION
        Pure function. Returns the URL with any trailing slash removed, so every
        caller concatenates against the same shape.

        A URL carrying a query or a fragment is refused. A base URL with a query
        string breaks every URL derived from it, because the query lands in the
        middle of the path and nothing complains.

    .PARAMETER Url
        Candidate base URL.

    .PARAMETER VariableName
        Environment variable the value came from, named in any failure so the
        message points at what to fix.

    .EXAMPLE
        Assert-HttpBaseUrl -Url 'https://example.com/' -VariableName 'JENKINS_URL'

    .OUTPUTS
        The normalized base URL.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Url,
        [Parameter(Mandatory)] [string] $VariableName
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        throw "$VariableName is empty. Set it in .env to an absolute URL, for example https://example.com."
    }

    $trimmed = $Url.Trim().TrimEnd('/')

    $parsed = $null
    if (-not [Uri]::TryCreate($trimmed, [UriKind]::Absolute, [ref] $parsed)) {
        throw "$VariableName is '$trimmed', which is not an absolute URL. It must include the scheme, for example https://example.com."
    }
    if ($parsed.Scheme -notin @('http', 'https')) {
        throw "$VariableName uses scheme '$($parsed.Scheme)'. Only http and https are supported."
    }
    # Credentials in the base URL, rejected rather than carried. Two reasons, and the
    # second is the one that bites: the header is already how this authenticates, so
    # userinfo adds nothing - and every error message below, plus detail.controllerUrl
    # in every report, interpolates this value. One misconfigured .env would copy a
    # token into every artefact the tool writes. The message deliberately does not
    # echo the URL back.
    if ($parsed.UserInfo) {
        throw "$VariableName carries credentials in the URL (a user[:password]@ before the host). Remove them: authentication uses the token from the environment, and a URL with userinfo would be copied into reports and error messages."
    }
    if ($parsed.Query) {
        throw "$VariableName carries a query string. Remove it: the query of a derived URL would end up in the middle of the path."
    }
    if ($parsed.Fragment) {
        throw "$VariableName carries a fragment. Remove it."
    }

    return $trimmed
}

function New-HttpUri {
    <#
    .SYNOPSIS
        Builds an absolute URL from a base URL, a path and an optional query.

    .DESCRIPTION
        Pure function. Query values are escaped here, so no caller has to remember
        to escape a JQL expression or a tree expression.

    .PARAMETER BaseUrl
        Normalized base URL.

    .PARAMETER Path
        Path with no leading slash.

    .PARAMETER Query
        Optional query values. A $null value is omitted rather than sent empty.

    .EXAMPLE
        New-HttpUri -BaseUrl 'https://example.com' -Path 'api/json' -Query @{ tree = 'jobs[name]' }

    .OUTPUTS
        The absolute URL.
    #>
    # Pure function: it computes a value and changes no system state. ShouldProcess
    # would offer a confirmation prompt for something there is nothing to confirm
    # about, and would train people to answer yes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Path,
        [System.Collections.IDictionary] $Query
    )

    $uri = $BaseUrl.TrimEnd('/')
    $cleanPath = $Path.Trim('/')
    if ($cleanPath) { $uri += '/' + $cleanPath }

    if ($Query -and $Query.Keys.Count -gt 0) {
        $pairs = foreach ($key in $Query.Keys) {
            $value = $Query[$key]
            if ($null -eq $value) { continue }
            '{0}={1}' -f [Uri]::EscapeDataString([string] $key), [Uri]::EscapeDataString([string] $value)
        }
        $joined = @($pairs) -join '&'
        if ($joined) { $uri += '?' + $joined }
    }

    return $uri
}

function New-BasicAuthorizationHeader {
    <#
    .SYNOPSIS
        Builds a Basic Authorization header value.

    .DESCRIPTION
        UTF-8 rather than ASCII. A user name or an email address is allowed to
        contain a non-ASCII character, and ASCII encoding turns it into a question
        mark - producing a 401 that reads like a wrong token and sends the reader
        looking in the wrong place.

    .PARAMETER UserName
        User name or email address.

    .PARAMETER Secret
        API token or password.

    .EXAMPLE
        New-BasicAuthorizationHeader -UserName $user -Secret $token

    .OUTPUTS
        The header value, beginning with 'Basic '.
    #>
    # Pure function: it computes a value and changes no system state. ShouldProcess
    # would offer a confirmation prompt for something there is nothing to confirm
    # about, and would train people to answer yes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $UserName,
        [Parameter(Mandatory)] [string] $Secret
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes($UserName + ':' + $Secret)
    return 'Basic ' + [Convert]::ToBase64String($bytes)
}

function Get-HttpResponseHeader {
    <#
    .SYNOPSIS
        Reads one response header, tolerating the two shapes PowerShell returns.

    .DESCRIPTION
        Pure function. On Windows PowerShell 5.1 a header value is a string; on
        PowerShell 7 it is a string array. Code that assumes either one works on one
        engine and returns 'System.String[]' on the other.

    .PARAMETER Headers
        Response header dictionary.

    .PARAMETER Name
        Header name, matched case-insensitively.

    .EXAMPLE
        Get-HttpResponseHeader -Headers $response.Headers -Name 'X-Jenkins'

    .OUTPUTS
        The header value, or an empty string when absent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $Headers,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $Headers) { return '' }

    foreach ($key in $Headers.Keys) {
        if ([string]::Equals([string] $key, $Name, [StringComparison]::OrdinalIgnoreCase)) {
            $value = $Headers[$key]
            if ($value -is [string]) { return $value }
            return (@($value) -join ', ')
        }
    }

    return ''
}

function Get-HttpErrorStatusCode {
    <#
    .SYNOPSIS
        Extracts the HTTP status code from a terminating web error.

    .DESCRIPTION
        Returns 0 when the failure carried no HTTP response at all, which
        Get-HttpRetryDecision treats as retryable.

    .PARAMETER ErrorRecord
        The caught error.

    .EXAMPLE
        Get-HttpErrorStatusCode -ErrorRecord $_

    .OUTPUTS
        The status code, or 0.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [object] $ErrorRecord
    )

    if (-not $ErrorRecord.Exception) { return 0 }
    if (-not $ErrorRecord.Exception.PSObject.Properties['Response']) { return 0 }

    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response) { return 0 }
    if (-not $response.PSObject.Properties['StatusCode']) { return 0 }

    try { return [int] $response.StatusCode } catch { return 0 }
}

function Get-HttpRetryAfterSecond {
    <#
    .SYNOPSIS
        Reads Retry-After from a failed response, in seconds.

    .DESCRIPTION
        Retry-After may be a number of seconds or an HTTP date, and both shapes
        appear in practice behind a reverse proxy.

    .PARAMETER ErrorRecord
        The caught error.

    .EXAMPLE
        Get-HttpRetryAfterSecond -ErrorRecord $_

    .OUTPUTS
        Seconds to wait, or 0 when absent or unparsable.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [object] $ErrorRecord
    )

    if (-not $ErrorRecord.Exception) { return 0 }
    if (-not $ErrorRecord.Exception.PSObject.Properties['Response']) { return 0 }
    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response) { return 0 }
    if (-not $response.PSObject.Properties['Headers']) { return 0 }

    $raw = Get-HttpResponseHeader -Headers $response.Headers -Name 'Retry-After'
    if (-not $raw) { return 0 }

    $seconds = 0
    if ([int]::TryParse($raw, [ref] $seconds)) { return [Math]::Max(0, $seconds) }

    $when = [datetime]::MinValue
    if ([datetime]::TryParse($raw, [ref] $when)) {
        $delta = [int] ($when.ToUniversalTime() - [datetime]::UtcNow).TotalSeconds
        return [Math]::Max(0, $delta)
    }

    return 0
}

function Get-HttpRetryDecision {
    <#
    .SYNOPSIS
        Decides whether a failed request should be retried, and after how long.

    .DESCRIPTION
        Pure function, so the retry policy is testable offline instead of only
        observable during an outage.

        Two rules are worth stating because the obvious implementation gets them
        backwards:

        A failure carrying NO status code - a DNS failure, a TLS reset, a timeout -
        is the most transient failure there is, and is retried. Classifying it as
        non-retryable because there is no code to match against is a common mistake,
        and it makes the tool fail on exactly the conditions retry exists for.

        An honoured Retry-After is capped. A service or proxy answering
        'Retry-After: 999999' would otherwise park the run in Start-Sleep for days.

    .PARAMETER StatusCode
        HTTP status code, or 0 when the failure carried none.

    .PARAMETER Attempt
        1-based number of the attempt that just failed.

    .PARAMETER MaximumRetryCount
        Total attempts allowed.

    .PARAMETER RetryAfterSeconds
        Value of the Retry-After header, or 0 when absent.

    .PARAMETER RetryAfterCapSeconds
        Upper bound applied to RetryAfterSeconds.

    .EXAMPLE
        Get-HttpRetryDecision -StatusCode 503 -Attempt 1 -MaximumRetryCount 3

    .OUTPUTS
        An object with ShouldRetry and DelaySeconds.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [int] $StatusCode,
        [Parameter(Mandatory)] [int] $Attempt,
        [Parameter(Mandatory)] [int] $MaximumRetryCount,
        [int] $RetryAfterSeconds = 0,
        [int] $RetryAfterCapSeconds = 120
    )

    $retryable = ($StatusCode -eq 0) -or ($script:RetryableStatusCode -contains $StatusCode)

    if (($Attempt -ge $MaximumRetryCount) -or -not $retryable) {
        return [pscustomobject]@{ ShouldRetry = $false; DelaySeconds = 0 }
    }

    if ($RetryAfterSeconds -gt 0) {
        $delay = [Math]::Min($RetryAfterSeconds, $RetryAfterCapSeconds)
    }
    else {
        $delay = [Math]::Min([Math]::Pow(2, $Attempt), $RetryAfterCapSeconds)
    }

    return [pscustomobject]@{ ShouldRetry = $true; DelaySeconds = [int] $delay }
}

function Get-HttpRetryableStatusCode {
    <#
    .SYNOPSIS
        Returns the status codes this module retries.

    .DESCRIPTION
        Exported so the test suite asserts against the same list the module
        enforces, rather than restating it and drifting from it.

    .EXAMPLE
        Get-HttpRetryableStatusCode

    .OUTPUTS
        The status codes.
    #>
    [CmdletBinding()]
    [OutputType([int[]])]
    param()

    return @($script:RetryableStatusCode)
}

function ConvertFrom-JsonResponse {
    <#
    .SYNOPSIS
        Parses a response body as JSON, and explains a non-JSON body instead of
        failing on it obscurely.

    .DESCRIPTION
        A raw ConvertFrom-Json failure reads "Invalid JSON primitive: <" and names a
        line inside a transport module, which tells the reader nothing about the cause.

        The cause is nearly always one of two things, and both are configuration:

        The base URL points at a web UI rather than at the API root. Pasting the URL
        out of a browser address bar is how this happens - a Jira URL copied from the
        board carries a /jira/software path, and every API request built from it lands
        on an HTML page that answers 200.

        Or a reverse proxy or SSO gateway is answering with a login page instead of
        passing the request through, which also answers 200 with HTML.

        Either way the status code is fine and the body is a document, so nothing
        upstream notices. This function names both possibilities.

    .PARAMETER Content
        The response body.

    .PARAMETER Uri
        The URL that was requested, quoted in any failure.

    .EXAMPLE
        ConvertFrom-JsonResponse -Content $response.Content -Uri $uri

    .OUTPUTS
        The parsed object.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content,
        [Parameter(Mandatory)] [string] $Uri
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        throw "GET $Uri answered with an empty body where JSON was expected. A 200 with no body usually means a proxy in front of the service handled the request itself."
    }

    $looksLikeMarkup = $Content.TrimStart().StartsWith('<')

    try {
        return ($Content | ConvertFrom-Json)
    }
    catch {
        if ($looksLikeMarkup) {
            throw "GET $Uri answered with HTML or XML where JSON was expected. Two usual causes: the configured base URL points at a web UI rather than the API root - a URL copied from a browser address bar carries a UI path - or a proxy or SSO gateway returned a login page. Check the base URL in .env and remove any path that belongs to the UI."
        }
        throw "GET $Uri answered with a body that is not JSON: $($_.Exception.Message)"
    }
}

function Invoke-ReadOnlyRequest {
    <#
    .SYNOPSIS
        Sends one authenticated GET and returns body, headers and status.

    .DESCRIPTION
        The only function in this repository that performs network I/O. It sends GET
        and nothing else: no parameter exists that could make it write.

        Three decisions worth knowing:

        Invoke-WebRequest rather than Invoke-RestMethod, because a response header is
        sometimes the answer - the Jenkins controller version arrives in X-Jenkins -
        and Windows PowerShell 5.1 has no -ResponseHeadersVariable. One code path on
        both engines instead of a version check.

        The body is decoded from the raw bytes as UTF-8 rather than trusting the
        response charset. Jenkins serves config.xml with no charset parameter, and
        5.1 then falls back to ISO-8859-1, which corrupts any non-ASCII character in
        a job description or a parameter default.

        Redirects are not followed. An Authorization header sent to whatever host a
        30x points at is a credential disclosure. The usual cause is a wrong base
        URL, so a redirect is reported as the configuration problem it is.

    .PARAMETER BaseUrl
        Normalized base URL.

    .PARAMETER Path
        Path with no leading slash.

    .PARAMETER Headers
        Request headers, including Authorization.

    .PARAMETER Query
        Optional query values.

    .PARAMETER TimeoutSeconds
        Per-attempt timeout.

    .PARAMETER MaximumRetryCount
        Total attempts allowed.

    .PARAMETER RetryAfterCapSeconds
        Upper bound on an honoured Retry-After.

    .PARAMETER StatusMessage
        Status code to guidance, supplied by the calling transport. It is data, so
        this module stays free of any knowledge about Jenkins or Jira while a 403
        can still say which permission is missing.

    .PARAMETER AllowNotFound
        Return $null instead of throwing on 404, where absence is itself an answer.

    .EXAMPLE
        Invoke-ReadOnlyRequest -BaseUrl $url -Path 'api/json' -Headers $headers -TimeoutSeconds 60 -MaximumRetryCount 3

    .OUTPUTS
        An object with Content, Headers and StatusCode, or $null on an allowed 404.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $BaseUrl,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Path,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Headers,
        [System.Collections.IDictionary] $Query,
        [int] $TimeoutSeconds = 60,
        [int] $MaximumRetryCount = 3,
        [int] $RetryAfterCapSeconds = 120,
        [System.Collections.IDictionary] $StatusMessage,
        [switch] $AllowNotFound
    )

    $uri = New-HttpUri -BaseUrl $BaseUrl -Path $Path -Query $Query

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $requestParameters = @{
                Uri                = $uri
                Method             = 'Get'
                Headers            = $Headers
                TimeoutSec         = $TimeoutSeconds
                MaximumRedirection = 0
                UseBasicParsing    = $true
                ErrorAction        = 'Stop'
            }
            $response = Invoke-WebRequest @requestParameters

            if ($response.PSObject.Properties['RawContentStream'] -and $response.RawContentStream) {
                $content = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
            }
            else {
                $content = [string] $response.Content
            }

            # A UTF-8 byte order mark ahead of an XML declaration makes an [xml] cast
            # throw "Data at the root level is invalid", three layers from here.
            $content = $content.TrimStart([char] 0xFEFF)

            return [pscustomobject]@{
                Content    = $content
                Headers    = $response.Headers
                StatusCode = [int] $response.StatusCode
            }
        }
        catch {
            $statusCode = Get-HttpErrorStatusCode -ErrorRecord $_

            if ($statusCode -eq 404 -and $AllowNotFound) { return $null }

            if ($statusCode -ge 300 -and $statusCode -lt 400) {
                throw "GET $uri was redirected (HTTP $statusCode), and redirects are not followed because forwarding the Authorization header to another host would disclose the credential. Check the base URL: http against https, or a missing or extra path prefix."
            }

            if ($StatusMessage -and $StatusMessage.Contains($statusCode)) {
                throw "GET $uri failed with HTTP $statusCode. $($StatusMessage[$statusCode])"
            }

            $decisionParameters = @{
                StatusCode           = $statusCode
                Attempt              = $attempt
                MaximumRetryCount    = $MaximumRetryCount
                RetryAfterSeconds    = (Get-HttpRetryAfterSecond -ErrorRecord $_)
                RetryAfterCapSeconds = $RetryAfterCapSeconds
            }
            $decision = Get-HttpRetryDecision @decisionParameters

            if (-not $decision.ShouldRetry) {
                $detail = if ($statusCode -gt 0) { "HTTP $statusCode" } else { 'no HTTP response' }
                throw "GET $uri failed after $attempt attempt(s) ($detail): $($_.Exception.Message)"
            }

            Write-Verbose "GET $uri failed on attempt $attempt. Retrying in $($decision.DelaySeconds)s."
            Start-Sleep -Seconds $decision.DelaySeconds
        }
    }
}

Export-ModuleMember -Function @(
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
