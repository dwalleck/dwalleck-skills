#Requires -Version 7.2
# Entry point: pwsh -NoProfile -File ipe.ps1 <Command> -Name value [-Switch] ...
# Exit codes: 0 pass, 1 fail or error, 2 drive conflict (Ipe.DriveConflict), 3 merge conflict (Ipe.MergeConflict, merge
# left in progress) or rebase conflict (Ipe.RebaseConflict, rebase aborted, branches unchanged).
# Plain $args, not a param block: [Parameter] attributes would make this an advanced script, and PowerShell would bind
# a command's parameter against this script's common parameters first (-Out is ambiguous with -OutVariable/-OutBuffer).
$Command = if ($args.Count -gt 0) { [string]$args[0] } else { $null }
$Rest = if ($args.Count -gt 1) { [object[]]$args[1..($args.Count - 1)] } else { $null }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$FormatEnumerationLimit = -1

$module = Import-Module (Join-Path $PSScriptRoot 'ipe.psm1') -Force -DisableNameChecking -PassThru
if (-not $Command -or $Command -in @('help', '-h', '--help', '-?', '/?'))
{
    & $module { Get-IpeHelp } | ForEach-Object { Write-Output $_ }
    exit 0
}

if ($null -eq $Rest)
{
    $Rest = @()
}

try
{
    $commandInfo = Get-Command -Module $module.Name -Name $Command -CommandType Function -ErrorAction SilentlyContinue
    if (-not $commandInfo)
    {
        [Console]::Error.WriteLine("unknown command '$Command'; run 'ipe.ps1 help'")
        exit 1
    }

    $splat = & $module { param($target, $arguments) ConvertTo-IpeSplat -Command $target -Arguments $arguments } $commandInfo $Rest
    $results = @(& $commandInfo @splat)
    $exitCode = 0
    foreach ($result in $results)
    {
        if ($null -eq $result)
        {
            continue
        }

        if ($result -is [string] -or $result.GetType().IsPrimitive)
        {
            Write-Output $result
            continue
        }

        $properties = $result.PSObject.Properties
        if ($properties['Report'])
        {
            foreach ($line in @($result.Report))
            {
                Write-Output $line
            }
        }
        else
        {
            $result | Format-List | Out-String -Width 4096 | ForEach-Object { Write-Output $_.TrimEnd() }
        }

        if ($properties['ExitCode'] -and $null -ne $result.ExitCode)
        {
            $exitCode = [int]$result.ExitCode
        }
    }

    exit $exitCode
}
catch
{
    $errorId = & $module { param($record) Get-IpeErrorId -ErrorRecord $record } $_
    [Console]::Error.WriteLine("error: $($_.Exception.Message)")
    switch ($errorId)
    {
        'Ipe.DriveConflict'
        {
            exit 2
        }
        'Ipe.MergeConflict'
        {
            exit 3
        }
        'Ipe.RebaseConflict'
        {
            exit 3
        }
        default
        {
            exit 1
        }
    }
}
