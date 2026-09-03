<#
    JenkinsAsCode.Report - evidence writing.

    Two artefacts, each answering a different question.

    * A plan report answers "what was about to happen", and is the thing a
      reviewer approves. It is written before any change.
    * A Markdown summary answers "can a person read this without a JSON viewer",
      and is what gets attached to a change ticket.

    Everything written here passes through Remove-SensitiveValue first, and that
    walk masks every string it copies with Protect-SecretInText. Two layers,
    because they see different things: one matches the NAME of a property, which
    catches a weak password whose value looks like nothing, and the other matches
    the VALUE, which catches a token embedded in a URL under a name like scmUrl
    that no pattern would ever flag.

    Both live at the writer rather than at each call site. A report is the artefact
    most likely to be pasted into a ticket or a chat window, and a call site added
    next year would otherwise reintroduce the leak without anybody noticing.
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

# Value shapes that carry a secret regardless of the property name holding them.
#
# Name-based redaction cannot see these, and that is not a hypothetical gap. A job
# whose SCM URL is https://user:TOKEN@host/org/repo.git stores that string under the
# name 'scmUrl', which looks innocent - while 'credentialsId', which is only a
# reference and no secret at all, IS redacted because its name contains
# 'credential'. The name layer was protecting the harmless field and passing the
# dangerous one.
#
# Free text is the other half of the same hole: a reason, a failure message or git's
# stderr ("Authentication failed for 'https://user:TOKEN@host'") is a string under a
# name no pattern would ever flag.
$script:SecretValuePattern = @(
    # URL userinfo. The host is kept: it is the diagnostically useful part, and a
    # reason that says which repository disagrees is the point of the message.
    @{ Pattern = '(?i)\b([a-z][a-z0-9+.\-]*://)[^/\s@"'']+@'; Replacement = '$1[redacted]@' }

    # A Basic credential, should one ever reach a message. Base64 of user:token.
    @{ Pattern = '(?i)\bBasic\s+[A-Za-z0-9+/]{8,}={0,2}'; Replacement = 'Basic [redacted]' }
)

function Protect-SecretInText {
    <#
    .SYNOPSIS
        Returns text with credential-shaped values masked.

    .DESCRIPTION
        Masks by VALUE, which is the complement of Remove-SensitiveValue masking by
        property name. Use it for any string that reaches a report, a Markdown
        summary or the console: a reason, an exception message, a URL read from a
        controller or from .git/config.

        The host of a URL is preserved deliberately. A message that says which
        repository was contacted is worth having; the userinfo in front of it never
        is.

        Pure function, so it is tested offline against strings.

    .PARAMETER Text
        Text to mask. Null or empty is returned unchanged.

    .EXAMPLE
        Protect-SecretInText -Text "failed for 'https://me:ghp_x@example.com/a.git'"

        failed for 'https://[redacted]@example.com/a.git'

    .OUTPUTS
        The masked string.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $masked = $Text
    foreach ($rule in $script:SecretValuePattern) {
        $masked = [regex]::Replace($masked, $rule.Pattern, $rule.Replacement)
    }
    return $masked
}

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

    # Every string in the evidence passes the value masker. Doing it here rather than
    # at each call site is the same reasoning that put name-based redaction at the
    # writer: a call site added later would otherwise reintroduce the leak silently.
    if ($InputObject -is [string]) {
        return (Protect-SecretInText -Text $InputObject)
    }

    if ($InputObject -is [bool] -or $InputObject -is [int] -or
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

function Format-MarkdownCell {
    <#
    .SYNOPSIS
        Returns text safe to place in one cell of a Markdown table.

    .DESCRIPTION
        A plan carries text this tool did not write: a job path, a script path and a
        reason all come from the controller being inspected or from git. Three things
        go wrong when that text is pasted into a table unescaped.

        A pipe ends the cell, so the row grows a column and the table stops lining
        up. A newline ends the row, so one value silently becomes two rows. And a
        bracket pair followed by a parenthesis is a link, so a value can inject one
        into whatever renders the summary on a ticket.

        None of that is a route to a secret - it is a route to a report that is wrong
        or that carries something nobody wrote. Pure function, so it is tested through
        the renderer without touching the file system.

    .PARAMETER Text
        Cell text. Null becomes an empty cell rather than the word null.

    .EXAMPLE
        Format-MarkdownCell -Text 'a | b'

        a \| b

    .OUTPUTS
        The escaped single-line string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [object] $Text
    )

    if ($null -eq $Text) { return '' }
    $cell = [string] $Text

    # Ordinal string replacement, not -replace. That operator takes a regex on the
    # left and a substitution string on the right, and both give a backslash its own
    # meaning - so escaping a backslash there is a pattern that reads as an escape
    # and a replacement that reads as an escape. The first version of this function
    # shipped a bare backslash as a pattern and threw on every row it rendered.
    # Replace() has no such semantics: it takes the characters it is given.
    #
    # Backslash goes first, because doing it later would escape the backslashes the
    # other steps just added.
    $cell = $cell.Replace('\', '\\')
    $cell = $cell.Replace('|', '\|')
    $cell = $cell.Replace('[', '\[').Replace(']', '\]')
    $cell = $cell.Replace('<', '&lt;').Replace('>', '&gt;')

    # A cell is one line. CRLF first, so a Windows newline does not leave a stray
    # carriage return behind for the next step to turn into a second space.
    $cell = $cell.Replace("`r`n", ' ').Replace("`n", ' ').Replace("`r", ' ')
    return $cell
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
                # All four cells escaped, not just the reason. Three of them carry text
                # the inspected controller chooses - a job path, a script path - so a
                # pipe or a newline in any of them breaks the table, and a bracket pair
                # injects a link into whatever renders this Markdown on a ticket.
                $cellResource = Format-MarkdownCell -Text $item.resource
                $cellName     = Format-MarkdownCell -Text $item.name
                $cellAction   = Format-MarkdownCell -Text $item.action
                $cellReason   = Format-MarkdownCell -Text $item.reason
                $lines.Add("| $cellResource | $cellName | $cellAction | $cellReason |")
            }
            $lines.Add('')
        }
    }

    return ($lines -join [Environment]::NewLine)
}

Export-ModuleMember -Function @(
    'Protect-SecretInText',
    'Remove-SensitiveValue',
    'Write-JenkinsAsCodeReport',
    'Format-JenkinsAsCodeReportMarkdown'
)
