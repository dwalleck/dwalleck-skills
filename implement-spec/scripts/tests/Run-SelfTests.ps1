#Requires -Version 7.2
# Runs every Test-* function defined in the *.Tests.ps1 files next to this script.
# Usage: pwsh -NoProfile -File Run-SelfTests.ps1 [-Name <wildcard>]   (exit 0 = all selected tests passed)
param([string]$Name = '*')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'SelfTest.Assertions.ps1')
$testFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' | Sort-Object Name)
foreach ($testFile in $testFiles)
{
    . $testFile.FullName
}

$filePaths = @($testFiles | ForEach-Object { $_.FullName })
$tests = @(Get-ChildItem Function:\Test-* |
        Where-Object { $_.ScriptBlock.File -in $filePaths -and $_.Name -like $Name } |
        Sort-Object { $filePaths.IndexOf($_.ScriptBlock.File) }, { $_.ScriptBlock.StartPosition.StartLine })

if ($tests.Count -eq 0)
{
    Write-Output "no tests match '$Name'"
    exit 1
}

$passed = 0
$failed = [System.Collections.Generic.List[string]]::new()
$total = [System.Diagnostics.Stopwatch]::StartNew()
foreach ($test in $tests)
{
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try
    {
        $null = & $test.Name
        $passed++
        Write-Output ('PASS {0} ({1:N1}s)' -f $test.Name, $watch.Elapsed.TotalSeconds)
    }
    catch
    {
        $failed.Add($test.Name)
        $where = ($_.ScriptStackTrace -split "`n" | Select-Object -First 1)
        Write-Output ('FAIL {0} ({1:N1}s): {2}' -f $test.Name, $watch.Elapsed.TotalSeconds, $_.Exception.Message)
        Write-Output "     at $where"
    }
}

Write-Output ('total {0}, passed {1}, failed {2} ({3:N0}s)' -f $tests.Count, $passed, $failed.Count, $total.Elapsed.TotalSeconds)
if ($failed.Count -gt 0)
{
    Write-Output "failed: $($failed -join ', ')"
    exit 1
}

exit 0
