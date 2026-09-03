<#
    Shared test helpers.

    Every fixture here is invented. A test that borrows a real job path, host name or
    credential turns the suite into another place sensitive data leaks from, and test
    files are the last place anyone thinks to look.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepositoryRoot {
    <#
    .SYNOPSIS
        Absolute path of the repository root.

    .EXAMPLE
        Get-RepositoryRoot

    .OUTPUTS
        The path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}

function Get-FixturePath {
    <#
    .SYNOPSIS
        Absolute path of a file under tests/fixtures.

    .PARAMETER Name
        File name.

    .EXAMPLE
        Get-FixturePath -Name 'freestyle.config.xml'

    .OUTPUTS
        The path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Name
    )

    $path = Join-Path (Join-Path $PSScriptRoot 'fixtures') $Name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Fixture not found: $path"
    }
    return (Resolve-Path -LiteralPath $path).Path
}

function Get-FixtureXml {
    <#
    .SYNOPSIS
        Content of a config.xml fixture, as text.

    .PARAMETER Name
        File name under tests/fixtures.

    .EXAMPLE
        Get-FixtureXml -Name 'freestyle.config.xml'

    .OUTPUTS
        The text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Name
    )

    return (Get-Content -LiteralPath (Get-FixturePath -Name $Name) -Raw)
}

