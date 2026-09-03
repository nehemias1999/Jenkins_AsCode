<#
.SYNOPSIS
    Discovers the Jenkins jobs on a controller and reports how the live configuration
    differs from the declaration.

.DESCRIPTION
    Command ladder. Nothing here writes to Jenkins:

      validate   Offline. The declaration against its schema, plus the invariants a
                 schema cannot express. No network, no token.
      inventory  Walks the declared folders and records what exists today, including
                 the branch specifier and script path of every job. Makes no
                 reference to the declaration, so it is the honest starting point.
      plan       Compares the declaration against live state and classifies every
                 difference.
      smoke      Plan plus the manual verification checklist.

    There is no apply. The write path in Jenkins is a POST of config.xml, which
    replaces the whole document: anything the declaration does not mention -
    a parameter, a trigger, a plugin section - is destroyed by a POST built from a
    template. Adding that safely means read-modify-write on the XML, which is a
    different piece of work with a different risk profile. Until it is done there is
    no code path to reach for by accident. See
    docs/adr/0001-read-only-by-construction.md.

    How the declaration is produced: not by hand. Run inventory first, read the
    snapshot, and derive the declaration from what was actually found. Then plan
    against the same controller must report zero pending - and that zero is the proof
    that the inventory and the comparison agree, which is what makes any later
    finding believable.

    Two things this deliberately does not report as a problem:

    An undeclared job is reported and never altered. What a job contains - its build
    history, its queue - is not in the declaration, so the blast radius of touching
    it cannot be predicted from a plan.

    An empty agent label on a Pipeline job is correct, not missing data. A declarative
    Pipeline keeps its agent label in the Jenkinsfile, in the SCM, not in config.xml.
    pipeline-drift reads it from there.

.PARAMETER Command
    Operation to run. See the ladder above.

.PARAMETER JobKey
    Restrict plan to these declared jobs. Omitting it covers all of them.

.PARAMETER EnvFile
    Environment files to load. Defaults to .env in the repository root.

.PARAMETER ProjectContextPath
    Override for foundation/config/project-context.json.

.PARAMETER ConfigurationPath
    Override for the declaration.

.PARAMETER ReportPath
    Where to write the report. Defaults under artifacts/, which is not versioned.

.EXAMPLE
    .\Invoke-JobInventory.ps1 -Command validate

    Offline check. Needs no credential.

.EXAMPLE
    .\Invoke-JobInventory.ps1 -Command inventory

    Walks the controller and writes the snapshot the declaration is derived from.

.EXAMPLE
    .\Invoke-JobInventory.ps1 -Command plan

    Zero pending means the declaration matches the controller.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('validate', 'inventory', 'plan', 'smoke')]
    [string] $Command,

    [string[]] $JobKey = @(),
    [string[]] $EnvFile,
    [string] $ProjectContextPath,
    [string] $ConfigurationPath,
    [string] $ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleName = 'job-inventory'
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

function Get-JobPresenceStatus {
    <#
    .SYNOPSIS
        Classifies whether a declared job exists on the controller.

    .DESCRIPTION
        Pure function. An absent job is blocked rather than pending: every other
        comparison for that job is meaningless, and reporting five differences
        against a job that is not there buries the one fact that matters.

    .PARAMETER Path
        Declared job path.

    .PARAMETER Exists
        Whether the controller returned a definition.

    .EXAMPLE
        Get-JobPresenceStatus -Path 'EXAMPLE-FOLDER/example' -Exists $false

    .OUTPUTS
        An object with Action, Status and Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [bool] $Exists
    )

    if ($Exists) {
        return [pscustomobject]@{ Action = 'exists'; Status = 'ok'; Reason = 'Present on the controller.' }
    }

    return [pscustomobject]@{
        Action = 'resolve'
        Status = 'blocked'
        Reason = "No job at '$Path'. Either it was renamed or removed, or the path is wrong - remember that every folder level is its own segment, so a job inside a folder is 'Folder/Job'."
    }
}

function Get-PropertyMatchStatus {
    <#
    .SYNOPSIS
        Compares one declared property against its live value.

    .DESCRIPTION
        Pure function, and the single place where a difference becomes a status, so
        every property is judged the same way.

        A declared value that is absent yields skip, not ok. The difference matters:
        ok asserts the live state was checked and matched, and claiming that about
        something never compared is how a report becomes confidently wrong.

        A difference is pending. In this repository pending means a change is
        required and a person makes it, because there is no apply - see
        docs/reference/command-model.md.

    .PARAMETER Property
        Name of the property, used in the reason.

    .PARAMETER Expected
        Declared value, or $null when not declared.

    .PARAMETER Actual
        Live value.

    .EXAMPLE
        Get-PropertyMatchStatus -Property 'branchSpecifier' -Expected '*/master' -Actual '*/main'

    .OUTPUTS
        An object with Action, Status and Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Property,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [object] $Expected,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [object] $Actual
    )

    if ($null -eq $Expected) {
        return [pscustomobject]@{
            Action = 'skip'
            Status = 'ok'
            Reason = "Not declared, so not compared. Live value: '$Actual'."
        }
    }

    $expectedText = [string] $Expected
    $actualText = [string] $Actual

    if ($expectedText -ceq $actualText) {
        return [pscustomobject]@{ Action = 'exists'; Status = 'ok'; Reason = "Matches: '$actualText'." }
    }

    # Case-only differences are called out separately. Jenkins treats a branch name
    # case-sensitively while Windows tooling around it often does not, so 'Main'
    # against 'main' is a real difference that reads like a typo in a report.
    if ($expectedText -ieq $actualText) {
        return [pscustomobject]@{
            Action = 'update'
            Status = 'pending'
            Reason = "$Property differs in case only: declared '$expectedText', live '$actualText'. Git refs are case-sensitive, so these are different."
        }
    }

    return [pscustomobject]@{
        Action = 'update'
        Status = 'pending'
        Reason = "$Property declared '$expectedText', live '$actualText'."
    }
}

function Get-UndeclaredJobStatus {
    <#
    .SYNOPSIS
        Classifies a job found on the controller that the declaration does not name.

    .DESCRIPTION
        Pure function. Always a warning, never pending and never a candidate for
        removal: what a job holds - its build history, whatever is queued on it - is
        not in the declaration, so nothing here can predict the effect of touching
        it. It is reported so somebody either declares it or deletes it knowingly.

    .PARAMETER Path
        Path of the discovered job.

    .EXAMPLE
        Get-UndeclaredJobStatus -Path 'EXAMPLE-FOLDER/other'

    .OUTPUTS
        An object with Action, Status and Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    return [pscustomobject]@{
        Action = 'manual'
        Status = 'warning'
        Reason = "'$Path' exists on the controller and is not declared. Preserved and reported: add it to the declaration, or remove it in Jenkins knowing it takes its build history with it."
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

$validationProblem = New-Object System.Collections.ArrayList

$declaredKeys = @($declaration.jobs | ForEach-Object { $_.key })
$duplicateKeys = @(Get-JenkinsAsCodeDuplicateValue -Value $declaredKeys)
if ($duplicateKeys.Count -gt 0) {
    $null = $validationProblem.Add("Duplicate job key(s): $($duplicateKeys -join ', '). A key names a row in every report.")
}

$declaredPaths = @($declaration.jobs | ForEach-Object { $_.path })
$duplicatePaths = @(Get-JenkinsAsCodeDuplicateValue -Value $declaredPaths)
if ($duplicatePaths.Count -gt 0) {
    $null = $validationProblem.Add("Duplicate job path(s): $($duplicatePaths -join ', '). Two declarations for one job would each report their own verdict about it.")
}

if ([int] $declaration.maximumDepth -lt 1) {
    $null = $validationProblem.Add('maximumDepth must be at least 1, otherwise the walk descends nowhere.')
}

foreach ($job in $declaration.jobs) {
    # New-JenkinsJobPath is the same function the requests use, so a path that
    # cannot become a URL fails here rather than as a 404 halfway through a run.
    try {
        $segment = New-JenkinsJobPath -Path $job.path
        if (-not $segment) {
            $null = $validationProblem.Add("Job '$($job.key)' has an empty path.")
        }
    }
    catch {
        $null = $validationProblem.Add("Job '$($job.key)' has an unusable path '$($job.path)': $($_.Exception.Message)")
    }

    # A branch specifier that names no single branch is worth catching offline: the
    # drift comparison downstream cannot resolve it to a commit.
    if ($job.expected.PSObject.Properties['branchSpecifier'] -and $job.expected.branchSpecifier) {
        $resolved = Resolve-GitBranchName -BranchSpecifier $job.expected.branchSpecifier
        if ($resolved.Ambiguous) {
            $null = $validationProblem.Add("Job '$($job.key)' declares branchSpecifier '$($job.expected.branchSpecifier)', which does not name one branch: $($resolved.Reason)")
        }
    }
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
Write-ModuleLog "Schema and invariants: $($declaredKeys.Count) job(s), $(@($declaration.folders).Count) folder(s), maximumDepth $($declaration.maximumDepth). Valid ($schemaEngine validation)."

if ($Command -eq 'validate') {
    Write-ModuleLog 'validate is offline and complete. Nothing was contacted.'
    return
}

# --- Live state -----------------------------------------------------------

$environmentFiles = if ($EnvFile) { $EnvFile } else { @((Join-Path $repositoryRoot '.env')) }
Import-JenkinsAsCodeEnvironment -Path $environmentFiles -Optional

$jenkinsContext = Get-JenkinsContext -ProjectContext $projectContext
$controllerVersion = Get-JenkinsControllerVersion -Context $jenkinsContext
Write-ModuleLog "Controller: $($jenkinsContext.BaseUrl) as $($jenkinsContext.UserName), Jenkins $controllerVersion."

# Discovery. This is the step that removes the need for anyone to hand over a list
# of job paths, and the reason inventory comes before the declaration exists.
$discovered = New-Object System.Collections.ArrayList
foreach ($folder in @($declaration.folders)) {
    $items = Get-JenkinsJobTree -Context $jenkinsContext -Path $folder -MaximumDepth ([int] $declaration.maximumDepth)
    foreach ($item in $items) { $null = $discovered.Add($item) }
    Write-ModuleLog ("folder '{0}' -> {1} item(s)" -f $(if ($folder) { $folder } else { '(root)' }), @($items).Count)
}

$truncated = @($discovered | Where-Object { $_.truncated })
if ($truncated.Count -gt 0) {
    Write-ModuleLog "$($truncated.Count) container(s) were not descended into because maximumDepth was reached. They are listed in the report."
}

# Read the definition of every buildable item found, plus every declared job, so a
# declared job that discovery missed still produces a verdict instead of silence.
$definitionByPath = @{}
$readFailure = New-Object System.Collections.ArrayList

$pathsToRead = New-Object System.Collections.ArrayList
foreach ($item in $discovered) {
    if (-not $item.isContainer) { $null = $pathsToRead.Add($item.path) }
}
foreach ($job in $declaration.jobs) {
    if ($pathsToRead -notcontains $job.path) { $null = $pathsToRead.Add($job.path) }
}

foreach ($path in $pathsToRead) {
    try {
        $definition = Get-JenkinsJobDefinition -Context $jenkinsContext -JobPath $path -AllowNotFound
        if ($null -ne $definition) { $definitionByPath[$path] = $definition }
    }
    catch {
        # One unreadable job must not end the walk. A missing Job/ExtendedRead on a
        # single folder is common, and a report that lists the other forty jobs plus
        # the one that failed is far more useful than an exception.
        $null = $readFailure.Add([pscustomobject]@{ path = $path; message = $_.Exception.Message })
        Write-ModuleLog "could not read '$path': $($_.Exception.Message)" -Level warning
    }
}

Write-ModuleLog "Read $($definitionByPath.Count) job definition(s); $($readFailure.Count) unreadable."

# --- Plan -----------------------------------------------------------------

# An empty folder means the controller root, which is a legitimate thing to walk.
# The plan target is a label for a reader, so it gets a name rather than an
# empty string, which New-Plan rejects.
$planTarget = (@($declaration.folders | ForEach-Object { if ($_) { $_ } else { '(root)' } }) -join ',')
if (-not $planTarget) { $planTarget = '(nothing declared)' }
$plan = New-Plan -Command $Command -Target $planTarget

foreach ($folder in @($declaration.folders)) {
    $label = if ($folder) { $folder } else { '(root)' }
    $childCount = @($discovered | Where-Object { $_.depth -eq 1 }).Count
    $status = if ($childCount -gt 0) {
        [pscustomobject]@{ Action = 'exists'; Status = 'ok'; Reason = "Walked. $childCount item(s) at the first level." }
    }
    else {
        [pscustomobject]@{ Action = 'validate'; Status = 'warning'; Reason = 'Walked and returned nothing. Either the folder is empty, or the token cannot see its children - Job/Read is needed to list them.' }
    }
    Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'folder' -Name "folder/$label" -Action $status.Action -Status $status.Status -Reason $status.Reason) | Out-Null
}

# The outer @() is load-bearing, and its absence was a real defect. PowerShell
# unwraps an array flowing out of a script block, so a -JobKey matching exactly ONE
# job left $selectedJobs holding the bare object - and .Count on the line below then
# threw under StrictMode, which is the one place it is guaranteed to run. The filter
# was broken for a single key, and nothing noticed because nothing ever ran it.
#
# Fourth appearance of this trap in this repository; the other three are recorded in
# the changelog. This one is the first that a test can see.
$selectedJobs = @(if ($JobKey.Count -gt 0) {
    @($declaration.jobs | Where-Object { $JobKey -contains $_.key })
}
else {
    @($declaration.jobs)
})
if ($JobKey.Count -gt 0 -and $selectedJobs.Count -ne $JobKey.Count) {
    $missing = @($JobKey | Where-Object { $declaredKeys -notcontains $_ })
    throw "No declared job with key(s): $($missing -join ', '). Declared keys: $($declaredKeys -join ', ')."
}

foreach ($job in $selectedJobs) {
    $definition = if ($definitionByPath.ContainsKey($job.path)) { $definitionByPath[$job.path] } else { $null }

    $presence = Get-JobPresenceStatus -Path $job.path -Exists ($null -ne $definition)
    Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'job' -Name "job/$($job.key)" -Action $presence.Action -Status $presence.Status -Reason $presence.Reason) | Out-Null
    if ($null -eq $definition) { continue }

    # Each declared property becomes its own operation, so a report names exactly
    # what differs instead of saying the job differs.
    $comparison = @(
        @{ Resource = 'jobType';         Property = 'type';            Expected = $job.expected.type;    Actual = $definition.type }
        @{ Resource = 'jobEnabled';      Property = 'enabled';         Expected = (-not [bool] $job.expected.enabled); Actual = $definition.disabled }
        @{ Resource = 'scmUrl';          Property = 'scmUrl';          Expected = $null;                 Actual = $definition.scm.url }
        @{ Resource = 'branchSpecifier'; Property = 'branchSpecifier'; Expected = $null;                 Actual = $definition.scm.branchSpecifier }
        @{ Resource = 'scriptPath';      Property = 'scriptPath';      Expected = $null;                 Actual = $definition.scm.scriptPath }
    )
    foreach ($optional in @('scmUrl', 'branchSpecifier', 'scriptPath')) {
        if ($job.expected.PSObject.Properties[$optional]) {
            foreach ($entry in $comparison) {
                if ($entry.Property -eq $optional) { $entry.Expected = $job.expected.$optional }
            }
        }
    }

    foreach ($entry in $comparison) {
        $status = Get-PropertyMatchStatus -Property $entry.Property -Expected $entry.Expected -Actual $entry.Actual
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource $entry.Resource -Name "$($job.key)/$($entry.Property)" -Action $status.Action -Status $status.Status -Reason $status.Reason) | Out-Null
    }

    # Reported, never compared against a declaration. An inline Pipeline script
    # cannot be traced to a commit, and that is the finding.
    if ($definition.scm.kind -eq 'inline') {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'scmBinding' -Name "$($job.key)/definition" -Action 'manual' -Status 'warning' `
            -Reason 'The pipeline script is stored in the job, not in SCM. There is no commit to compare it against, so nothing can say what changed or who changed it.') | Out-Null
    }
}

foreach ($item in @($discovered | Where-Object { -not $_.isContainer })) {
    if ($declaredPaths -contains $item.path) { continue }
    $status = Get-UndeclaredJobStatus -Path $item.path
    Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'undeclaredJob' -Name "job/$($item.path)" -Action $status.Action -Status $status.Status -Reason $status.Reason) | Out-Null
}

foreach ($failure in $readFailure) {
    Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'jobDefinition' -Name "job/$($failure.path)" -Action 'resolve' -Status 'blocked' `
        -Reason "The definition could not be read, so nothing about this job was compared: $($failure.message)") | Out-Null
}

Write-PlanSummary -Plan $plan

# --- Evidence -------------------------------------------------------------

$reportPathResolved = Get-JenkinsAsCodeReportPath -RepositoryRoot $repositoryRoot -Module $moduleName -Command $Command -ReportPath $ReportPath

# Provenance, so a report answers who produced it, from what code, against
# which declaration and at what scope. The scope is the one that mattered most:
# a filtered run and a whole one differed only in a total, so "pending 0" read
# as "everything is aligned" when it could equally mean "one item was examined".
$provenanceArgument = @{
    Command         = $Command
    DeclarationPath = $configurationPath
    DeclarationText = (Get-Content -LiteralPath $configurationPath -Raw)
    SchemaEngine    = $schemaEngine
    Scope           = if ($JobKey.Count -gt 0) { 'jobKey=' + ($JobKey -join ',') } else { 'all' }
    RepositoryRoot  = $repositoryRoot
    ToolVersion     = "$($projectContext.version)"
    UsedTemplate    = $usedTemplate
}

$detail = [ordered]@{
    provenance        = Get-JenkinsAsCodeProvenance @provenanceArgument
    runLog            = $runLogPath
    controllerUrl     = $jenkinsContext.BaseUrl
    controllerVersion = $controllerVersion
    declarationPath   = $configurationPath
    folders           = @($declaration.folders)
    maximumDepth      = [int] $declaration.maximumDepth
    truncatedPaths    = @($truncated | ForEach-Object { $_.path })
    unreadablePaths   = @($readFailure | ForEach-Object { $_.path })

    # The snapshot the declaration is derived from. Everything needed to write
    # jobs.json is here, so nobody has to click through the UI to find it.
    discovered        = @($pathsToRead | ForEach-Object {
        $path = $_
        $definition = if ($definitionByPath.ContainsKey($path)) { $definitionByPath[$path] } else { $null }

        # Built before the hash literal, not inside it. In Windows PowerShell 5.1 an
        # empty array flowing out of a script block is unwrapped to $null, so
        # 'parameters = if ($definition) { @(...) } else { @() }' serialised a job with
        # no parameters as null. To a consumer, null and [] are different claims -
        # "not known" against "none" - and an inventory must not confuse them.
        $entryParameters = @()
        $entryTriggers = @()
        if ($definition) {
            $entryParameters = @($definition.parameters | ForEach-Object { [ordered]@{ name = $_.name; type = $_.type; isSecret = $_.isSecret } })
            $entryTriggers = @($definition.triggers | ForEach-Object { [ordered]@{ type = $_.type; spec = $_.spec } })
        }

        [ordered]@{
            path            = $path
            declared        = [bool] ($declaredPaths -contains $path)
            readable        = [bool] ($null -ne $definition)
            type            = if ($definition) { $definition.type } else { '' }
            rootElement     = if ($definition) { $definition.rootElement } else { '' }
            disabled        = if ($definition) { [bool] $definition.disabled } else { $null }
            assignedNode    = if ($definition) { $definition.assignedNode } else { '' }
            definitionKind  = if ($definition) { $definition.scm.kind } else { '' }
            scmUrl          = if ($definition) { $definition.scm.url } else { '' }
            credentialsId   = if ($definition) { $definition.scm.credentialsId } else { '' }
            branchSpecifier = if ($definition) { $definition.scm.branchSpecifier } else { '' }
            scriptPath      = if ($definition) { $definition.scm.scriptPath } else { '' }
            parameters      = $entryParameters
            triggers        = $entryTriggers
        }
    })
}

$written = Write-JenkinsAsCodeReport -Plan $plan -Path $reportPathResolved -Module $moduleName -Detail ([pscustomobject]$detail)
Write-ModuleLog "Report: $($written.JsonPath)"
Write-ModuleLog "Summary: $($written.MarkdownPath)"

# Parameter default values are deliberately absent from the snapshot above. A
# non-secret default is harmless, but telling one from a secret one reliably enough
# to write it into a file that gets pasted into tickets is not worth the risk, so
# the report carries names and types only.

# --- smoke ----------------------------------------------------------------

if ($Command -eq 'smoke') {
    Write-ModuleLog 'Manual verification checklist:'
    Write-ModuleLog '  1. Open one job in Jenkins and compare its Branch Specifier against the value in the report. They must match character for character.'
    Write-ModuleLog '  2. Confirm the number of jobs discovered matches what you see in the UI. A smaller number usually means the token cannot see a folder.'
    Write-ModuleLog '  3. Re-run plan. It must report the same operations as the first run; if it does not, the difference is not in Jenkins.'
    Write-ModuleLog '  4. For every undeclared job in the report, decide: declare it, or leave it and accept it stays unmanaged.'
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
    Write-ModuleLog 'The plan contains blocked operation(s). Each one needs a person, not a retry.' -Level warning
    exit 2
}

exit 0
