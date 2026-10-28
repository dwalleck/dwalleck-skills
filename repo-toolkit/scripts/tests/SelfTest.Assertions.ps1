# Assertions and fixtures shared by the self-tests. Dot-sourced by Run-SelfTests.ps1.
Set-StrictMode -Version Latest

$script:ScriptsRoot = Split-Path -Parent $PSScriptRoot
$script:IpeModulePath = Join-Path $script:ScriptsRoot 'ipe.psm1'
$script:IpeEntryPath = Join-Path $script:ScriptsRoot 'ipe.ps1'
$script:FixturesRoot = Join-Path $PSScriptRoot 'fixtures'
$script:PwshPath = (Get-Process -Id $PID).Path
$script:TestGitTimeoutSeconds = 120

function Import-IpeForTest
{
    Import-Module $script:IpeModulePath -Force -DisableNameChecking -Global
}

function Invoke-IpePrivate
{
    # Runs a script block inside the module so private helpers can be exercised directly.
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock, [object[]]$ArgumentList = @())

    $module = Get-Module ipe
    return & $module $ScriptBlock @ArgumentList
}

function Format-TestValue
{
    param([AllowNull()][object]$Value)

    if ($null -eq $Value)
    {
        return '<null>'
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string])
    {
        return '@(' + ((@($Value) | ForEach-Object { Format-TestValue $_ }) -join ', ') + ')'
    }

    return "'$Value'"
}

function Assert-Equal
{
    param(
        [AllowNull()][object]$Expected,
        [AllowNull()][object]$Actual,
        [string]$Message = ''
    )

    $expectedIsList = $Expected -is [System.Collections.IEnumerable] -and $Expected -isnot [string]
    $actualIsList = $Actual -is [System.Collections.IEnumerable] -and $Actual -isnot [string]
    $equal = $true
    if ($expectedIsList -or $actualIsList)
    {
        $left = @($Expected)
        $right = @($Actual)
        if ($left.Count -ne $right.Count)
        {
            $equal = $false
        }
        else
        {
            for ($i = 0; $i -lt $left.Count; $i++)
            {
                if (-not ($left[$i] -ceq $right[$i]))
                {
                    $equal = $false
                    break
                }
            }
        }
    }
    elseif ($null -eq $Expected -or $null -eq $Actual)
    {
        $equal = ($null -eq $Expected -and $null -eq $Actual)
    }
    else
    {
        # -ceq converts the right side to the left side's type, so 'x' would equal $true; booleans compare as booleans.
        $bothBool = $Expected -is [bool] -and $Actual -is [bool]
        $equal = if ($Expected -is [bool] -or $Actual -is [bool]) { $bothBool -and $Expected -eq $Actual } else { $Expected -ceq $Actual }
    }

    if (-not $equal)
    {
        throw "Assert-Equal failed${Message}: expected $(Format-TestValue $Expected), actual $(Format-TestValue $Actual)"
    }
}

function Assert-True
{
    param([bool]$Condition, [string]$Message = 'condition was false')

    if (-not $Condition)
    {
        throw "Assert-True failed: $Message"
    }
}

function Assert-Throws
{
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$ErrorId,
        [string]$MessageLike
    )

    $caught = $null
    try
    {
        & $ScriptBlock | Out-Null
    }
    catch
    {
        $caught = $_
    }

    if (-not $caught)
    {
        throw 'Assert-Throws failed: nothing was thrown'
    }

    if ($ErrorId)
    {
        $id = $caught.Exception.Data['IpeErrorId']
        if (-not $id)
        {
            $id = ($caught.FullyQualifiedErrorId -split ',')[0]
        }

        if ($id -ne $ErrorId)
        {
            throw "Assert-Throws failed: expected error id '$ErrorId', got '$id' ($($caught.Exception.Message))"
        }
    }

    if ($MessageLike -and $caught.Exception.Message -notlike $MessageLike)
    {
        throw "Assert-Throws failed: message '$($caught.Exception.Message)' is not like '$MessageLike'"
    }

    return $caught
}

function Assert-Contains
{
    # A string haystack is searched for the needle as an ordinal substring; a collection must hold an equal element.
    param([AllowNull()][object]$Haystack, [Parameter(Mandatory)][object]$Needle, [string]$Message = '')

    if ($Haystack -is [string])
    {
        $found = $Haystack.Contains([string]$Needle, [System.StringComparison]::Ordinal)
    }
    else
    {
        $found = @(@($Haystack) | Where-Object { $_ -ceq $Needle }).Count -gt 0
    }

    if (-not $found)
    {
        throw "Assert-Contains failed${Message}: $(Format-TestValue $Needle) not in $(Format-TestValue $Haystack)"
    }
}

function Assert-NotContains
{
    param([AllowNull()][object]$Haystack, [Parameter(Mandatory)][object]$Needle, [string]$Message = '')

    if ($Haystack -is [string])
    {
        $found = $Haystack.Contains([string]$Needle, [System.StringComparison]::Ordinal)
    }
    else
    {
        $found = @(@($Haystack) | Where-Object { $_ -ceq $Needle }).Count -gt 0
    }

    if ($found)
    {
        throw "Assert-NotContains failed${Message}: $(Format-TestValue $Needle) was found"
    }
}

function New-TempDir
{
    $path = Join-Path ([System.IO.Path]::GetTempPath()) "ipe-selftest-$([guid]::NewGuid().ToString('N'))"
    [void][System.IO.Directory]::CreateDirectory($path)
    return $path
}

function Remove-TempDir
{
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path))
    {
        return
    }

    for ($attempt = 1; $attempt -le 5; $attempt++)
    {
        try
        {
            Remove-Item -LiteralPath $Path -Recurse -Force
            return
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException]
        {
            Start-Sleep -Milliseconds (200 * $attempt)
        }
    }

    Write-Warning "could not remove $Path"
}

function Use-TestEnvironment
{
    # Sets process environment variables for the block and restores the previous values afterwards.
    param([Parameter(Mandatory)][hashtable]$Variables, [Parameter(Mandatory)][scriptblock]$ScriptBlock)

    $previous = @{}
    foreach ($name in $Variables.Keys)
    {
        $previous[$name] = [System.Environment]::GetEnvironmentVariable($name, 'Process')
        Set-TestVariable -Name $name -Value $Variables[$name]
    }

    try
    {
        & $ScriptBlock
    }
    finally
    {
        foreach ($name in $previous.Keys)
        {
            Set-TestVariable -Name $name -Value $previous[$name]
        }
    }
}

function Set-TestVariable
{
    # A null or empty value removes the variable; PowerShell would otherwise pass $null to .NET as ''.
    param([Parameter(Mandatory)][string]$Name, [AllowNull()][string]$Value)

    if ([string]::IsNullOrEmpty($Value))
    {
        Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
    }
    else
    {
        [System.Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
    }
}

function Get-TestGitIdentity
{
    # Commit identity for throwaway repos, passed only through environment variables (never git config).
    return @{
        GIT_AUTHOR_NAME = 'Self Test'
        GIT_AUTHOR_EMAIL = 'selftest@example.invalid'
        GIT_COMMITTER_NAME = 'Self Test'
        GIT_COMMITTER_EMAIL = 'selftest@example.invalid'
    }
}

function Invoke-TestGit
{
    # Runs git through the module's Invoke-IpeProcess, so a hung call is killed with its process tree at the timeout.
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string[]]$Arguments)

    if (-not (Get-Module ipe))
    {
        Import-IpeForTest
    }

    $allArguments = [string[]](@('-c', 'core.longpaths=true', '-C', $Repo) + $Arguments)
    $result = Invoke-IpePrivate -ScriptBlock {
        param([string[]]$GitArguments, [string]$Directory, [int]$Timeout)
        Invoke-IpeProcess -FilePath 'git' -ArgumentList $GitArguments -WorkingDirectory $Directory -TimeoutSeconds $Timeout -Environment @{ GIT_TERMINAL_PROMPT = '0' }
    } -ArgumentList @($allArguments, $Repo, $script:TestGitTimeoutSeconds)
    if ($result.TimedOut)
    {
        throw "git $($Arguments -join ' ') timed out after $($script:TestGitTimeoutSeconds) s"
    }

    if ($result.ExitCode -ne 0)
    {
        throw "git $($Arguments -join ' ') failed ($($result.ExitCode)): $($result.StdErr.Trim()) $($result.StdOut.Trim())"
    }

    if ([string]::IsNullOrEmpty($result.StdOut))
    {
        return
    }

    return ($result.StdOut -replace '\r?\n\z', '') -split '\r?\n'
}

function New-TempRepo
{
    # Creates a throwaway repo under TEMP with branch main. Callers commit inside Use-TestEnvironment (Get-TestGitIdentity).
    $path = New-TempDir
    Invoke-TestGit -Repo $path -Arguments @('init', '-q', '-b', 'main') | Out-Null
    return $path
}

function New-TempCommit
{
    param([Parameter(Mandatory)][string]$Repo, [string]$Message = 'test commit')

    Use-TestEnvironment -Variables (Get-TestGitIdentity) -ScriptBlock {
        Invoke-TestGit -Repo $Repo -Arguments @('add', '-A') | Out-Null
        Invoke-TestGit -Repo $Repo -Arguments @('-c', 'commit.gpgsign=false', 'commit', '-q', '-m', $Message) | Out-Null
    }
}

function Write-TestBytes
{
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text, [switch]$Bom)

    $directory = Split-Path -Parent $Path
    [void][System.IO.Directory]::CreateDirectory($directory)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    if ($Bom)
    {
        $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + $bytes)
    }

    [System.IO.File]::WriteAllBytes($Path, [byte[]]$bytes)
}

function Get-FreeTestDriveLetter
{
    # A letter that is neither a real drive, a PowerShell drive nor a subst mapping. Searched from the end of the
    # alphabet so tests stay clear of the letters a repo config usually pools first.
    $used = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($drive in [System.IO.DriveInfo]::GetDrives())
    {
        [void]$used.Add($drive.Name.Substring(0, 1))
    }

    foreach ($psDrive in Get-PSDrive -PSProvider FileSystem)
    {
        if ($psDrive.Name.Length -eq 1)
        {
            [void]$used.Add($psDrive.Name)
        }
    }

    foreach ($line in (& subst))
    {
        if ($line -match '^([A-Za-z]):')
        {
            [void]$used.Add($Matches[1])
        }
    }

    $free = @(foreach ($code in 90..68)
        {
            $letter = [string][char]$code
            if (-not $used.Contains($letter))
            {
                $letter
            }
        })

    if ($free.Count -eq 0)
    {
        throw 'no free drive letter for the test'
    }

    return $free
}

function Remove-TestSubst
{
    # Backstop for drive tests: removes a mapping of the letter only when it points at the test directory.
    param([string]$Letter, [string]$Target)

    if (-not $Letter)
    {
        return
    }

    foreach ($line in (& subst))
    {
        if ($line -match "^${Letter}:\\: => (.+)$" -and $Matches[1].TrimEnd('\') -ieq $Target.TrimEnd('\'))
        {
            & subst "${Letter}:" /d | Out-Null
        }
    }
}

function New-TestConfig
{
    # Writes a valid config file into Directory and returns its path. Overrides replace top-level keys; SqlOverrides
    # replace keys of the Sql section. Values are PowerShell data-file literals.
    param(
        [Parameter(Mandatory)][string]$Directory,
        [hashtable]$Overrides = @{},
        [hashtable]$SqlOverrides = @{},
        [string[]]$Omit = @()
    )

    $sql = [ordered]@{
        EnvVar = "'IPE_SELFTEST_SQL'"
        ConnectionFile = "'connection.txt'"
        Server = "'127.0.0.1,1'"
        StartCommand = "@('pwsh', '-NoProfile', '-Command', 'exit 0')"
        LeakedDatabasePattern = "'^contoso_[0-9a-f]{32}$'"
    }
    foreach ($key in $SqlOverrides.Keys)
    {
        $sql[$key] = $SqlOverrides[$key]
    }

    $sqlText = '@{ ' + (($sql.Keys | ForEach-Object { "$_ = $($sql[$_])" }) -join '; ') + ' }'
    $values = [ordered]@{
        SchemaVersion = '1'
        Solution = "'src\Contoso.sln'"
        SourcePaths = "@('src', 'tests')"
        LogDir = "'.ipe-logs'"
        WorktreeDir = "'.worktrees'"
        DrivePool = "@('Z')"
        MutationSpecDir = "'.scratch\{feature}\mutations'"
        UseSubst = '$true'
        TestProjects = "@(@{ Name = 'Unit'; Path = 'tests\Contoso.Tests\Contoso.Tests.csproj'; Kind = 'tunit'; NeedsSql = `$false; AllowEmpty = `$false })"
        Sql = $sqlText
        FormatExclusions = '@()'
        Warnings = "@{ Script = 'eng\check-warnings.ps1'; Baseline = 'eng\warnings-baseline.txt' }"
        Commit = "@{ Types = @('feat', 'fix'); DenyNames = @('HANDOFF.md'); DenySegments = @('.vs') }"
        Timeouts = '@{ BuildSeconds = 60; XunitSeconds = 60; TunitSeconds = 60; TunitInner = ''1m''; FormatSeconds = 60; GitSeconds = 60; SubstSeconds = 30; SqlStartSeconds = 30; SqlProbeSeconds = 5; CleanupSeconds = 300; FocusedSeconds = 60; MutationHangSeconds = 30 }'
    }
    foreach ($key in $Overrides.Keys)
    {
        $values[$key] = $Overrides[$key]
    }

    foreach ($key in $Omit)
    {
        $values.Remove($key)
    }

    $lines = @('@{') + @($values.Keys | ForEach-Object { "    $_ = $($values[$_])" }) + @('}')
    $path = Join-Path $Directory 'implement-spec.psd1'
    [System.IO.File]::WriteAllText($path, ($lines -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
    return $path
}
