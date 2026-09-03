<#
    Jenkins.Jobs - reading folders and job definitions from a Jenkins controller.

    Two halves, deliberately separated:

    The impure half walks the controller and fetches documents. It is thin.

    The pure half turns a config.xml document into an object. It is where all the
    knowledge lives, and it takes a string rather than a URL, so every rule in it
    is testable against a fixture with no controller, no token and no network. The
    repository is shaped this way on purpose: "it can only really be tested against
    the live system" is true of the requests and false of everything worth testing.

    This module knows nothing about which jobs a client has - that is the
    declaration, and it lives in an automation.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Root element of config.xml, mapped to a short name a plan can print. The _class
# reported by /api/json says the same thing in a different vocabulary; the XML root
# is used because config.xml is fetched anyway and is the authoritative document.
$script:JobTypeByRootElement = @{
    'flow-definition'                                                      = 'pipeline'
    'project'                                                              = 'freestyle'
    'maven2-moduleset'                                                     = 'maven'
    'matrix-project'                                                       = 'matrix'
    'com.cloudbees.hudson.plugins.folder.Folder'                           = 'folder'
    'org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject' = 'multibranch'
    'jenkins.branch.OrganizationFolder'                                    = 'organization-folder'
}

# _class values from /api/json that hold children rather than being buildable.
$script:ContainerClass = @(
    'com.cloudbees.hudson.plugins.folder.Folder',
    'org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject',
    'jenkins.branch.OrganizationFolder',
    'hudson.model.ItemGroup'
)

function Get-JenkinsJobTypeName {
    <#
    .SYNOPSIS
        Maps the config.xml root element to a short job type name.

    .DESCRIPTION
        Pure function. An unrecognised root element returns 'unknown' rather than
        throwing: an inventory that refuses to report a job type it has not seen
        before is less useful than one that reports it as unknown and carries on,
        and the raw element name travels alongside so nothing is lost.

    .PARAMETER RootElementName
        Name of the document element of config.xml.

    .EXAMPLE
        Get-JenkinsJobTypeName -RootElementName 'flow-definition'

        pipeline

    .OUTPUTS
        The short type name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $RootElementName
    )

    if ($script:JobTypeByRootElement.ContainsKey($RootElementName)) {
        return $script:JobTypeByRootElement[$RootElementName]
    }
    return 'unknown'
}

function Test-JenkinsContainerClass {
    <#
    .SYNOPSIS
        Says whether an /api/json _class value holds children.

    .DESCRIPTION
        Pure function. Used to decide whether the walk descends. Matching is by
        prefix, because a plugin subclasses these types and reports the subclass.

    .PARAMETER ClassName
        The _class value.

    .EXAMPLE
        Test-JenkinsContainerClass -ClassName 'com.cloudbees.hudson.plugins.folder.Folder'

    .OUTPUTS
        $true when the item holds children.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $ClassName
    )

    if ([string]::IsNullOrWhiteSpace($ClassName)) { return $false }
    foreach ($known in $script:ContainerClass) {
        if ($ClassName -eq $known) { return $true }
    }
    return $false
}

function Get-XmlNodeText {
    <#
    .SYNOPSIS
        Reads the text of the first node matching an XPath, or a default.

    .DESCRIPTION
        Pure function, and the reason this module navigates by XPath rather than by
        dotted property access. Under Set-StrictMode a missing property is a
        terminating error, so $xml.project.scm.branches would throw on any job that
        happens not to have that element - which is most of them. SelectSingleNode
        returns $null instead, and $null is an answer.

    .PARAMETER Node
        Node to search from.

    .PARAMETER XPath
        Expression to evaluate.

    .PARAMETER Default
        Value returned when nothing matches.

    .EXAMPLE
        Get-XmlNodeText -Node $xml.DocumentElement -XPath 'disabled' -Default 'false'

    .OUTPUTS
        The trimmed inner text, or the default.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $Node,
        [Parameter(Mandatory)] [string] $XPath,
        [string] $Default = ''
    )

    if ($null -eq $Node) { return $Default }

    $found = $Node.SelectSingleNode($XPath)
    if ($null -eq $found) { return $Default }

    $text = [string] $found.InnerText
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }
    return $text.Trim()
}

function Get-JenkinsJobParameter {
    <#
    .SYNOPSIS
        Extracts the declared build parameters from a parsed config.xml.

    .DESCRIPTION
        Pure function.

        A password parameter is reported by name and type, and its default is
        replaced with a marker rather than read. The stored value is reversibly
        encrypted, not hashed, so copying it into an inventory that gets written to
        disk and pasted into a ticket turns a job export into a credential leak.
        That is the one field in a job definition this repository refuses to carry.

    .PARAMETER DocumentElement
        Document element of config.xml.

    .EXAMPLE
        Get-JenkinsJobParameter -DocumentElement $xml.DocumentElement

    .OUTPUTS
        One object per parameter, with name, type and default.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $DocumentElement
    )

    if ($null -eq $DocumentElement) { return @() }

    $definitions = $DocumentElement.SelectNodes('properties/hudson.model.ParametersDefinitionProperty/parameterDefinitions/*')
    if ($null -eq $definitions) { return @() }

    $result = New-Object System.Collections.ArrayList
    foreach ($definition in $definitions) {
        $typeName = [string] $definition.LocalName
        $shortType = ($typeName -split '\.')[-1] -replace 'ParameterDefinition$', ''
        if (-not $shortType) { $shortType = $typeName }

        $isSecret = $typeName -match 'Password|Credentials'

        if ($isSecret) {
            $defaultValue = '[not read: stored reversibly encrypted]'
        }
        elseif ($shortType -eq 'Choice') {
            # A choice parameter has no defaultValue element; the first choice is the
            # default. The choices live under a collection whose element name varies
            # by plugin version, so every leaf under <choices> is taken.
            $choices = @($definition.SelectNodes('choices//string') | ForEach-Object { $_.InnerText })
            $defaultValue = if ($choices.Count -gt 0) { $choices[0] } else { '' }
        }
        else {
            $defaultValue = Get-XmlNodeText -Node $definition -XPath 'defaultValue'
        }

        $null = $result.Add([pscustomobject]@{
            name         = Get-XmlNodeText -Node $definition -XPath 'name'
            type         = $shortType
            defaultValue = $defaultValue
            isSecret     = [bool] $isSecret
        })
    }

    return @($result.ToArray())
}

function Get-JenkinsJobTrigger {
    <#
    .SYNOPSIS
        Extracts the declared triggers from a parsed config.xml.

    .DESCRIPTION
        Pure function.

        Worth reporting even when empty, and especially when empty. A job everyone
        believes runs on a schedule, whose config.xml declares no TimerTrigger, is
        a finding - it means something else queues it, and that something else is
        not in the inventory yet.

    .PARAMETER DocumentElement
        Document element of config.xml.

    .EXAMPLE
        Get-JenkinsJobTrigger -DocumentElement $xml.DocumentElement

    .OUTPUTS
        One object per trigger, with type and spec.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $DocumentElement
    )

    if ($null -eq $DocumentElement) { return @() }

    # A Pipeline job keeps triggers under a job property; a Freestyle job keeps them
    # in a top-level <triggers>. Both are read, so one function covers both types.
    $xpath = 'properties/org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty/triggers/* | triggers/*'
    $nodes = $DocumentElement.SelectNodes($xpath)
    if ($null -eq $nodes) { return @() }

    $result = New-Object System.Collections.ArrayList
    foreach ($node in $nodes) {
        $typeName = [string] $node.LocalName
        $null = $result.Add([pscustomobject]@{
            type = ($typeName -split '\.')[-1]
            spec = Get-XmlNodeText -Node $node -XPath 'spec'
        })
    }

    return @($result.ToArray())
}

function Get-JenkinsJobScm {
    <#
    .SYNOPSIS
        Extracts the SCM binding from a parsed config.xml.

    .DESCRIPTION
        Pure function, and the reason config.xml is fetched at all. None of what it
        returns is available from /api/json.

        The branch specifier is the field that matters most. A Pipeline job reading
        a single branch stores it as written in the UI - '*/main', 'main' or
        'refs/heads/main' are all valid and all mean the same branch. Resolving
        that spelling to a branch name is Scm.Git's job, not this one: this function
        reports what is configured, verbatim.

    .PARAMETER DocumentElement
        Document element of config.xml.

    .EXAMPLE
        Get-JenkinsJobScm -DocumentElement $xml.DocumentElement

    .OUTPUTS
        An object describing the binding. Its 'kind' is 'scm', 'inline' or 'none'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [object] $DocumentElement
    )

    $empty = [pscustomobject]@{
        kind            = 'none'
        url             = ''
        credentialsId   = ''
        branchSpecifier = ''
        scriptPath      = ''
        lightweight     = $false
    }
    if ($null -eq $DocumentElement) { return $empty }

    # A Pipeline job whose script is typed into the UI. Reported as 'inline' and
    # never with its content: an inline script cannot be compared against a commit,
    # which is itself the finding worth reporting.
    $inline = $DocumentElement.SelectSingleNode('definition[contains(@class, "CpsFlowDefinition")]')
    if ($null -ne $inline) {
        $empty.kind = 'inline'
        return $empty
    }

    # 'definition/scm' is a Pipeline from SCM; bare 'scm' is a Freestyle job.
    $scm = $DocumentElement.SelectSingleNode('definition/scm | scm')
    if ($null -eq $scm) { return $empty }

    $scmClass = [string] $scm.GetAttribute('class')
    if ($scmClass -eq 'hudson.scm.NullSCM') { return $empty }

    return [pscustomobject]@{
        kind            = 'scm'
        url             = Get-XmlNodeText -Node $scm -XPath 'userRemoteConfigs/*/url'
        credentialsId   = Get-XmlNodeText -Node $scm -XPath 'userRemoteConfigs/*/credentialsId'
        branchSpecifier = Get-XmlNodeText -Node $scm -XPath 'branches/*/name'
        scriptPath      = Get-XmlNodeText -Node $DocumentElement -XPath 'definition/scriptPath'
        lightweight     = (Get-XmlNodeText -Node $DocumentElement -XPath 'definition/lightweight' -Default 'false') -eq 'true'
    }
}

function ConvertTo-Xml10Text {
    <#
    .SYNOPSIS
        Makes a Jenkins config.xml document loadable by the .NET XML parser.

    .DESCRIPTION
        Pure function. It exists because of a mismatch that stops the whole
        repository dead on the first real document:

        Jenkins writes its configuration with an XML 1.1 declaration -
        <?xml version='1.1' encoding='UTF-8'?> - and has done since 2.190. It does
        so because XML 1.1 allows control characters that 1.0 forbids, which a job
        description pasted from somewhere else can contain. The .NET XmlDocument
        supports XML 1.0 only, and answers with

            Version number '1.1' is invalid. Line 1, position 16.

        which reads like a corrupt document rather than like a version mismatch.

        The fix is to drop the declaration - the text is already decoded, so the
        declared encoding no longer carries information - and to replace the
        characters XML 1.0 forbids. Both are reported rather than done quietly: a
        parser that silently edits its input is how a diff comes out clean against a
        document that was actually different.

    .PARAMETER Xml
        The document, as text.

    .EXAMPLE
        ConvertTo-Xml10Text -Xml $configXml

    .OUTPUTS
        An object with Text, DeclarationRemoved and ReplacedCharacterCount.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Xml
    )

    $text = $Xml
    $declarationRemoved = $false

    # Only a declaration at the very start is one; the same characters later in the
    # document are content.
    $match = [regex]::Match($text, '^\s*<\?xml\s[^>]*\?>')
    if ($match.Success) {
        $text = $text.Substring($match.Length)
        $declarationRemoved = $true
    }

    # XML 1.0 permits tab, line feed and carriage return, and nothing else below
    # 0x20. It also forbids 0x7F-0x84 and 0x86-0x9F, which XML 1.1 allows escaped.
    $illegal = "[^\u0009\u000A\u000D\u0020-\uD7FF\uE000-\uFFFD]"
    $replaced = [regex]::Matches($text, $illegal).Count
    if ($replaced -gt 0) {
        $text = [regex]::Replace($text, $illegal, '?')
    }

    return [pscustomobject]@{
        Text                   = $text.TrimStart()
        DeclarationRemoved     = $declarationRemoved
        ReplacedCharacterCount = $replaced
    }
}

function ConvertFrom-JenkinsJobConfigXml {
    <#
    .SYNOPSIS
        Turns a config.xml document into a job definition object.

    .DESCRIPTION
        Pure function, and the heart of this module. It takes a string, so every
        rule in it is testable against a fixture with no controller.

        One field deserves a warning, because assuming otherwise produces a
        confident wrong answer: assignedNode is the agent label as stored in
        config.xml, and a declarative Pipeline job does not store one. Its
        agent/label directive lives in the Jenkinsfile, in the SCM, not in the job.
        So assignedNode is empty for almost every Pipeline job, and that is correct
        rather than missing data - the label is reported by pipeline-drift, which
        reads the Jenkinsfile. A plan that treated an empty assignedNode on a
        Pipeline job as drift would flag every job on the controller.

    .PARAMETER Xml
        The config.xml document, as text.

    .EXAMPLE
        ConvertFrom-JenkinsJobConfigXml -Xml (Get-Content ./fixture.xml -Raw)

    .OUTPUTS
        The job definition object.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Xml
    )

    if ([string]::IsNullOrWhiteSpace($Xml)) {
        throw 'The config.xml document is empty. A controller answering 200 with an empty body is usually a login page from a reverse proxy in front of Jenkins.'
    }

    # Jenkins writes an XML 1.1 declaration and .NET parses XML 1.0 only. See
    # ConvertTo-Xml10Text for what this does and why it is reported, not hidden.
    $prepared = ConvertTo-Xml10Text -Xml $Xml

    $document = New-Object System.Xml.XmlDocument
    # A job description is arbitrary operator text and may legitimately contain an
    # entity; resolving an external one is never wanted here and is an XXE vector.
    $document.XmlResolver = $null
    try {
        # Loaded through a reader that refuses a DTD outright. XmlResolver = $null
        # above already blocks an EXTERNAL entity, but an internal one still expands,
        # and expansion is multiplicative: a handful of nested entity definitions in
        # a config.xml exhaust the memory of this process. Anybody able to configure
        # a job on the inspected controller can write that document, and reading a
        # controller this tool does not own is the whole point of it.
        $readerSettings = New-Object System.Xml.XmlReaderSettings
        $readerSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $readerSettings.XmlResolver = $null
        $stringReader = New-Object System.IO.StringReader($prepared.Text)
        try {
            $xmlReader = [System.Xml.XmlReader]::Create($stringReader, $readerSettings)
            try { $document.Load($xmlReader) } finally { $xmlReader.Dispose() }
        }
        finally { $stringReader.Dispose() }
    }
    catch {
        throw "The config.xml document could not be parsed as XML: $($_.Exception.Message)"
    }

    $root = $document.DocumentElement
    if ($null -eq $root) {
        throw 'The config.xml document has no root element.'
    }

    $rootName = [string] $root.LocalName
    $concurrentXPath = 'properties/org.jenkinsci.plugins.workflow.job.properties.DisableConcurrentBuildsJobProperty'

    return [pscustomobject]@{
        type                     = Get-JenkinsJobTypeName -RootElementName $rootName
        rootElement              = $rootName
        disabled                 = (Get-XmlNodeText -Node $root -XPath 'disabled' -Default 'false') -eq 'true'
        description              = Get-XmlNodeText -Node $root -XPath 'description'
        assignedNode             = Get-XmlNodeText -Node $root -XPath 'assignedNode'
        concurrentBuildsDisabled = $null -ne $root.SelectSingleNode($concurrentXPath)
        scm                      = Get-JenkinsJobScm -DocumentElement $root
        parameters               = @(Get-JenkinsJobParameter -DocumentElement $root)
        triggers                 = @(Get-JenkinsJobTrigger -DocumentElement $root)

        # Carried so a report can state that the document was adjusted before
        # parsing. A non-zero replacedCharacterCount means the live config.xml
        # holds characters XML 1.0 forbids, which is worth someone knowing.
        xmlDeclarationRemoved    = $prepared.DeclarationRemoved
        replacedCharacterCount   = $prepared.ReplacedCharacterCount
    }
}

function Get-JenkinsFolderChild {
    <#
    .SYNOPSIS
        Lists the immediate children of a folder, or of the controller root.

    .DESCRIPTION
        One request per level, with an explicit tree expression. Not one recursive
        request with a nested tree: the nesting depth would have to be guessed, and a
        guess that is too shallow omits jobs while appearing to succeed.

    .PARAMETER Context
        Context from Get-JenkinsContext.

    .PARAMETER Path
        Display path of the folder, or an empty string for the controller root.

    .EXAMPLE
        Get-JenkinsFolderChild -Context $context -Path 'EXAMPLE-FOLDER'

    .OUTPUTS
        One object per child, with name, path, className and isContainer.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Path
    )

    $segment = New-JenkinsJobPath -Path $Path
    $response = Get-JenkinsJson -Context $Context -Path $segment -Tree 'jobs[name,_class]' -AllowNotFound
    if ($null -eq $response) { return @() }
    if (-not $response.PSObject.Properties['jobs'] -or $null -eq $response.jobs) { return @() }

    $result = New-Object System.Collections.ArrayList
    foreach ($child in $response.jobs) {
        $name = [string] $child.name
        if (-not $name) { continue }
        $className = if ($child.PSObject.Properties['_class']) { [string] $child._class } else { '' }

        $null = $result.Add([pscustomobject]@{
            name        = $name
            path        = if ($Path) { $Path.TrimEnd('/') + '/' + $name } else { $name }
            className   = $className
            isContainer = Test-JenkinsContainerClass -ClassName $className
        })
    }

    return @($result.ToArray())
}

function Get-JenkinsJobTree {
    <#
    .SYNOPSIS
        Walks a folder recursively and returns every item found.

    .DESCRIPTION
        Breadth-first, one request per folder. -MaximumDepth exists so a walk cannot
        run away: an Organization Folder discovers repositories by itself, and a
        controller with a misconfigured one can present a tree far deeper than anyone
        expects. Reaching the limit is reported on the item, never silently dropped.

    .PARAMETER Context
        Context from Get-JenkinsContext.

    .PARAMETER Path
        Folder to start from. An empty string walks the whole controller.

    .PARAMETER MaximumDepth
        How many levels below the starting point to descend.

    .EXAMPLE
        Get-JenkinsJobTree -Context $context -Path 'EXAMPLE-FOLDER'

    .OUTPUTS
        One object per item: name, path, className, isContainer, depth, truncated.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Path,
        [int] $MaximumDepth = 8
    )

    $found = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue([pscustomobject]@{ Path = $Path; Depth = 0 })

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()

        foreach ($child in (Get-JenkinsFolderChild -Context $Context -Path $current.Path)) {
            $atLimit = $child.isContainer -and (($current.Depth + 1) -ge $MaximumDepth)

            $null = $found.Add([pscustomobject]@{
                name        = $child.name
                path        = $child.path
                className   = $child.className
                isContainer = $child.isContainer
                depth       = $current.Depth + 1
                truncated   = [bool] $atLimit
            })

            if ($child.isContainer -and -not $atLimit) {
                $queue.Enqueue([pscustomobject]@{ Path = $child.path; Depth = $current.Depth + 1 })
            }
        }
    }

    return @($found.ToArray())
}

function Get-JenkinsJobDefinition {
    <#
    .SYNOPSIS
        Reads the config.xml of one job and returns it parsed.

    .DESCRIPTION
        The thin impure wrapper over ConvertFrom-JenkinsJobConfigXml. It adds the
        job path to the result and nothing else; every decision is in the pure
        function.

    .PARAMETER Context
        Context from Get-JenkinsContext.

    .PARAMETER JobPath
        Display path of the job.

    .PARAMETER AllowNotFound
        Return $null instead of throwing when the job does not exist.

    .EXAMPLE
        Get-JenkinsJobDefinition -Context $context -JobPath 'EXAMPLE-FOLDER/example-pipeline'

    .OUTPUTS
        The job definition with a path property added, or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [string] $JobPath,
        [switch] $AllowNotFound
    )

    $xml = Get-JenkinsConfigXml -Context $Context -JobPath $JobPath -AllowNotFound:$AllowNotFound
    if ($null -eq $xml) { return $null }

    $definition = ConvertFrom-JenkinsJobConfigXml -Xml $xml
    Add-Member -InputObject $definition -MemberType NoteProperty -Name 'path' -Value $JobPath
    return $definition
}

Export-ModuleMember -Function @(
    'Get-JenkinsJobTypeName',
    'ConvertTo-Xml10Text',
    'Test-JenkinsContainerClass',
    'Get-XmlNodeText',
    'Get-JenkinsJobParameter',
    'Get-JenkinsJobTrigger',
    'Get-JenkinsJobScm',
    'ConvertFrom-JenkinsJobConfigXml',
    'Get-JenkinsFolderChild',
    'Get-JenkinsJobTree',
    'Get-JenkinsJobDefinition'
)
