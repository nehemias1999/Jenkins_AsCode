<#
    JenkinsAsCode.Report - evidence writing.

    Three artefacts, each answering a different question.

    * A plan report answers "what was about to happen", and is the thing a
      reviewer approves. It is written before any change.
    * A receipt answers "what actually happened", and is written incrementally -
      after every completed operation, not once at the end. That distinction is
      the whole point: an apply that dies halfway through still leaves a record of
      exactly which operations completed, which is the only way to resume without
      guessing.
    * A Markdown summary answers "can a person read this without a JSON viewer",
      and is what gets attached to a change ticket.

    Everything written here passes through Remove-SensitiveValue first. A report
    is the artefact most likely to be pasted into a chat window, so redaction
    belongs at the writer, not at each call site.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Property names whose values are replaced before a report is written. Matching is
# on the name, not the value, so a credential is redacted even when it does not
# look like one.
#
# The pattern is built in two halves, because a single unanchored alternation is
# wrong in both directions at once.
#
# Long, unambiguous tokens match anywhere in the name. Case-insensitivity is what
# makes these cover camelCase too: 'sshkey' matches 'sshKey'.
$script:SensitiveNameFragment = @(
    'password', 'passwd', 'pwd', 'passphrase'
    'secret', 'credential', 'token', 'authorization'
    'apikey', 'api_key', 'accesskey', 'privatekey', 'private_key', 'sshkey', 'signingkey', 'keymaterial'
    'connectionstring', 'connstr', 'signature'
) -join '|'

# Short tokens that are also common substrings of innocent words. These match only
# as a whole word or a whole underscore/dash-delimited segment.
#
# 'pat' is the reason this split exists. Unanchored, it matched 'areaPaths',
# 'iterationPaths', 'reportPath', 'patch' and 'compatible' - so every
# team-provisioning inventory report silently replaced its Area Path and Iteration
# Path inventory, the very data the report exists to carry, with the redaction
# marker. Redaction that destroys evidence is not failing safe; it is failing
# quietly, which is worse.
$script:SensitiveNameSegment = @(
    'pat', 'key', 'sas', 'cert', 'auth', 'bearer'
) -join '|'

$script:SensitivePropertyPattern = "(?i)($($script:SensitiveNameFragment)|(?:^|[_-])(?:$($script:SensitiveNameSegment))(?:[_-]|$))"

function Remove-SensitiveValue {
    <#
    .SYNOPSIS
        Returns a copy of an object with sensitive property values replaced.

    .DESCRIPTION
        Walks objects, dictionaries and arrays. A property whose NAME looks like a
        credential is replaced with a fixed marker; everything else is copied. Name
        matching rather than value matching is deliberate: a weak password does not
        look like a secret, but its property name always does.

        Depth is capped so a cyclic or pathologically nested structure cannot hang
        the writer.

    .PARAMETER InputObject
        Object to sanitize.

    .PARAMETER Replacement
        Marker written in place of a sensitive value.

    .PARAMETER Depth
        Remaining recursion depth.

    .EXAMPLE
        Remove-SensitiveValue -InputObject $operation

    .OUTPUTS
        A sanitized copy. The input is not modified.
    #>
    # Pure function: it computes a value and changes no system state. ShouldProcess
    # would offer a confirmation prompt for something there is nothing to confirm
    # about, and would train people to answer yes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $InputObject,
        [string] $Replacement = '[redacted]',
        [ValidateRange(0, 32)] [int] $Depth = 12
    )

    if ($null -eq $InputObject) { return $null }
    if ($Depth -le 0) { return '[depth limit reached]' }

    if ($InputObject -is [string] -or $InputObject -is [bool] -or $InputObject -is [int] -or
        $InputObject -is [long] -or $InputObject -is [double] -or $InputObject -is [decimal] -or
        $InputObject -is [datetime]) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            if ("$key" -match $script:SensitivePropertyPattern) {
                $copy["$key"] = $Replacement
                continue
            }
            $copy["$key"] = Remove-SensitiveValue -InputObject $InputObject[$key] -Replacement $Replacement -Depth ($Depth - 1)
        }
        return [pscustomobject]$copy
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        $items = @($InputObject | ForEach-Object {
            Remove-SensitiveValue -InputObject $_ -Replacement $Replacement -Depth ($Depth - 1)
        })
        # The leading comma is load-bearing. PowerShell enumerates a function's
        # output, so `return @($items)` hands a single-element array back to the
        # caller as the bare element - and a one-item list in an inventory then
        # serialised as a string instead of an array, silently changing the shape of
        # the evidence file. The comma wraps the array so enumeration yields it
        # whole.
        return , $items
    }

    $properties = @($InputObject.PSObject.Properties)
    if ($properties.Count -eq 0) { return $InputObject }

    $copy = [ordered]@{}
    foreach ($property in $properties) {
        if ($property.Name -match $script:SensitivePropertyPattern) {
            $copy[$property.Name] = $Replacement
            continue
        }
        $copy[$property.Name] = Remove-SensitiveValue -InputObject $property.Value -Replacement $Replacement -Depth ($Depth - 1)
    }
    return [pscustomobject]$copy
}

function Write-Utf8NoBom {
    <#
    .SYNOPSIS
        Writes text as UTF-8 with no byte order mark.

    .DESCRIPTION
        Set-Content -Encoding UTF8 writes a BOM on Windows PowerShell 5.1, and a JSON
        document that starts with a BOM is rejected by strict parsers - Python answers
        "Unexpected UTF-8 BOM", and several CI tools do the same. A report nobody can
        parse is not evidence.

        PowerShell 7 has -Encoding utf8NoBOM, but 5.1 is the support floor, so the
        write goes through .NET where both engines behave identically.

    .PARAMETER Path
        File to write.

    .PARAMETER Content
        Text to write.

    .EXAMPLE
        Write-Utf8NoBom -Path $path -Content $json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)

    # A relative path is resolved against PowerShell's current location, because .NET
    # would resolve it against the process working directory, which is not the same
    # thing. An absolute path is used as it is: joining a rooted path onto the current
    # location puts a drive letter in the middle of it, and the write then throws
    # "The given path's format is not supported". That is how the first version of
    # this silently produced no report at all.
    $fullPath = if ([System.IO.Path]::IsPathRooted($Path)) {
        $Path
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $Path))
    }

    [System.IO.File]::WriteAllText($fullPath, $Content, $encoding)
}

function Write-JenkinsAsCodeReport {
    <#
    .SYNOPSIS
        Writes a plan or result report as JSON, plus a Markdown sibling.

    .DESCRIPTION
        The JSON file is the machine-readable record; the Markdown file next to it
        is what a person reads or attaches to a ticket. Both are written from the
        same sanitized object, so they cannot disagree.

        The parent directory is created if needed. Reports belong under `artifacts/`,
        which is excluded from version control: they describe one run of one
        environment and are not part of the declared state.

    .PARAMETER Plan
        Plan object from New-Plan.

    .PARAMETER Path
        Destination path for the JSON report. The Markdown file replaces the
        extension with .md.

    .PARAMETER Module
        Name of the automation that produced the report.

    .PARAMETER Detail
        Optional extra object to embed, for example the inventory counts observed.

    .EXAMPLE
        Write-JenkinsAsCodeReport -Plan $plan -Path 'artifacts/plans/team-provisioning-APP_ALPHA.json' -Module 'team-provisioning'

    .OUTPUTS
        PSCustomObject with JsonPath and MarkdownPath.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $Plan,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Module,
        [object] $Detail
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $summary = Get-PlanSummary -Plan $Plan
    $report = [ordered]@{
        module      = $Module
        command     = $Plan.command
        target      = $Plan.target
        generatedAt = $Plan.generatedAt
        summary     = $summary
        operations  = @($Plan.operations)
    }
    if ($PSBoundParameters.ContainsKey('Detail') -and $null -ne $Detail) {
        $report.detail = $Detail
    }

    $sanitized = Remove-SensitiveValue -InputObject ([pscustomobject]$report)
    Write-Utf8NoBom -Path $Path -Content ($sanitized | ConvertTo-Json -Depth 12)

    $markdownPath = [System.IO.Path]::ChangeExtension($Path, '.md')
    Write-Utf8NoBom -Path $markdownPath -Content (Format-JenkinsAsCodeReportMarkdown -Report $sanitized)

    Write-Verbose "Wrote report '$Path' and summary '$markdownPath'."
    return [pscustomobject]@{ JsonPath = $Path; MarkdownPath = $markdownPath }
}

function Format-JenkinsAsCodeReportMarkdown {
    <#
    .SYNOPSIS
        Renders a report object as Markdown.

    .DESCRIPTION
        Pure function, so the rendering is covered by a test without touching the
        file system. Operations are grouped by status, with the ones needing
        attention first, because that is the order a reviewer reads in.

    .PARAMETER Report
        Sanitized report object.

    .EXAMPLE
        Format-JenkinsAsCodeReportMarkdown -Report $report

    .OUTPUTS
        The Markdown document as a single string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [object] $Report
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# $($Report.module): $($Report.command) - $($Report.target)")
    $lines.Add('')
    $lines.Add("Generated at $($Report.generatedAt) (UTC).")
    $lines.Add('')
    $lines.Add('## Summary')
    $lines.Add('')
    $lines.Add('| Status | Count |')
    $lines.Add('| --- | --- |')
    foreach ($property in $Report.summary.PSObject.Properties) {
        $lines.Add("| $($property.Name) | $($property.Value) |")
    }
    $lines.Add('')
    $lines.Add('## Operations')
    $lines.Add('')

    $operations = @($Report.operations)
    if ($operations.Count -eq 0) {
        $lines.Add('No operations were produced.')
    }
    else {
        foreach ($status in @('blocked', 'warning', 'pending', 'protected', 'ok')) {
            $items = @($operations | Where-Object { $_.status -eq $status })
            if ($items.Count -eq 0) { continue }

            $lines.Add("### $status ($($items.Count))")
            $lines.Add('')
            $lines.Add('| Resource | Name | Action | Reason |')
            $lines.Add('| --- | --- | --- | --- |')
            foreach ($item in $items) {
                $reason = "$($item.reason)" -replace '\|', '\|'
                $lines.Add("| $($item.resource) | $($item.name) | $($item.action) | $reason |")
            }
            $lines.Add('')
        }
    }

    return ($lines -join [Environment]::NewLine)
}

function Save-JenkinsAsCodeReceipt {
    <#
    .SYNOPSIS
        Writes or updates the receipt of an apply.

    .DESCRIPTION
        Called after every completed operation, not once at the end. The file is
        rewritten each time, which is cheap and means the record on disk is never
        behind what has actually been done.

        `status` moves from in_progress to completed or failed. A receipt left at
        in_progress is itself the signal that the run was interrupted, and its
        completedOperations list is what the operator resumes from.

    .PARAMETER Path
        Receipt path. Conventionally the report path with a .receipt.json extension.

    .PARAMETER Target
        What was being applied.

    .PARAMETER Status
        'in_progress', 'completed' or 'failed'.

    .PARAMETER CompletedOperations
        Operations finished so far.

    .PARAMETER Message
        Optional note, typically the failure reason.

    .EXAMPLE
        Save-JenkinsAsCodeReceipt -Path $receiptPath -Target 'APP_ALPHA' -Status in_progress -CompletedOperations $done
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [ValidateSet('in_progress', 'completed', 'failed')] [string] $Status,
        [AllowEmptyCollection()] [object[]] $CompletedOperations = @(),
        [string] $Message = ''
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $receipt = [pscustomobject]@{
        generatedAt         = (Get-Date).ToUniversalTime().ToString('o')
        target              = $Target
        status              = $Status
        message             = $Message
        completedOperations = @($CompletedOperations)
    }

    $sanitized = Remove-SensitiveValue -InputObject $receipt
    Write-Utf8NoBom -Path $Path -Content ($sanitized | ConvertTo-Json -Depth 12)
}

function Get-JenkinsAsCodeReceiptPath {
    <#
    .SYNOPSIS
        Derives the receipt path that belongs to a report path.

    .DESCRIPTION
        One convention in one place, so a report and its receipt always sit side by
        side and can be found without being told where to look.

    .PARAMETER ReportPath
        Path of the JSON report.

    .EXAMPLE
        Get-JenkinsAsCodeReceiptPath -ReportPath 'artifacts/plans/apply-APP_ALPHA.json'

        Returns 'artifacts/plans/apply-APP_ALPHA.receipt.json'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ReportPath
    )

    return [System.IO.Path]::ChangeExtension($ReportPath, 'receipt.json')
}

Export-ModuleMember -Function @(
    'Remove-SensitiveValue',
    'Write-JenkinsAsCodeReport',
    'Format-JenkinsAsCodeReportMarkdown',
    'Save-JenkinsAsCodeReceipt',
    'Get-JenkinsAsCodeReceiptPath'
)
