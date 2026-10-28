# Checks: line endings, format, warnings wrapper, leaked-database cleanup app.

function Get-AutoCrlfEnvironment
{
    # core.autocrlf=true for child git processes only, through GIT_CONFIG_* variables (never git config files).
    return @{ GIT_CONFIG_COUNT = '1'; GIT_CONFIG_KEY_0 = 'core.autocrlf'; GIT_CONFIG_VALUE_0 = 'true'; IPE_CONFIG = $null }
}

function New-LineEndingRepo
{
    $repo = New-TempRepo
    Write-TestBytes -Path (Join-Path $repo 'src\Changed.cs') -Text "class A`r`n{`r`n}`r`n"
    Write-TestBytes -Path (Join-Path $repo 'src\Same.cs') -Text "class B`r`n{`r`n}`r`n"
    Write-TestBytes -Path (Join-Path $repo 'src\Bom.cs') -Text "class C`r`n{`r`n}`r`n" -Bom
    New-TempCommit -Repo $repo -Message 'base'
    return $repo
}

function Test-LineEndingsChecksTheChangedAndTheUntrackedFile
{
    Import-IpeForTest
    Use-TestEnvironment -Variables (Get-AutoCrlfEnvironment) -ScriptBlock {
        $repo = New-LineEndingRepo
        try
        {
            Write-TestBytes -Path (Join-Path $repo 'src\Changed.cs') -Text "class A`r`n{`r`n    int x;`r`n}`r`n"
            Write-TestBytes -Path (Join-Path $repo 'docs\New.md') -Text "# New`n"
            Write-TestBytes -Path (Join-Path $repo '.ipe-logs\run.ps1') -Text "'log dir'`n"
            $result = Test-LineEndings -Worktree $repo -Base HEAD
            Assert-Equal 0 $result.ExitCode
            Assert-Equal @('src/Changed.cs', 'docs/New.md') @($result.Files | ForEach-Object { $_.Path })
            Assert-Equal @('modified', 'untracked') @($result.Files | ForEach-Object { $_.State })
            Assert-Equal @('CRLF', 'LF') @($result.Files | ForEach-Object { $_.Style })
            Assert-Equal $true $result.AutoCrlf
            Assert-Contains ($result.Report -join "`n") 'core.autocrlf=true'
            Assert-Contains $result.Report 'line endings: pass'
        }
        finally
        {
            Remove-TempDir $repo
        }
    }
}

function Test-LineEndingsFailsOnMixedEndings
{
    Import-IpeForTest
    Use-TestEnvironment -Variables (Get-AutoCrlfEnvironment) -ScriptBlock {
        $repo = New-LineEndingRepo
        try
        {
            Write-TestBytes -Path (Join-Path $repo 'src\Changed.cs') -Text "class A`r`n{`n    int x;`r`n}`r`n"
            $result = Test-LineEndings -Worktree $repo -Base HEAD
            Assert-Equal 1 $result.ExitCode
            Assert-Equal 1 $result.Failures
            Assert-Contains $result.Report 'FAIL src/Changed.cs: mixed line endings (CRLF 3, LF 1)'
        }
        finally
        {
            Remove-TempDir $repo
        }
    }
}

function Test-LineEndingsFailsWhenTheBaseBomIsRemoved
{
    Import-IpeForTest
    Use-TestEnvironment -Variables (Get-AutoCrlfEnvironment) -ScriptBlock {
        $repo = New-LineEndingRepo
        try
        {
            Write-TestBytes -Path (Join-Path $repo 'src\Bom.cs') -Text "class C`r`n{`r`n    int y;`r`n}`r`n"
            $result = Test-LineEndings -Worktree $repo -Base HEAD
            Assert-Equal 1 $result.ExitCode
            Assert-Contains $result.Report 'FAIL src/Bom.cs: BOM removed (the base blob has a UTF-8 BOM)'
        }
        finally
        {
            Remove-TempDir $repo
        }
    }
}

function Test-LineEndingsFixMakesCrlfAndKeepsTheBom
{
    Import-IpeForTest
    Use-TestEnvironment -Variables (Get-AutoCrlfEnvironment) -ScriptBlock {
        $repo = New-LineEndingRepo
        try
        {
            $path = Join-Path $repo 'src\Bom.cs'
            Write-TestBytes -Path $path -Text "class C`r`n{`n    string s = `"`u{e9}`";`n}`r`n" -Bom
            $result = Test-LineEndings -Worktree $repo -Base HEAD -Fix
            Assert-Equal 0 $result.ExitCode
            Assert-Equal $true $result.Files[0].Fixed
            $bytes = [System.IO.File]::ReadAllBytes($path)
            Assert-Equal @(0xEF, 0xBB, 0xBF) @($bytes[0..2])
            Assert-Equal "class C`r`n{`r`n    string s = `"`u{e9}`";`r`n}`r`n" ([System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3))
            $again = Test-LineEndings -Worktree $repo -Base HEAD
            Assert-Equal 0 $again.ExitCode
        }
        finally
        {
            Remove-TempDir $repo
        }
    }
}

function Test-LineEndingsWarnsOnWholeFileRewrite
{
    Import-IpeForTest
    Use-TestEnvironment -Variables (Get-AutoCrlfEnvironment) -ScriptBlock {
        $repo = New-TempRepo
        try
        {
            $path = Join-Path $repo 'src\Long.cs'
            Write-TestBytes -Path $path -Text ((1..30 | ForEach-Object { "line $_" }) -join "`r`n")
            New-TempCommit -Repo $repo -Message 'base'
            Write-TestBytes -Path $path -Text ((1..30 | ForEach-Object { "other $_" }) -join "`r`n")
            $result = Test-LineEndings -Worktree $repo -Base HEAD
            Assert-Equal 0 $result.ExitCode
            Assert-Equal 1 $result.Warnings
            Assert-Contains $result.Report 'warn src/Long.cs: whole-file rewrite (deleted 30 of 30 base lines)'
        }
        finally
        {
            Remove-TempDir $repo
        }
    }
}

function Test-FormatWithNothingChangedPassesWithoutRunning
{
    Import-IpeForTest
    Use-TestEnvironment -Variables @{ IPE_CONFIG = $null } -ScriptBlock {
        $repo = New-TempRepo
        try
        {
            Write-TestBytes -Path (Join-Path $repo 'src\A.cs') -Text "class A { }`r`n"
            New-TempCommit -Repo $repo -Message 'base'
            Write-TestBytes -Path (Join-Path $repo 'notes.md') -Text "not code`n"
            $config = New-TestConfig -Directory $repo
            $result = Invoke-Format -Worktree $repo -Base HEAD -ConfigPath $config
            Assert-Equal 0 $result.ExitCode
            Assert-Equal @('format: nothing to format') $result.Report
        }
        finally
        {
            Remove-TempDir $repo
        }
    }
}

function Test-FormatExclusionsFilterByPathSuffixAndDiagnostic
{
    Import-IpeForTest
    $report = @'
[
  { "FileName": "Context.cs", "FilePath": "/root/src/Data/Context.cs",
    "FileChanges": [ { "LineNumber": 10, "CharNumber": 5, "DiagnosticId": "CS8618", "FormatDescription": "nullable" },
                     { "LineNumber": 12, "CharNumber": 1, "DiagnosticId": "WHITESPACE", "FormatDescription": "Fix whitespace" } ] },
  { "FileName": "Other.cs", "FilePath": "/root/src/Other.cs",
    "FileChanges": [ { "LineNumber": 3, "CharNumber": 1, "DiagnosticId": "CS8618", "FormatDescription": "nullable" } ] }
]
'@ | ConvertFrom-Json
    $exclusions = @(@{ Path = 'src\Data\Context.cs'; Code = 'CS8618' })
    $remaining = & (Get-Module ipe) { param($r, $e) Select-IpeFormatChanges -Report $r -Exclusions $e } @($report) $exclusions
    Assert-Equal @('WHITESPACE', 'CS8618') @($remaining | ForEach-Object { $_.DiagnosticId })
    Assert-Equal @('/root/src/Data/Context.cs', '/root/src/Other.cs') @($remaining | ForEach-Object { $_.FilePath })
}

function New-WarningsTree
{
    $tree = New-TempDir
    $script = @'
param([string]$BuildLog, [string]$Baseline, [string]$RepoRoot)
[ordered]@{ BuildLog = $BuildLog; Baseline = $Baseline; RepoRoot = $RepoRoot } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'args.json')
'fake warnings: compared'
exit ([int](Get-Content -LiteralPath (Join-Path $PSScriptRoot 'exit.txt')))
'@
    Write-TestBytes -Path (Join-Path $tree 'eng\check-warnings.ps1') -Text $script
    return $tree
}

function Test-CompareWarningsPassesArgumentsAndExitCode
{
    Import-IpeForTest
    $tree = New-WarningsTree
    try
    {
        $config = New-TestConfig -Directory $tree
        $log = Join-Path $tree 'build.log'
        Write-TestBytes -Path (Join-Path $tree 'eng\exit.txt') -Text '0'
        $pass = Compare-Warnings -Worktree $tree -BuildLog $log -ConfigPath $config
        Assert-Equal 0 $pass.ExitCode
        Assert-Contains $pass.Report 'fake warnings: compared'
        Assert-Contains $pass.Report 'warnings: pass'
        $recorded = Get-Content -LiteralPath (Join-Path $tree 'eng\args.json') -Raw | ConvertFrom-Json
        Assert-Equal $log $recorded.BuildLog
        Assert-Equal (Join-Path $tree 'eng\warnings-baseline.txt') $recorded.Baseline
        Assert-Equal $tree $recorded.RepoRoot

        Write-TestBytes -Path (Join-Path $tree 'eng\exit.txt') -Text '1'
        $root = Join-Path $tree 'root'
        $fail = Compare-Warnings -Worktree $tree -BuildLog $log -RepoRoot $root -ConfigPath $config
        Assert-Equal 1 $fail.ExitCode
        Assert-Equal 1 $fail.ScriptExitCode
        Assert-Contains $fail.Report 'warnings: FAIL (exit 1)'
        Assert-Equal $root (Get-Content -LiteralPath (Join-Path $tree 'eng\args.json') -Raw | ConvertFrom-Json).RepoRoot
    }
    finally
    {
        Remove-TempDir $tree
    }
}

function Test-CompareWarningsThrowsWhenTheScriptIsMissing
{
    Import-IpeForTest
    $tree = New-TempDir
    try
    {
        $config = New-TestConfig -Directory $tree
        Assert-Throws { Compare-Warnings -Worktree $tree -BuildLog (Join-Path $tree 'build.log') -ConfigPath $config } -ErrorId 'Ipe.WarningsScriptMissing' -MessageLike '*check-warnings.ps1*' | Out-Null
    }
    finally
    {
        Remove-TempDir $tree
    }
}

function Invoke-CleanupApp
{
    param([Parameter(Mandatory)][string[]]$Arguments)

    return & (Get-Module ipe) {
        param($appArguments)
        $app = Get-IpeCleanupAppPath
        Invoke-IpeProcess -FilePath 'dotnet' -ArgumentList ([string[]](@('run', '--file', $app, '--') + $appArguments)) -WorkingDirectory ([System.IO.Path]::GetDirectoryName($app)) -TimeoutSeconds 600
    } $Arguments
}

function Test-CleanupAppRefusesANonLoopbackServerWithoutConnecting
{
    Import-IpeForTest
    $remote = 'Server=10.0.0.5,1433;Database=master;User ID=PLACEHOLDER;Password=PLACEHOLDER-SECRET;Connect Timeout=60'
    Use-TestEnvironment -Variables @{ IPE_SELFTEST_CLEANUP = $remote } -ScriptBlock {
        $result = Invoke-CleanupApp -Arguments @('--env', 'IPE_SELFTEST_CLEANUP', '--server', '10.0.0.5,1433', '--pattern', '^contoso_')
        Assert-Equal 1 $result.ExitCode
        Assert-Contains $result.StdOut 'refusing: not the configured loopback server'
        Assert-NotContains ($result.StdOut + $result.StdErr) 'PLACEHOLDER-SECRET'
        Assert-NotContains $result.StdOut 'count='
    }

    $otherPort = 'Server=127.0.0.1,1433;Database=master;User ID=PLACEHOLDER;Password=PLACEHOLDER-SECRET'
    Use-TestEnvironment -Variables @{ IPE_SELFTEST_CLEANUP = $otherPort } -ScriptBlock {
        $result = Invoke-CleanupApp -Arguments @('--env', 'IPE_SELFTEST_CLEANUP', '--server', '127.0.0.1,1', '--pattern', '^contoso_')
        Assert-Equal 1 $result.ExitCode
        Assert-Contains $result.StdOut 'refusing: not the configured loopback server'
    }
}

function Test-CleanupAppExitsTwoWhenTheVariableIsMissing
{
    Import-IpeForTest
    Use-TestEnvironment -Variables @{ IPE_SELFTEST_CLEANUP = $null } -ScriptBlock {
        $result = Invoke-CleanupApp -Arguments @('--env', 'IPE_SELFTEST_CLEANUP', '--server', '127.0.0.1,1', '--pattern', '^contoso_')
        Assert-Equal 2 $result.ExitCode
        Assert-Contains $result.StdErr 'environment variable IPE_SELFTEST_CLEANUP is not set'
    }
}
