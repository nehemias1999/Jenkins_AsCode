<#
    Tests for the config.xml parser.

    Every test is named after the failure it prevents, not the function it calls.
    All of them run offline against invented fixtures: the parser takes a string, so
    no controller, token or network is involved.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
    . (Join-Path (Get-RepositoryRoot) 'foundation/Import-Foundation.ps1')
}

Describe 'ConvertTo-Xml10Text' {

    It 'strips the XML 1.1 declaration Jenkins writes, which .NET cannot parse' {
        # Jenkins has written version='1.1' since 2.190. XmlDocument supports 1.0
        # only and answers "Version number '1.1' is invalid", which reads like a
        # corrupt document rather than a version mismatch, so every job on every
        # controller would fail to parse.
        $result = ConvertTo-Xml10Text -Xml "<?xml version='1.1' encoding='UTF-8'?><project/>"
        $result.DeclarationRemoved | Should -BeTrue
        $result.Text | Should -Be '<project/>'
    }

    It 'leaves a document with no declaration alone' {
        $result = ConvertTo-Xml10Text -Xml '<project/>'
        $result.DeclarationRemoved | Should -BeFalse
        $result.Text | Should -Be '<project/>'
    }

    It 'does not treat a processing instruction in the body as the declaration' {
        # Only a declaration at the very start is one. Stripping a later match would
        # silently delete content.
        $result = ConvertTo-Xml10Text -Xml '<project><description><?xml stray ?></description></project>'
        $result.DeclarationRemoved | Should -BeFalse
    }

    It 'reports how many forbidden characters it replaced, rather than doing it quietly' {
        # XML 1.1 permits escaped control characters that 1.0 forbids. Replacing them
        # is necessary to parse at all; doing it without saying so would let a diff
        # come out clean against a document that was actually different.
        $result = ConvertTo-Xml10Text -Xml ('<project><description>a' + [char] 0x01 + 'b</description></project>')
        $result.ReplacedCharacterCount | Should -Be 1
    }
}

Describe 'ConvertFrom-JenkinsJobConfigXml' {

    It 'reads the branch specifier, which /api/json never returns' {
        # The whole repository exists because this field is only in config.xml. If
        # this breaks, an inventory looks complete and cannot say which commit runs.
        $definition = ConvertFrom-JenkinsJobConfigXml -Xml (Get-FixtureXml -Name 'pipeline-from-scm.config.xml')
        $definition.scm.branchSpecifier | Should -Be '*/main'
        $definition.scm.scriptPath | Should -Be 'Jenkinsfile'
        $definition.scm.url | Should -Be 'https://github.example.com/example-org/example-pipeline.git'
    }

    It 'never reads a password parameter default' {
        # Stored reversibly encrypted, not hashed. Copying it into a report that gets
        # written to disk and pasted into a ticket turns a job export into a
        # credential leak.
        $definition = ConvertFrom-JenkinsJobConfigXml -Xml (Get-FixtureXml -Name 'pipeline-from-scm.config.xml')
        $secret = @($definition.parameters | Where-Object { $_.name -eq 'ExampleSecret' })
        $secret.Count | Should -Be 1
        $secret[0].isSecret | Should -BeTrue
        $secret[0].defaultValue | Should -Not -Match 'AQAAAB'
        # Replaced, not merely absent. An empty default would also satisfy the line
        # above while leaving a reader unable to tell "there was no default" from
        # "there was one and we refused to read it".
        $secret[0].defaultValue | Should -Match 'not read'
    }

    It 'takes the first choice as the default of a choice parameter' {
        # A choice parameter has no defaultValue element at all, so reading one
        # yields empty and a report claims the job has no default when it has one.
        $definition = ConvertFrom-JenkinsJobConfigXml -Xml (Get-FixtureXml -Name 'pipeline-from-scm.config.xml')
        $choice = @($definition.parameters | Where-Object { $_.name -eq 'ExampleChoice' })
        $choice[0].defaultValue | Should -Be 'Objects'
    }

    It 'finds triggers kept under a job property, where a Pipeline stores them' {
        # A Freestyle job uses a top-level triggers element; a Pipeline uses a job
        # property. Reading only the first reports every Pipeline as untriggered.
        $definition = ConvertFrom-JenkinsJobConfigXml -Xml (Get-FixtureXml -Name 'pipeline-from-scm.config.xml')
        @($definition.triggers).Count | Should -Be 1
        $definition.triggers[0].type | Should -Be 'TimerTrigger'
        $definition.triggers[0].spec | Should -Be 'H/10 * * * *'
    }

    It 'finds triggers in the top-level element, where a Freestyle job stores them' {
        $definition = ConvertFrom-JenkinsJobConfigXml -Xml (Get-FixtureXml -Name 'freestyle.config.xml')
        @($definition.triggers).Count | Should -Be 1
        $definition.triggers[0].type | Should -Be 'SCMTrigger'
    }
}

Describe 'ConvertFrom-JenkinsJobConfigXml, on the shapes that are easy to misread' {

    It 'reports an inline script as inline and carries none of its content' {
        # An inline script has no commit behind it, so drift cannot be asked about
        # it. Reporting the kind is the finding; carrying the script would put
        # whatever it contains into a report.
        $definition = ConvertFrom-JenkinsJobConfigXml -Xml (Get-FixtureXml -Name 'pipeline-inline.config.xml')
        $definition.scm.kind | Should -Be 'inline'
        $definition.scm.url | Should -BeNullOrEmpty
    }

    It 'reports NullSCM as no SCM rather than as an SCM with an empty URL' {
        # An empty URL would be compared against the declaration and reported as
        # drift on a job that correctly has no repository.
        $definition = ConvertFrom-JenkinsJobConfigXml -Xml (Get-FixtureXml -Name 'no-scm.config.xml')
        $definition.scm.kind | Should -Be 'none'
    }

    It 'reads the agent label of a Freestyle job, and reports none for a Pipeline' {
        # A declarative Pipeline keeps its label in the Jenkinsfile, not in
        # config.xml. Treating the empty value as drift would flag every Pipeline
        # job on the controller.
        (ConvertFrom-JenkinsJobConfigXml -Xml (Get-FixtureXml -Name 'freestyle.config.xml')).assignedNode | Should -Be 'EXAMPLE-AGENT-1'
        (ConvertFrom-JenkinsJobConfigXml -Xml (Get-FixtureXml -Name 'pipeline-from-scm.config.xml')).assignedNode | Should -BeNullOrEmpty
    }

    It 'reads the disabled flag' {
        (ConvertFrom-JenkinsJobConfigXml -Xml (Get-FixtureXml -Name 'pipeline-inline.config.xml')).disabled | Should -BeTrue
        (ConvertFrom-JenkinsJobConfigXml -Xml (Get-FixtureXml -Name 'pipeline-from-scm.config.xml')).disabled | Should -BeFalse
    }

    It 'identifies a folder, so a walk does not try to read it as a job' {
        (ConvertFrom-JenkinsJobConfigXml -Xml (Get-FixtureXml -Name 'folder.config.xml')).type | Should -Be 'folder'
    }

    It 'reports an unknown root element as unknown instead of throwing' {
        # A controller with a plugin nobody here has seen must still produce an
        # inventory. The raw element name travels alongside, so nothing is lost.
        $definition = ConvertFrom-JenkinsJobConfigXml -Xml '<some.unknown.Plugin><disabled>false</disabled></some.unknown.Plugin>'
        $definition.type | Should -Be 'unknown'
        $definition.rootElement | Should -Be 'some.unknown.Plugin'
    }

    It 'rejects an empty document rather than returning an empty job' {
        { ConvertFrom-JenkinsJobConfigXml -Xml '' } | Should -Throw
    }
}

Describe 'Test-JenkinsContainerClass' {

    It 'treats a folder as a container so the walk descends into it' {
        Test-JenkinsContainerClass -ClassName 'com.cloudbees.hudson.plugins.folder.Folder' | Should -BeTrue
    }

    It 'does not treat a Pipeline job as a container' {
        Test-JenkinsContainerClass -ClassName 'org.jenkinsci.plugins.workflow.job.WorkflowJob' | Should -BeFalse
    }

    It 'treats an empty class as not a container rather than failing' {
        Test-JenkinsContainerClass -ClassName '' | Should -BeFalse
    }
}

Describe 'ConvertFrom-JenkinsJobConfigXml, on a hostile document' {

    It 'refuses a document carrying a DTD instead of expanding it' {
        # Billion laughs. XmlResolver = $null blocks an EXTERNAL entity, but an
        # internal one still expands, and expansion is multiplicative: this shape with
        # a few more levels exhausts the memory of the process. Anybody who can
        # configure a job on the inspected controller can write this document, and
        # reading a controller you do not own is what this tool is for.
        $hostile = @'
<!DOCTYPE project [
  <!ENTITY a "aaaaaaaaaa">
  <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">
  <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">
]>
<project><description>&c;</description></project>
'@
        { ConvertFrom-JenkinsJobConfigXml -Xml $hostile } | Should -Throw
    }

    It 'still reads an ordinary document with no DTD' {
        # The guard above must not have made every document unreadable, which is the
        # way a fix like this usually goes wrong.
        $definition = ConvertFrom-JenkinsJobConfigXml -Xml (Get-FixtureXml -Name 'pipeline-from-scm.config.xml')
        $definition.scm.branchSpecifier | Should -Be '*/main'
    }
}
