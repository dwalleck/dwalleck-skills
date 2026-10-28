# Runners: front matter, test filters, Invoke-Mutations, Invoke-FullCheck, Invoke-Focused, Repeat-Tests.
# The build/test seams are replaced in module scope; their behaviour comes from $global:IpeRunnerTest.

function Install-RunnerSeams
{
    & (Get-Module ipe) {
        function script:Invoke-IpeBuild
        {
            param([string]$Root, [string]$Target, [string]$LogPath, [int]$TimeoutSeconds, [switch]$NoIncremental, [string]$FileLogPath, [string[]]$ExtraArguments)

            $state = $global:IpeRunnerTest
            $state.Builds.Add([pscustomobject]@{ Root = $Root; Target = $Target; NoIncremental = [bool]$NoIncremental; FileLogPath = $FileLogPath })
            $exitCode = if ($state.BuildAction) { [int](& $state.BuildAction $Root $Target) } else { 0 }
            [System.IO.File]::WriteAllText($LogPath, "fake build`n")
            return [pscustomobject]@{
                ExitCode = $exitCode; TimedOut = $false; ElapsedSeconds = 0.1; LogPath = $LogPath; FileLogPath = $FileLogPath
                Summary = [pscustomobject]@{ Errors = $(if ($exitCode -eq 0) { 0 } else { 1 }); Warnings = 0 }
            }
        }

        function script:Invoke-IpeTestProject
        {
            param(
                [string]$Root, [hashtable]$Project, [hashtable]$Config, [string]$LogPath, [string]$Filter, [switch]$NoBuild,
                [int]$TimeoutSeconds, [string]$InnerTimeout, [string]$TrxPath, [hashtable]$Environment
            )

            $state = $global:IpeRunnerTest
            $state.Tests.Add([pscustomobject]@{
                    Root = $Root; Project = $Project.Name; Filter = $Filter; NoBuild = [bool]$NoBuild; TimeoutSeconds = $TimeoutSeconds
                    InnerTimeout = $InnerTimeout; TrxPath = $TrxPath; Environment = $Environment; SqlSet = [bool]$env:IPE_SELFTEST_SQL
                })
            $outcome = & $state.TestAction $Root $Project $Filter
            $total = [int]$outcome['Total']
            $failed = [int]$outcome['Failed']
            $skipped = [int]$outcome['Skipped']
            $zero = [bool]$outcome['ZeroTests']
            $exitCode = if ($outcome.ContainsKey('ExitCode')) { [int]$outcome['ExitCode'] } elseif ($failed -gt 0) { 2 } else { 0 }
            [System.IO.File]::WriteAllText($LogPath, "fake test run`n")
            if ($TrxPath -and $outcome['Trx'])
            {
                $rows = foreach ($entry in $outcome['Trx'])
                {
                    "<UnitTestResult testName=`"$($entry.Name)`" outcome=`"Passed`" duration=`"$([System.TimeSpan]::FromSeconds($entry.Seconds).ToString('c'))`" />"
                }

                $xml = '<?xml version="1.0" encoding="utf-8"?><TestRun xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010"><Results>' + ($rows -join '') + '</Results></TestRun>'
                [System.IO.File]::WriteAllText($TrxPath, $xml)
            }

            return [pscustomobject]@{
                Project = $Project.Name; ExitCode = $exitCode; TimedOut = [bool]$outcome['TimedOut']; ElapsedSeconds = 0.2; LogPath = $LogPath
                Summary = [pscustomobject]@{
                    Kind = $Project.Kind; Found = $true; Total = $total; Failed = $failed; Succeeded = $total - $failed - $skipped; Skipped = $skipped
                    FailedNames = [string[]]@($outcome['FailedNames'] | Where-Object { $_ }); ZeroTests = $zero; Warnings = 0; Errors = 0; BuildFailed = $false
                }
            }
        }

        function script:Remove-LeakedTestDatabases
        {
            param([switch]$List, [switch]$Drop, [string]$Worktree, [string]$ConfigPath)

            return [pscustomobject]@{ ExitCode = 0; Leaked = [string[]]@(); Dropped = [string[]]@(); Report = [string[]]@('leaked databases: 0 (listed only)') }
        }
    }
}

function New-RunnerState
{
    param([scriptblock]$TestAction = { param($Root, $Project, $Filter) @{ Total = 3 } }, [scriptblock]$BuildAction)

    $global:IpeRunnerTest = @{
        Builds = [System.Collections.Generic.List[object]]::new()
        Tests = [System.Collections.Generic.List[object]]::new()
        TestAction = $TestAction
        BuildAction = $BuildAction
    }
    return $global:IpeRunnerTest
}

function New-RunnerTree
{
    # A throwaway repo (src/Calc.cs, a fake warnings script) and a config outside it whose drive pool is one free
    # letter. -FullCheck configures three projects (Alpha xunit, Beta tunit NeedsSql, Gamma tunit AllowEmpty) and a
    # loopback listener standing in for SQL Server. ConfigOverrides replace top-level config keys (data-file literals).
    param([switch]$FullCheck, [hashtable]$ConfigOverrides = @{})

    $letter = @(Get-FreeTestDriveLetter)[0]
    $repo = New-TempRepo
    $configDir = New-TempDir
    Write-TestBytes -Path (Join-Path $repo 'src\Calc.cs') -Text "class Calc`r`n{`r`n    int Add(int a, int b) => a + b;`r`n}`r`n"
    $warnings = @'
param([string]$BuildLog, [string]$Baseline, [string]$RepoRoot)
'fake warnings: compared'
exit ([int](Get-Content -LiteralPath (Join-Path $PSScriptRoot 'exit.txt')))
'@
    Write-TestBytes -Path (Join-Path $repo 'eng\check-warnings.ps1') -Text $warnings
    Write-TestBytes -Path (Join-Path $repo 'eng\exit.txt') -Text '0'
    New-TempCommit -Repo $repo -Message 'base'
    $overrides = @{ DrivePool = "@('$letter')" }
    $sqlOverrides = @{}
    $listener = $null
    if ($FullCheck)
    {
        $overrides.TestProjects = "@(@{ Name = 'Alpha'; Path = 'tests\Alpha\Alpha.csproj'; Kind = 'xunit'; NeedsSql = `$false; AllowEmpty = `$false }, " +
        "@{ Name = 'Beta'; Path = 'tests\Beta\Beta.csproj'; Kind = 'tunit'; NeedsSql = `$true; AllowEmpty = `$false }, " +
        "@{ Name = 'Gamma'; Path = 'tests\Gamma\Gamma.csproj'; Kind = 'tunit'; NeedsSql = `$false; AllowEmpty = `$true })"
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $sqlOverrides.Server = "'127.0.0.1,$(([System.Net.IPEndPoint]$listener.LocalEndpoint).Port)'"
        Write-TestBytes -Path (Join-Path $configDir 'connection.txt') -Text "PLACEHOLDER-SECRET`n"
    }

    foreach ($key in $ConfigOverrides.Keys)
    {
        $overrides[$key] = $ConfigOverrides[$key]
    }

    $config = New-TestConfig -Directory $configDir -Overrides $overrides -SqlOverrides $sqlOverrides
    return @{ Repo = $repo; ConfigDir = $configDir; Config = $config; Letter = $letter; Listener = $listener; Records = (Join-Path $repo '.scratch\demo\mutations') }
}

function Remove-RunnerTree
{
    param([hashtable]$Fixture)

    Remove-Variable -Name IpeRunnerTest -Scope Global -ErrorAction SilentlyContinue
    if (-not $Fixture)
    {
        return
    }

    if ($Fixture.Listener)
    {
        $Fixture.Listener.Stop()
    }

    Remove-TestSubst -Letter $Fixture.Letter -Target $Fixture.Repo
    Remove-TempDir $Fixture.Repo
    Remove-TempDir $Fixture.ConfigDir
}

function Write-MutationRecord
{
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$FrontMatter, [switch]$Bom)

    $body = "---`n" + $FrontMatter.Replace("`r`n", "`n").Trim("`n") + "`n---`n# $Name`n`n- Prose stays.`n"
    $path = Join-Path $Directory "$Name.md"
    Write-TestBytes -Path $path -Text $body.Replace("`n", "`r`n") -Bom:$Bom
    return $path
}

function Get-CalcRecord
{
    param([string]$Id = 'm1', [string]$Status = 'active', [string]$Replace = 'a - b', [int]$ExpectedMatches = 1)

    return @"
id: $Id
status: $Status
project: Unit
filter: '/*/*/CalcTests/*'
file: src/Calc.cs
expectedMatches: $ExpectedMatches
find: |-
  a + b
replace: |-
  $Replace
"@
}

function Get-RedWhenMutated
{
    # Tests fail while src/Calc.cs no longer adds, which proves the mutation was applied when the tests ran.
    return {
        param($Root, $Project, $Filter)
        $text = [System.IO.File]::ReadAllText((Join-Path $Root 'src\Calc.cs'))
        if ($text.Contains('a + b'))
        {
            return @{ Total = 3 }
        }

        return @{ Total = 3; Failed = 1; FailedNames = @('CalcTests.Add') }
    }
}

function Get-CalcBytes
{
    param([hashtable]$Fixture)

    return , [System.IO.File]::ReadAllBytes((Join-Path $Fixture.Repo 'src\Calc.cs'))
}

function Test-FrontMatterParsesScalarsBlocksAndEdits
{
    Import-IpeForTest
    $text = @'
---
# a comment
id: 03-M4
status: 'it''s'
note: "say \"hi\" \\ there"
count: 3
negative: -2
empty:
find: |-
  @"^[\x20-\x5D]{1,17}\z" and "quotes" and 'single'

  second paragraph
keep: |
  one line
indented: |2-
      leading spaces kept
  back to two
edits:
  - file: src/A.cs
    expectedMatches: 1
    find: |-
      a + b
    replace: ''
  - file: src/B.cs
    occurrence: 2
---
# body
'@
    $parsed = Invoke-IpePrivate -ScriptBlock { param($t) ConvertFrom-IpeFrontMatter -Text $t -Path 'demo.md' } -ArgumentList @($text)
    $data = $parsed.Data
    Assert-Equal @('id', 'status', 'note', 'count', 'negative', 'empty', 'find', 'keep', 'indented', 'edits') @($data.Keys)
    Assert-Equal '03-M4' $data['id']
    Assert-Equal "it's" $data['status']
    Assert-Equal 'say "hi" \ there' $data['note']
    Assert-True ($data['count'] -is [int] -and $data['count'] -eq 3) 'count is not the integer 3'
    Assert-True ($data['negative'] -is [int] -and $data['negative'] -eq -2) 'negative is not the integer -2'
    Assert-Equal '' $data['empty']
    Assert-Equal ('@"^[\x20-\x5D]{1,17}\z" and "quotes" and ''single''' + "`n`n" + 'second paragraph') $data['find']
    Assert-Equal "one line`n" $data['keep']
    Assert-Equal "    leading spaces kept`nback to two" $data['indented']
    $edits = @($data['edits'])
    Assert-Equal 2 $edits.Count
    Assert-Equal 'src/A.cs' $edits[0]['file']
    Assert-Equal 1 $edits[0]['expectedMatches']
    Assert-Equal 'a + b' $edits[0]['find']
    Assert-Equal '' $edits[0]['replace']
    Assert-Equal @('file', 'occurrence') @($edits[1].Keys)
    Assert-True ($edits[1]['occurrence'] -is [int] -and $edits[1]['occurrence'] -eq 2) 'occurrence is not the integer 2'
    Assert-Equal 27 $parsed.BodyLine
}

function Test-FrontMatterBadLinesNameTheLineNumber
{
    Import-IpeForTest
    $cases = @(
        @{ Text = "---`nid: a`n  stray: b`n---`n"; Like = '*line 3: unexpected indentation*' }
        @{ Text = "---`nid: a`nlist: [a, b]`n---`n"; Like = '*line 3: unsupported value*' }
        @{ Text = "---`nid: a`nnot a key`n---`n"; Like = '*line 3: expected ''key: value''*' }
        @{ Text = "---`nid: a`nid: b`n---`n"; Like = '*line 3: duplicate key ''id''*' }
        @{ Text = "---`nedits:`n  - file: a`n    more:`n      - x: 1`n---`n"; Like = '*line 5: nested sequences are not supported*' }
        @{ Text = "---`nid: `"open`n---`n"; Like = '*line 2: unterminated double-quoted value*' }
        @{ Text = "---`nid: a`n"; Like = '*never closed*' }
    )
    foreach ($case in $cases)
    {
        Assert-Throws { Invoke-IpePrivate -ScriptBlock { param($t) ConvertFrom-IpeFrontMatter -Text $t -Path 'bad.md' } -ArgumentList @($case.Text) } -ErrorId 'Ipe.FrontMatterInvalid' -MessageLike "bad.md: *$($case.Like)" | Out-Null
    }
}

function Test-FrontMatterMissingIsAnError
{
    Import-IpeForTest
    Assert-Throws { Invoke-IpePrivate -ScriptBlock { ConvertFrom-IpeFrontMatter -Text "# title`n`nprose`n" -Path 'plain.md' } } -ErrorId 'Ipe.FrontMatterMissing' -MessageLike 'plain.md: no front matter*' | Out-Null
}

function Test-TestFilterForOneAndTwoClasses
{
    Import-IpeForTest
    $filters = Invoke-IpePrivate -ScriptBlock {
        @(
            (New-IpeTestFilter -Kind tunit -Classes @('CalcTests'))
            (New-IpeTestFilter -Kind tunit -Classes @('CalcTests', 'MathTests'))
            (New-IpeTestFilter -Kind xunit -Classes @('CalcTests'))
            (New-IpeTestFilter -Kind xunit -Classes @('CalcTests', 'Contoso.MathTests'))
        )
    }
    Assert-Equal @('/*/*/CalcTests/*', '/*/*/(CalcTests|MathTests)/*', 'FullyQualifiedName~CalcTests', 'FullyQualifiedName~CalcTests|FullyQualifiedName~Contoso.MathTests') $filters
    Assert-Throws { Invoke-IpePrivate -ScriptBlock { New-IpeTestFilter -Kind tunit -Classes @('Calc*') } } -ErrorId 'Ipe.BadArguments' | Out-Null
    Assert-Throws { Invoke-IpePrivate -ScriptBlock { Resolve-IpeTestFilter -Kind tunit -Classes @('A') -Filter '/*/*/B/*' } } -ErrorId 'Ipe.BadArguments' | Out-Null
}

function Test-MutationsRefuseADirtySourceTree
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree
        $state = New-RunnerState -TestAction (Get-RedWhenMutated)
        [void](Write-MutationRecord -Directory $fixture.Records -Name 'm1' -FrontMatter (Get-CalcRecord))
        Write-TestBytes -Path (Join-Path $fixture.Repo 'src\Calc.cs') -Text "class Calc { }`r`n"
        Assert-Throws { Invoke-Mutations -Worktree $fixture.Repo -Feature demo -ConfigPath $fixture.Config } -ErrorId 'Ipe.DirtyTree' -MessageLike '*src/Calc.cs*' | Out-Null
        Assert-Equal 0 $state.Builds.Count
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-MutationsRecordWithoutFrontMatterIsAnErrorNamingIt
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree
        [void](New-RunnerState)
        [void](Write-MutationRecord -Directory $fixture.Records -Name 'm1' -FrontMatter (Get-CalcRecord))
        Write-TestBytes -Path (Join-Path $fixture.Records 'plain.md') -Text "# prose only`r`n"
        Assert-Throws { Invoke-Mutations -Worktree $fixture.Repo -Feature demo -ValidateOnly -ConfigPath $fixture.Config } -ErrorId 'Ipe.FrontMatterMissing' -MessageLike '*plain.md: no front matter*' | Out-Null
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-MutationsValidateOnlyChecksCountsWithoutTouchingFiles
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree
        $state = New-RunnerState
        [void](Write-MutationRecord -Directory $fixture.Records -Name 'm1' -FrontMatter (Get-CalcRecord))
        [void](Write-MutationRecord -Directory $fixture.Records -Name 'm2' -FrontMatter (Get-CalcRecord -Id 'm2' -ExpectedMatches 2))
        $before = Get-CalcBytes $fixture
        $result = Invoke-Mutations -Worktree $fixture.Repo -Feature demo -ValidateOnly -ConfigPath $fixture.Config
        Assert-Equal 1 $result.ExitCode
        Assert-Equal "records: 2 parsed in $($fixture.Records), 2 selected (2 active, 0 control, 0 stale)" $result.Report[0]
        Assert-Contains $result.Report 'ok   m1: src/Calc.cs matches 1 (expected 1)'
        Assert-Contains $result.Report 'FAIL m2: src/Calc.cs matches 1, expected 2'
        Assert-Contains $result.Report 'validate: FAIL'
        Assert-Equal $before (Get-CalcBytes $fixture)
        Assert-Equal 0 $state.Builds.Count
        $only = Invoke-Mutations -Worktree $fixture.Repo -Feature demo -ValidateOnly -Only @('M1') -ConfigPath $fixture.Config
        Assert-Equal 0 $only.ExitCode
        Assert-Contains $only.Report 'validate: pass'
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-MutationsMatchCountMismatchIsApplyFailedAndLeavesBytes
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree
        $state = New-RunnerState -TestAction (Get-RedWhenMutated)
        [void](Write-MutationRecord -Directory $fixture.Records -Name 'm1' -FrontMatter (Get-CalcRecord -ExpectedMatches 2))
        $before = Get-CalcBytes $fixture
        $result = Invoke-Mutations -Worktree $fixture.Repo -Feature demo -ConfigPath $fixture.Config
        Assert-Equal 1 $result.ExitCode
        Assert-Equal 'apply-failed' $result.Results[0].Verdict
        Assert-Contains $result.Results[0].Detail 'expected 2 match(es), found 1'
        Assert-Equal $before (Get-CalcBytes $fixture)
        Assert-Equal 0 $state.Builds.Count
        Assert-Equal 0 $state.Tests.Count
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-MutationsBuildFailureIsBuildFailedNotRed
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree
        $state = New-RunnerState -TestAction (Get-RedWhenMutated) -BuildAction { param($Root, $Target) 1 }
        [void](Write-MutationRecord -Directory $fixture.Records -Name 'm1' -FrontMatter (Get-CalcRecord))
        $before = Get-CalcBytes $fixture
        $result = Invoke-Mutations -Worktree $fixture.Repo -Feature demo -NoFinalRebuild -ConfigPath $fixture.Config
        Assert-Equal 1 $result.ExitCode
        Assert-Equal 'build-failed' $result.Results[0].Verdict
        Assert-Equal 0 $state.Tests.Count
        Assert-Equal $before (Get-CalcBytes $fixture)
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-MutationsFailingTestsAreRedAndRestored
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree
        $state = New-RunnerState -TestAction (Get-RedWhenMutated)
        [void](Write-MutationRecord -Directory $fixture.Records -Name 'm1' -FrontMatter (Get-CalcRecord))
        $before = Get-CalcBytes $fixture
        $result = Invoke-Mutations -Worktree $fixture.Repo -Feature demo -ConfigPath $fixture.Config
        Assert-Equal 0 $result.ExitCode
        $only = $result.Results[0]
        Assert-Equal @('m1', 'red', 'red', $true, 1, 3) @($only.Id, $only.Verdict, $only.Expected, $only.AsExpected, $only.Failed, $only.Total)
        Assert-Equal $before (Get-CalcBytes $fixture)
        Assert-Equal "$($fixture.Letter):\" $state.Tests[0].Root
        Assert-Equal '/*/*/CalcTests/*' $state.Tests[0].Filter
        Assert-Equal '30s' $state.Tests[0].InnerTimeout
        Assert-Equal 90 $state.Tests[0].TimeoutSeconds
        Assert-Equal $true $state.Tests[0].NoBuild
        Assert-Equal @('tests\Contoso.Tests\Contoso.Tests.csproj', 'tests\Contoso.Tests\Contoso.Tests.csproj') @($state.Builds | ForEach-Object { $_.Target })
        Assert-Contains $result.Report 'final rebuild: pass (Unit)'
        Assert-Contains $result.Report 'tree: clean (src, tests)'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Repo '.ipe-logs\mutation-journal.json'))) 'the journal was left behind'
        Assert-True (-not ((& subst) -join "`n").Contains("$($fixture.Letter):\")) 'the drive is still mapped'
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-MutationsSurvivorFailsTheRunAndAControlPasses
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree
        [void](New-RunnerState)
        [void](Write-MutationRecord -Directory $fixture.Records -Name 'c1' -FrontMatter (Get-CalcRecord -Id 'c1' -Status 'control' -Replace 'b + a'))
        [void](Write-MutationRecord -Directory $fixture.Records -Name 'm1' -FrontMatter (Get-CalcRecord))
        $result = Invoke-Mutations -Worktree $fixture.Repo -Feature demo -NoFinalRebuild -ConfigPath $fixture.Config
        Assert-Equal 1 $result.ExitCode
        Assert-Equal @('c1', 'm1') @($result.Results | ForEach-Object { $_.Id })
        Assert-Equal @('survived', 'survived') @($result.Results | ForEach-Object { $_.Verdict })
        Assert-Equal @($true, $false) @($result.Results | ForEach-Object { $_.AsExpected })
        Assert-Contains $result.Report 'mutations: FAIL (1 as expected, 1 not)'
        $control = Invoke-Mutations -Worktree $fixture.Repo -Feature demo -Only @('c1') -NoFinalRebuild -ConfigPath $fixture.Config
        Assert-Equal 0 $control.ExitCode
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-MutationsSeamThatThrowsStillRestoresBytes
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree
        [void](New-RunnerState -TestAction { param($Root, $Project, $Filter) throw 'test host crashed' })
        [void](Write-MutationRecord -Directory $fixture.Records -Name 'm1' -FrontMatter (Get-CalcRecord))
        $before = Get-CalcBytes $fixture
        $result = Invoke-Mutations -Worktree $fixture.Repo -Feature demo -NoFinalRebuild -ConfigPath $fixture.Config
        Assert-Equal 1 $result.ExitCode
        Assert-Equal 'error' $result.Results[0].Verdict
        Assert-Equal 'test host crashed' $result.Results[0].Detail
        Assert-Equal $before (Get-CalcBytes $fixture)
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Repo '.ipe-logs\mutation-journal.json'))) 'the journal was left behind'
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-MutationsRemnantFailsTheRun
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree
        [void](New-RunnerState -TestAction (Get-RedWhenMutated) -BuildAction {
                param($Root, $Target)
                [System.IO.File]::WriteAllText((Join-Path $Root 'src\Extra.cs'), "class Extra { }`r`n")
                0
            })
        [void](Write-MutationRecord -Directory $fixture.Records -Name 'm1' -FrontMatter (Get-CalcRecord))
        $result = Invoke-Mutations -Worktree $fixture.Repo -Feature demo -NoFinalRebuild -ConfigPath $fixture.Config
        Assert-Equal 'red' $result.Results[0].Verdict
        Assert-Equal 1 $result.ExitCode
        Assert-Equal @('src/Extra.cs') $result.Remnants
        Assert-Contains $result.Report 'tree: FAIL, left changed: src/Extra.cs'
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-MutationsRestoreAJournalLeftByAnInterruptedRun
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree
        [void](New-RunnerState -TestAction (Get-RedWhenMutated))
        [void](Write-MutationRecord -Directory $fixture.Records -Name 'm1' -FrontMatter (Get-CalcRecord))
        $before = Get-CalcBytes $fixture
        $journal = Join-Path $fixture.Repo '.ipe-logs\mutation-journal.json'
        Invoke-IpePrivate -ScriptBlock { param($path, $bytes) Write-IpeMutationJournal -Path $path -Id 'm0' -Originals ([ordered]@{ 'src/Calc.cs' = $bytes }) } -ArgumentList @($journal, $before)
        Write-TestBytes -Path (Join-Path $fixture.Repo 'src\Calc.cs') -Text "class Calc { int Add(int a, int b) => 0; }`r`n"
        $result = Invoke-Mutations -Worktree $fixture.Repo -Feature demo -NoFinalRebuild -ConfigPath $fixture.Config
        Assert-Equal 'restored 1 file(s) left mutated by an interrupted run of m0: src/Calc.cs' $result.Report[0]
        Assert-Equal 0 $result.ExitCode
        Assert-Equal 'red' $result.Results[0].Verdict
        Assert-Equal $before (Get-CalcBytes $fixture)
        Assert-True (-not (Test-Path -LiteralPath $journal)) 'the journal was left behind'

        Invoke-IpePrivate -ScriptBlock { param($path, $bytes) Write-IpeMutationJournal -Path $path -Id 'm0' -Originals ([ordered]@{ 'src/Calc.cs' = $bytes }) } -ArgumentList @($journal, $before)
        Write-TestBytes -Path (Join-Path $fixture.Repo 'src\Calc.cs') -Text "mutated`r`n"
        $restore = Invoke-Mutations -Worktree $fixture.Repo -Feature demo -RestoreOnly -ConfigPath $fixture.Config
        Assert-Equal 0 $restore.ExitCode
        Assert-Equal $before (Get-CalcBytes $fixture)
        $nothing = Invoke-Mutations -Worktree $fixture.Repo -Feature demo -RestoreOnly -ConfigPath $fixture.Config
        Assert-Equal @('restore: nothing to restore') $nothing.Report
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-MutationsAppendVerdictsKeepsCrlfAndBom
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree
        [void](New-RunnerState -TestAction (Get-RedWhenMutated))
        $record = Write-MutationRecord -Directory $fixture.Records -Name 'm1' -FrontMatter (Get-CalcRecord) -Bom
        $original = [System.IO.File]::ReadAllBytes($record)
        $result = Invoke-Mutations -Worktree $fixture.Repo -Feature demo -AppendVerdicts -NoFinalRebuild -ConfigPath $fixture.Config
        Assert-Equal 0 $result.ExitCode
        $short = (Invoke-TestGit -Repo $fixture.Repo -Arguments @('rev-parse', '--short', 'HEAD')).Trim()
        $date = [System.DateTime]::Now.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        $line = "- Verified $date at ${short}: red, 1 failed of 3 (Unit, filter /*/*/CalcTests/*); restored.`r`n"
        $expected = [byte[]]($original + [System.Text.UTF8Encoding]::new($false).GetBytes($line))
        Assert-Equal $expected ([System.IO.File]::ReadAllBytes($record))
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-MutationsSkipAStaleRecordWithItsReason
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree
        $state = New-RunnerState
        $stale = @'
id: s1
status: stale
staleReason: the mutated logic was removed
project: Unit
file: src/Gone.cs
expectedMatches: 1
find: |-
  x
replace: ''
'@
        [void](Write-MutationRecord -Directory $fixture.Records -Name 's1' -FrontMatter $stale)
        $result = Invoke-Mutations -Worktree $fixture.Repo -Feature demo -ConfigPath $fixture.Config
        Assert-Equal 0 $result.ExitCode
        Assert-Equal 'stale' $result.Results[0].Verdict
        Assert-Contains $result.Report '  the mutated logic was removed'
        Assert-Equal 0 $state.Builds.Count
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Get-FullCheckAction
{
    param([hashtable]$Overrides = @{})

    $defaults = @{ Alpha = @{ Total = 5 }; Beta = @{ Total = 3 }; Gamma = @{ Total = 0; ZeroTests = $true; ExitCode = 8 } }
    foreach ($key in $Overrides.Keys)
    {
        $defaults[$key] = $Overrides[$key]
    }

    return { param($Root, $Project, $Filter) $defaults[$Project.Name] }.GetNewClosure()
}

function Invoke-TestFullCheck
{
    param([hashtable]$Fixture)

    return Use-TestEnvironment -Variables @{ IPE_SELFTEST_SQL = $null; IPE_CONFIG = $null } -ScriptBlock {
        Invoke-FullCheck -Worktree $Fixture.Repo -Base HEAD -ConfigPath $Fixture.Config
    }
}

function Test-FullCheckPassesAndWritesSummaryAndRecord
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree -FullCheck
        $state = New-RunnerState -TestAction (Get-FullCheckAction)
        $head = (Invoke-TestGit -Repo $fixture.Repo -Arguments @('rev-parse', 'HEAD')).Trim()
        $result = Invoke-TestFullCheck $fixture
        Assert-Equal 0 $result.ExitCode
        $summary = [System.IO.File]::ReadAllLines($result.SummaryPath)
        Assert-Contains $summary "head: $head"
        Assert-Contains $summary 'warnings: pass'
        Assert-Contains $summary 'project Alpha (xunit): passed 5, failed 0, skipped 0, total 5, exit 0, 0.2 s - pass'
        Assert-Contains $summary 'project Beta (tunit): passed 3, failed 0, skipped 0, total 3, exit 0, 0.2 s - pass'
        Assert-Contains $summary 'project Gamma (tunit): passed 0, failed 0, skipped 0, total 0, exit 8, 0.2 s - zero tests (AllowEmpty)'
        Assert-Contains $summary 'format: nothing to format'
        Assert-Contains $summary 'line endings: pass'
        Assert-Contains $summary 'leaked databases: 0 (listed only)'
        Assert-Equal 'overall: pass' $summary[-1]

        $record = Get-Content -LiteralPath $result.RecordPath -Raw | ConvertFrom-Json
        Assert-Equal @('result', 'head', 'tree', 'dirtyPaths', 'summaryPath', 'finished') @($record.PSObject.Properties.Name)
        Assert-Equal 'pass' $record.result
        Assert-Equal $head $record.head
        Assert-Equal $fixture.Repo $record.tree
        Assert-Equal 0 @($record.dirtyPaths).Count
        Assert-Equal $result.SummaryPath $record.summaryPath
        Assert-True ([System.DateTimeOffset]::Parse($record.finished, [System.Globalization.CultureInfo]::InvariantCulture) -le [System.DateTimeOffset]::UtcNow) 'finished is not a past timestamp'
        Assert-Equal (Get-Content -LiteralPath $result.RecordPath -Raw) (Get-Content -LiteralPath (Join-Path $fixture.Repo '.ipe-logs\last-full-check.json') -Raw)

        Assert-Equal 1 $state.Builds.Count
        Assert-Equal @('src\Contoso.sln', $true, (Join-Path $fixture.Repo '.ipe-logs\full-check-build.log')) @($state.Builds[0].Target, $state.Builds[0].NoIncremental, $state.Builds[0].FileLogPath)
        Assert-Equal @('Alpha', 'Beta', 'Gamma') @($state.Tests | ForEach-Object { $_.Project })
        Assert-Equal @($true, $true, $true) @($state.Tests | ForEach-Object { $_.NoBuild })
        Assert-Equal @($true, $true, $true) @($state.Tests | ForEach-Object { $_.SqlSet })
        Assert-Equal $head (Invoke-TestGit -Repo $fixture.Repo -Arguments @('rev-parse', 'HEAD')).Trim()
        Assert-True (-not ((& subst) -join "`n").Contains("$($fixture.Letter):\")) 'the drive is still mapped'
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-FullCheckFailsOnSkippedTestsInASqlProject
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree -FullCheck
        [void](New-RunnerState -TestAction (Get-FullCheckAction -Overrides @{ Beta = @{ Total = 3; Skipped = 1 } }))
        Write-TestBytes -Path (Join-Path $fixture.Repo 'docs\notes.md') -Text "notes`n"
        $result = Invoke-TestFullCheck $fixture
        Assert-Equal 1 $result.ExitCode
        $summary = [System.IO.File]::ReadAllLines($result.SummaryPath)
        Assert-Contains $summary 'project Beta (tunit): passed 2, failed 0, skipped 1, total 3, exit 0, 0.2 s - FAIL (1 skipped in a project that needs SQL)'
        Assert-Equal 'overall: FAIL (project Beta)' $summary[-1]
        $record = Get-Content -LiteralPath $result.RecordPath -Raw | ConvertFrom-Json
        Assert-Equal 'fail' $record.result
        Assert-Equal @('docs/notes.md') @($record.dirtyPaths)
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-FullCheckAllowEmptyAppliesOnlyToItsProject
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree -FullCheck
        [void](New-RunnerState -TestAction (Get-FullCheckAction -Overrides @{ Alpha = @{ Total = 0; ZeroTests = $true } }))
        $result = Invoke-TestFullCheck $fixture
        Assert-Equal 1 $result.ExitCode
        $summary = [System.IO.File]::ReadAllLines($result.SummaryPath)
        Assert-Contains $summary 'project Alpha (xunit): passed 0, failed 0, skipped 0, total 0, exit 0, 0.2 s - FAIL (zero tests ran)'
        Assert-Contains $summary 'project Gamma (tunit): passed 0, failed 0, skipped 0, total 0, exit 8, 0.2 s - zero tests (AllowEmpty)'
        Assert-Equal 'overall: FAIL (project Alpha)' $summary[-1]
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-FullCheckFailsWhenTheWarningsScriptFails
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree -FullCheck
        [void](New-RunnerState -TestAction (Get-FullCheckAction))
        Write-TestBytes -Path (Join-Path $fixture.Repo 'eng\exit.txt') -Text '1'
        $result = Invoke-TestFullCheck $fixture
        Assert-Equal 1 $result.ExitCode
        $summary = [System.IO.File]::ReadAllLines($result.SummaryPath)
        Assert-Contains $summary 'warnings: FAIL (exit 1)'
        Assert-Contains $summary '  fake warnings: compared'
        Assert-Equal 'overall: FAIL (warnings)' $summary[-1]
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-FullCheckFailsWhenTheWarningsScriptIsMissing
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree -FullCheck
        $state = New-RunnerState -TestAction (Get-FullCheckAction)
        Remove-Item -LiteralPath (Join-Path $fixture.Repo 'eng\check-warnings.ps1')
        $result = Invoke-TestFullCheck $fixture
        Assert-Equal 1 $result.ExitCode
        $summary = [System.IO.File]::ReadAllLines($result.SummaryPath)
        Assert-Contains $summary "warnings: FAIL (script missing: $(Join-Path $fixture.Repo 'eng\check-warnings.ps1'))"
        Assert-Equal 3 $state.Tests.Count
        Assert-Equal 'overall: FAIL (warnings)' $summary[-1]
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-FullCheckRunsExtraChecksAndFailsOnTheirExit
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree -FullCheck -ConfigOverrides @{ ExtraChecks = "@(@{ Name = 'hygiene'; Script = 'eng\extra.ps1' })" }
        $extra = @'
param([string]$Base, [string]$RepoRoot)
"extra base: $Base"
exit ([int](Get-Content -LiteralPath (Join-Path $PSScriptRoot 'extra-exit.txt')))
'@
        Write-TestBytes -Path (Join-Path $fixture.Repo 'eng\extra.ps1') -Text $extra
        Write-TestBytes -Path (Join-Path $fixture.Repo 'eng\extra-exit.txt') -Text '0'
        New-TempCommit -Repo $fixture.Repo -Message 'extra check'
        [void](New-RunnerState -TestAction (Get-FullCheckAction))
        $head = (Invoke-TestGit -Repo $fixture.Repo -Arguments @('rev-parse', 'HEAD')).Trim()
        $result = Invoke-TestFullCheck $fixture
        Assert-Equal 0 $result.ExitCode
        $summary = [System.IO.File]::ReadAllLines($result.SummaryPath)
        Assert-Contains $summary 'extra check hygiene: pass'
        Assert-Contains $summary "  extra base: $head"
        Assert-Equal 'overall: pass' $summary[-1]

        Write-TestBytes -Path (Join-Path $fixture.Repo 'eng\extra-exit.txt') -Text '1'
        New-TempCommit -Repo $fixture.Repo -Message 'extra check fails'
        $result = Invoke-TestFullCheck $fixture
        Assert-Equal 1 $result.ExitCode
        $summary = [System.IO.File]::ReadAllLines($result.SummaryPath)
        Assert-Contains $summary 'extra check hygiene: FAIL (exit 1)'
        Assert-Equal 'overall: FAIL (extra check hygiene)' $summary[-1]
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-FullCheckFailsWhenAnExtraCheckScriptIsMissing
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree -FullCheck -ConfigOverrides @{ ExtraChecks = "@(@{ Name = 'hygiene'; Script = 'eng\missing.ps1' })" }
        $state = New-RunnerState -TestAction (Get-FullCheckAction)
        $result = Invoke-TestFullCheck $fixture
        Assert-Equal 1 $result.ExitCode
        $summary = [System.IO.File]::ReadAllLines($result.SummaryPath)
        Assert-Contains $summary "extra check hygiene: FAIL (script missing: $(Join-Path $fixture.Repo 'eng\missing.ps1'))"
        Assert-Equal 3 $state.Tests.Count
        Assert-Equal 'overall: FAIL (extra check hygiene)' $summary[-1]
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-FullCheckFailsWhenAnExtraCheckTimesOut
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree -FullCheck -ConfigOverrides @{ ExtraChecks = "@(@{ Name = 'slow'; Script = 'eng\slow.ps1'; TimeoutSeconds = 1 })" }
        Write-TestBytes -Path (Join-Path $fixture.Repo 'eng\slow.ps1') -Text "param([string]`$Base, [string]`$RepoRoot)`nStart-Sleep -Seconds 60`n"
        New-TempCommit -Repo $fixture.Repo -Message 'slow check'
        [void](New-RunnerState -TestAction (Get-FullCheckAction))
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-TestFullCheck $fixture
        $watch.Stop()
        Assert-Equal 1 $result.ExitCode
        $summary = [System.IO.File]::ReadAllLines($result.SummaryPath)
        Assert-Contains $summary 'extra check slow: FAIL (timed out after 1 s)'
        Assert-Equal 'overall: FAIL (extra check slow)' $summary[-1]
        Assert-True ($watch.Elapsed.TotalSeconds -lt 30) "the full check took $($watch.Elapsed.TotalSeconds) s, so the 60 s script was not killed at its 1 s timeout"
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-FullCheckFailsOnAFormatFailure
{
    Import-IpeForTest
    Install-RunnerSeams
    & (Get-Module ipe) {
        function script:Invoke-Format
        {
            param([string]$Worktree, [string]$Base, [string[]]$Paths, [string]$Drive, [string]$Tag, [string]$ConfigPath)

            return [pscustomobject]@{ ExitCode = 1; Report = [string[]]@('format whitespace: FAIL (1 change(s))', '  src/Calc.cs:3 WHITESPACE Fix whitespace', 'format: FAIL') }
        }
    }
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree -FullCheck
        [void](New-RunnerState -TestAction (Get-FullCheckAction))
        $result = Invoke-TestFullCheck $fixture
        Assert-Equal 1 $result.ExitCode
        $summary = [System.IO.File]::ReadAllLines($result.SummaryPath)
        Assert-Contains $summary 'format: FAIL'
        Assert-Contains $summary '  src/Calc.cs:3 WHITESPACE Fix whitespace'
        Assert-Equal 'overall: FAIL (format)' $summary[-1]
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-FullCheckBuildErrorStopsBeforeTests
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree -FullCheck
        $state = New-RunnerState -TestAction (Get-FullCheckAction) -BuildAction { param($Root, $Target) 1 }
        $result = Invoke-TestFullCheck $fixture
        Assert-Equal 1 $result.ExitCode
        Assert-Equal 0 $state.Tests.Count
        $summary = [System.IO.File]::ReadAllLines($result.SummaryPath)
        Assert-Contains $summary 'project Alpha (xunit): not run'
        Assert-Contains $summary 'warnings: not run'
        Assert-Equal 'overall: FAIL (build)' $summary[-1]
        Assert-Equal 'fail' (Get-Content -LiteralPath $result.RecordPath -Raw | ConvertFrom-Json).result
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-FocusedFailsOnSkippedSqlTestsUnlessAllowed
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree -FullCheck
        $state = New-RunnerState -TestAction (Get-FullCheckAction -Overrides @{ Beta = @{ Total = 3; Skipped = 1 } })
        Use-TestEnvironment -Variables @{ IPE_SELFTEST_SQL = $null; IPE_CONFIG = $null } -ScriptBlock {
            $failed = Invoke-Focused -Worktree $fixture.Repo -Project beta -Classes @('A', 'B') -ConfigPath $fixture.Config
            Assert-Equal 1 $failed.ExitCode
            Assert-Equal 'focused: FAIL (1 skipped in a project that needs SQL)' $failed.Report[-1]
            Assert-Contains $failed.Report[0] 'focused Beta (tunit) filter /*/*/(A|B)/*: total 3, passed 2, failed 0, skipped 1, exit 0'
            $allowed = Invoke-Focused -Worktree $fixture.Repo -Project Beta -Classes @('A', 'B') -AllowSkip -ConfigPath $fixture.Config
            Assert-Equal 0 $allowed.ExitCode
        }

        Assert-Equal @('/*/*/(A|B)/*', '/*/*/(A|B)/*') @($state.Tests | ForEach-Object { $_.Filter })
        Assert-Equal @($true, $true) @($state.Tests | ForEach-Object { $_.SqlSet })
        Assert-Equal @('tests\Beta\Beta.csproj', 'tests\Beta\Beta.csproj') @($state.Builds | ForEach-Object { $_.Target })
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}

function Test-RepeatTestsCapsThreadsAndListsTheSlowest
{
    Import-IpeForTest
    Install-RunnerSeams
    $fixture = $null
    try
    {
        $fixture = New-RunnerTree -FullCheck
        $state = New-RunnerState -TestAction {
            param($Root, $Project, $Filter)
            if ($global:IpeRunnerTest.Tests.Count -eq 1)
            {
                return @{ Total = 2; Trx = @(@{ Name = 'A'; Seconds = 0.5 }, @{ Name = 'B'; Seconds = 1.5 }) }
            }

            return @{ Total = 3; Failed = 1; FailedNames = @('C'); Trx = @(@{ Name = 'A'; Seconds = 2 }, @{ Name = 'B'; Seconds = 0.1 }, @{ Name = 'C'; Seconds = 0.3 }) }
        }
        $result = Use-TestEnvironment -Variables @{ IPE_CONFIG = $null } -ScriptBlock {
            Repeat-Tests -Worktree $fixture.Repo -Project Alpha -Runs 2 -MaxThreads 12 -MinThreads 4 -Slowest 2 -ConfigPath $fixture.Config
        }
        Assert-Equal 1 $result.ExitCode
        Assert-Equal 1 $state.Builds.Count
        Assert-Equal @('C', '4') @($state.Tests[0].Environment['DOTNET_ThreadPool_ForceMaxWorkerThreads'], $state.Tests[0].Environment['DOTNET_ThreadPool_ForceMinWorkerThreads'])
        Assert-Contains $result.Report 'run 1/2 exit 0 wall 0.2s total 2 failed 0 skipped 0'
        Assert-Contains $result.Report 'run 2/2 exit 2 wall 0.2s total 3 failed 1 skipped 0 [C]'
        Assert-Equal @('slowest: 2.000 s  A (run 2)', 'slowest: 1.500 s  B (run 1)') @($result.Report | Where-Object { $_.StartsWith('slowest:') })
        Assert-Equal 'repeat: FAIL (1 of 2 runs failed)' $result.Report[-1]
    }
    finally
    {
        Remove-RunnerTree $fixture
    }
}
