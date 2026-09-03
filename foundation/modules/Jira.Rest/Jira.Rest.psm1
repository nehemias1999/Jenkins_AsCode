<#
    Jira.Rest - reading Jira. Reading only.

    What is Jira-specific about a request: the API version in the path, Basic
    authentication with an email address and an API token, and which endpoint answers
    which question. The generic HTTP half is in JenkinsAsCode.Http.

    READ ONLY BY CONSTRUCTION, and here that is a decision about somebody else's
    workflow rather than only about safety. The Jenkinsfiles in this estate already
    transition and comment on issues themselves, through the Jenkins Jira plugin. A
    second tool writing to the same workflow produces double transitions that are
    very hard to attribute afterwards, so this module has no code path that could.

    Adding one is an ADR. See docs/adr/0001-read-only-by-construction.md.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:StatusMessage = @{
    400 = 'Jira rejected the request. For a search this is almost always the JQL: check field names and quoting.'
    401 = 'Check JIRA_EMAIL and JIRA_API_TOKEN. The token comes from id.atlassian.com and pairs with the email address of the same account, not with a user name.'
    403 = 'The account authenticated but is not allowed to see this. Reading needs the Browse Projects permission on the project concerned.'
}

function Get-JiraContext {
    <#
    .SYNOPSIS
        Builds the Jira request context from the environment variables the project
        context names.

    .DESCRIPTION
        Basic authentication with an email address and an API token. Jira Cloud
        rejects a user name in place of the email address with a 401, which reads
        like a bad token and sends the reader looking in the wrong place - hence the
        guidance attached to 401 in this module.

    .PARAMETER ProjectContext
        Parsed foundation/config/project-context.json.

    .EXAMPLE
        Get-JiraContext -ProjectContext $projectContext

    .OUTPUTS
        The context object.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $ProjectContext
    )

    $baseUrlEnv = $ProjectContext.jira.baseUrlEnv
    $baseUrl = Assert-HttpBaseUrl -VariableName $baseUrlEnv -Url (Get-JenkinsAsCodeRequiredValue -Name $baseUrlEnv)
    $email = Get-JenkinsAsCodeRequiredValue -Name $ProjectContext.jira.emailEnv
    $token = Get-JenkinsAsCodeRequiredValue -Name $ProjectContext.jira.tokenEnv

    return [pscustomobject]@{
        BaseUrl              = $baseUrl
        Email                = $email
        ApiVersion           = [string] $ProjectContext.jira.apiVersion
        Headers              = @{
            Authorization = New-BasicAuthorizationHeader -UserName $email -Secret $token
            Accept        = 'application/json'
        }
        TimeoutSeconds       = [int] $ProjectContext.defaults.requestTimeoutSeconds
        MaximumRetryCount    = [int] $ProjectContext.defaults.maximumRetryCount
        RetryAfterCapSeconds = [int] $ProjectContext.defaults.retryAfterCapSeconds
    }
}

function Invoke-JiraRequest {
    <#
    .SYNOPSIS
        Sends one authenticated GET to Jira and returns the parsed body.

    .DESCRIPTION
        A thin adapter over Invoke-ReadOnlyRequest. It prefixes the API version and
        supplies the Jira-specific guidance for 400, 401 and 403.

    .PARAMETER Context
        Context from Get-JiraContext.

    .PARAMETER Path
        Path below /rest/api/<version>/, with no leading slash.

    .PARAMETER Query
        Optional query values.

    .PARAMETER AllowNotFound
        Return $null instead of throwing on 404.

    .EXAMPLE
        Invoke-JiraRequest -Context $context -Path 'field'

    .OUTPUTS
        The parsed response, or $null on an allowed 404.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $Path,
        [System.Collections.IDictionary] $Query,
        [switch] $AllowNotFound
    )

    $requestPath = 'rest/api/' + $Context.ApiVersion + '/' + $Path.TrimStart('/')
    $requestParameters = @{
        BaseUrl              = $Context.BaseUrl
        Path                 = $requestPath
        Headers              = $Context.Headers
        Query                = $Query
        TimeoutSeconds       = $Context.TimeoutSeconds
        MaximumRetryCount    = $Context.MaximumRetryCount
        RetryAfterCapSeconds = $Context.RetryAfterCapSeconds
        StatusMessage        = $script:StatusMessage
        AllowNotFound        = $AllowNotFound
    }
    $response = Invoke-ReadOnlyRequest @requestParameters
    if ($null -eq $response) { return $null }

    return ConvertFrom-JsonResponse -Content $response.Content -Uri (New-HttpUri -BaseUrl $Context.BaseUrl -Path $requestPath)
}

function Get-JiraField {
    <#
    .SYNOPSIS
        Returns every field defined in the Jira instance.

    .DESCRIPTION
        The list every custom field question starts from. A custom field is addressed
        in the API by an opaque id such as customfield_10042, while everyone refers to
        it by its display name, and there is no way to derive one from the other.

    .PARAMETER Context
        Context from Get-JiraContext.

    .EXAMPLE
        Get-JiraField -Context $context

    .OUTPUTS
        One object per field.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [object] $Context
    )

    return @(Invoke-JiraRequest -Context $Context -Path 'field')
}

function Find-JiraFieldByName {
    <#
    .SYNOPSIS
        Finds the fields whose display name matches, returning all matches.

    .DESCRIPTION
        Pure function, and it returns a list rather than a field on purpose.

        A Jira instance is perfectly willing to hold two custom fields with the same
        display name - it happens whenever a field is recreated instead of edited, and
        the old one keeps existing on other screens. A function that returned the
        first match would resolve the name to an id that works, reads plausibly, and
        belongs to the wrong field. The caller is made to see the ambiguity and report
        it, which is what a plan status is for.

    .PARAMETER Field
        Fields from Get-JiraField.

    .PARAMETER Name
        Display name to look for, matched case-insensitively after trimming.

    .EXAMPLE
        Find-JiraFieldByName -Field $fields -Name 'Etapa'

    .OUTPUTS
        Every matching field, with id, name and custom.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Field,
        [Parameter(Mandatory)] [string] $Name
    )

    $wanted = $Name.Trim()

    $matched = New-Object System.Collections.ArrayList
    foreach ($candidate in $Field) {
        if ($null -eq $candidate) { continue }
        if (-not $candidate.PSObject.Properties['name']) { continue }
        if (-not [string]::Equals([string] $candidate.name, $wanted, [StringComparison]::OrdinalIgnoreCase)) { continue }

        $null = $matched.Add([pscustomobject]@{
            id     = if ($candidate.PSObject.Properties['id']) { [string] $candidate.id } else { '' }
            name   = [string] $candidate.name
            custom = if ($candidate.PSObject.Properties['custom']) { [bool] $candidate.custom } else { $false }
        })
    }

    return @($matched.ToArray())
}

function Get-JiraIssue {
    <#
    .SYNOPSIS
        Reads one issue, optionally restricted to named fields.

    .PARAMETER Context
        Context from Get-JiraContext.

    .PARAMETER IssueKey
        Issue key, for example PROJ-123.

    .PARAMETER Field
        Field ids or names to return. Omitting this returns every field, which for an
        issue with many custom fields is a large response nobody reads.

    .PARAMETER AllowNotFound
        Return $null instead of throwing when the issue does not exist. Jira answers
        404 both for an issue that is absent and for one the account cannot see, so a
        $null here does not prove absence.

    .EXAMPLE
        Get-JiraIssue -Context $context -IssueKey 'PROJ-123' -Field @('status', 'customfield_10042')

    .OUTPUTS
        The issue, or $null.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $IssueKey,
        [string[]] $Field,
        [switch] $AllowNotFound
    )

    $query = @{}
    if ($Field -and $Field.Count -gt 0) { $query['fields'] = ($Field -join ',') }

    return Invoke-JiraRequest -Context $Context -Path ('issue/' + [Uri]::EscapeDataString($IssueKey)) -Query $query -AllowNotFound:$AllowNotFound
}

function Search-JiraIssue {
    <#
    .SYNOPSIS
        Runs a JQL search and returns the issues.

    .DESCRIPTION
        The endpoint differs by API version, and getting it wrong produces a 404 that
        looks like a permission problem:

        On Jira Cloud, API version 3, the classic /search has been removed and the
        replacement is /search/jql, which paginates with an opaque nextPageToken
        rather than with startAt.

        On Server and Data Center, version 2, /search is still correct and paginates
        with startAt.

        Both are handled here so a caller writes one call.

    .PARAMETER Context
        Context from Get-JiraContext.

    .PARAMETER Jql
        The query.

    .PARAMETER Field
        Field ids or names to return per issue.

    .PARAMETER MaximumResult
        Upper bound on issues returned, across pages. A search that quietly returned
        only the first page would make a report understate what exists.

    .EXAMPLE
        Search-JiraIssue -Context $context -Jql 'project = PROJ AND status = Done'

    .OUTPUTS
        One object per issue.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $Jql,
        [string[]] $Field,
        [int] $MaximumResult = 200
    )

    $pageSize = [Math]::Min(100, $MaximumResult)
    $collected = New-Object System.Collections.ArrayList
    $useTokenPaging = $Context.ApiVersion -eq '3'
    $path = if ($useTokenPaging) { 'search/jql' } else { 'search' }
    $nextPageToken = ''
    $startAt = 0

    while ($collected.Count -lt $MaximumResult) {
        $query = @{ jql = $Jql; maxResults = [string] $pageSize }
        if ($Field -and $Field.Count -gt 0) { $query['fields'] = ($Field -join ',') }
        if ($useTokenPaging) {
            if ($nextPageToken) { $query['nextPageToken'] = $nextPageToken }
        }
        else {
            $query['startAt'] = [string] $startAt
        }

        $page = Invoke-JiraRequest -Context $Context -Path $path -Query $query
        if ($null -eq $page) { break }
        if (-not $page.PSObject.Properties['issues'] -or $null -eq $page.issues) { break }

        $issues = @($page.issues)
        if ($issues.Count -eq 0) { break }
        foreach ($issue in $issues) {
            if ($collected.Count -ge $MaximumResult) { break }
            $null = $collected.Add($issue)
        }

        if ($useTokenPaging) {
            $nextPageToken = if ($page.PSObject.Properties['nextPageToken']) { [string] $page.nextPageToken } else { '' }
            if (-not $nextPageToken) { break }
        }
        else {
            $startAt += $issues.Count
            $total = if ($page.PSObject.Properties['total']) { [int] $page.total } else { 0 }
            if ($startAt -ge $total) { break }
        }
    }

    return @($collected.ToArray())
}

function Get-JiraIssueChangelog {
    <#
    .SYNOPSIS
        Returns the change history of one issue.

    .DESCRIPTION
        Useful for answering when a field last changed and who changed it, which is
        the question that follows any surprise in an inventory.

    .PARAMETER Context
        Context from Get-JiraContext.

    .PARAMETER IssueKey
        Issue key.

    .PARAMETER MaximumResult
        Upper bound on history entries.

    .EXAMPLE
        Get-JiraIssueChangelog -Context $context -IssueKey 'PROJ-123'

    .OUTPUTS
        One object per change group.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $IssueKey,
        [int] $MaximumResult = 100
    )

    $query = @{ maxResults = [string] ([Math]::Min(100, $MaximumResult)) }
    $response = Invoke-JiraRequest -Context $Context -Path ('issue/' + [Uri]::EscapeDataString($IssueKey) + '/changelog') -Query $query
    if ($null -eq $response) { return @() }
    if (-not $response.PSObject.Properties['values'] -or $null -eq $response.values) { return @() }

    return @($response.values)
}

Export-ModuleMember -Function @(
    'Get-JiraContext',
    'Invoke-JiraRequest',
    'Get-JiraField',
    'Find-JiraFieldByName',
    'Get-JiraIssue',
    'Search-JiraIssue',
    'Get-JiraIssueChangelog'
)
