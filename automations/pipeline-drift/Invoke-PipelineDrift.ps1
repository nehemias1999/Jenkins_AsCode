<#
.SYNOPSIS
    Answers, for each Jenkins job, which commit actually feeds it and whether the
    local working copy is the same code.

.DESCRIPTION
    Three sources are joined, and no single one of them can answer the question:

      1. The live job says which repository and which branch it reads. Only
         config.xml holds that; /api/json does not.
      2. The remote says which commit that branch points at right now.
      3. The local working copy says what somebody is looking at while they work.

    Command ladder. Nothing here writes to Jenkins:

      validate   Offline. The declaration against its schema plus the invariants a
                 schema cannot express. No network, no token.
      inventory  Records branch, resolved branch name, remote commit and local commit
                 for each declared pipeline.
      plan       Classifies every difference.
      smoke      Plan plus the manual verification checklist.

    The trap this exists to catch: a job configured to read main keeps running the
    code on main, no matter how many feature branches exist. Creating a branch and
    editing it changes nothing about what runs until the job's Branch Specifier is
    changed too - and since the specifier lives in the Jenkins UI, nothing in the
    repository records whether it was. That is a silent failure with no error
    message, and it is exactly what this module reports.

    What it touches locally: a shallow fetch, when the commit the job reads is not
    present in the clone. That adds objects and moves FETCH_HEAD. It never checks
    anything out, never moves a branch and never touches the working tree - there is
    no checkout or pull path anywhere in Scm.Git.

.PARAMETER Command
    Operation to run. See the ladder above.

.PARAMETER PipelineKey
    Restrict the run to these declared pipelines.

.PARAMETER EnvFile
    Environment files to load. Defaults to .env in the repository root.

.PARAMETER ProjectContextPath
    Override for foundation/config/project-context.json.

.PARAMETER ConfigurationPath
    Override for the declaration.

.PARAMETER ReportPath
    Where to write the report. Defaults under artifacts/, which is not versioned.

.EXAMPLE
    .\Invoke-PipelineDrift.ps1 -Command validate

    Offline check. Needs no credential.

.EXAMPLE
    .\Invoke-PipelineDrift.ps1 -Command plan -PipelineKey example-pipeline

    Reports whether the local copy is the code the job would run.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('validate', 'inventory', 'plan', 'smoke')]
    [string] $Command,

    [string[]] $PipelineKey = @(),
    [string[]] $EnvFile,
    [string] $ProjectContextPath,
    [string] $ConfigurationPath,
    [string] $ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleName = 'pipeline-drift'
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

function Get-JenkinsfileAgentLabel {
    <#
    .SYNOPSIS
        Extracts the agent labels a Jenkinsfile asks for.

    .DESCRIPTION
        Pure function, and the piece job-inventory structurally cannot provide: a
        declarative Pipeline keeps its agent label in the Jenkinsfile, not in
        config.xml, so the only way to know which agent a job wants is to read the
        script at the commit the job runs.

        Best-effort by design, and it says so rather than pretending. It matches a
        label directive lexically, so it will also match one inside a comment, and it
        will not resolve one built from a variable. Every label found is returned, and
        a report states the number rather than asserting a single answer - which is
        honest about a regex reading a language it does not parse.

    .PARAMETER Jenkinsfile
        Content of the Jenkinsfile.

    .EXAMPLE
        Get-JenkinsfileAgentLabel -Jenkinsfile $text

    .OUTPUTS
        The distinct labels found, in the order they appear.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Jenkinsfile
    )

    if ([string]::IsNullOrWhiteSpace($Jenkinsfile)) { return @() }

    $found = New-Object System.Collections.ArrayList
    foreach ($match in [regex]::Matches($Jenkinsfile, "label\s*[:=]?\s*(['" + '"' + "])(?<label>[^'" + '"' + "]+)\1")) {
        $label = $match.Groups['label'].Value.Trim()
        if (-not $label) { continue }
        if ($found -notcontains $label) { $null = $found.Add($label) }
    }

    return @($found.ToArray())
}

function Get-CommitAlignmentStatus {
    <#
    .SYNOPSIS
        Classifies the relationship between the commit the job reads and the local one.

    .DESCRIPTION
        Pure function.

        Equal commits are ok. Different commits are a warning, not an error: a clone
        being behind the remote is the normal state of a clone, and reporting it as a
        failure would make every run noisy and train people to ignore it. What makes
        it worth printing is that it explains the Jenkinsfile verdict underneath -
        a drift verdict against a stale clone means nothing until the clone is
        updated.

    .PARAMETER RemoteCommit
        Commit the job's branch points at on the remote.

    .PARAMETER LocalCommit
        Commit the working copy is on.

    .EXAMPLE
        Get-CommitAlignmentStatus -RemoteCommit $remote -LocalCommit $local

    .OUTPUTS
        An object with Action, Status and Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $RemoteCommit,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $LocalCommit
    )

    if (-not $RemoteCommit) {
        return [pscustomobject]@{ Action = 'resolve'; Status = 'blocked'; Reason = 'The branch the job reads does not exist on the remote, so there is no commit to compare against.' }
    }
    if (-not $LocalCommit) {
        return [pscustomobject]@{ Action = 'resolve'; Status = 'blocked'; Reason = 'The working copy has no commit, so there is nothing local to compare.' }
    }
    if ($RemoteCommit -eq $LocalCommit) {
        return [pscustomobject]@{ Action = 'exists'; Status = 'ok'; Reason = "Working copy is on the commit the job would run ($($RemoteCommit.Substring(0, 8)))." }
    }

    return [pscustomobject]@{
        Action = 'validate'
        Status = 'warning'
        Reason = "Working copy is on $($LocalCommit.Substring(0, 8)) while the job would run $($RemoteCommit.Substring(0, 8)). Any file verdict below is against those two different commits."
    }
}

function Get-JenkinsfileDriftStatus {
    <#
    .SYNOPSIS
        Turns a text comparison verdict into a plan status.

    .DESCRIPTION
        Pure function. identical is ok; cosmetic is ok with the reason stated,
        because a line-ending difference is not something anyone should act on; drift
        is pending, meaning a person decides what to do about it.

    .PARAMETER Verdict
        Verdict from Compare-ScmText.

    .PARAMETER Detail
        Detail from Compare-ScmText.

    .EXAMPLE
        Get-JenkinsfileDriftStatus -Verdict 'drift' -Detail 'Content differs.'

    .OUTPUTS
        An object with Action, Status and Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateSet('identical', 'cosmetic', 'drift')] [string] $Verdict,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Detail
    )

    switch ($Verdict) {
        'identical' { return [pscustomobject]@{ Action = 'exists'; Status = 'ok'; Reason = 'The local file is the code the job would run.' } }
        'cosmetic'  { return [pscustomobject]@{ Action = 'exists'; Status = 'ok'; Reason = "Same code. $Detail" } }
        default     { return [pscustomobject]@{ Action = 'update'; Status = 'pending'; Reason = "The local file is not the code the job would run. $Detail" } }
    }
}

# --- Declaration ----------------------------------------------------------

$projectContextPathResolved = if ($ProjectContextPath) { $ProjectContextPath } else { 'foundation/config/project-context.json' }
$projectContextPathResolved = Resolve-JenkinsAsCodePath -Path $projectContextPathResolved -RootPath $repositoryRoot
$projectContext = Get-JenkinsAsCodeConfiguration -Path $projectContextPathResolved

$moduleContext = $projectContext.automations.$moduleName
if ($ConfigurationPath) {
    $configurationPath = Resolve-JenkinsAsCodePath -Path $ConfigurationPath -RootPath $repositoryRoot
}
else {
    $active = Resolve-JenkinsAsCodePath -Path $moduleContext.configuration -RootPath $repositoryRoot
    if (Test-Path -LiteralPath $active) {
        $configurationPath = $active
    }
    else {
        $configurationPath = Resolve-JenkinsAsCodePath -Path $moduleContext.template -RootPath $repositoryRoot
        $usedTemplate = $true
        Write-ModuleLog "No active declaration at $active. Using the versioned template instead: $configurationPath. The report will describe the example, not an estate." -Level warning
    }
}

$declaration = Get-JenkinsAsCodeConfiguration -Path $configurationPath
Write-ModuleLog "Declaration: $configurationPath"

$workingCopyRoot = Resolve-JenkinsAsCodePath -Path $declaration.workingCopyRoot -RootPath $repositoryRoot

# --- validate -------------------------------------------------------------

$validationProblem = New-Object System.Collections.ArrayList

$declaredKeys = @($declaration.pipelines | ForEach-Object { $_.key })
$duplicateKeys = @($declaredKeys | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
if ($duplicateKeys.Count -gt 0) {
    $null = $validationProblem.Add("Duplicate pipeline key(s): $($duplicateKeys -join ', ').")
}

$declaredJobPaths = @($declaration.pipelines | ForEach-Object { $_.jobPath })
$duplicateJobPaths = @($declaredJobPaths | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
if ($duplicateJobPaths.Count -gt 0) {
    $null = $validationProblem.Add("Duplicate jobPath(s): $($duplicateJobPaths -join ', '). Two entries for one job would each report their own verdict about it.")
}

foreach ($pipeline in $declaration.pipelines) {
    try {
        if (-not (New-JenkinsJobPath -Path $pipeline.jobPath)) {
            $null = $validationProblem.Add("Pipeline '$($pipeline.key)' has an empty jobPath.")
        }
    }
    catch {
        $null = $validationProblem.Add("Pipeline '$($pipeline.key)' has an unusable jobPath '$($pipeline.jobPath)': $($_.Exception.Message)")
    }
    if ([string]::IsNullOrWhiteSpace($pipeline.workingCopy)) {
        $null = $validationProblem.Add("Pipeline '$($pipeline.key)' has an empty workingCopy.")
    }
    else {
        # workingCopy has to stay under the declared root. Join-Path neither normalises
        # nor validates, so '../../elsewhere' resolves to a repository the declaration
        # never named - and that path is what git then runs in. Checked here rather than
        # with a schema pattern because on Windows PowerShell 5.1 the reduced validator
        # does not evaluate pattern, so a schema rule would be enforced on one engine
        # and ignored on the support floor.
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $workingCopyRoot $pipeline.workingCopy))
        $rootPrefix = [System.IO.Path]::GetFullPath($workingCopyRoot).TrimEnd('\', '/')
        if ($candidate -ne $rootPrefix -and -not $candidate.StartsWith($rootPrefix + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            $null = $validationProblem.Add("Pipeline '$($pipeline.key)' has a workingCopy that resolves outside workingCopyRoot. It must name a directory under the declared root, not a path that escapes it.")
        }
    }
    # A remote name is an operand to git, and git reads a leading dash as an option:
    # '--upload-pack=<binary>' in this field is a command git executes. Scm.Git and
    # Invoke-GitCommand both refuse it, but failing here names the declaration entry
    # that is wrong instead of failing mid-run.
    if ($pipeline.PSObject.Properties['remoteName'] -and $pipeline.remoteName -and
        $pipeline.remoteName -notmatch '^[A-Za-z0-9._][A-Za-z0-9._/-]*$') {
        $null = $validationProblem.Add("Pipeline '$($pipeline.key)' has an unusable remoteName. It must start with a letter, digit, dot or underscore and contain only those plus dash and slash.")
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
Write-ModuleLog "Schema and invariants: $($declaredKeys.Count) pipeline(s). Working copies under $workingCopyRoot. Valid ($schemaEngine validation)."

if ($Command -eq 'validate') {
    Write-ModuleLog 'validate is offline and complete. Nothing was contacted, and no working copy was read.'
    return
}

# --- Live state -----------------------------------------------------------

$environmentFiles = if ($EnvFile) { $EnvFile } else { @((Join-Path $repositoryRoot '.env')) }
Import-JenkinsAsCodeEnvironment -Path $environmentFiles -Optional

$jenkinsContext = Get-JenkinsContext -ProjectContext $projectContext
$controllerVersion = Get-JenkinsControllerVersion -Context $jenkinsContext
Write-ModuleLog "Controller: $($jenkinsContext.BaseUrl), Jenkins $controllerVersion."

$selected = if ($PipelineKey.Count -gt 0) {
    @($declaration.pipelines | Where-Object { $PipelineKey -contains $_.key })
}
else {
    @($declaration.pipelines)
}
if ($PipelineKey.Count -gt 0 -and $selected.Count -ne $PipelineKey.Count) {
    $missing = @($PipelineKey | Where-Object { $declaredKeys -notcontains $_ })
    throw "No declared pipeline with key(s): $($missing -join ', '). Declared keys: $($declaredKeys -join ', ')."
}

$jenkinsfileName = [string] $projectContext.defaults.jenkinsfilePath
$observation = New-Object System.Collections.ArrayList

foreach ($pipeline in $selected) {
    $remoteName = if ($pipeline.PSObject.Properties['remoteName'] -and $pipeline.remoteName) { $pipeline.remoteName } else { 'origin' }
    $workingCopyPath = Join-Path $workingCopyRoot $pipeline.workingCopy

    $record = [ordered]@{
        key             = $pipeline.key
        jobPath         = $pipeline.jobPath
        workingCopyPath = $workingCopyPath
        remoteName      = $remoteName
        jobFound        = $false
        definitionKind  = ''
        scmUrl          = ''
        branchSpecifier = ''
        scriptPath      = ''
        branch          = ''
        branchAmbiguous = $false
        branchReason    = ''
        remoteCommit    = ''
        localCommit     = ''
        isWorkingCopy   = $false
        comparison      = $null
        agentLabels     = @()
        failure         = ''
    }

    try {
        $definition = Get-JenkinsJobDefinition -Context $jenkinsContext -JobPath $pipeline.jobPath -AllowNotFound
        if ($null -ne $definition) {
            $record.jobFound = $true
            $record.definitionKind = $definition.scm.kind
            $record.scmUrl = $definition.scm.url
            $record.branchSpecifier = $definition.scm.branchSpecifier
            $record.scriptPath = if ($definition.scm.scriptPath) { $definition.scm.scriptPath } else { $jenkinsfileName }

            $resolved = Resolve-GitBranchName -BranchSpecifier $definition.scm.branchSpecifier -RemoteName $remoteName
            $record.branch = $resolved.Branch
            $record.branchAmbiguous = [bool] $resolved.Ambiguous
            $record.branchReason = $resolved.Reason

            $record.isWorkingCopy = Test-GitWorkingCopy -Path $workingCopyPath

            if ($record.isWorkingCopy -and -not $resolved.Ambiguous) {
                $record.remoteCommit = Get-GitRemoteBranchCommit -RepositoryPath $workingCopyPath -Branch $resolved.Branch -RemoteName $remoteName
                $record.localCommit = Get-GitWorkingCopyCommit -RepositoryPath $workingCopyPath

                if ($record.remoteCommit) {
                    $atCommit = Get-GitFileAtCommit -RepositoryPath $workingCopyPath -Commit $record.remoteCommit -FilePath $record.scriptPath -Branch $resolved.Branch -RemoteName $remoteName
                    $record.agentLabels = @(Get-JenkinsfileAgentLabel -Jenkinsfile $atCommit)

                    # scriptPath comes from the config.xml of the inspected controller,
                    # so it is somebody else's input. Unchecked, a job declaring
                    # ../../../.env makes this read that file off the auditor's disk. The
                    # content never reaches the report - only a SHA-256 and a line count -
                    # so the leak degrades to a hash oracle rather than an exfiltration,
                    # which is why this is a containment check and not a refusal to run.
                    $localFile = [System.IO.Path]::GetFullPath((Join-Path $workingCopyPath $record.scriptPath))
                    $copyPrefix = [System.IO.Path]::GetFullPath($workingCopyPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
                    if (-not $localFile.StartsWith($copyPrefix + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                        throw "The job declares a script path that resolves outside its working copy, so nothing was read from it."
                    }
                    $localText = if (Test-Path -LiteralPath $localFile) { Get-Content -LiteralPath $localFile -Raw } else { '' }
                    $record.comparison = Compare-ScmText -Left $atCommit -Right $localText
                }
            }
        }
    }
    catch {
        # One unreachable repository or unreadable job must not end the run. The
        # failure is recorded against that pipeline and becomes a blocked operation.
        $record.failure = $_.Exception.Message
        Write-ModuleLog "pipeline '$($pipeline.key)' failed: $($_.Exception.Message)" -Level warning
    }

    $null = $observation.Add([pscustomobject]$record)
    $verdict = if ($record.comparison) { $record.comparison.Verdict } elseif ($record.failure) { 'failed' } else { 'incomplete' }
    Write-ModuleLog ("pipeline '{0}' branch='{1}' -> {2}" -f $pipeline.key, $record.branchSpecifier, $verdict)
}

# --- Plan -----------------------------------------------------------------

$planTarget = (@($selected | ForEach-Object { $_.key }) -join ',')
if (-not $planTarget) { $planTarget = '(nothing declared)' }
$plan = New-Plan -Command $Command -Target $planTarget

foreach ($record in $observation) {
    $name = $record.key

    if ($record.failure) {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'pipeline' -Name "pipeline/$name" -Action 'resolve' -Status 'blocked' `
            -Reason "Nothing could be compared: $($record.failure)") | Out-Null
        continue
    }

    if (-not $record.jobFound) {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'job' -Name "job/$name" -Action 'resolve' -Status 'blocked' `
            -Reason "No job at '$($record.jobPath)', so there is nothing to say about which commit feeds it.") | Out-Null
        continue
    }

    if ($record.definitionKind -ne 'scm') {
        $reason = if ($record.definitionKind -eq 'inline') {
            'The pipeline script is stored in the job, not in SCM. There is no commit behind it, so drift is not a question that can be asked - and that is itself the finding worth acting on.'
        }
        else {
            'The job declares no SCM, so there is no repository to compare against.'
        }
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'scmBinding' -Name "$name/definition" -Action 'manual' -Status 'warning' -Reason $reason) | Out-Null
        continue
    }

    if ($record.branchAmbiguous) {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'branchSpecifier' -Name "$name/branch" -Action 'resolve' -Status 'blocked' `
            -Reason $record.branchReason) | Out-Null
        continue
    }
    Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'branchSpecifier' -Name "$name/branch" -Action 'validate' -Status 'ok' `
        -Reason "The job reads '$($record.branchSpecifier)', which is branch '$($record.branch)'.") | Out-Null

    if (-not $record.isWorkingCopy) {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'workingCopy' -Name "$name/workingCopy" -Action 'resolve' -Status 'blocked' `
            -Reason "No git working copy at '$($record.workingCopyPath)'. Clone the repository there, or correct workingCopy in the declaration.") | Out-Null
        continue
    }

    # Guards against the quiet mistake of comparing against the wrong repository:
    # a working copy whose remote is not the repository the job reads would produce
    # a confident drift verdict about two unrelated files.
    $localRemoteUrl = ''
    try {
        $remoteResult = Invoke-GitCommand -WorkingDirectory $record.workingCopyPath -Arguments @('remote', 'get-url', $record.remoteName)
        if ($remoteResult.ExitCode -eq 0) { $localRemoteUrl = $remoteResult.StandardOutput.Trim() }
    }
    catch { $localRemoteUrl = '' }

    # Three outcomes, not two. The catch above turns a failed 'git remote get-url'
    # into an empty string, and an empty string used to fall through to the ok
    # branch - so a check that could not run reported that the working copy points
    # at the right repository, and the file comparison below inherited that
    # confidence. The rule this repository states for itself applies here: ok
    # asserts the live state was checked and matched, and claiming that about
    # something never compared is how a report becomes confidently wrong.
    if (-not $record.scmUrl) {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'remoteUrl' -Name "$name/remoteUrl" -Action 'skip' -Status 'ok' `
            -Reason "The job declares no SCM URL, so there is nothing to compare the working copy remote against.") | Out-Null
    }
    elseif (-not $localRemoteUrl) {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'remoteUrl' -Name "$name/remoteUrl" -Action 'validate' -Status 'warning' `
            -Reason "The remote '$($record.remoteName)' could not be read from the working copy, so whether it points at the repository the job reads is unknown. Any file comparison below assumes it does.") | Out-Null
    }
    elseif ($localRemoteUrl.TrimEnd('/') -ine $record.scmUrl.TrimEnd('/')) {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'remoteUrl' -Name "$name/remoteUrl" -Action 'update' -Status 'pending' `
            -Reason "The job reads '$($record.scmUrl)' but the working copy remote '$($record.remoteName)' is '$localRemoteUrl'. Any file comparison below is between two different repositories.") | Out-Null
    }
    else {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'remoteUrl' -Name "$name/remoteUrl" -Action 'validate' -Status 'ok' `
            -Reason "The working copy points at the repository the job reads.") | Out-Null
    }

    $alignment = Get-CommitAlignmentStatus -RemoteCommit $record.remoteCommit -LocalCommit $record.localCommit
    Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'commit' -Name "$name/commit" -Action $alignment.Action -Status $alignment.Status -Reason $alignment.Reason) | Out-Null

    if ($null -ne $record.comparison) {
        $drift = Get-JenkinsfileDriftStatus -Verdict $record.comparison.Verdict -Detail $record.comparison.Detail
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'jenkinsfile' -Name "$name/$($record.scriptPath)" -Action $drift.Action -Status $drift.Status -Reason $drift.Reason) | Out-Null
    }

    # The agent label, which job-inventory structurally cannot report because a
    # declarative Pipeline does not store it in config.xml.
    $labels = @($record.agentLabels)
    # A label built from a build parameter is reported as what it is. The first real
    # Jenkinsfile this was run against declared its agent as a parameter reference, and
    # printing that as though it were a label name would state a fact that is not one:
    # which agent runs is decided per build, not by the file.
    $parameterised = @($labels | Where-Object { $_ -match '\$\{|\$[A-Za-z_]' })
    if ($parameterised.Count -gt 0) {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'agentLabel' -Name "$name/agent" -Action 'validate' -Status 'warning' `
            -Reason "The Jenkinsfile builds its agent label from a parameter ($($parameterised -join ', ')), so which agent runs is decided per build and cannot be read from the file.") | Out-Null
    }
    elseif ($labels.Count -eq 1) {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'agentLabel' -Name "$name/agent" -Action 'validate' -Status 'ok' `
            -Reason "The Jenkinsfile asks for agent label '$($labels[0])'.") | Out-Null
    }
    elseif ($labels.Count -eq 0) {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'agentLabel' -Name "$name/agent" -Action 'validate' -Status 'warning' `
            -Reason 'No agent label was found in the Jenkinsfile. Either the pipeline uses agent any, or the label is built from a variable and cannot be read lexically.') | Out-Null
    }
    else {
        Add-PlanOperation -Plan $plan -Operation (New-PlanOperation -Resource 'agentLabel' -Name "$name/agent" -Action 'validate' -Status 'warning' `
            -Reason "$($labels.Count) agent labels were found ($($labels -join ', ')). This is read lexically, so a label inside a comment also matches - confirm in the file which one governs.") | Out-Null
    }
}

Write-PlanSummary -Plan $plan

# --- Evidence -------------------------------------------------------------

$reportPathResolved = if ($ReportPath) {
    Resolve-JenkinsAsCodePath -Path $ReportPath -RootPath $repositoryRoot
}
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
    Scope           = if ($PipelineKey.Count -gt 0) { 'pipelineKey=' + ($PipelineKey -join ',') } else { 'all' }
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
    workingCopyRoot   = $workingCopyRoot

    # Fingerprints travel with every verdict, so a report can be re-checked rather
    # than believed.
    pipelines         = @($observation | ForEach-Object {
        [ordered]@{
            key              = $_.key
            jobPath          = $_.jobPath
            workingCopyPath  = $_.workingCopyPath
            definitionKind   = $_.definitionKind
            scmUrl           = $_.scmUrl
            branchSpecifier  = $_.branchSpecifier
            branch           = $_.branch
            scriptPath       = $_.scriptPath
            remoteCommit     = $_.remoteCommit
            localCommit      = $_.localCommit
            verdict          = if ($_.comparison) { $_.comparison.Verdict } else { '' }
            remoteFingerprint = if ($_.comparison) { $_.comparison.LeftFingerprint } else { '' }
            localFingerprint = if ($_.comparison) { $_.comparison.RightFingerprint } else { '' }
            agentLabels      = @($_.agentLabels)
            failure          = $_.failure
        }
    })
}

$written = Write-JenkinsAsCodeReport -Plan $plan -Path $reportPathResolved -Module $moduleName -Detail ([pscustomobject]$detail)
Write-ModuleLog "Report: $($written.JsonPath)"
Write-ModuleLog "Summary: $($written.MarkdownPath)"

# The Jenkinsfile content itself is never written to the report. These files hold
# credentials in clear text more often than not, and a report is the one artefact that
# gets attached to a ticket. Fingerprints and line counts answer the question
# without carrying the secret.

# --- smoke ----------------------------------------------------------------

if ($Command -eq 'smoke') {
    Write-ModuleLog 'Manual verification checklist:'
    Write-ModuleLog '  1. For one pipeline, open the job in Jenkins and confirm the Branch Specifier in the report matches the UI character for character.'
    Write-ModuleLog '  2. Confirm the remote commit in the report matches git ls-remote run by hand in the working copy.'
    Write-ModuleLog '  3. Make a whitespace-only edit to a local Jenkinsfile and re-run. The verdict must stay ok, reported as cosmetic.'
    Write-ModuleLog '  4. Make a real edit and re-run. The verdict must become pending. If it does not, the comparison is not doing anything.'
    Write-ModuleLog '  5. Check the report contains no line of Jenkinsfile content. It should carry fingerprints only.'
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
