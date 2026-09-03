<#
    The automation contract, enforced.

    A contract nothing checks is a wish. These tests are the mechanical half of
    docs/reference/automation-contract.md: what a module must ship, what a command
    surface must expose, and - the rule this repository rests on - that no code path
    exists which could write to Jenkins, to Jira or to a git branch.
#>

# The automation table drives -ForEach, which Pester evaluates during discovery -
# before BeforeAll has run. Declared here for that reason; a table built in BeforeAll
# is still null when the cases are expanded, and Pester reports it as an empty ForEach.
BeforeDiscovery {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')

    $script:Automation = @(
        @{ Name = 'job-inventory';   EntryPoint = 'Invoke-JobInventory.ps1';   Template = 'jobs.example.json';      Active = 'jobs.json' }
        @{ Name = 'pipeline-drift';  EntryPoint = 'Invoke-PipelineDrift.ps1';  Template = 'pipelines.example.json'; Active = 'pipelines.json' }
        @{ Name = 'jira-inventory';  EntryPoint = 'Invoke-JiraInventory.ps1';  Template = 'issues.example.json';    Active = 'issues.json' }
    )
}

BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
    $script:RepositoryRoot = Get-RepositoryRoot
    $script:ModuleSource = @(Get-ChildItem (Join-Path $script:RepositoryRoot 'foundation/modules') -Recurse -Filter '*.psm1')
    $script:EntryPointSource = @(Get-ChildItem (Join-Path $script:RepositoryRoot 'automations') -Recurse -Filter 'Invoke-*.ps1')
}

Describe 'Every automation ships what the contract requires' {

    It 'has an entry point, a versioned template, a schema and a guide: <Name>' -ForEach $script:Automation {
        $root = Join-Path (Get-RepositoryRoot) "automations/$Name"
        Test-Path -LiteralPath (Join-Path $root $EntryPoint) | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root "config/$Template") | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'README.md') | Should -BeTrue
        @(Get-ChildItem (Join-Path $root 'schemas') -Filter '*.schema.json').Count | Should -BeGreaterThan 0
    }

    It 'excludes its active configuration from version control: <Name>' -ForEach $script:Automation {
        # The active file is produced by renaming the template. Renaming rather than
        # copying is not a style preference: the active name is the one .gitignore
        # excludes, and a copy invites a file with a new name, full of real values,
        # that Git happily tracks.
        $ignored = Get-Content -LiteralPath (Join-Path (Get-RepositoryRoot) '.gitignore') -Raw
        $ignored | Should -Match ([regex]::Escape($Active))
    }

    It 'declares the schema that governs its template: <Name>' -ForEach $script:Automation {
        # Shipping a schema and never running it is common and worthless: the schema
        # documents an intention while the loader accepts anything, and the two drift
        # apart with nobody noticing.
        $template = Join-Path (Get-RepositoryRoot) "automations/$Name/config/$Template"
        $document = Get-Content -LiteralPath $template -Raw | ConvertFrom-Json
        $document.PSObject.Properties.Name | Should -Contain '$schema'
    }

    It 'is registered in the project context: <Name>' -ForEach $script:Automation {
        $context = Get-Content -LiteralPath (Join-Path (Get-RepositoryRoot) 'foundation/config/project-context.json') -Raw | ConvertFrom-Json
        $context.automations.PSObject.Properties.Name | Should -Contain $Name
    }

    It 'documents rollback in its guide: <Name>' -ForEach $script:Automation {
        # The section people skip and the one that matters at two in the morning. It
        # is allowed to say "nothing to reverse, and here is why" - it is not allowed
        # to be absent.
        $guide = Get-Content -LiteralPath (Join-Path (Get-RepositoryRoot) "automations/$Name/README.md") -Raw
        $guide | Should -Match '(?i)rollback'
    }
}

Describe 'The command surface is the ladder the contract describes' {

    It 'exposes validate, inventory, plan and smoke: <Name>' -ForEach $script:Automation {
        $source = Get-Content -LiteralPath (Join-Path (Get-RepositoryRoot) "automations/$Name/$EntryPoint") -Raw
        foreach ($verb in @('validate', 'inventory', 'plan', 'smoke')) {
            $source | Should -Match ("ValidateSet\([^)]*'" + $verb + "'")
        }
    }

    It 'exposes no verb that writes: <Name>' -ForEach $script:Automation {
        # apply, reconcile and rename are absent by construction, not by convention.
        # Raising that is an ADR, and this test is what makes the ADR the only way.
        $source = Get-Content -LiteralPath (Join-Path (Get-RepositoryRoot) "automations/$Name/$EntryPoint") -Raw
        $validateSet = [regex]::Match($source, "ValidateSet\((?<set>[^)]*)\)").Groups['set'].Value
        foreach ($verb in @('apply', 'reconcile', 'rename', 'delete', 'remove')) {
            $validateSet | Should -Not -Match ("'" + $verb + "'")
        }
    }

    It 'has no confirmation switch, because nothing here needs confirming: <Name>' -ForEach $script:Automation {
        # A -ConfirmApply parameter on a module that cannot write would be a promise
        # of a capability that does not exist, and the first thing somebody reaches
        # for when they want one.
        $source = Get-Content -LiteralPath (Join-Path (Get-RepositoryRoot) "automations/$Name/$EntryPoint") -Raw
        $source | Should -Not -Match '\$ConfirmApply'
    }
}

Describe 'No code path can write to Jenkins or Jira' {

    It 'performs network I/O in exactly one place' {
        # One function does the requesting, so there is one place to audit and one
        # place a write could ever be added.
        $callers = @($script:ModuleSource + $script:EntryPointSource | Where-Object {
            (Get-Content -LiteralPath $_.FullName -Raw) -match 'Invoke-WebRequest|Invoke-RestMethod'
        })
        @($callers | ForEach-Object { $_.Name }) | Should -Be @('JenkinsAsCode.Http.psm1')
    }

    It 'sends no HTTP method other than GET' {
        foreach ($file in ($script:ModuleSource + $script:EntryPointSource)) {
            $source = Get-Content -LiteralPath $file.FullName -Raw
            foreach ($method in @('Post', 'Put', 'Patch', 'Delete')) {
                $source | Should -Not -Match ("Method\s*=\s*'" + $method + "'") -Because "$($file.Name) must not send $method"
                $source | Should -Not -Match ("-Method\s+'?" + $method) -Because "$($file.Name) must not send $method"
            }
        }
    }

    It 'runs no git command that changes a branch or a working tree' {
        # A shallow fetch adds objects and moves FETCH_HEAD, which is safe. checkout,
        # reset, pull, merge, commit and push are not: they would alter somebody's
        # clone while they were working in it.
        foreach ($file in ($script:ModuleSource + $script:EntryPointSource)) {
            $source = Get-Content -LiteralPath $file.FullName -Raw
            foreach ($command in @('checkout', 'reset', 'pull', 'merge', 'commit', 'push', 'clean')) {
                $source | Should -Not -Match ("'" + $command + "'\s*,") -Because "$($file.Name) must not run git $command"
            }
        }
    }

    It 'never writes a password parameter default into a report' {
        # A password parameter default is stored reversibly encrypted, not hashed. A
        # report is the artefact that gets attached to a ticket.
        $source = Get-Content -LiteralPath (Join-Path (Get-RepositoryRoot) 'foundation/modules/Jenkins.Jobs/Jenkins.Jobs.psm1') -Raw
        $source | Should -Match 'Password\|Credentials'
        $source | Should -Match 'not read'
    }
}

Describe 'The shipped templates are executable, and contain nothing real' {

    It 'passes its own validate command offline: <Name>' -ForEach $script:Automation {
        # validate is the promise that a malformed declaration fails in a second
        # rather than halfway through a run. This is that promise, exercised.
        $entryPoint = Join-Path (Get-RepositoryRoot) "automations/$Name/$EntryPoint"
        $template = Join-Path (Get-RepositoryRoot) "automations/$Name/config/$Template"
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $entryPoint -Command validate -ConfigurationPath $template 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
    }

    It 'names only reserved example hosts: <Name>' -ForEach $script:Automation {
        # Every fixture and template is invented. A template that borrowed a real host
        # name would turn this repository into another place to leak one, and template
        # files are the last place anyone thinks to look.
        $template = Get-Content -LiteralPath (Join-Path (Get-RepositoryRoot) "automations/$Name/config/$Template") -Raw
        foreach ($url in [regex]::Matches($template, 'https?://(?<host>[^/"]+)')) {
            $url.Groups['host'].Value | Should -Match '(^|\.)example\.(com|org|net)$'
        }
    }
}

Describe 'Documentation is indexed' {

    It 'links every document from the documentation index' {
        # A document nobody can reach from the index is a document nobody reads, and
        # it drifts from the code silently. Continuous integration enforces this, so
        # an unindexed document is treated as incomplete rather than as a nice extra.
        $documentationRoot = Join-Path (Get-RepositoryRoot) 'docs'
        $index = Get-Content -LiteralPath (Join-Path $documentationRoot 'README.md') -Raw

        $unlinked = New-Object System.Collections.ArrayList
        foreach ($document in (Get-ChildItem $documentationRoot -Recurse -Filter '*.md')) {
            if ($document.Name -eq 'README.md' -and $document.DirectoryName -eq (Resolve-Path -LiteralPath $documentationRoot).Path) { continue }
            if ($index -notmatch [regex]::Escape($document.Name)) { $null = $unlinked.Add($document.Name) }
        }

        $unlinked | Should -BeNullOrEmpty -Because 'every document under docs/ must be reachable from docs/README.md'
    }
}
