# Core: process and git primitives, search, file editing, log parsing, config, dispatch, drive, SQL scope, host killing.

function Test-ProcessCapturesOutputExitCodeAndChildEnvironment
{
    Import-IpeForTest
    $dir = New-TempDir
    try
    {
        $result = Invoke-IpePrivate -ScriptBlock {
            param($pwsh, $cwd)
            Invoke-IpeProcess -FilePath $pwsh -ArgumentList @('-NoProfile', '-Command', 'Write-Output (''out|'' + $env:NO_COLOR + ''|'' + $env:MSBUILDTERMINALLOGGER + ''|'' + $env:IPE_SELFTEST_EXTRA); [Console]::Error.WriteLine(''err-line''); exit 7') -WorkingDirectory $cwd -TimeoutSeconds 60 -Environment @{ IPE_SELFTEST_EXTRA = 'extra' }
        } -ArgumentList @($script:PwshPath, $dir)

        Assert-Equal 7 $result.ExitCode
        Assert-Equal $false $result.TimedOut
        Assert-Equal 'out|1|off|extra' $result.StdOut.Trim()
        Assert-Equal 'err-line' $result.StdErr.Trim()
    }
    finally
    {
        Remove-TempDir $dir
    }
}

function Test-ProcessTimeoutKillsChildAndGrandchild
{
    Import-IpeForTest
    $dir = New-TempDir
    $pidFile = Join-Path $dir 'pids.txt'
    $childScript = Join-Path $dir 'child.ps1'
    $body = @"
`$grandchild = Start-Process -FilePath '$($script:PwshPath)' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 120' -PassThru -WindowStyle Hidden
Set-Content -LiteralPath '$pidFile' -Value "`$PID`n`$(`$grandchild.Id)"
Start-Sleep -Seconds 120
"@
    Write-TestBytes -Path $childScript -Text $body
    $pids = @()
    try
    {
        $result = Invoke-IpePrivate -ScriptBlock {
            param($pwsh, $script, $cwd)
            Invoke-IpeProcess -FilePath $pwsh -ArgumentList @('-NoProfile', '-File', $script) -WorkingDirectory $cwd -TimeoutSeconds 12
        } -ArgumentList @($script:PwshPath, $childScript, $dir)

        Assert-Equal $true $result.TimedOut
        Assert-Equal (-1) $result.ExitCode
        Assert-True (Test-Path -LiteralPath $pidFile) 'the child never wrote its PIDs before the timeout'
        $pids = @(Get-Content -LiteralPath $pidFile | Where-Object { $_ } | ForEach-Object { [int]$_ })
        Assert-Equal 2 $pids.Count
        $deadline = [System.Diagnostics.Stopwatch]::StartNew()
        while ($deadline.Elapsed.TotalSeconds -lt 15 -and @($pids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count -gt 0)
        {
            Start-Sleep -Milliseconds 250
        }

        foreach ($id in $pids)
        {
            Assert-True ($null -eq (Get-Process -Id $id -ErrorAction SilentlyContinue)) "process $id is still running"
        }
    }
    finally
    {
        foreach ($id in $pids)
        {
            Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
        }

        Remove-TempDir $dir
    }
}

function Test-GitAlwaysPassesLongPaths
{
    Import-IpeForTest
    $repo = New-TempRepo
    try
    {
        $result = Invoke-Git -Worktree $repo -Arguments @('config', '--get', 'core.longpaths')
        Assert-Equal 'true' $result.Lines[0]
        Assert-Throws { Invoke-Git -Worktree $repo -Arguments @('rev-parse', 'no-such-ref') } -ErrorId 'Ipe.GitFailed' | Out-Null
        Assert-Throws { Invoke-Git -Worktree 'relative\path' -Arguments @('status') } -ErrorId 'Ipe.RelativePath' | Out-Null
    }
    finally
    {
        Remove-TempDir $repo
    }
}

function New-SearchRepo
{
    $repo = New-TempRepo
    Write-TestBytes -Path (Join-Path $repo 'tracked.txt') -Text "alpha line`n"
    New-TempCommit -Repo $repo -Message 'base'
    Write-TestBytes -Path (Join-Path $repo 'untracked.txt') -Text "first`nbeta needle`n"
    return $repo
}

function Test-SearchWorktreeFindsUntrackedFile
{
    Import-IpeForTest
    $repo = New-SearchRepo
    try
    {
        $result = Search-Worktree -Worktree $repo -Pattern 'needle'
        Assert-Equal 1 $result.Hits.Count
        Assert-Equal 'untracked.txt' $result.Hits[0].Path
        Assert-Equal 2 $result.Hits[0].Line
        Assert-Equal 'beta needle' $result.Hits[0].Text
    }
    finally
    {
        Remove-TempDir $repo
    }
}

function Test-SearchWorktreeHandlesAlternationAndNoMatch
{
    Import-IpeForTest
    $repo = New-SearchRepo
    try
    {
        $result = Search-Worktree -Worktree $repo -Pattern 'alpha|needle'
        Assert-Equal @('tracked.txt', 'untracked.txt') @($result.Hits | ForEach-Object { $_.Path })
        $none = Search-Worktree -Worktree $repo -Pattern 'absent-text'
        Assert-Equal 0 $none.ExitCode
        Assert-Equal 0 $none.Hits.Count
        Assert-Contains $none.Report 'no matches'
    }
    finally
    {
        Remove-TempDir $repo
    }
}

function Test-EditFileKeepsBomAndCrlf
{
    Import-IpeForTest
    $dir = New-TempDir
    try
    {
        $path = Join-Path $dir 'Bom.cs'
        Write-TestBytes -Path $path -Text "class A`r`n{`r`n    int x = 1;`r`n}`r`n" -Bom
        $result = Edit-File -Path $path -Find 'int x = 1;' -Replace 'int x = 2;' -ExpectCount 1
        Assert-Equal 1 $result.Matches
        $bytes = [System.IO.File]::ReadAllBytes($path)
        Assert-Equal @(0xEF, 0xBB, 0xBF) @($bytes[0..2])
        Assert-Equal "class A`r`n{`r`n    int x = 2;`r`n}`r`n" ([System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3))
    }
    finally
    {
        Remove-TempDir $dir
    }
}

function Test-EditFileKeepsLfAndNoBom
{
    Import-IpeForTest
    $dir = New-TempDir
    try
    {
        $path = Join-Path $dir 'Lf.cs'
        Write-TestBytes -Path $path -Text "a`nb`nc`n"
        [void](Edit-File -Path $path -Find "b`r`nc" -Replace "B`r`nC" -ExpectCount 1)
        Assert-Equal "a`nB`nC`n" ([System.IO.File]::ReadAllText($path))
        Assert-Equal ([byte][char]'a') ([System.IO.File]::ReadAllBytes($path)[0])
    }
    finally
    {
        Remove-TempDir $dir
    }
}

function Test-EditFileNormalisesLfFindAgainstCrlfFile
{
    Import-IpeForTest
    $dir = New-TempDir
    try
    {
        $path = Join-Path $dir 'Crlf.cs'
        Write-TestBytes -Path $path -Text "first`r`nsecond`r`nthird`r`n"
        [void](Edit-File -Path $path -Find "first`nsecond" -Replace "one`ntwo`nextra" -ExpectCount 1)
        Assert-Equal "one`r`ntwo`r`nextra`r`nthird`r`n" ([System.IO.File]::ReadAllText($path))
    }
    finally
    {
        Remove-TempDir $dir
    }
}

function Test-EditFileHonoursOccurrence
{
    Import-IpeForTest
    $dir = New-TempDir
    try
    {
        $path = Join-Path $dir 'Many.cs'
        Write-TestBytes -Path $path -Text "x = 1;`nx = 1;`nx = 1;`n"
        $result = Edit-File -Path $path -Find 'x = 1;' -Replace 'x = 9;' -ExpectCount 3 -Occurrence 2
        Assert-Equal 3 $result.Matches
        Assert-Equal 1 $result.Replaced
        Assert-Equal "x = 1;`nx = 9;`nx = 1;`n" ([System.IO.File]::ReadAllText($path))
        [void](Edit-File -Path $path -Find 'x = 1;' -Replace 'y;' -ExpectCount 2)
        Assert-Equal "y;`nx = 9;`ny;`n" ([System.IO.File]::ReadAllText($path))
    }
    finally
    {
        Remove-TempDir $dir
    }
}

function Test-EditFileMatchCountMismatchLeavesBytesUnchanged
{
    Import-IpeForTest
    $dir = New-TempDir
    try
    {
        $path = Join-Path $dir 'Mismatch.cs'
        Write-TestBytes -Path $path -Text "same`r`nsame`r`n" -Bom
        $before = [System.IO.File]::ReadAllBytes($path)
        Assert-Throws { Edit-File -Path $path -Find 'same' -Replace 'other' -ExpectCount 1 } -ErrorId 'Ipe.MatchCount' -MessageLike '*expected 1 match(es), found 2*' | Out-Null
        Assert-Throws { Edit-File -Path $path -Find 'missing' -Replace 'other' -ExpectCount 1 } -ErrorId 'Ipe.MatchCount' | Out-Null
        $after = [System.IO.File]::ReadAllBytes($path)
        Assert-Equal ([Convert]::ToBase64String($before)) ([Convert]::ToBase64String($after))
    }
    finally
    {
        Remove-TempDir $dir
    }
}

function Assert-Summary
{
    param([Parameter(Mandatory)][string]$Fixture, [Parameter(Mandatory)][hashtable]$Expected)

    $summary = Get-RunSummary -Path (Join-Path $script:FixturesRoot $Fixture)
    foreach ($key in $Expected.Keys)
    {
        Assert-Equal $Expected[$key] $summary.$key " ($Fixture $key)"
    }
}

function Test-RunSummaryTunitPass
{
    Import-IpeForTest
    Assert-Summary -Fixture 'tunit-pass.txt' -Expected @{ Kind = 'tunit'; Found = $true; Total = 42; Failed = 0; Succeeded = 41; Skipped = 1; FailedNames = @(); ZeroTests = $false }
}

function Test-RunSummaryTunitFail
{
    Import-IpeForTest
    Assert-Summary -Fixture 'tunit-fail.txt' -Expected @{
        Kind = 'tunit'; Found = $true; Total = 10; Failed = 2; Succeeded = 7; Skipped = 1; ZeroTests = $false
        FailedNames = @('Create_RejectsEmptyName', 'Total_RoundsToCents(1.005)')
    }
}

function Test-RunSummaryTunitZero
{
    Import-IpeForTest
    Assert-Summary -Fixture 'tunit-zero.txt' -Expected @{ Kind = 'tunit'; Found = $true; Total = 0; Failed = 0; ZeroTests = $true; FailedNames = @() }
}

function Test-RunSummaryXunitPass
{
    Import-IpeForTest
    Assert-Summary -Fixture 'xunit-pass.txt' -Expected @{ Kind = 'xunit'; Found = $true; Total = 123; Failed = 0; Succeeded = 120; Skipped = 3; FailedNames = @(); ZeroTests = $false }
}

function Test-RunSummaryXunitFail
{
    Import-IpeForTest
    Assert-Summary -Fixture 'xunit-fail.txt' -Expected @{
        Kind = 'xunit'; Found = $true; Total = 100; Failed = 1; Succeeded = 99; Skipped = 0
        FailedNames = @('Contoso.Unit.Tests.InvoiceTests.Total_IncludesTax')
    }
}

function Test-RunSummaryMsbuildOk
{
    Import-IpeForTest
    Assert-Summary -Fixture 'msbuild-ok.txt' -Expected @{ Kind = 'msbuild'; Found = $true; Warnings = 1; Errors = 0; BuildFailed = $false }
}

function Test-RunSummaryMsbuildFail
{
    Import-IpeForTest
    Assert-Summary -Fixture 'msbuild-fail.txt' -Expected @{ Kind = 'msbuild'; Found = $true; Warnings = 0; Errors = 1; BuildFailed = $true }
}

function Test-ConfigLoadsAndExpandsConnectionFile
{
    Import-IpeForTest
    $dir = New-TempDir
    try
    {
        $path = New-TestConfig -Directory $dir -SqlOverrides @{ ConnectionFile = "'%IPE_SELFTEST_ROOT%\secret\connection.txt'" }
        $config = Use-TestEnvironment -Variables @{ IPE_SELFTEST_ROOT = $dir } -ScriptBlock {
            Invoke-IpePrivate -ScriptBlock { param($p) Import-IpeConfig -ConfigPath $p } -ArgumentList @($path)
        }

        Assert-Equal (Join-Path $dir 'secret\connection.txt') $config.Sql.ConnectionFile
        Assert-Equal @('Z') $config.DrivePool
        Assert-Equal 'Unit' $config.TestProjects[0].Name
        $relative = Invoke-IpePrivate -ScriptBlock { param($p) Import-IpeConfig -ConfigPath $p } -ArgumentList @((New-TestConfig -Directory $dir))
        Assert-Equal (Join-Path $dir 'connection.txt') $relative.Sql.ConnectionFile
    }
    finally
    {
        Remove-TempDir $dir
    }
}

function Test-ConfigValidationNamesTheBadKey
{
    Import-IpeForTest
    $dir = New-TempDir
    try
    {
        $missing = New-TestConfig -Directory $dir -Omit @('LogDir')
        Assert-Throws { Invoke-IpePrivate -ScriptBlock { param($p) Import-IpeConfig -ConfigPath $p } -ArgumentList @($missing) } -ErrorId 'Ipe.ConfigInvalid' -MessageLike "*missing key 'LogDir'*" | Out-Null
        $nested = New-TestConfig -Directory $dir -Overrides @{ TestProjects = "@(@{ Name = 'Unit'; Path = 'u.csproj'; NeedsSql = `$false; AllowEmpty = `$false })" }
        Assert-Throws { Invoke-IpePrivate -ScriptBlock { param($p) Import-IpeConfig -ConfigPath $p } -ArgumentList @($nested) } -ErrorId 'Ipe.ConfigInvalid' -MessageLike '*missing key ''TestProjects`[0`].Kind''*' | Out-Null
        $wrongType = New-TestConfig -Directory $dir -Overrides @{ SchemaVersion = "'one'" }
        Assert-Throws { Invoke-IpePrivate -ScriptBlock { param($p) Import-IpeConfig -ConfigPath $p } -ArgumentList @($wrongType) } -ErrorId 'Ipe.ConfigInvalid' -MessageLike "*'SchemaVersion' must be int*" | Out-Null
        $unknown = New-TestConfig -Directory $dir -Overrides @{ Typo = "'x'" }
        Assert-Throws { Invoke-IpePrivate -ScriptBlock { param($p) Import-IpeConfig -ConfigPath $p } -ArgumentList @($unknown) } -ErrorId 'Ipe.ConfigInvalid' -MessageLike "*unknown key 'Typo'*" | Out-Null
    }
    finally
    {
        Remove-TempDir $dir
    }
}

function Test-ConfigExtraChecksIsOptionalAndValidated
{
    Import-IpeForTest
    $dir = New-TempDir
    try
    {
        $absent = Invoke-IpePrivate -ScriptBlock { param($p) Import-IpeConfig -ConfigPath $p } -ArgumentList @((New-TestConfig -Directory $dir))
        Assert-Equal 0 @($absent.ExtraChecks).Count
        $valid = New-TestConfig -Directory $dir -Overrides @{ ExtraChecks = "@(@{ Name = 'hygiene'; Script = 'eng\hygiene.ps1' }, @{ Name = 'docs'; Script = 'eng\docs.ps1'; TimeoutSeconds = 30 })" }
        $loaded = Invoke-IpePrivate -ScriptBlock { param($p) Import-IpeConfig -ConfigPath $p } -ArgumentList @($valid)
        Assert-Equal @('hygiene', 'docs') @($loaded.ExtraChecks | ForEach-Object { $_.Name })
        Assert-Equal @('eng\hygiene.ps1', 'eng\docs.ps1') @($loaded.ExtraChecks | ForEach-Object { $_.Script })
        Assert-Equal @(300, 30) @($loaded.ExtraChecks | ForEach-Object { $_.TimeoutSeconds })
        $noScript = New-TestConfig -Directory $dir -Overrides @{ ExtraChecks = "@(@{ Name = 'hygiene' })" }
        Assert-Throws { Invoke-IpePrivate -ScriptBlock { param($p) Import-IpeConfig -ConfigPath $p } -ArgumentList @($noScript) } -ErrorId 'Ipe.ConfigInvalid' -MessageLike '*missing key ''ExtraChecks`[0`].Script''*' | Out-Null
        $duplicate = New-TestConfig -Directory $dir -Overrides @{ ExtraChecks = "@(@{ Name = 'hygiene'; Script = 'a.ps1' }, @{ Name = 'Hygiene'; Script = 'b.ps1' })" }
        Assert-Throws { Invoke-IpePrivate -ScriptBlock { param($p) Import-IpeConfig -ConfigPath $p } -ArgumentList @($duplicate) } -ErrorId 'Ipe.ConfigInvalid' -MessageLike '*''ExtraChecks`[1`].Name'' duplicates ''Hygiene''*' | Out-Null
    }
    finally
    {
        Remove-TempDir $dir
    }
}

function Test-ConfigResolvesFromMainCheckoutOfAWorktree
{
    Import-IpeForTest
    $repo = New-TempRepo
    $worktree = "$repo-wt"
    $outside = $null
    try
    {
        Write-TestBytes -Path (Join-Path $repo 'readme.md') -Text "x`n"
        New-TempCommit -Repo $repo -Message 'base'
        [void][System.IO.Directory]::CreateDirectory((Join-Path $repo '.kiro'))
        [void](New-TestConfig -Directory (Join-Path $repo '.kiro'))
        Invoke-TestGit -Repo $repo -Arguments @('worktree', 'add', '-q', '-b', 'feature', $worktree) | Out-Null
        $config = Use-TestEnvironment -Variables @{ IPE_CONFIG = $null } -ScriptBlock {
            Invoke-IpePrivate -ScriptBlock { param($w) Resolve-IpeConfig -Worktree $w } -ArgumentList @($worktree)
        }

        $expectedPath = Join-Path $repo '.kiro\implement-spec.psd1'
        Assert-True ($config.ConfigPath -ieq $expectedPath) "resolved $($config.ConfigPath), expected $expectedPath"
        $outside = New-TempDir
        Use-TestEnvironment -Variables @{ IPE_CONFIG = $null } -ScriptBlock {
            Assert-Throws { Invoke-IpePrivate -ScriptBlock { param($w) Resolve-IpeConfig -Worktree $w } -ArgumentList @($outside) } -ErrorId 'Ipe.ConfigNotFound' | Out-Null
        }
    }
    finally
    {
        if ($outside)
        {
            Remove-TempDir $outside
        }

        Remove-TempDir $worktree
        Remove-TempDir $repo
    }
}

function Test-DispatchSplitsCommaListsAndCoercesTypes
{
    Import-IpeForTest
    function global:Invoke-IpeDispatchProbe
    {
        param([string[]]$Only, [switch]$Fix, [switch]$Quiet, [int]$Count, [string]$Name)
    }

    try
    {
        $command = Get-Command Invoke-IpeDispatchProbe
        $splat = Invoke-IpePrivate -ScriptBlock { param($c, $a) ConvertTo-IpeSplat -Command $c -Arguments $a } -ArgumentList @($command, @('-Only', 'a,b', '-Fix', '-Count', '3', '-quiet', $false, '-Name', 'x,y'))
        Assert-Equal @('a', 'b') $splat['Only']
        Assert-True ($splat['Only'] -is [string[]]) 'Only is not a string[]'
        Assert-Equal $true $splat['Fix']
        Assert-Equal $false $splat['Quiet']
        Assert-Equal 3 $splat['Count']
        Assert-True ($splat['Count'] -is [int]) 'Count is not an int'
        Assert-Equal 'x,y' $splat['Name']
        Assert-Throws { Invoke-IpePrivate -ScriptBlock { param($c, $a) ConvertTo-IpeSplat -Command $c -Arguments $a } -ArgumentList @($command, @('-Bogus', '1')) } -ErrorId 'Ipe.BadArguments' -MessageLike '*unknown parameter -Bogus*' | Out-Null
    }
    finally
    {
        Remove-Item Function:\Invoke-IpeDispatchProbe -ErrorAction SilentlyContinue
    }
}

function Test-DispatchThroughPwshFileSplitsCommaList
{
    Import-IpeForTest
    $repo = New-TempRepo
    try
    {
        Write-TestBytes -Path (Join-Path $repo 'a.txt') -Text "needle a`n"
        Write-TestBytes -Path (Join-Path $repo 'b.txt') -Text "needle b`n"
        Write-TestBytes -Path (Join-Path $repo 'c.txt') -Text "needle c`n"
        $output = & $script:PwshPath -NoProfile -File $script:IpeEntryPath Search-Worktree -Worktree $repo -Pattern 'needle' -Path 'a.txt,b.txt'
        Assert-Equal 0 $LASTEXITCODE
        Assert-Equal @('a.txt:1:needle a', 'b.txt:1:needle b', 'matches: 2') @($output)
        $help = & $script:PwshPath -NoProfile -File $script:IpeEntryPath help
        Assert-Equal 0 $LASTEXITCODE
        Assert-True (@($help | Where-Object { $_ -like 'Use-Drive*' }).Count -ge 1) 'help does not list Use-Drive'
        & $script:PwshPath -NoProfile -File $script:IpeEntryPath Search-Worktree -Worktree $repo -Bogus x 2>$null | Out-Null
        Assert-Equal 1 $LASTEXITCODE
    }
    finally
    {
        Remove-TempDir $repo
    }
}

function Test-UseDriveMapsReusesConflictsAndUnmaps
{
    Import-IpeForTest
    $letter = @(Get-FreeTestDriveLetter)[0]
    $first = New-TempDir
    $second = New-TempDir
    try
    {
        $config = New-TestConfig -Directory $first -Overrides @{ DrivePool = "@('$letter')" }
        $mapped = Use-Drive -Worktree $first -ConfigPath $config
        Assert-Equal $letter $mapped.Drive
        Assert-Equal "${letter}:\" $mapped.Root
        Assert-Equal $true $mapped.Created
        Assert-True (Test-Path -LiteralPath "${letter}:\implement-spec.psd1") 'the mapped drive does not show the tree'
        $again = Use-Drive -Worktree $first -ConfigPath $config
        Assert-Equal $letter $again.Drive
        Assert-Equal $false $again.Created
        Assert-Throws { Use-Drive -Worktree $second -Drive $letter -ConfigPath $config } -ErrorId 'Ipe.DriveConflict' | Out-Null
        & $script:PwshPath -NoProfile -File $script:IpeEntryPath Use-Drive -Worktree $second -Drive $letter -ConfigPath $config 2>$null | Out-Null
        Assert-Equal 2 $LASTEXITCODE
        [void](Use-Drive -Worktree $second -Unmap -ConfigPath $config)
        Assert-True (Test-Path -LiteralPath "${letter}:\") 'unmapping another tree removed this mapping'
        [void](Use-Drive -Worktree $first -Unmap -ConfigPath $config)
        Assert-True (-not (Test-Path -LiteralPath "${letter}:\")) 'the mapping is still present after -Unmap'
    }
    finally
    {
        Remove-TestSubst -Letter $letter -Target $first
        Remove-TempDir $first
        Remove-TempDir $second
    }
}

function Test-UseDriveReturnsTheTreeWhenUseSubstIsOff
{
    Import-IpeForTest
    $dir = New-TempDir
    try
    {
        $config = New-TestConfig -Directory $dir -Overrides @{ UseSubst = '$false' }
        $before = @(& subst)
        $mapped = Use-Drive -Worktree $dir -ConfigPath $config
        Assert-Equal $null $mapped.Drive
        Assert-Equal (Get-Item -LiteralPath $dir).FullName.TrimEnd('\') $mapped.Root.TrimEnd('\')
        Assert-Equal $false $mapped.Created
        Assert-Equal $before @(& subst)
    }
    finally
    {
        Remove-TempDir $dir
    }
}

function Test-UseSqlScopesTheVariableAndNeverPrintsIt
{
    Import-IpeForTest
    $dir = New-TempDir
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try
    {
        $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        Write-TestBytes -Path (Join-Path $dir 'connection.txt') -Text "PLACEHOLDER-SECRET`n"
        $config = New-TestConfig -Directory $dir -SqlOverrides @{ Server = "'127.0.0.1,$port'" }
        Use-TestEnvironment -Variables @{ IPE_SELFTEST_SQL = $null } -ScriptBlock {
            $probe = @{}
            $output = Use-Sql -ConfigPath $config -ScriptBlock { $probe.Value = $env:IPE_SELFTEST_SQL; 'block ran' } *>&1
            Assert-True ($probe.Value -ceq 'PLACEHOLDER-SECRET') 'the block did not see the connection string'
            Assert-Equal $null ([System.Environment]::GetEnvironmentVariable('IPE_SELFTEST_SQL'))
            $text = $output | Out-String
            Assert-Contains $text 'block ran'
            Assert-NotContains $text 'PLACEHOLDER-SECRET'

            $caught = Assert-Throws { Use-Sql -ConfigPath $config -ScriptBlock { throw 'boom' } } -MessageLike 'boom'
            Assert-Equal $null ([System.Environment]::GetEnvironmentVariable('IPE_SELFTEST_SQL'))
            Assert-NotContains ($caught | Out-String) 'PLACEHOLDER-SECRET'

            $check = Use-Sql -Check -ConfigPath $config *>&1
            $checkText = $check | Out-String
            Assert-Equal @('sql: ready') @($check | ForEach-Object { $_.Report })
            Assert-NotContains $checkText 'PLACEHOLDER-SECRET'
            Assert-Equal $null ([System.Environment]::GetEnvironmentVariable('IPE_SELFTEST_SQL'))

            $missing = New-TestConfig -Directory $dir -SqlOverrides @{ Server = "'127.0.0.1,$port'"; ConnectionFile = "'absent.txt'" }
            Assert-Throws { Use-Sql -Check -ConfigPath $missing } -ErrorId 'Ipe.SqlConnectionFileMissing' | Out-Null
        }
    }
    finally
    {
        $listener.Stop()
        Remove-TempDir $dir
    }
}

function Test-StopTestHostsKillsProcessesOnTheDrive
{
    Import-IpeForTest
    $letter = @(Get-FreeTestDriveLetter)[0]
    $dir = New-TempDir
    $process = $null
    try
    {
        Write-TestBytes -Path (Join-Path $dir 'sleep.ps1') -Text "Start-Sleep -Seconds 120`n"
        $config = New-TestConfig -Directory $dir -Overrides @{ DrivePool = "@('$letter')" }
        [void](Use-Drive -Worktree $dir -ConfigPath $config)
        $process = Start-Process -FilePath $script:PwshPath -ArgumentList @('-NoProfile', '-File', "${letter}:\sleep.ps1") -PassThru -WindowStyle Hidden
        $listed = Stop-TestHosts -Drive $letter -ListOnly
        Assert-Contains @($listed.Processes | ForEach-Object { $_.ProcessId }) $process.Id
        Assert-Equal 0 $listed.Killed
        Start-Sleep -Milliseconds 500
        Assert-True (-not $process.HasExited) '-ListOnly killed the process'
        $stopped = Stop-TestHosts -Drive $letter
        Assert-True ($stopped.Killed -ge 1) 'nothing was killed'
        Assert-True ($process.WaitForExit(15000)) 'the process is still running'
    }
    finally
    {
        if ($process -and -not $process.HasExited)
        {
            $process.Kill($true)
            [void]$process.WaitForExit(10000)
        }

        Remove-TestSubst -Letter $letter -Target $dir
        Remove-TempDir $dir
    }
}
