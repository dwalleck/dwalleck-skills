#requires -Version 7
<#
.SYNOPSIS
    Builds and runs the TUnit assertion behaviour probe against one TUnit version and diffs
    the outcomes against the recorded baseline.

.DESCRIPTION
    Copies scripts/probe to a scratch directory (never builds inside the skill folder), builds it
    with -p:TUnitVersion=<Version>, runs it, and prints one line per probe:
    "<id> <description> => PASS" or "=> FAIL <exception type> :: <message>".
    Then compares PASS/FAIL per probe id with references/probe-baseline.txt and lists every probe
    whose outcome differs. A difference means a claim in SKILL.md does not hold for that version.

.PARAMETER Version
    TUnit package version to probe, e.g. 1.65.63. Take it from the project's csproj or
    Directory.Packages.props.

.PARAMETER WorkDir
    Scratch directory for the copy, build output and logs. Must not be inside a project whose
    Directory.Build.props would apply; the copied probe carries its own empty one to stop the walk.

.PARAMETER TimeoutMinutes
    Passed to the TUnit runner as --timeout so a hang fails instead of stalling. Default 5.
#>
param(
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [string] $WorkDir,
    [int] $TimeoutMinutes = 5
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$source = Join-Path $PSScriptRoot 'probe'
$baseline = Join-Path $skillRoot 'references\probe-baseline.txt'

$target = Join-Path $WorkDir ('tunit-probe-' + $Version)
if (Test-Path $target) { Remove-Item -Recurse -Force $target }
New-Item -ItemType Directory -Path $target | Out-Null
Copy-Item -Path (Join-Path $source '*') -Destination $target -Recurse

$proj = Join-Path $target 'AssertionProbe.csproj'
$buildLog = Join-Path $target 'build.log'
$runLog = Join-Path $target 'run.log'

dotnet build $proj -nologo ('-p:TUnitVersion=' + $Version) > $buildLog 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Output ('BUILD FAILED for TUnit ' + $Version + ' (exit ' + $LASTEXITCODE + '). Errors:')
    Select-String -Path $buildLog -Pattern ': error ' | ForEach-Object { $_.Line.Trim() } | Sort-Object -Unique
    Write-Output 'A compile error names an API the probe uses that this version lacks. Report it; do not treat the probe as passed.'
    exit 1
}

dotnet run --project $proj --no-build ('-p:TUnitVersion=' + $Version) -- --no-ansi --no-progress --timeout ($TimeoutMinutes.ToString() + 'm') > $runLog 2>&1
$runExit = $LASTEXITCODE
Select-String -Path $runLog -Pattern 'total:|failed:|succeeded:|skipped:' | ForEach-Object { $_.Line.Trim() }
if ($runExit -ne 0) {
    Write-Output ('RUN FAILED (exit ' + $runExit + '); see ' + $runLog)
    exit 1
}

$resultFile = Get-ChildItem -Path (Join-Path $target 'bin') -Recurse -Filter probe-results.txt | Select-Object -First 1
if ($null -eq $resultFile) {
    Write-Output 'No probe-results.txt was written; the probes did not run. Do not report the probe as passed.'
    exit 1
}

$actual = Get-Content $resultFile.FullName | Sort-Object
Write-Output ('--- TUnit ' + $Version + ' results (' + $actual.Count + ' probes) ---')
$actual

function Get-Outcomes([string[]] $lines) {
    $map = @{}
    foreach ($line in $lines) {
        if ($line -match '^(\w+) .*? => (PASS|FAIL)') { $map[$Matches[1]] = $Matches[2] }
    }
    return $map
}

$expected = Get-Outcomes (Get-Content $baseline | Where-Object { $_ -and -not $_.StartsWith('#') })
$got = Get-Outcomes $actual
$diffs = foreach ($id in ($expected.Keys + $got.Keys | Sort-Object -Unique)) {
    if ($expected[$id] -ne $got[$id]) { '{0}: baseline {1}, TUnit {2} {3}' -f $id, $expected[$id], $Version, $got[$id] }
}
Write-Output '--- Differences from references/probe-baseline.txt ---'
if ($diffs) { $diffs } else { 'none' }
