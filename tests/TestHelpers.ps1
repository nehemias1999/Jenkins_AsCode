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


function Get-PowerShellHostPath {
    <#
    .SYNOPSIS
        Path of the PowerShell executable running this suite.

    .DESCRIPTION
        Tests that need a child process used to name powershell.exe outright, and
        that had two consequences. The only cases that actually execute an entry
        point never ran under PowerShell 7, so half the declared support floor went
        unexercised by the very tests that claim to cover it. And they could not run
        at all on a host where that executable does not exist.

        Asking the current process means the child matches whichever host started
        the suite, so running the suite under 7 actually tests 7.

    .EXAMPLE
        & (Get-PowerShellHostPath) -NoProfile -File $script

    .OUTPUTS
        The executable path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $path = (Get-Process -Id $PID).Path
    if (-not $path) {
        # A host that will not name its own executable is not one this suite can
        # drive a child process from, and guessing would put us back where we were.
        throw 'Could not determine the path of the PowerShell host running this suite.'
    }
    return $path
}
function Remove-Assertedly {
    <#
    .SYNOPSIS
        Removes a test artefact and says so when it cannot.

    .DESCRIPTION
        Cleanup used to run with -ErrorAction SilentlyContinue, which meant a file
        the suite created inside the working copy could survive the run with nobody
        told. The next thing to notice it would be the sensitive data gate scanning
        it, or a diff, long after the run that left it.

        It warns rather than throwing. This is called from a finally block, and
        throwing there would replace a real assertion failure with a cleanup error -
        hiding the thing the test was actually reporting.

    .PARAMETER Path
        Item to remove.

    .PARAMETER Recurse
        Remove a directory and its contents.

    .EXAMPLE
        try { ... } finally { Remove-Assertedly -Path $probe }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [switch] $Recurse
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }
    try { Remove-Item -LiteralPath $Path -Force -Recurse:$Recurse -ErrorAction Stop }
    catch { Write-Warning "Test cleanup could not remove '$Path': $($_.Exception.Message). It is still in the working copy." }
    if (Test-Path -LiteralPath $Path) {
        Write-Warning "Test cleanup left '$Path' behind."
    }
}