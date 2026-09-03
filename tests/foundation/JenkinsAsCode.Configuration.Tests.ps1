<#
    Tests for configuration loading and for the schema engine this session will use.

    This module had no tests, and two of the things in it are load-bearing in ways
    that only a test can hold. The .env loader is a security control: without its
    protected-name list, a configuration file could set PSModulePath and turn itself
    into a code execution path. And the schema engine is the difference between real
    JSON Schema validation and a reduced validator that ignores half a dozen
    keywords - on Windows PowerShell 5.1, the declared support floor, the reduced one
    is all there is.

    Everything here is offline: no controller, no network, no credential.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
    . (Join-Path (Get-RepositoryRoot) 'foundation/Import-Foundation.ps1')

    # It does create a file, so the analyser is right about the verb - but a
    # confirmation prompt inside a test suite would stop the run waiting for an
    # answer nobody is there to give.
    function New-TemporaryEnvFile {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string[]] $Line)
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ("jenkinsascode-env-" + [guid]::NewGuid().ToString('N') + '.env')
        Set-Content -LiteralPath $path -Value $Line -Encoding ASCII
        return $path
    }
}

Describe 'Get-JenkinsAsCodeSchemaEngine' {

    It 'names one of the two engines and nothing else' {
        # A third value would mean a caller reporting an engine that does not exist.
        Get-JenkinsAsCodeSchemaEngine | Should -BeIn @('Test-Json', 'reduced')
    }

    It 'agrees with what this host can actually do' {
        # Detected by capability rather than by version, so a host that gains the
        # parameter later is not misclassified by a version comparison.
        $canSchema = (Get-Command Test-Json -ErrorAction SilentlyContinue) -and
                     (Get-Command Test-Json).Parameters.ContainsKey('Schema')
        $expected = if ($canSchema) { 'Test-Json' } else { 'reduced' }
        Get-JenkinsAsCodeSchemaEngine | Should -Be $expected
    }
}

Describe 'Import-JenkinsAsCodeEnvironment' {

    It 'loads a key and value into the process environment' {
        $name = 'JENKINSASCODE_TEST_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $file = New-TemporaryEnvFile -Line @("$name=example-value")
        try {
            Import-JenkinsAsCodeEnvironment -Path $file
            [Environment]::GetEnvironmentVariable($name, 'Process') | Should -Be 'example-value'
        }
        finally {
            Remove-Item -LiteralPath $file -Force
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
    }

    It 'ignores comments and blank lines rather than treating them as names' {
        $name = 'JENKINSASCODE_TEST_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $file = New-TemporaryEnvFile -Line @('# a comment', '', "$name=kept")
        try {
            Import-JenkinsAsCodeEnvironment -Path $file
            [Environment]::GetEnvironmentVariable($name, 'Process') | Should -Be 'kept'
        }
        finally {
            Remove-Item -LiteralPath $file -Force
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
    }

    It 'refuses to let a .env file set PSModulePath' {
        # The security control. PSModulePath decides where Import-Module finds code,
        # so a configuration file able to set it is a configuration file able to run
        # code. The refusal has to be loud: silently skipping the line would leave
        # the operator believing the file was applied.
        $before = $env:PSModulePath
        $file = New-TemporaryEnvFile -Line @('PSModulePath=C:\somewhere-else')
        try {
            { Import-JenkinsAsCodeEnvironment -Path $file } | Should -Throw
            $env:PSModulePath | Should -Be $before
        }
        finally { Remove-Item -LiteralPath $file -Force }
    }

    It 'refuses the other names that decide what gets executed' {
        foreach ($protected in @('Path', 'ComSpec', 'DOTNET_STARTUP_HOOKS', 'LD_PRELOAD')) {
            $file = New-TemporaryEnvFile -Line @("$protected=anything")
            try { { Import-JenkinsAsCodeEnvironment -Path $file } | Should -Throw }
            finally { Remove-Item -LiteralPath $file -Force }
        }
    }

    It 'names the file that is missing instead of failing obscurely' {
        $absent = Join-Path ([System.IO.Path]::GetTempPath()) ('absent-' + [guid]::NewGuid().ToString('N') + '.env')
        { Import-JenkinsAsCodeEnvironment -Path $absent } | Should -Throw -ExpectedMessage '*not found*'
    }
}

Describe 'Get-JenkinsAsCodeRequiredValue' {

    It 'names the variable to set rather than reporting an empty value' {
        # The message is the whole value of this function: an operator reading it
        # should know which line of .env to fill in.
        $name = 'JENKINSASCODE_ABSENT_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        { Get-JenkinsAsCodeRequiredValue -Name $name } | Should -Throw -ExpectedMessage "*$name*"
    }

    It 'returns the value when it is set' {
        $name = 'JENKINSASCODE_TEST_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        [Environment]::SetEnvironmentVariable($name, 'present', 'Process')
        try { Get-JenkinsAsCodeRequiredValue -Name $name | Should -Be 'present' }
        finally { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
    }
}
Describe 'The declared schemas do not rely on what the support floor cannot check' {

    # Windows PowerShell 5.1 has no Test-Json -Schema, so on the declared support
    # floor every declaration is validated by the reduced validator in
    # JenkinsAsCode.Configuration. That validator ignores a specific set of keywords
    # rather than guessing at them - deliberately, so it never rejects a valid
    # document. The consequence is easy to miss: a rule written with one of those
    # keywords is enforced on PowerShell 7 and silently absent on 5.1.
    #
    # Nothing said so before. This is what says so, at the moment somebody adds one.
    # Only what -ForEach needs is built during discovery, because Pester expands
    # -ForEach before any BeforeAll runs. Everything else is built at run time: a
    # $script: variable set during discovery is NOT visible when the test executes,
    # which is the trap Automations.Tests.ps1 also documents.
    BeforeDiscovery {
        . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
        $script:SchemaFile = @(
            Get-ChildItem -Path (Join-Path (Get-RepositoryRoot) 'automations') -Filter '*.schema.json' -Recurse -File
            Get-ChildItem -Path (Join-Path (Get-RepositoryRoot) 'foundation/schemas') -Filter '*.schema.json' -File
        ) | ForEach-Object { @{ Name = $_.Name; FullName = $_.FullName } }
    }

    BeforeAll {
        $script:IgnoredKeyword = @(
            'pattern', 'minLength', 'maxLength',
            'minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum', 'multipleOf',
            'minItems', 'maxItems', 'uniqueItems',
            'format', 'oneOf', 'anyOf', 'allOf', 'not',
            'patternProperties', 'dependentRequired'
        )
        # Each entry is a keyword that IS used, with the code that enforces it anyway.
        # A new use has to be added here, and adding it means naming the code path -
        # which is the point of the gate.
        $script:EnforcedInCode = @{
            'pipelines.schema.json|pattern' = 'remoteName is validated in Invoke-PipelineDrift, and again by the option allowlist in Invoke-GitCommand'
        }
    }
    It 'uses no keyword the reduced validator ignores, unless the code enforces it: <Name>' -ForEach $script:SchemaFile {
        $text = Get-Content -LiteralPath $FullName -Raw
        foreach ($keyword in $script:IgnoredKeyword) {
            if ($text -notmatch ('"' + $keyword + '"\s*:')) { continue }
            $allowKey = "$Name|$keyword"
            $script:EnforcedInCode.ContainsKey($allowKey) | Should -BeTrue -Because @"
$Name declares "$keyword", which the reduced 5.1 validator ignores - so the rule holds on
PowerShell 7 and not on the declared support floor. Either enforce it in code as an
invariant, the way the other unexpressible rules are, or drop it from the schema. If you
have enforced it, add "$allowKey" to EnforcedInCode naming where.
"@
        }
    }
}