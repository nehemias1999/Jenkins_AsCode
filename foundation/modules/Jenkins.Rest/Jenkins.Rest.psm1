<#
    Jenkins.Rest - what is Jenkins-specific about talking to a Jenkins controller.

    The generic half of an HTTP request - retry, header handling, redirect refusal,
    UTF-8 decoding - lives in JenkinsAsCode.Http, shared with the Jira transport so
    the retry policy exists once. What is left here is only what Jenkins does
    differently: how a folder path becomes a URL, which endpoint holds the
    authoritative job configuration, and what a 403 means on this system.

    This module knows nothing about jobs, folders or pipelines as concepts - that is
    Jenkins.Jobs. It knows about requests.

    READ ONLY BY CONSTRUCTION. Every call goes through Invoke-ReadOnlyRequest, which
    sends GET and nothing else. See docs/adr/0001-read-only-by-construction.md.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Guidance attached to the status codes whose cause is specific to Jenkins. Passed
# to the shared transport as data, so that layer stays free of any knowledge about
# this system while a 403 can still name the permission that is missing.
$script:StatusMessage = @{
    401 = 'Check JENKINS_USER and JENKINS_API_TOKEN. The token must be an API token from /me/configure, not the account password.'
    403 = 'Reading a job definition needs the Job/ExtendedRead permission. Job/Read alone is enough for /api/json but not for config.xml, so an inventory that lists jobs and then fails on the first one is almost always this.'
}

function New-JenkinsJobPath {
    <#
    .SYNOPSIS
        Converts a job path into the URL segment Jenkins expects.

    .DESCRIPTION
        Pure function, and the single most common source of a 404 that reads like
        "the job does not exist".

        In Jenkins every folder level carries its own /job/ segment. The job
        displayed as INFRA-DEVOPS/AP_EnvioBTLAN lives at

            /job/INFRA-DEVOPS/job/AP_EnvioBTLAN/

        not at /job/INFRA-DEVOPS/AP_EnvioBTLAN/. A function that joins the parts
        with a slash produces a URL the controller answers 404 to, and the caller
        concludes the job is missing rather than that the URL is wrong.

        Each segment is URL-escaped, because a job name may contain a space.

        Comparison note: names are handled verbatim. PowerShell compares strings
        case-insensitively by default, and Jenkins job names are case-sensitive, so
        nothing here folds case.

    .PARAMETER Path
        Display path, segments separated by / or backslash. An empty path means the
        controller root, which yields an empty segment string.

    .EXAMPLE
        New-JenkinsJobPath -Path 'INFRA-DEVOPS/AP_EnvioBTLAN'

        job/INFRA-DEVOPS/job/AP_EnvioBTLAN

    .OUTPUTS
        The path segment, with no leading or trailing slash.
    #>
    # Pure function: it computes a value and changes no system state. ShouldProcess
    # would offer a confirmation prompt for something there is nothing to confirm
    # about, and would train people to answer yes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Path
    )

    $segments = @(
        $Path -split '[/\\]' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )

    if ($segments.Count -eq 0) { return '' }

    # No guard against a segment literally named 'job'. The URL alternates strictly
    # between the literal separator and one encoded name, so /job/A/job/job names the
    # job 'job' inside folder A and nothing else - rejecting it would refuse a valid
    # name for an ambiguity that does not exist.
    return (($segments | ForEach-Object { 'job/' + [Uri]::EscapeDataString($_) }) -join '/')
}

function Get-JenkinsContext {
    <#
    .SYNOPSIS
        Builds the request context from the environment variables the project
        context names.

    .DESCRIPTION
        Built once per run and passed down, so there is exactly one place where a
        credential becomes a header.

        Authentication is Basic with the controller user and an API token. A token
        rather than a password because it can be revoked on its own, and because
        Jenkins exempts API-token requests from CSRF crumb handling - which this
        repository never needs anyway, having no write path.

    .PARAMETER ProjectContext
        Parsed foundation/config/project-context.json.

    .EXAMPLE
        Get-JenkinsContext -ProjectContext $projectContext

    .OUTPUTS
        The context object.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $ProjectContext
    )

    $baseUrlEnv = $ProjectContext.jenkins.baseUrlEnv
    $baseUrl = Assert-HttpBaseUrl -VariableName $baseUrlEnv -Url (Get-JenkinsAsCodeRequiredValue -Name $baseUrlEnv)
    $user = Get-JenkinsAsCodeRequiredValue -Name $ProjectContext.jenkins.userEnv
    $token = Get-JenkinsAsCodeRequiredValue -Name $ProjectContext.jenkins.tokenEnv

    return [pscustomobject]@{
        BaseUrl              = $baseUrl
        UserName             = $user
        Headers              = @{
            Authorization = New-BasicAuthorizationHeader -UserName $user -Secret $token
            Accept        = 'application/json'
        }
        TimeoutSeconds       = [int] $ProjectContext.defaults.requestTimeoutSeconds
        MaximumRetryCount    = [int] $ProjectContext.defaults.maximumRetryCount
        RetryAfterCapSeconds = [int] $ProjectContext.defaults.retryAfterCapSeconds
    }
}

function Invoke-JenkinsRequest {
    <#
    .SYNOPSIS
        Sends one authenticated GET to the controller.

    .DESCRIPTION
        A thin adapter over Invoke-ReadOnlyRequest: it supplies the context and the
        Jenkins-specific guidance for 401 and 403, and adds nothing else. There is no
        parameter here that could make it write.

    .PARAMETER Context
        Context from Get-JenkinsContext.

    .PARAMETER Path
        Path with no leading slash.

    .PARAMETER Query
        Optional query values.

    .PARAMETER AllowNotFound
        Return $null instead of throwing on 404.

    .EXAMPLE
        Invoke-JenkinsRequest -Context $context -Path 'api/json' -Query @{ tree = 'jobs[name]' }

    .OUTPUTS
        An object with Content, Headers and StatusCode, or $null on an allowed 404.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Path,
        [System.Collections.IDictionary] $Query,
        [switch] $AllowNotFound
    )

    $requestParameters = @{
        BaseUrl              = $Context.BaseUrl
        Path                 = $Path
        Headers              = $Context.Headers
        Query                = $Query
        TimeoutSeconds       = $Context.TimeoutSeconds
        MaximumRetryCount    = $Context.MaximumRetryCount
        RetryAfterCapSeconds = $Context.RetryAfterCapSeconds
        StatusMessage        = $script:StatusMessage
        AllowNotFound        = $AllowNotFound
    }
    return Invoke-ReadOnlyRequest @requestParameters
}

function Get-JenkinsJson {
    <#
    .SYNOPSIS
        Reads the remote API of a Jenkins object as an object.

    .DESCRIPTION
        Always with an explicit tree expression, never with depth. depth=1 already
        returns every build of every job; on a controller with a few hundred jobs the
        response is large enough to time out, while the fields actually wanted are a
        handful. tree names them.

    .PARAMETER Context
        Context from Get-JenkinsContext.

    .PARAMETER Path
        Path of the object, for example 'job/A', or an empty string for the root.

    .PARAMETER Tree
        Jenkins tree expression naming the fields to return.

    .PARAMETER AllowNotFound
        Return $null instead of throwing on 404.

    .EXAMPLE
        Get-JenkinsJson -Context $context -Path '' -Tree 'jobs[name,_class]'

    .OUTPUTS
        The parsed response, or $null on an allowed 404.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Path,
        [Parameter(Mandatory)] [string] $Tree,
        [switch] $AllowNotFound
    )

    $requestPath = if ($Path) { $Path.Trim('/') + '/api/json' } else { 'api/json' }
    $response = Invoke-JenkinsRequest -Context $Context -Path $requestPath -Query @{ tree = $Tree } -AllowNotFound:$AllowNotFound
    if ($null -eq $response) { return $null }

    return ConvertFrom-JsonResponse -Content $response.Content -Uri (New-HttpUri -BaseUrl $Context.BaseUrl -Path $requestPath)
}

function Get-JenkinsConfigXml {
    <#
    .SYNOPSIS
        Reads the config.xml of a job or folder, as text.

    .DESCRIPTION
        This is the endpoint the whole repository is built around, because /api/json
        does not expose what matters: the branch specifier the job reads, the script
        path, the parameter defaults and the triggers exist only in this XML. An
        inventory built from /api/json alone looks complete and cannot answer which
        commit feeds the job.

        Returned as text, not as [xml]. Parsing is a separate, pure step in
        Jenkins.Jobs, so it can be tested against fixtures with no controller.

    .PARAMETER Context
        Context from Get-JenkinsContext.

    .PARAMETER JobPath
        Display path of the job, for example 'INFRA-DEVOPS/AP_EnvioBTLAN'.

    .PARAMETER AllowNotFound
        Return $null instead of throwing on 404.

    .EXAMPLE
        Get-JenkinsConfigXml -Context $context -JobPath 'INFRA-DEVOPS/AP_EnvioBTLAN'

    .OUTPUTS
        The XML as a string, or $null on an allowed 404.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $JobPath,
        [switch] $AllowNotFound
    )

    $segment = New-JenkinsJobPath -Path $JobPath
    if (-not $segment) {
        throw 'A config.xml was requested for an empty job path. The controller root has no job configuration.'
    }

    $response = Invoke-JenkinsRequest -Context $Context -Path ($segment + '/config.xml') -AllowNotFound:$AllowNotFound
    if ($null -eq $response) { return $null }

    return $response.Content
}

function Get-JenkinsControllerVersion {
    <#
    .SYNOPSIS
        Returns the controller version, from the X-Jenkins response header.

    .DESCRIPTION
        Recorded in every inventory on purpose. The notes in
        docs/reference/jenkins-notes.md describe behaviour that is version dependent,
        and a note whose version is unknown cannot be verified later.

    .PARAMETER Context
        Context from Get-JenkinsContext.

    .EXAMPLE
        Get-JenkinsControllerVersion -Context $context

    .OUTPUTS
        The version string, or 'unknown' when the header is absent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [object] $Context
    )

    $response = Invoke-JenkinsRequest -Context $Context -Path 'api/json' -Query @{ tree = 'mode' }
    $version = Get-HttpResponseHeader -Headers $response.Headers -Name 'X-Jenkins'
    if (-not $version) { return 'unknown' }
    return $version
}

Export-ModuleMember -Function @(
    'New-JenkinsJobPath',
    'Get-JenkinsContext',
    'Invoke-JenkinsRequest',
    'Get-JenkinsJson',
    'Get-JenkinsConfigXml',
    'Get-JenkinsControllerVersion'
)
