<#
.SYNOPSIS
    Reads Jira: resolves custom field ids from display names, and records the result
    of declared JQL queries.

.DESCRIPTION
    Command ladder. Nothing here writes, to Jira or anywhere else except a report
    under artifacts/:

      validate   Offline. The declaration against its schema, plus the invariants a
                 schema cannot express. No network, no token.
      inventory  What Jira holds today: the API id behind each declared field name,
                 and the issues each declared query returns.
      plan       Classifies every declared field and query against live state.
      smoke      Plan plus the manual verification checklist.

    There is no apply, and no code path that could write. Two reasons. The pipelines
    commonly comment on and transition issues themselves through the
    Jenkins Jira plugin; a second writer against the same workflow produces double
    transitions that nobody can attribute afterwards. And the question this module
    exists to answer is a read: what is the opaque id behind a field everyone refers
    to by name.

    That question is not academic. A custom field is addressed in the API as
    customfield_XXXXX and nowhere in Jira does the display name appear next to it, so
    a pipeline that needs to read a field has to be told the id by somebody who looked
    it up. This is that lookup, made repeatable and reviewable.

.PARAMETER Command
    Operation to run. See the ladder above.

.PARAMETER FieldName
    Resolve this display name in addition to the declared ones. For answering a
    one-off question without editing the declaration.

.PARAMETER EnvFile
    Environment files to load. Defaults to .env in the repository root.

.PARAMETER ProjectContextPath
    Override for foundation/config/project-context.json.

.PARAMETER ConfigurationPath
    Override for the declaration. Defaults to the active file named in the project
    context, falling back to the versioned template.

.PARAMETER ReportPath
    Where to write the report. Defaults under artifacts/, which is not versioned.

.EXAMPLE
    .\Invoke-JiraInventory.ps1 -Command validate

    Offline check. Needs no credential.

.EXAMPLE
    .\Invoke-JiraInventory.ps1 -Command inventory -FieldName 'Example Stage'

    Prints the API id behind the field displayed as Example Stage.

.EXAMPLE
    .\Invoke-JiraInventory.ps1 -Command plan

    Reports every declared field and query as ok, warning or blocked.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('validate', 'inventory', 'plan', 'smoke')]
    [string] $Command,

    [string[]] $FieldName = @(),
    [string[]] $EnvFile,
    [string] $ProjectContextPath,
    [string] $ConfigurationPath,
    [string] $ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleName = 'jira-inventory'
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repositoryRoot 'foundation/Import-Foundation.ps1')

# Opened before the first line of progress, so the transcript holds the whole run
# and not just the part after some later setup step succeeded.
$usedTemplate = $false
$runLogPath = Start-JenkinsAsCodeRunLog -RepositoryRoot $repositoryRoot -Module $moduleName -Command $Command

function Write-ModuleLog {
    <#
    .SYNOPSIS
        Writes a prefixed progress line.

    .DESCRIPTION
        Progress goes through here and nowhere else, so the value masker is applied
        here too. Console output does not pass through the report writer, and git's
        stderr names the remote it failed to authenticate against - URL, userinfo and
        all. Masking at the funnel rather than at each call site means a log line
        added later cannot reintroduce the leak.

        Severity is a parameter because everything used to come out identically: a
        job that could not be read looked exactly like a folder listing, same prefix,
        same stream, same prominence. A reader scanning the tail of a long run had no
        way to pick the failures out, and nothing downstream could filter them.

    .PARAMETER Message
        Text to write.

    .PARAMETER Level
        info for progress, warning for something a person needs to read. A warning
        goes to the warning stream, so a caller can capture or redirect it on its
        own.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('info', 'warning')] [string] $Level = 'info'
    )

    $masked = Protect-SecretInText -Text $Message
    # The console gets it and so does the transcript, from the one funnel - so a line
    # added later cannot end up in only one of them.
    Add-JenkinsAsCodeRunLogLine -Path $runLogPath -Level $Level -Message $Message
    if ($Level -eq 'warning') {
        Write-Warning "[$moduleName] $masked"
        return
    }
    Write-Information "[$moduleName] $masked" -InformationAction Continue
}

function Get-CustomFieldStatus {
    <#
    .SYNOPSIS
        Classifies the resolution of one declared custom field.

    .DESCRIPTION
        Pure function, so the rule is tested offline. Three outcomes, and the third
        is the one worth having:

            one match    - ok. The id is known.
            no match     - blocked. Nothing downstream can use a field that is not
                           there, and guessing an id would be worse than stopping.
            many matches - blocked, deliberately. Jira allows two custom fields with
                           the same display name, which happens whenever a field is
                           recreated rather than edited. Picking the first would
                           produce an id that works, reads plausibly and belongs to
                           the wrong field - so a human decides which one.

    .PARAMETER DisplayName
        Declared display name.

    .PARAMETER Match
        Matches from Find-JiraFieldByName.

    .EXAMPLE
        Get-CustomFieldStatus -DisplayName 'Example Stage' -Match $matches

    .OUTPUTS
        An object with Action, Status, Reason and FieldId.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $DisplayName,
        # AllowNull as well as AllowEmptyCollection: PowerShell unwraps an empty array
        # to $null on assignment, so the zero-match case - which is the most important
        # one this function has, because it is the answer "no such field" - arrives here
        # as null rather than as an empty array.
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyCollection()] [object[]] $Match
    )

    # Two statements, not an if-expression. In Windows PowerShell 5.1 an empty array
    # flowing out of a script block is unwrapped to $null, so
    # $found = if (...) { @() } else { ... } assigns null and the next .Count throws
    # under StrictMode. A direct assignment of @() does keep the empty array.
    $found = @()
    if ($null -ne $Match) { $found = @($Match) }

    if ($found.Count -eq 0) {
        return [pscustomobject]@{
            Action  = 'resolve'
            Status  = 'blocked'
            Reason  = "No field is displayed as '$DisplayName'. Check the spelling in Jira, or that the account can see the project the field is used on."
            FieldId = ''
        }
    }

    if ($found.Count -gt 1) {
        $ids = (@($found | ForEach-Object { $_.id }) -join ', ')
        return [pscustomobject]@{
            Action  = 'resolve'
            Status  = 'blocked'
            Reason  = "$($found.Count) fields are displayed as '$DisplayName' ($ids). Jira permits duplicate display names, so which one is meant cannot be inferred - name the id explicitly once somebody has decided."
            FieldId = ''
        }
    }

    return [pscustomobject]@{
        Action  = 'validate'
        Status  = 'ok'
        Reason  = "Resolves to $($found[0].id)."
        FieldId = [string] $found[0].id
    }
}

function Get-QueryStatus {
    <#
    .SYNOPSIS
        Classifies the result of one declared query.

    .DESCRIPTION
        Pure function.

        A query declared as non-empty that returns nothing is a warning rather than
        an error, because both causes are worth a human look and they are not
        distinguishable from here: either there genuinely is no work in that state,
        or the JQL refers to a status or component that has been renamed. A renamed
        status does not make JQL fail - it makes it return zero rows, quietly, which
        is how a pipeline that watches a queue stops finding work and nobody notices.

    .PARAMETER Expectation
        Declared expectation: 'any' or 'non-empty'.

    .PARAMETER IssueCount
        Number of issues returned.

    .EXAMPLE
        Get-QueryStatus -Expectation 'non-empty' -IssueCount 0

    .OUTPUTS
        An object with Action, Status and Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateSet('any', 'non-empty')] [string] $Expectation,
        [Parameter(Mandatory)] [int] $IssueCount
    )

    if ($Expectation -eq 'non-empty' -and $IssueCount -eq 0) {
        return [pscustomobject]@{
            Action = 'validate'
            Status = 'warning'
            Reason = 'The query is declared non-empty and returned nothing. Either there is no work in that state, or the JQL names a status or component that has been renamed - a rename returns zero rows rather than failing.'
        }
    }

    return [pscustomobject]@{
        Action = 'validate'
        Status = 'ok'
        Reason = "Returned $IssueCount issue(s)."
    }
}

# --- Declaration ----------------------------------------------------------

$projectContextPathResolved = if ($ProjectContextPath) { $ProjectContextPath } else { 'foundation/config/project-context.json' }
$projectContextPathResolved = Resolve-JenkinsAsCodePath -Path $projectContextPathResolved -RootPath $repositoryRoot
$projectContext = Get-JenkinsAsCodeConfiguration -Path $projectContextPathResolved

# The rule - explicit path, else the active declaration, else the template - is the
# same for all three automations, so it lives in the shared layer rather than being
# written out three times. Saying it out loud stays here, because the shared layer
# knows nothing about how a caller reports.
$declarationChoice = Resolve-JenkinsAsCodeDeclaration -ProjectContext $projectContext -Module $moduleName -RepositoryRoot $repositoryRoot -ConfigurationPath $ConfigurationPath
$configurationPath = $declarationChoice.Path
$usedTemplate = $declarationChoice.UsedTemplate
if ($usedTemplate) {
    Write-ModuleLog "No active declaration at $($declarationChoice.ActivePath). Using the versioned template instead: $configurationPath. The report will describe the example, not an estate." -Level warning
}

$declaration = Get-JenkinsAsCodeConfiguration -Path $configurationPath
Write-ModuleLog "Declaration: $configurationPath"

# --- validate -------------------------------------------------------------

# Invariants a JSON Schema cannot express. Each one is a real way a declaration
# passes its schema and still cannot be executed.
$validationProblem = New-Object System.Collections.ArrayList

$fieldKeys = @($declaration.customFields | ForEach-Object { $_.key })
$duplicateFieldKeys = @(Get-JenkinsAsCodeDuplicateValue -Value $fieldKeys)
if ($duplicateFieldKeys.Count -gt 0) {
    $null = $validationProblem.Add("Duplicate customFields key(s): $($duplicateFieldKeys -join ', '). A key names a row in every report, so a duplicate makes two findings indistinguishable.")
}

$queryKeys = @($declaration.queries | ForEach-Object { $_.key })
$duplicateQueryKeys = @(Get-JenkinsAsCodeDuplicateValue -Value $queryKeys)
if ($duplicateQueryKeys.Count -gt 0) {
    $null = $validationProblem.Add("Duplicate queries key(s): $($duplicateQueryKeys -join ', ').")
}

foreach ($query in $declaration.queries) {
    if ([string]::IsNullOrWhiteSpace($query.jql)) {
        $null = $validationProblem.Add("Query '$($query.key)' has an empty jql.")
    }
}
foreach ($field in $declaration.customFields) {
    if ([string]::IsNullOrWhiteSpace($field.displayName)) {
        $null = $validationProblem.Add("Custom field '$($field.key)' has an empty displayName.")
    }
}
if (@($declaration.projectKeys).Count -eq 0) {
    $null = $validationProblem.Add('projectKeys is empty, so nothing is in scope.')
}

if ($validationProblem.Count -gt 0) {
    $detail = ($validationProblem | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
    throw "The declaration satisfies its schema but is not executable:$([Environment]::NewLine)$detail"
}

# Which validator ran is part of the result, not a footnote. The reduced 5.1
# engine ignores pattern, minimum, minItems and the oneOf family, so a report
# from it carries less assurance about its own declaration than one from the
# full engine - and this success line was the only place an operator ever saw.
$schemaEngine = Get-JenkinsAsCodeSchemaEngine
Write-ModuleLog "Schema and invariants: $($fieldKeys.Count) custom field(s), $($queryKeys.Count) query(ies), $(@($declaration.projectKeys).Count) project(s). Valid ($schemaEngine validation)."

if ($Command -eq 'validate') {
    Write-ModuleLog 'validate is offline and complete. Nothing was contacted.'
    return
}

# --- Credentials ----------------------------------------------------------

$environmentFiles = if ($EnvFile) { $EnvFile } else { @((Join-Path $repositoryRoot '.env')) }
Import-JenkinsAsCodeEnvironment -Path $environmentFiles -Optional

$jiraContext = Get-JiraContext -ProjectContext $projectContext
Write-ModuleLog "Jira: $($jiraContext.BaseUrl) as $($jiraContext.Email), API v$($jiraContext.ApiVersion)."

# --- Live state -----------------------------------------------------------

$allFields = Get-JiraField -Context $jiraContext
Write-ModuleLog "Read $(@($allFields).Count) field definition(s)."

# -FieldName lets somebody answer a question without editing the declaration. The
# ad hoc entries are marked, so a report never suggests they are declared state.
$requestedFields = New-Object System.Collections.ArrayList
foreach ($field in $declaration.customFields) {
    $null = $requestedFields.Add([pscustomobject]@{ key = $field.key; displayName = $field.displayName; declared = $true })
}
foreach ($name in $FieldName) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $null = $requestedFields.Add([pscustomobject]@{ key = "adhoc:$name"; displayName = $name; declared = $false })
}

$fieldResult = New-Object System.Collections.ArrayList
foreach ($request in $requestedFields) {
    $matched = @(Find-JiraFieldByName -Field $allFields -Name $request.displayName)
    $status = Get-CustomFieldStatus -DisplayName $request.displayName -Match $matched

    $null = $fieldResult.Add([pscustomobject]@{
        key         = $request.key
        displayName = $request.displayName
        declared    = $request.declared
        fieldId     = $status.FieldId
        matchCount  = @($matched).Count
        candidates  = @($matched | ForEach-Object { $_.id })
        status      = $status
    })

    Write-ModuleLog ("field '{0}' -> {1}" -f $request.displayName, $(if ($status.FieldId) { $status.FieldId } else { $status.Status.ToUpperInvariant() }))
}

$queryResult = New-Object System.Collections.ArrayList
foreach ($query in $declaration.queries) {
    $fields = if ($query.PSObject.Properties['fields'] -and $query.fields) { @($query.fields) } else { @('status') }
    $issues = Search-JiraIssue -Context $jiraContext -Jql $query.jql -Field $fields
    $status = Get-QueryStatus -Expectation $query.expectation -IssueCount @($issues).Count

    $null = $queryResult.Add([pscustomobject]@{
        key        = $query.key
        jql        = $query.jql
        issueCount = @($issues).Count
        issueKeys  = @($issues | ForEach-Object { $_.key })
        status     = $status
    })

    Write-ModuleLog ("query '{0}' -> {1} issue(s), {2}" -f $query.key, @($issues).Count, $status.Status)
}

# --- Plan -----------------------------------------------------------------

$planTarget = (@($declaration.projectKeys) -join ',')
if (-not $planTarget) { $planTarget = '(nothing declared)' }
$plan = New-Plan -Command $Command -Target $planTarget

foreach ($result in $fieldResult) {
    $operationName = if ($result.declared) { "customField/$($result.key)" } else { "customField/$($result.displayName) (ad hoc)" }
    Add-PlanOperation -Plan $plan -Operation (New-PlanOperation `
        -Resource 'customField' -Name $operationName `
        -Action $result.status.Action -Status $result.status.Status -Reason $result.status.Reason) | Out-Null
}

foreach ($result in $queryResult) {
    Add-PlanOperation -Plan $plan -Operation (New-PlanOperation `
        -Resource 'jqlQuery' -Name "query/$($result.key)" `
        -Action $result.status.Action -Status $result.status.Status -Reason $result.status.Reason) | Out-Null
}

Write-PlanSummary -Plan $plan

# --- Evidence -------------------------------------------------------------

$reportPathResolved = Get-JenkinsAsCodeReportPath -RepositoryRoot $repositoryRoot -Module $moduleName -Command $Command -ReportPath $ReportPath
else {
    # UTC, and unique rather than merely precise. Local time in the name while the
    # content is UTC meant the lexicographic order of a directory was not the
    # chronological one, and in the autumn clock change two runs an hour apart landed
    # on the same name. One second of granularity collided on its own anyway: two runs
    # of the same command in the same second overwrote each other, and the writer
    # truncates without a word. The suffix is what makes the name unique.
    $stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
    $unique = [guid]::NewGuid().ToString('N').Substring(0, 6)
    Join-Path $repositoryRoot ("artifacts/reports/{0}-{1}-{2}Z-{3}.json" -f $moduleName, $Command, $stamp, $unique)
}

# Provenance, so a report answers who produced it, from what code, against
# which declaration and at what scope. The scope is the one that mattered most:
# a filtered run and a whole one differed only in a total, so "pending 0" read
# as "everything is aligned" when it could equally mean "one item was examined".
$provenanceArgument = @{
    Command         = $Command
    DeclarationPath = $configurationPath
    DeclarationText = (Get-Content -LiteralPath $configurationPath -Raw)
    SchemaEngine    = $schemaEngine
    Scope           = if ($FieldName.Count -gt 0) { 'fieldName=' + ($FieldName -join ',') } else { 'all' }
    RepositoryRoot  = $repositoryRoot
    ToolVersion     = "$($projectContext.version)"
    UsedTemplate    = $usedTemplate
}

$detail = [ordered]@{
    provenance        = Get-JenkinsAsCodeProvenance @provenanceArgument
    runLog            = $runLogPath
    jiraBaseUrl    = $jiraContext.BaseUrl
    apiVersion     = $jiraContext.ApiVersion
    projectKeys    = @($declaration.projectKeys)
    declarationPath = $configurationPath
    customFields   = @($fieldResult | ForEach-Object {
        [ordered]@{
            key         = $_.key
            displayName = $_.displayName
            declared    = $_.declared
            fieldId     = $_.fieldId
            matchCount  = $_.matchCount
            candidates  = $_.candidates
        }
    })
    queries        = @($queryResult | ForEach-Object {
        [ordered]@{
            key        = $_.key
            jql        = $_.jql
            issueCount = $_.issueCount
            issueKeys  = $_.issueKeys
        }
    })
}

$written = Write-JenkinsAsCodeReport -Plan $plan -Path $reportPathResolved -Module $moduleName -Detail ([pscustomobject]$detail)
Write-ModuleLog "Report: $($written.JsonPath)"
Write-ModuleLog "Summary: $($written.MarkdownPath)"

# --- smoke ----------------------------------------------------------------

if ($Command -eq 'smoke') {
    Write-ModuleLog 'Manual verification checklist:'
    Write-ModuleLog '  1. For each resolved field id, open an issue in Jira and confirm the field shown is the one you meant.'
    Write-ModuleLog '  2. For any field reported blocked with more than one match, decide which id is correct and record the decision.'
    Write-ModuleLog '  3. For any query reported warning, run the same JQL in the Jira UI. Zero rows there too means the JQL is stale, not that the queue is empty.'
    Write-ModuleLog '  4. Confirm the report under artifacts/ contains no issue summary you would not paste into a ticket.'
}

# Exit code, because the result has a consumer that is not a person reading the
# screen. Test-PlanBlocked was already being called here and its answer thrown away
# in a log line, so a scheduled run whose plan was entirely blocked reported
# success. A job whose definition could not be read becomes a blocked operation
# too, so this one code covers both "nothing could be determined" cases rather than
# inventing a second one.
#
#   0  the run completed and nothing is blocked
#   2  the run completed and at least one resource could not be determined
#   1  the run itself failed (an uncaught throw: bad declaration, no credential,
#      controller unreachable)
if (Test-PlanBlocked -Plan $plan) {
    Write-ModuleLog 'The plan contains blocked operation(s). Read the reasons above: each one needs a person, not a retry.' -Level warning
    exit 2
}

exit 0
