#Requires -Version 7.2
# repo-toolkit: one module for a repo's build, test, check and git chores.
# Every external process goes through Invoke-IpeProcess and every git call through Invoke-Git. Repo-specific values
# come only from the repo's config file (see Import-IpeConfig); nothing here names a repo or a machine.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModuleRoot = $PSScriptRoot
$script:AnsiPattern = '\x1b\[[0-9;?]*[ -/]*[@-~]'
$script:DefaultGitSeconds = 120
$script:DefaultLogDir = '.ipe-logs'
$script:StreamDrainMilliseconds = 30000
$script:ChildEnvironment = [ordered]@{
    MSBUILDTERMINALLOGGER = 'off'
    NO_COLOR = '1'
    DOTNET_NOLOGO = '1'
}
$script:TextExtensions = @(
    '.cs', '.csproj', '.props', '.targets', '.sln', '.json', '.md', '.yml', '.yaml',
    '.ps1', '.psm1', '.psd1', '.xml', '.config', '.editorconfig'
)
$script:TunitSummaryFields = @{ total = 'Total'; failed = 'Failed'; succeeded = 'Succeeded'; skipped = 'Skipped' }

# Config schema: key -> type. 'string[]+' and 'table[]+' must be non-empty; a trailing '?' marks an optional key.
$script:ConfigSchema = [ordered]@{
    SchemaVersion = 'int'
    Solution = 'string'
    SourcePaths = 'string[]+'
    LogDir = 'string'
    WorktreeDir = 'string'
    DrivePool = 'string[]+'
    MutationSpecDir = 'string'
    UseSubst = 'bool'
    TestProjects = 'table[]+'
    Sql = 'table'
    FormatExclusions = 'table[]'
    Warnings = 'table'
    Commit = 'table'
    Timeouts = 'table'
    ExtraChecks = 'table[]?'
}
$script:TestProjectSchema = [ordered]@{ Name = 'string'; Path = 'string'; Kind = 'string'; NeedsSql = 'bool'; AllowEmpty = 'bool' }
$script:SqlSchema = [ordered]@{ EnvVar = 'string'; ConnectionFile = 'string'; Server = 'string'; StartCommand = 'string[]+'; LeakedDatabasePattern = 'string' }
$script:FormatExclusionSchema = [ordered]@{ Path = 'string'; Code = 'string' }
$script:WarningsSchema = [ordered]@{ Script = 'string'; Baseline = 'string' }
$script:CommitSchema = [ordered]@{ Types = 'string[]+'; DenyNames = 'string[]'; DenySegments = 'string[]' }
$script:ExtraCheckSchema = [ordered]@{ Name = 'string'; Script = 'string'; TimeoutSeconds = 'int?' }
$script:DefaultExtraCheckSeconds = 300
$script:TimeoutsSchema = [ordered]@{
    BuildSeconds = 'int'; XunitSeconds = 'int'; TunitSeconds = 'int'; TunitInner = 'string'; FormatSeconds = 'int'
    GitSeconds = 'int'; SubstSeconds = 'int'; SqlStartSeconds = 'int'; SqlProbeSeconds = 'int'; CleanupSeconds = 'int'
    FocusedSeconds = 'int'; MutationHangSeconds = 'int'
}
# Default config file names under <main repo root>\.kiro, newest first; the second is the pre-repo-toolkit name.
$script:ConfigFileNames = @('repo-toolkit.psd1', 'implement-spec.psd1')
# A base config's local overlay is its sibling <stem>.local.psd1. It may set only these machine keys: a $null value
# is a top-level key typed by $script:ConfigSchema, a schema is a section whose listed keys may be set.
$script:OverlaySuffix = '.local.psd1'
$script:OverlayKeys = [ordered]@{
    UseSubst = $null
    DrivePool = $null
    Sql = [ordered]@{ ConnectionFile = $script:SqlSchema.ConnectionFile; Server = $script:SqlSchema.Server; StartCommand = $script:SqlSchema.StartCommand }
    Timeouts = $script:TimeoutsSchema
}

# Private helpers ---------------------------------------------------------------------------------------------------

function New-IpeErrorRecord
{
    param(
        [Parameter(Mandatory)][string]$ErrorId,
        [Parameter(Mandatory)][string]$Message,
        [System.Management.Automation.ErrorCategory]$Category = [System.Management.Automation.ErrorCategory]::InvalidOperation,
        [object]$Target
    )

    $exception = [System.InvalidOperationException]::new($Message)
    $exception.Data['IpeErrorId'] = $ErrorId
    return [System.Management.Automation.ErrorRecord]::new($exception, $ErrorId, $Category, $Target)
}

function Get-IpeErrorId
{
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $id = $ErrorRecord.Exception.Data['IpeErrorId']
    if ($id)
    {
        return [string]$id
    }

    return ($ErrorRecord.FullyQualifiedErrorId -split ',')[0]
}

function Assert-IpeAbsolutePath
{
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Path]::IsPathFullyQualified($Path))
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.RelativePath' -Message "-$Name must be an absolute path: '$Path'" -Category InvalidArgument)
    }
}

function Get-IpeNormalPath
{
    param([Parameter(Mandatory)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length)
    {
        $full = $full.TrimEnd([char[]]@('\', '/'))
    }

    return $full
}

function Test-IpeSamePath
{
    param([string]$Left, [string]$Right)

    if (-not $Left -or -not $Right)
    {
        return $false
    }

    return [string]::Equals((Get-IpeNormalPath $Left), (Get-IpeNormalPath $Right), [System.StringComparison]::OrdinalIgnoreCase)
}

function Split-IpeLines
{
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text))
    {
        return , [string[]]@()
    }

    $lines = [string[]]($Text -split "`r?`n")
    if ($lines.Count -gt 0 -and $lines[-1] -eq '')
    {
        $lines = [string[]]($lines | Select-Object -SkipLast 1)
    }

    return , $lines
}

function Split-IpeNul
{
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text))
    {
        return , [string[]]@()
    }

    return , [string[]]@($Text.Split([char]0) | Where-Object { $_ -ne '' })
}

function Join-IpeTreePath
{
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Relative)

    if ([System.IO.Path]::IsPathFullyQualified($Relative))
    {
        return $Relative
    }

    $native = $Relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar).Replace('\', [System.IO.Path]::DirectorySeparatorChar)
    return [System.IO.Path]::Combine($Root, $native)
}

function Invoke-IpeProcess
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [AllowEmptyCollection()][string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][ValidateRange(1, 86400)][int]$TimeoutSeconds,
        [string]$LogPath,
        [hashtable]$Environment,
        [switch]$CaptureBytes
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($argument in $ArgumentList)
    {
        $startInfo.ArgumentList.Add($argument)
    }

    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($key in $script:ChildEnvironment.Keys)
    {
        $startInfo.Environment[$key] = $script:ChildEnvironment[$key]
    }

    if ($Environment)
    {
        foreach ($key in $Environment.Keys)
        {
            if ($null -eq $Environment[$key])
            {
                [void]$startInfo.Environment.Remove($key)
            }
            else
            {
                $startInfo.Environment[$key] = [string]$Environment[$key]
            }
        }
    }

    if ($LogPath)
    {
        $logDirectory = [System.IO.Path]::GetDirectoryName($LogPath)
        if ($logDirectory)
        {
            [void][System.IO.Directory]::CreateDirectory($logDirectory)
        }

        $outStream = [System.IO.FileStream]::new($LogPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $errStream = [System.IO.FileStream]::new("$LogPath.stderr", [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    }
    else
    {
        $outStream = [System.IO.MemoryStream]::new()
        $errStream = [System.IO.MemoryStream]::new()
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try
    {
        try
        {
            [void]$process.Start()
        }
        catch [System.ComponentModel.Win32Exception]
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.ProcessStartFailed' -Message "could not start '$FilePath': $($_.Exception.Message)" -Category ObjectNotFound)
        }

        $process.StandardInput.Close()
        $outTask = $process.StandardOutput.BaseStream.CopyToAsync($outStream)
        $errTask = $process.StandardError.BaseStream.CopyToAsync($errStream)
        $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut)
        {
            try
            {
                $process.Kill($true)
            }
            catch [System.InvalidOperationException], [System.ComponentModel.Win32Exception], [System.AggregateException]
            {
                Write-Verbose "kill after timeout: $($_.Exception.Message)"
            }

            [void]$process.WaitForExit(30000)
        }

        try
        {
            [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($outTask, $errTask), $script:StreamDrainMilliseconds)
        }
        catch [System.AggregateException]
        {
            Write-Verbose "output copy ended early: $($_.Exception.Message)"
        }

        $exitCode = if ($timedOut) { -1 } else { $process.ExitCode }
        $stopwatch.Stop()
        $stdOut = $null
        $stdErr = $null
        $bytes = $null
        if (-not $LogPath)
        {
            $outBytes = $outStream.ToArray()
            $stdOut = [System.Text.Encoding]::UTF8.GetString($outBytes)
            $stdErr = [System.Text.Encoding]::UTF8.GetString($errStream.ToArray())
            if ($CaptureBytes)
            {
                $bytes = $outBytes
            }
        }

        return [pscustomobject]@{
            ExitCode = $exitCode
            TimedOut = $timedOut
            ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
            LogPath = if ($LogPath) { $LogPath } else { $null }
            StdOut = $stdOut
            StdErr = $stdErr
            Bytes = $bytes
        }
    }
    finally
    {
        $process.Dispose()
        $outStream.Dispose()
        $errStream.Dispose()
    }
}

function Test-IpeConfigValue
{
    param([object]$Value, [string]$Type)

    $required = $Type.TrimEnd('?')
    $nonEmpty = $required.EndsWith('+')
    $baseType = $required.TrimEnd('+')
    switch ($baseType)
    {
        'int'
        {
            return ($Value -is [int])
        }
        'bool'
        {
            return ($Value -is [bool])
        }
        'string'
        {
            return ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value))
        }
        'table'
        {
            return ($Value -is [hashtable])
        }
        'string[]'
        {
            $items = @($Value)
            if ($nonEmpty -and $items.Count -eq 0)
            {
                return $false
            }

            foreach ($item in $items)
            {
                if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item))
                {
                    return $false
                }
            }

            return $true
        }
        'table[]'
        {
            $items = @($Value)
            if ($nonEmpty -and $items.Count -eq 0)
            {
                return $false
            }

            foreach ($item in $items)
            {
                if ($item -isnot [hashtable])
                {
                    return $false
                }
            }

            return $true
        }
    }

    throw [System.Diagnostics.UnreachableException]::new("unknown schema type $Type")
}

function Assert-IpeConfigSection
{
    param(
        [Parameter(Mandatory)][hashtable]$Table,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Schema,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Prefix,
        [Parameter(Mandatory)][string]$ConfigPath
    )

    foreach ($key in $Schema.Keys)
    {
        if (-not $Table.ContainsKey($key))
        {
            if ($Schema[$key].EndsWith('?'))
            {
                continue
            }

            throw (New-IpeErrorRecord -ErrorId 'Ipe.ConfigInvalid' -Message "config ${ConfigPath}: missing key '$Prefix$key'" -Category InvalidData)
        }

        if (-not (Test-IpeConfigValue -Value $Table[$key] -Type $Schema[$key]))
        {
            $expected = $Schema[$key].TrimEnd('?').Replace('+', ' (non-empty)')
            throw (New-IpeErrorRecord -ErrorId 'Ipe.ConfigInvalid' -Message "config ${ConfigPath}: key '$Prefix$key' must be $expected" -Category InvalidData)
        }
    }

    foreach ($key in $Table.Keys)
    {
        if (-not $Schema.Contains($key))
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.ConfigInvalid' -Message "config ${ConfigPath}: unknown key '$Prefix$key'" -Category InvalidData)
        }
    }
}

function Assert-IpeOverlay
{
    # A local overlay may set only machine values: the keys in $script:OverlayKeys, each with its base schema type.
    param([Parameter(Mandatory)][hashtable]$Overlay, [Parameter(Mandatory)][string]$OverlayPath)

    foreach ($key in $Overlay.Keys)
    {
        if (-not $script:OverlayKeys.Contains($key))
        {
            throw (New-IpeOverlayKeyError -OverlayPath $OverlayPath -Key $key)
        }

        $value = $Overlay[$key]
        $sectionSchema = $script:OverlayKeys[$key]
        if ($null -eq $sectionSchema)
        {
            Assert-IpeOverlayValue -OverlayPath $OverlayPath -Key $key -Value $value -Type $script:ConfigSchema[$key]
            continue
        }

        if ($value -isnot [hashtable])
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.ConfigInvalid' -Message "config overlay ${OverlayPath}: key '$key' must be table" -Category InvalidData)
        }

        foreach ($innerKey in $value.Keys)
        {
            if (-not $sectionSchema.Contains($innerKey))
            {
                throw (New-IpeOverlayKeyError -OverlayPath $OverlayPath -Key "$key.$innerKey")
            }

            Assert-IpeOverlayValue -OverlayPath $OverlayPath -Key "$key.$innerKey" -Value $value[$innerKey] -Type $sectionSchema[$innerKey]
        }
    }
}

function New-IpeOverlayKeyError
{
    param([Parameter(Mandatory)][string]$OverlayPath, [Parameter(Mandatory)][string]$Key)

    $allowed = 'UseSubst, DrivePool, Sql.ConnectionFile, Sql.Server, Sql.StartCommand, Timeouts.*'
    return (New-IpeErrorRecord -ErrorId 'Ipe.ConfigInvalid' -Message "config overlay ${OverlayPath}: key '$Key' may not be set in a local overlay (allowed: $allowed)" -Category InvalidData)
}

function Assert-IpeOverlayValue
{
    param([Parameter(Mandatory)][string]$OverlayPath, [Parameter(Mandatory)][string]$Key, [object]$Value, [Parameter(Mandatory)][string]$Type)

    if (-not (Test-IpeConfigValue -Value $Value -Type $Type))
    {
        $expected = $Type.TrimEnd('?').Replace('+', ' (non-empty)')
        throw (New-IpeErrorRecord -ErrorId 'Ipe.ConfigInvalid' -Message "config overlay ${OverlayPath}: key '$Key' must be $expected" -Category InvalidData)
    }
}

function Merge-IpeOverlay
{
    # Top-level overlay keys replace the base value; Sql and Timeouts merge per key, but only over a base section that
    # is a table, so the base validation still reports a missing or malformed section by its own key.
    param([Parameter(Mandatory)][hashtable]$Base, [Parameter(Mandatory)][hashtable]$Overlay)

    $merged = @{} + $Base
    foreach ($key in $Overlay.Keys)
    {
        if ($null -eq $script:OverlayKeys[$key])
        {
            $merged[$key] = $Overlay[$key]
            continue
        }

        if ($merged.ContainsKey($key) -and $merged[$key] -is [hashtable])
        {
            $section = @{} + $merged[$key]
            foreach ($innerKey in $Overlay[$key].Keys)
            {
                $section[$innerKey] = $Overlay[$key][$innerKey]
            }

            $merged[$key] = $section
        }
    }

    return $merged
}

function Import-IpeConfig
{
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath)

    Assert-IpeAbsolutePath -Path $ConfigPath -Name 'ConfigPath'
    if ($ConfigPath.EndsWith($script:OverlaySuffix, [System.StringComparison]::OrdinalIgnoreCase))
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.ConfigInvalid' -Message "config $ConfigPath is a local overlay; pass the base config" -Category InvalidArgument)
    }

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf))
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.ConfigNotFound' -Message "config file not found: $ConfigPath" -Category ObjectNotFound)
    }

    $data = Import-PowerShellDataFile -LiteralPath $ConfigPath
    $label = $ConfigPath
    $overlayPath = Get-IpeNormalPath ([System.IO.Path]::ChangeExtension($ConfigPath, $script:OverlaySuffix))
    if (Test-Path -LiteralPath $overlayPath -PathType Leaf)
    {
        $overlay = Import-PowerShellDataFile -LiteralPath $overlayPath
        Assert-IpeOverlay -Overlay $overlay -OverlayPath $overlayPath
        $data = Merge-IpeOverlay -Base $data -Overlay $overlay
        $label = "$ConfigPath (with overlay $overlayPath)"
    }
    else
    {
        $overlayPath = $null
    }

    Assert-IpeConfigSection -Table $data -Schema $script:ConfigSchema -Prefix '' -ConfigPath $label
    if ($data.SchemaVersion -ne 1)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.ConfigInvalid' -Message "config ${label}: key 'SchemaVersion' must be 1, found $($data.SchemaVersion)" -Category InvalidData)
    }

    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $index = 0
    foreach ($project in @($data.TestProjects))
    {
        Assert-IpeConfigSection -Table $project -Schema $script:TestProjectSchema -Prefix "TestProjects[$index]." -ConfigPath $label
        if ($project.Kind -notin @('xunit', 'tunit'))
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.ConfigInvalid' -Message "config ${label}: key 'TestProjects[$index].Kind' must be 'xunit' or 'tunit', found '$($project.Kind)'" -Category InvalidData)
        }

        if (-not $names.Add($project.Name))
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.ConfigInvalid' -Message "config ${label}: key 'TestProjects[$index].Name' duplicates '$($project.Name)'" -Category InvalidData)
        }

        $index++
    }

    foreach ($letter in @($data.DrivePool))
    {
        if ($letter -notmatch '^[A-Za-z]$')
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.ConfigInvalid' -Message "config ${label}: key 'DrivePool' entries must be single letters, found '$letter'" -Category InvalidData)
        }
    }

    Assert-IpeConfigSection -Table $data.Sql -Schema $script:SqlSchema -Prefix 'Sql.' -ConfigPath $label
    if ($data.Sql.Server -notmatch '^[^,]+,\d+$')
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.ConfigInvalid' -Message "config ${label}: key 'Sql.Server' must be 'host,port', found '$($data.Sql.Server)'" -Category InvalidData)
    }

    try
    {
        [void][regex]::new($data.Sql.LeakedDatabasePattern)
    }
    catch [System.ArgumentException]
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.ConfigInvalid' -Message "config ${label}: key 'Sql.LeakedDatabasePattern' is not a valid regex" -Category InvalidData)
    }

    $index = 0
    foreach ($exclusion in @($data.FormatExclusions))
    {
        Assert-IpeConfigSection -Table $exclusion -Schema $script:FormatExclusionSchema -Prefix "FormatExclusions[$index]." -ConfigPath $label
        $index++
    }

    Assert-IpeConfigSection -Table $data.Warnings -Schema $script:WarningsSchema -Prefix 'Warnings.' -ConfigPath $label
    Assert-IpeConfigSection -Table $data.Commit -Schema $script:CommitSchema -Prefix 'Commit.' -ConfigPath $label
    Assert-IpeConfigSection -Table $data.Timeouts -Schema $script:TimeoutsSchema -Prefix 'Timeouts.' -ConfigPath $label

    $extraChecks = [System.Collections.Generic.List[hashtable]]::new()
    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $index = 0
    $declaredChecks = if ($data.ContainsKey('ExtraChecks')) { @($data.ExtraChecks) } else { @() }
    foreach ($check in $declaredChecks)
    {
        Assert-IpeConfigSection -Table $check -Schema $script:ExtraCheckSchema -Prefix "ExtraChecks[$index]." -ConfigPath $label
        if (-not $names.Add($check.Name))
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.ConfigInvalid' -Message "config ${label}: key 'ExtraChecks[$index].Name' duplicates '$($check.Name)'" -Category InvalidData)
        }

        $timeout = if ($check.ContainsKey('TimeoutSeconds')) { $check.TimeoutSeconds } else { $script:DefaultExtraCheckSeconds }
        if ($timeout -lt 1)
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.ConfigInvalid' -Message "config ${label}: key 'ExtraChecks[$index].TimeoutSeconds' must be at least 1, found $timeout" -Category InvalidData)
        }

        $extraChecks.Add(@{ Name = $check.Name; Script = $check.Script; TimeoutSeconds = $timeout })
        $index++
    }

    $configDirectory = [System.IO.Path]::GetDirectoryName((Get-IpeNormalPath $ConfigPath))
    $connectionFile = [System.Environment]::ExpandEnvironmentVariables($data.Sql.ConnectionFile)
    if (-not [System.IO.Path]::IsPathFullyQualified($connectionFile))
    {
        $connectionFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($configDirectory, $connectionFile))
    }

    $sql = @{} + $data.Sql
    $sql.ConnectionFile = $connectionFile
    $sql.StartCommand = [string[]]@($data.Sql.StartCommand)

    $config = @{} + $data
    $config.SourcePaths = [string[]]@($data.SourcePaths)
    $config.DrivePool = [string[]]@($data.DrivePool | ForEach-Object { $_.ToUpperInvariant() })
    $config.TestProjects = @($data.TestProjects)
    $config.FormatExclusions = @($data.FormatExclusions)
    $config.ExtraChecks = $extraChecks.ToArray()
    $config.Sql = $sql
    $config.ConfigPath = Get-IpeNormalPath $ConfigPath
    $config.ConfigDirectory = $configDirectory
    $config.OverlayPath = $overlayPath
    return $config
}

function Get-IpeMainRepoRoot
{
    param([Parameter(Mandatory)][string]$Worktree)

    if (-not (Test-Path -LiteralPath $Worktree -PathType Container))
    {
        return $null
    }

    $result = Invoke-Git -Worktree $Worktree -Arguments @('rev-parse', '--path-format=absolute', '--git-common-dir') -AllowExitCodes @(0, 128)
    if ($result.ExitCode -ne 0 -or $result.Lines.Count -eq 0)
    {
        return $null
    }

    $commonDir = Get-IpeNormalPath $result.Lines[0]
    return [System.IO.Path]::GetDirectoryName($commonDir)
}

function Resolve-IpeConfig
{
    param([string]$Worktree, [string]$ConfigPath, [switch]$Optional)

    if ($ConfigPath)
    {
        return Import-IpeConfig -ConfigPath $ConfigPath
    }

    if ($env:IPE_CONFIG)
    {
        return Import-IpeConfig -ConfigPath $env:IPE_CONFIG
    }

    $candidates = @()
    if ($Worktree)
    {
        $root = Get-IpeMainRepoRoot -Worktree $Worktree
        if ($root)
        {
            $candidates = @($script:ConfigFileNames | ForEach-Object { Join-Path $root '.kiro' $_ })
            $found = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
            if ($found.Count -gt 1)
            {
                throw (New-IpeErrorRecord -ErrorId 'Ipe.ConfigAmbiguous' -Message "both $($found[0]) and $($found[1]) exist; delete one" -Category InvalidData)
            }

            if ($found.Count -eq 1)
            {
                return Import-IpeConfig -ConfigPath $found[0]
            }
        }
    }

    if ($Optional)
    {
        return $null
    }

    $looked = if ($candidates.Count -gt 0) { " (looked for $($candidates -join ' and '))" } else { '' }
    throw (New-IpeErrorRecord -ErrorId 'Ipe.ConfigNotFound' -Message "no config: pass -ConfigPath, set IPE_CONFIG, or create <main repo root>\.kiro\repo-toolkit.psd1 (or the older <main repo root>\.kiro\implement-spec.psd1)$looked" -Category ObjectNotFound)
}

function ConvertFrom-IpeBytes
{
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes, [Parameter(Mandatory)][string]$Path)

    if (($Bytes.Length -ge 2 -and (($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) -or ($Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF))) -or
        ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0 -and $Bytes[1] -eq 0 -and $Bytes[2] -eq 0xFE -and $Bytes[3] -eq 0xFF))
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.UnsupportedEncoding' -Message "$Path has a UTF-16 or UTF-32 byte order mark; only UTF-8 files are supported" -Category InvalidData)
    }

    $hasBom = $Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    $strict = [System.Text.UTF8Encoding]::new($false, $true)
    try
    {
        $text = $strict.GetString($Bytes, $offset, $Bytes.Length - $offset)
    }
    catch [System.Text.DecoderFallbackException]
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.UnsupportedEncoding' -Message "$Path is not valid UTF-8" -Category InvalidData)
    }

    $lf = $text.Length - $text.Replace("`n", '').Length
    $crlf = ($text.Length - $text.Replace("`r`n", '').Length) / 2
    $bareLf = $lf - $crlf
    $newline = if ($bareLf -gt $crlf) { "`n" } elseif ($crlf -gt 0) { "`r`n" } else { [System.Environment]::NewLine }
    return [pscustomobject]@{
        Path = $Path
        Bytes = $Bytes
        HasBom = $hasBom
        Text = $text
        Newline = $newline
        CrlfCount = [int]$crlf
        LfCount = [int]$bareLf
        IsMixed = ($crlf -gt 0 -and $bareLf -gt 0)
    }
}

function Read-IpeText
{
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return ConvertFrom-IpeBytes -Bytes $bytes -Path $Path
}

function Write-IpeText
{
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][bool]$HasBom
    )

    $body = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    if ($HasBom)
    {
        $body = [byte[]](@(0xEF, 0xBB, 0xBF) + $body)
    }

    [System.IO.File]::WriteAllBytes($Path, [byte[]]$body)
}

function ConvertTo-IpeNewline
{
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Newline)

    $normal = $Text.Replace("`r`n", "`n")
    if ($Newline -eq "`n")
    {
        return $normal
    }

    return $normal.Replace("`n", $Newline)
}

function ConvertTo-IpeDriveLetter
{
    param([Parameter(Mandatory)][string]$Drive)

    if ($Drive -notmatch '^([A-Za-z])(:\\?)?$')
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.BadDrive' -Message "not a drive letter: '$Drive'" -Category InvalidArgument)
    }

    return $Matches[1].ToUpperInvariant()
}

function Get-IpeSubstMap
{
    param([int]$TimeoutSeconds = 30)

    $result = Invoke-IpeProcess -FilePath 'subst' -WorkingDirectory ([System.IO.Path]::GetTempPath()) -TimeoutSeconds $TimeoutSeconds
    if ($result.TimedOut -or $result.ExitCode -ne 0)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.SubstFailed' -Message "subst failed (exit $($result.ExitCode)): $($result.StdErr)")
    }

    $map = @{}
    foreach ($line in (Split-IpeLines $result.StdOut))
    {
        if ($line -match '^([A-Za-z]):\\: => (.+)$')
        {
            $map[$Matches[1].ToUpperInvariant()] = $Matches[2].Trim()
        }
    }

    return $map
}

function Get-IpeUsedDriveLetters
{
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

    return , $used
}

function Get-IpeDriveForTree
{
    param([Parameter(Mandatory)][string]$Worktree, [int]$TimeoutSeconds = 30)

    if (-not $IsWindows)
    {
        return $null
    }

    $map = Get-IpeSubstMap -TimeoutSeconds $TimeoutSeconds
    foreach ($letter in ($map.Keys | Sort-Object))
    {
        if (Test-IpeSamePath $map[$letter] $Worktree)
        {
            return $letter
        }
    }

    return $null
}

function Invoke-IpeSubst
{
    param([Parameter(Mandatory)][string[]]$Arguments, [int]$TimeoutSeconds = 30)

    $result = Invoke-IpeProcess -FilePath 'subst' -ArgumentList $Arguments -WorkingDirectory ([System.IO.Path]::GetTempPath()) -TimeoutSeconds $TimeoutSeconds
    if ($result.TimedOut -or $result.ExitCode -ne 0)
    {
        $detail = ("$($result.StdOut) $($result.StdErr)").Trim()
        throw (New-IpeErrorRecord -ErrorId 'Ipe.SubstFailed' -Message "subst $($Arguments -join ' ') failed (exit $($result.ExitCode)): $detail")
    }
}

function Get-IpeSqlEndpoint
{
    param([Parameter(Mandatory)][string]$Server)

    $comma = $Server.LastIndexOf(',')
    return [pscustomobject]@{
        Host = $Server.Substring(0, $comma).Trim()
        Port = [int]::Parse($Server.Substring($comma + 1), [System.Globalization.CultureInfo]::InvariantCulture)
    }
}

function Test-IpeTcpPort
{
    param([Parameter(Mandatory)][string]$HostName, [Parameter(Mandatory)][int]$Port, [int]$TimeoutMilliseconds = 2000)

    $client = [System.Net.Sockets.TcpClient]::new()
    try
    {
        $task = $client.ConnectAsync($HostName, $Port)
        return ($task.Wait($TimeoutMilliseconds) -and $client.Connected)
    }
    catch [System.AggregateException], [System.Net.Sockets.SocketException]
    {
        return $false
    }
    finally
    {
        $client.Dispose()
    }
}

function Start-IpeSqlServer
{
    param([Parameter(Mandatory)][hashtable]$Config)

    $command = [string[]]$Config.Sql.StartCommand
    $arguments = [string[]]@($command | Select-Object -Skip 1)
    try
    {
        return Invoke-IpeProcess -FilePath $command[0] -ArgumentList $arguments -WorkingDirectory ([System.IO.Path]::GetTempPath()) -TimeoutSeconds $Config.Timeouts.SqlStartSeconds
    }
    catch
    {
        if ((Get-IpeErrorId $_) -ne 'Ipe.ProcessStartFailed')
        {
            throw
        }

        return [pscustomobject]@{ ExitCode = -1; TimedOut = $false; StdOut = ''; StdErr = $_.Exception.Message }
    }
}

# Build and test seams: the composite commands build and test only through these two functions, and the self-tests
# replace them in module scope. Invoke-IpeBuild builds a solution or project (Target, relative to Root) with the
# console log to LogPath and, with FileLogPath, a minimal MSBuild file log for the warnings check.
function Invoke-IpeBuild
{
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [switch]$NoIncremental,
        [string]$FileLogPath,
        [string[]]$ExtraArguments = @()
    )

    # -nodeReuse:false so a killed build leaves no MSBuild node processes behind.
    $arguments = [System.Collections.Generic.List[string]]@('build', (Join-IpeTreePath -Root $Root -Relative $Target), '-nodeReuse:false')
    if ($NoIncremental)
    {
        $arguments.Add('--no-incremental')
    }

    if ($FileLogPath)
    {
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($FileLogPath))
        $arguments.Add("-flp:LogFile=$FileLogPath;Verbosity=minimal")
    }

    $arguments.AddRange([string[]]$ExtraArguments)
    $process = Invoke-IpeProcess -FilePath 'dotnet' -ArgumentList $arguments.ToArray() -WorkingDirectory $Root -TimeoutSeconds $TimeoutSeconds -LogPath $LogPath
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        TimedOut = $process.TimedOut
        ElapsedSeconds = $process.ElapsedSeconds
        LogPath = $LogPath
        FileLogPath = if ($FileLogPath) { $FileLogPath } else { $null }
        Summary = Get-RunSummary -Path $LogPath -Kind msbuild
    }
}

# Runs one configured test project (a TestProjects row) and returns its run summary merged with the process result.
# InnerTimeout overrides the TUnit --timeout value; TrxPath asks for a TRX file at that path; Environment adds child
# environment variables.
function Invoke-IpeTestProject
{
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][hashtable]$Project,
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$LogPath,
        [string]$Filter,
        [switch]$NoBuild,
        [int]$TimeoutSeconds,
        [string]$InnerTimeout,
        [string]$TrxPath,
        [hashtable]$Environment
    )

    $projectPath = Join-IpeTreePath -Root $Root -Relative $Project.Path
    $trxDirectory = if ($TrxPath) { [System.IO.Path]::GetDirectoryName($TrxPath) } else { $null }
    $trxName = if ($TrxPath) { [System.IO.Path]::GetFileName($TrxPath) } else { $null }
    if ($Project.Kind -eq 'xunit')
    {
        $arguments = [System.Collections.Generic.List[string]]@('test', $projectPath)
        if ($NoBuild)
        {
            $arguments.Add('--no-build')
        }

        if ($Filter)
        {
            $arguments.AddRange([string[]]@('--filter', $Filter))
        }

        if ($TrxPath)
        {
            $arguments.AddRange([string[]]@('--logger', "trx;LogFileName=$trxName", '--results-directory', $trxDirectory))
        }

        if (-not $TimeoutSeconds)
        {
            $TimeoutSeconds = $Config.Timeouts.XunitSeconds
        }
    }
    else
    {
        $arguments = [System.Collections.Generic.List[string]]@('run', '--project', $projectPath)
        if ($NoBuild)
        {
            $arguments.Add('--no-build')
        }

        $inner = if ($InnerTimeout) { $InnerTimeout } else { $Config.Timeouts.TunitInner }
        $arguments.AddRange([string[]]@('--', '--no-ansi', '--no-progress', '--timeout', $inner))
        if ($Filter)
        {
            $arguments.AddRange([string[]]@('--treenode-filter', $Filter))
        }

        if ($TrxPath)
        {
            $arguments.AddRange([string[]]@('--report-trx', '--report-trx-filename', $trxName, '--results-directory', $trxDirectory))
        }

        if (-not $TimeoutSeconds)
        {
            $TimeoutSeconds = $Config.Timeouts.TunitSeconds
        }
    }

    $process = Invoke-IpeProcess -FilePath 'dotnet' -ArgumentList $arguments.ToArray() -WorkingDirectory $Root -TimeoutSeconds $TimeoutSeconds -LogPath $LogPath -Environment $Environment
    $summary = Get-RunSummary -Path $LogPath -Kind $Project.Kind
    return [pscustomobject]@{
        Project = $Project.Name
        ExitCode = $process.ExitCode
        TimedOut = $process.TimedOut
        ElapsedSeconds = $process.ElapsedSeconds
        LogPath = $LogPath
        Summary = $summary
    }
}

function Get-IpeCleanupAppPath
{
    $source = Join-Path $script:ModuleRoot 'cleanup-test-databases.cs'
    # Run from a directory with no Directory.Build.props or central package management above it, so the
    # file-based app builds the same way whichever repo the toolkit was copied into.
    $directory = Join-Path ([System.IO.Path]::GetTempPath()) 'ipe-cleanup-test-databases'
    [void][System.IO.Directory]::CreateDirectory($directory)
    $target = Join-Path $directory 'cleanup-test-databases.cs'
    $sourceBytes = [System.IO.File]::ReadAllBytes($source)
    $same = $false
    if (Test-Path -LiteralPath $target -PathType Leaf)
    {
        $targetBytes = [System.IO.File]::ReadAllBytes($target)
        $same = [System.Linq.Enumerable]::SequenceEqual($sourceBytes, $targetBytes)
    }

    if (-not $same)
    {
        [System.IO.File]::WriteAllBytes($target, $sourceBytes)
    }

    return $target
}

function Select-IpeFormatChanges
{
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Report,
        [AllowEmptyCollection()][object[]]$Exclusions = @()
    )

    $remaining = [System.Collections.Generic.List[object]]::new()
    foreach ($document in $Report)
    {
        $filePath = [string]$document.FilePath
        $normalFile = $filePath.Replace('\', '/')
        foreach ($change in @($document.FileChanges))
        {
            $excluded = $false
            foreach ($exclusion in $Exclusions)
            {
                $suffix = ([string]$exclusion.Path).Replace('\', '/')
                if ($normalFile.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase) -and
                    [string]::Equals([string]$change.DiagnosticId, [string]$exclusion.Code, [System.StringComparison]::OrdinalIgnoreCase))
                {
                    $excluded = $true
                    break
                }
            }

            if (-not $excluded)
            {
                $remaining.Add([pscustomobject]@{
                        FilePath = $filePath
                        Line = $change.LineNumber
                        DiagnosticId = $change.DiagnosticId
                        Description = $change.FormatDescription
                    })
            }
        }
    }

    return , $remaining.ToArray()
}

function Get-IpeChangedFiles
{
    # Files added or modified since Base (working tree vs Base) plus untracked files, as repo-relative paths.
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Base,
        [string[]]$Pathspec = @()
    )

    $tail = [System.Collections.Generic.List[string]]::new()
    if ($Pathspec.Count -gt 0)
    {
        $tail.Add('--')
        $tail.AddRange([string[]]@($Pathspec | ForEach-Object { $_.Replace('\', '/') }))
    }

    $diffArguments = [System.Collections.Generic.List[string]]@('diff', '--name-status', '--no-renames', '--diff-filter=AM', '-z', $Base)
    $diffArguments.AddRange($tail)
    $diff = Invoke-Git -Worktree $Worktree -Arguments $diffArguments.ToArray()
    $tokens = Split-IpeNul $diff.StdOut
    $files = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    for ($i = 0; $i + 1 -lt $tokens.Count; $i += 2)
    {
        if ($seen.Add($tokens[$i + 1]))
        {
            $files.Add([pscustomobject]@{ Path = $tokens[$i + 1]; State = if ($tokens[$i] -eq 'M') { 'modified' } else { 'added' } })
        }
    }

    $untrackedArguments = [System.Collections.Generic.List[string]]@('ls-files', '--others', '--exclude-standard', '--full-name', '-z')
    $untrackedArguments.AddRange($tail)
    $untracked = Invoke-Git -Worktree $Worktree -Arguments $untrackedArguments.ToArray()
    foreach ($path in (Split-IpeNul $untracked.StdOut))
    {
        if ($seen.Add($path))
        {
            $files.Add([pscustomobject]@{ Path = $path; State = 'untracked' })
        }
    }

    # Unrolled on purpose: callers pipe the result, so each file must be its own pipeline object.
    return $files.ToArray()
}

function Get-IpeTopLevel
{
    param([Parameter(Mandatory)][string]$Worktree)

    $result = Invoke-Git -Worktree $Worktree -Arguments @('rev-parse', '--show-toplevel')
    return Get-IpeNormalPath $result.Lines[0]
}

function ConvertTo-IpeArgumentValue
{
    param([Parameter(Mandatory)][type]$Type, [AllowNull()][object]$Value, [Parameter(Mandatory)][string]$Name)

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $text = [string]$Value
    if ($Type -eq [string[]])
    {
        return , [string[]]@($text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    }

    if ($Type -eq [int[]])
    {
        return , [int[]]@($text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | ForEach-Object { [int]::Parse($_, $invariant) })
    }

    if ($Type -eq [int])
    {
        return [int]::Parse($text, $invariant)
    }

    if ($Type -eq [bool])
    {
        if ($Value -is [bool])
        {
            return $Value
        }

        return [bool]::Parse($text.TrimStart('$'))
    }

    if ($Type -eq [string])
    {
        return $text
    }

    throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message "-$Name of type $($Type.Name) cannot be passed on the command line" -Category InvalidArgument)
}

# Turns 'ipe.ps1 <Command> -Name value -Switch' arguments into a splat for the command. pwsh -File hands a comma list
# over as one string, so every [string[]] / [int[]] parameter value is split on commas here.
function ConvertTo-IpeSplat
{
    param(
        [Parameter(Mandatory)][System.Management.Automation.CommandInfo]$Command,
        [AllowNull()][AllowEmptyCollection()][object[]]$Arguments = @()
    )

    $splat = @{}
    if ($null -eq $Arguments)
    {
        return $splat
    }

    $i = 0
    while ($i -lt $Arguments.Count)
    {
        $token = $Arguments[$i]
        if ($token -isnot [string] -or $token -notmatch '^-([A-Za-z][A-Za-z0-9]*)(?::(.*))?$')
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message "unexpected argument '$token' for $($Command.Name): pass -Name value pairs" -Category InvalidArgument)
        }

        $name = $Matches[1]
        $inline = if ($Matches.ContainsKey(2) -and $Matches[2] -ne '') { $Matches[2] } else { $null }
        $key = $Command.Parameters.Keys | Where-Object { $_ -ieq $name } | Select-Object -First 1
        if (-not $key)
        {
            $valid = ($Command.Parameters.Keys | Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters } | ForEach-Object { "-$_" }) -join ' '
            throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message "unknown parameter -$name for $($Command.Name); valid: $valid" -Category InvalidArgument)
        }

        $type = $Command.Parameters[$key].ParameterType
        $i++
        if ($type -eq [switch])
        {
            if ($null -ne $inline)
            {
                $splat[$key] = [bool]::Parse($inline.TrimStart('$'))
            }
            elseif ($i -lt $Arguments.Count -and $Arguments[$i] -is [bool])
            {
                $splat[$key] = $Arguments[$i]
                $i++
            }
            else
            {
                $splat[$key] = $true
            }

            continue
        }

        if ($null -ne $inline)
        {
            $value = $inline
        }
        elseif ($i -lt $Arguments.Count)
        {
            $value = $Arguments[$i]
            $i++
        }
        else
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message "-$key needs a value" -Category InvalidArgument)
        }

        $splat[$key] = ConvertTo-IpeArgumentValue -Type $type -Value $value -Name $key
    }

    return $splat
}

function Get-IpeHelp
{
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('usage: pwsh -NoProfile -File ipe.ps1 <Command> -Name value [-Switch] ...')
    $lines.Add('comma lists are split for [string[]] parameters; exit 0 pass, 1 fail, 2 drive conflict, 3 merge conflict (merge left in progress) or rebase conflict (rebase aborted, branches unchanged)')
    $lines.Add('')
    foreach ($command in (Get-Command -Module $ExecutionContext.SessionState.Module.Name -CommandType Function | Sort-Object Name))
    {
        foreach ($syntax in (Split-IpeLines (Get-Command $command.Name -Syntax | Out-String)))
        {
            if ($syntax.Trim())
            {
                $lines.Add($syntax.Trim().Replace(' [<CommonParameters>]', ''))
            }
        }
    }

    return , $lines.ToArray()
}

# Public commands ---------------------------------------------------------------------------------------------------

function Invoke-Git
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds,
        [int[]]$AllowExitCodes = @(0),
        [switch]$Bytes,
        [hashtable]$Environment,
        [string]$ConfigPath
    )

    Assert-IpeAbsolutePath -Path $Worktree -Name 'Worktree'
    if (-not $PSBoundParameters.ContainsKey('TimeoutSeconds'))
    {
        $TimeoutSeconds = if ($ConfigPath) { (Import-IpeConfig -ConfigPath $ConfigPath).Timeouts.GitSeconds } else { $script:DefaultGitSeconds }
    }

    $gitEnvironment = @{ GIT_TERMINAL_PROMPT = '0' }
    if ($Environment)
    {
        foreach ($key in $Environment.Keys)
        {
            $gitEnvironment[$key] = $Environment[$key]
        }
    }

    $allArguments = [string[]](@('-c', 'core.longpaths=true', '-C', $Worktree) + $Arguments)
    $result = Invoke-IpeProcess -FilePath 'git' -ArgumentList $allArguments -WorkingDirectory $Worktree -TimeoutSeconds $TimeoutSeconds -Environment $gitEnvironment -CaptureBytes:$Bytes
    if ($result.TimedOut)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.GitTimeout' -Message "git $($Arguments -join ' ') timed out after $TimeoutSeconds s in $Worktree" -Category OperationTimeout)
    }

    if ($result.ExitCode -notin $AllowExitCodes)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.GitFailed' -Message "git $($Arguments -join ' ') exited $($result.ExitCode) in ${Worktree}: $($result.StdErr.Trim())")
    }

    $lines = Split-IpeLines $result.StdOut
    return [pscustomobject]@{
        ExitCode = $result.ExitCode
        StdOut = $result.StdOut
        StdErr = $result.StdErr
        Lines = $lines
        Bytes = $result.Bytes
        Report = $lines
    }
}

function Search-Worktree
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Pattern,
        [string[]]$Path = @(),
        [switch]$Fixed,
        [switch]$IgnoreCase,
        [string]$ConfigPath
    )

    $arguments = [System.Collections.Generic.List[string]]@('grep', '-n', '-I', '--untracked', '--no-color')
    $arguments.Add($(if ($Fixed) { '-F' } else { '-E' }))
    if ($IgnoreCase)
    {
        $arguments.Add('-i')
    }

    $arguments.AddRange([string[]]@('-e', $Pattern))
    if ($Path.Count -gt 0)
    {
        $arguments.Add('--')
        $arguments.AddRange($Path)
    }

    $result = Invoke-Git -Worktree $Worktree -Arguments $arguments.ToArray() -AllowExitCodes @(0, 1)
    $hits = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $result.Lines)
    {
        if ($line -match '^(.*?):(\d+):(.*)$')
        {
            $hits.Add([pscustomobject]@{ Path = $Matches[1]; Line = [int]$Matches[2]; Text = $Matches[3] })
        }
    }

    $report = [System.Collections.Generic.List[string]]::new()
    $report.AddRange([string[]]$result.Lines)
    $report.Add($(if ($hits.Count -eq 0) { 'no matches' } else { "matches: $($hits.Count)" }))
    return [pscustomobject]@{
        ExitCode = 0
        Hits = $hits.ToArray()
        Report = $report.ToArray()
    }
}

function Edit-File
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Find,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Replace,
        [Parameter(Mandatory)][int]$ExpectCount,
        [int]$Occurrence,
        [string]$ConfigPath
    )

    Assert-IpeAbsolutePath -Path $Path -Name 'Path'
    if ($ExpectCount -lt 1)
    {
        throw [System.ArgumentOutOfRangeException]::new('ExpectCount', $ExpectCount, 'ExpectCount must be at least 1.')
    }

    $hasOccurrence = $PSBoundParameters.ContainsKey('Occurrence')
    if ($hasOccurrence -and ($Occurrence -lt 1 -or $Occurrence -gt $ExpectCount))
    {
        throw [System.ArgumentOutOfRangeException]::new('Occurrence', $Occurrence, "Occurrence must be between 1 and ExpectCount ($ExpectCount).")
    }

    $info = Read-IpeText -Path $Path
    $findText = ConvertTo-IpeNewline -Text $Find -Newline $info.Newline
    $replaceText = ConvertTo-IpeNewline -Text $Replace -Newline $info.Newline
    $text = $info.Text
    $positions = [System.Collections.Generic.List[int]]::new()
    $index = 0
    while (($index = $text.IndexOf($findText, $index, [System.StringComparison]::Ordinal)) -ge 0)
    {
        $positions.Add($index)
        $index += $findText.Length
    }

    if ($positions.Count -ne $ExpectCount)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.MatchCount' -Message "Edit-File ${Path}: expected $ExpectCount match(es), found $($positions.Count); file left unchanged" -Category InvalidData -Target $Path)
    }

    $selected = if ($hasOccurrence) { [int[]]@($positions[$Occurrence - 1]) } else { $positions.ToArray() }
    $selected = [int[]]@($selected)
    $builder = [System.Text.StringBuilder]::new($text.Length)
    $cursor = 0
    foreach ($position in $selected)
    {
        [void]$builder.Append($text, $cursor, $position - $cursor)
        [void]$builder.Append($replaceText)
        $cursor = $position + $findText.Length
    }

    [void]$builder.Append($text, $cursor, $text.Length - $cursor)
    Write-IpeText -Path $Path -Text $builder.ToString() -HasBom $info.HasBom
    return [pscustomobject]@{
        ExitCode = 0
        Path = $Path
        OriginalBytes = $info.Bytes
        Matches = $positions.Count
        Replaced = $selected.Count
        Report = [string[]]@("edited ${Path}: replaced $($selected.Count) of $($positions.Count) match(es)")
    }
}

function Get-RunSummary
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('auto', 'tunit', 'xunit', 'msbuild')][string]$Kind = 'auto',
        [string]$ConfigPath
    )

    $text = [regex]::Replace([System.IO.File]::ReadAllText($Path), $script:AnsiPattern, '')
    $lines = Split-IpeLines $text
    $xunitPattern = '(Passed|Failed)!\s+-\s+Failed:\s+(\d+),\s+Passed:\s+(\d+),\s+Skipped:\s+(\d+),\s+Total:\s+(\d+)'
    if ($Kind -eq 'auto')
    {
        $Kind = if ($text -match '(?m)^Test run summary:' -or $text.Contains('Zero tests ran')) { 'tunit' }
        elseif ($text -match $xunitPattern -or $text.Contains('No test is available')) { 'xunit' }
        elseif ($text -match '(?m)^\s*\d+ (Warning|Error)\(s\)' -or $text -match '(?m)^\s*Build (FAILED|succeeded)') { 'msbuild' }
        else { 'unknown' }
    }

    $summary = [ordered]@{
        Kind = $Kind; Found = $false; Total = 0; Failed = 0; Succeeded = 0; Skipped = 0
        FailedNames = [string[]]@(); ZeroTests = $false; Warnings = 0; Errors = 0; BuildFailed = $false
    }
    $names = [System.Collections.Generic.List[string]]::new()
    switch ($Kind)
    {
        'tunit'
        {
            $last = -1
            for ($i = 0; $i -lt $lines.Count; $i++)
            {
                if ($lines[$i].StartsWith('Test run summary:', [System.StringComparison]::Ordinal))
                {
                    $last = $i
                }
            }

            if ($last -ge 0)
            {
                $summary.Found = $true
                for ($i = $last + 1; $i -lt $lines.Count; $i++)
                {
                    if ($lines[$i] -match '^\s+(total|failed|succeeded|skipped):\s*(\d+)')
                    {
                        $field = $script:TunitSummaryFields[$Matches[1]]
                        $summary[$field] = [int]$Matches[2]
                    }
                    elseif ($lines[$i] -notmatch '^\s')
                    {
                        break
                    }
                }
            }

            foreach ($line in $lines)
            {
                if ($line -match '^failed (.+) \(([^()]*)\)\s*$' -and -not $names.Contains($Matches[1]))
                {
                    $names.Add($Matches[1])
                }
            }

            if ($text.Contains('Zero tests ran'))
            {
                $summary.ZeroTests = $true
                $summary.Found = $true
            }
        }
        'xunit'
        {
            foreach ($line in $lines)
            {
                if ($line -match $xunitPattern)
                {
                    $summary.Found = $true
                    $summary.Failed += [int]$Matches[2]
                    $summary.Succeeded += [int]$Matches[3]
                    $summary.Skipped += [int]$Matches[4]
                    $summary.Total += [int]$Matches[5]
                }
                elseif ($line -match '^\s+Failed (\S+) \[' -and -not $names.Contains($Matches[1]))
                {
                    $names.Add($Matches[1])
                }
            }

            if ($text.Contains('No test is available'))
            {
                $summary.ZeroTests = $true
                $summary.Found = $true
            }
        }
        'msbuild'
        {
            foreach ($line in $lines)
            {
                if ($line -match '^\s*(\d+) Warning\(s\)')
                {
                    $summary.Found = $true
                    $summary.Warnings = [int]$Matches[1]
                }
                elseif ($line -match '^\s*(\d+) Error\(s\)')
                {
                    $summary.Found = $true
                    $summary.Errors = [int]$Matches[1]
                }
                elseif ($line -match '^\s*Build FAILED')
                {
                    $summary.Found = $true
                    $summary.BuildFailed = $true
                }
            }
        }
    }

    $summary.FailedNames = $names.ToArray()
    return [pscustomobject]$summary
}

function Use-Drive
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [string]$Drive,
        [switch]$Unmap,
        [string]$ConfigPath
    )

    Assert-IpeAbsolutePath -Path $Worktree -Name 'Worktree'
    $tree = Get-IpeNormalPath $Worktree
    if (-not $IsWindows)
    {
        return [pscustomobject]@{ ExitCode = 0; Drive = $null; Root = $tree; Created = $false; Report = [string[]]@("no drive mapping on this OS; using $tree") }
    }

    $config = Resolve-IpeConfig -Worktree $tree -ConfigPath $ConfigPath
    if (-not $config.UseSubst -and -not $Unmap)
    {
        # A tree at a short path builds in place; UseSubst = $false turns the mapping off.
        return [pscustomobject]@{ ExitCode = 0; Drive = $null; Root = $tree; Created = $false; Report = [string[]]@("UseSubst is off; using $tree") }
    }

    $timeout = $config.Timeouts.SubstSeconds
    $map = Get-IpeSubstMap -TimeoutSeconds $timeout
    $requested = if ($Drive) { ConvertTo-IpeDriveLetter $Drive } else { $null }
    $mine = @($map.Keys | Where-Object { Test-IpeSamePath $map[$_] $tree } | Sort-Object)

    if ($Unmap)
    {
        $targets = @($mine | Where-Object { -not $requested -or $_ -eq $requested })
        foreach ($letter in $targets)
        {
            Invoke-IpeSubst -Arguments @("${letter}:", '/d') -TimeoutSeconds $timeout
        }

        $removed = if ($targets.Count -gt 0) { "removed $(($targets | ForEach-Object { "${_}:" }) -join ', ')" } else { 'nothing mapped to this tree' }
        return [pscustomobject]@{ ExitCode = 0; Drive = $null; Root = $tree; Created = $false; Report = [string[]]@("unmap ${tree}: $removed") }
    }

    if ($requested)
    {
        if ($map.ContainsKey($requested))
        {
            if (Test-IpeSamePath $map[$requested] $tree)
            {
                return [pscustomobject]@{ ExitCode = 0; Drive = $requested; Root = "${requested}:\"; Created = $false; Report = [string[]]@("drive ${requested}: -> $tree (reused)") }
            }

            throw (New-IpeErrorRecord -ErrorId 'Ipe.DriveConflict' -Message "drive ${requested}: already maps $($map[$requested]), not $tree" -Category ResourceExists)
        }

        if ((Get-IpeUsedDriveLetters).Contains($requested))
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.DriveConflict' -Message "drive ${requested}: is a real or mapped drive, not a subst mapping" -Category ResourceExists)
        }

        $letter = $requested
    }
    else
    {
        if ($mine.Count -gt 0)
        {
            return [pscustomobject]@{ ExitCode = 0; Drive = $mine[0]; Root = "$($mine[0]):\"; Created = $false; Report = [string[]]@("drive $($mine[0]): -> $tree (reused)") }
        }

        $used = Get-IpeUsedDriveLetters
        $letter = $config.DrivePool | Where-Object { -not $map.ContainsKey($_) -and -not $used.Contains($_) } | Select-Object -First 1
        if (-not $letter)
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.NoFreeDrive' -Message "no free drive letter in DrivePool ($($config.DrivePool -join ' '))" -Category ResourceUnavailable)
        }
    }

    Invoke-IpeSubst -Arguments @("${letter}:", $tree) -TimeoutSeconds $timeout
    $after = Get-IpeSubstMap -TimeoutSeconds $timeout
    if (-not ($after.ContainsKey($letter) -and (Test-IpeSamePath $after[$letter] $tree)))
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.SubstFailed' -Message "subst ${letter}: $tree did not take effect")
    }

    return [pscustomobject]@{ ExitCode = 0; Drive = $letter; Root = "${letter}:\"; Created = $true; Report = [string[]]@("drive ${letter}: -> $tree (created)") }
}

function Use-Sql
{
    [CmdletBinding(DefaultParameterSetName = 'Block')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Block')][scriptblock]$ScriptBlock,
        [Parameter(Mandatory, ParameterSetName = 'Check')][switch]$Check,
        [string]$Worktree,
        [string]$ConfigPath
    )

    $config = Resolve-IpeConfig -Worktree $Worktree -ConfigPath $ConfigPath
    $sql = $config.Sql
    $start = Start-IpeSqlServer -Config $config
    $endpoint = Get-IpeSqlEndpoint -Server $sql.Server
    $deadline = [System.Diagnostics.Stopwatch]::StartNew()
    $ready = $false
    while (-not $ready)
    {
        $ready = Test-IpeTcpPort -HostName $endpoint.Host -Port $endpoint.Port
        if ($ready -or $deadline.Elapsed.TotalSeconds -ge $config.Timeouts.SqlProbeSeconds)
        {
            break
        }

        Start-Sleep -Milliseconds 500
    }

    if (-not $ready)
    {
        $startNote = "start command exited $($start.ExitCode)"
        throw (New-IpeErrorRecord -ErrorId 'Ipe.SqlUnavailable' -Message "SQL Server $($sql.Server) did not accept connections within $($config.Timeouts.SqlProbeSeconds) s ($startNote)" -Category ConnectionError)
    }

    if (-not (Test-Path -LiteralPath $sql.ConnectionFile -PathType Leaf))
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.SqlConnectionFileMissing' -Message "connection file not found: $($sql.ConnectionFile)" -Category ObjectNotFound)
    }

    $previous = [System.Environment]::GetEnvironmentVariable($sql.EnvVar, 'Process')
    $value = [System.IO.File]::ReadAllText($sql.ConnectionFile).Trim()
    if (-not $value)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.SqlConnectionFileMissing' -Message "connection file is empty: $($sql.ConnectionFile)" -Category InvalidData)
    }

    try
    {
        [System.Environment]::SetEnvironmentVariable($sql.EnvVar, $value, 'Process')
        $value = $null
        if ($Check)
        {
            return [pscustomobject]@{ ExitCode = 0; Report = [string[]]@('sql: ready') }
        }

        & $ScriptBlock
    }
    finally
    {
        # Restore rather than clear, so a nested scope does not strip the variable from an enclosing one.
        if ([string]::IsNullOrEmpty($previous))
        {
            Remove-Item -LiteralPath "Env:$($sql.EnvVar)" -ErrorAction SilentlyContinue
        }
        else
        {
            [System.Environment]::SetEnvironmentVariable($sql.EnvVar, $previous, 'Process')
        }

        $previous = $null
    }
}

function Stop-TestHosts
{
    [CmdletBinding(DefaultParameterSetName = 'Drive')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Drive')][string]$Drive,
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [switch]$ListOnly,
        [string]$ConfigPath
    )

    if (-not $IsWindows)
    {
        throw [System.PlatformNotSupportedException]::new('Stop-TestHosts needs Win32_Process and runs on Windows only')
    }

    if ($PSCmdlet.ParameterSetName -eq 'Drive')
    {
        $needle = "$(ConvertTo-IpeDriveLetter $Drive):\"
    }
    else
    {
        Assert-IpeAbsolutePath -Path $Path -Name 'Path'
        $needle = Get-IpeNormalPath $Path
    }

    $all = @(Get-CimInstance -ClassName Win32_Process)
    $byId = @{}
    foreach ($process in $all)
    {
        $byId[[int]$process.ProcessId] = $process
    }

    $protected = [System.Collections.Generic.HashSet[int]]::new()
    $current = $PID
    while ($current -and $byId.ContainsKey($current) -and $protected.Add($current))
    {
        $current = [int]$byId[$current].ParentProcessId
    }

    [void]$protected.Add($PID)
    $matched = @($all | Where-Object {
            -not $protected.Contains([int]$_.ProcessId) -and (
                ($_.CommandLine -and $_.CommandLine.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                ($_.ExecutablePath -and $_.ExecutablePath.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0))
        })

    $report = [System.Collections.Generic.List[string]]::new()
    $found = [System.Collections.Generic.List[object]]::new()
    $killed = 0
    foreach ($process in $matched)
    {
        $commandLine = [string]$process.CommandLine
        $head = if ($commandLine.Length -gt 160) { $commandLine.Substring(0, 160) + '...' } else { $commandLine }
        $found.Add([pscustomobject]@{ ProcessId = [int]$process.ProcessId; Name = $process.Name; CommandLine = $head })
        $report.Add("pid $($process.ProcessId) $($process.Name) $head")
        if (-not $ListOnly)
        {
            try
            {
                [System.Diagnostics.Process]::GetProcessById([int]$process.ProcessId).Kill($true)
                $killed++
            }
            catch [System.ArgumentException], [System.InvalidOperationException], [System.ComponentModel.Win32Exception], [System.AggregateException]
            {
                $report.Add("pid $($process.ProcessId) already gone or not killable: $($_.Exception.Message)")
            }
        }
    }

    $report.Add($(if ($ListOnly) { "listed $($found.Count) process(es) using $needle; none killed" } else { "killed $killed of $($found.Count) process(es) using $needle" }))
    return [pscustomobject]@{ ExitCode = 0; Processes = $found.ToArray(); Killed = $killed; Report = $report.ToArray() }
}

function Get-IpeTextShape
{
    # BOM and newline counts of a file's bytes. Latin-1 maps every byte to one char, so counting never alters bytes.
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)

    $utf16 = $Bytes.Length -ge 2 -and (($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) -or ($Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF))
    $latin = [System.Text.Encoding]::Latin1.GetString($Bytes)
    $bom = $Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF
    $lf = $latin.Length - $latin.Replace("`n", '').Length
    $crlf = [int](($latin.Length - $latin.Replace("`r`n", '').Length) / 2)
    $bareLf = $lf - $crlf
    $style = if ($crlf -gt 0 -and $bareLf -gt 0) { 'mixed' } elseif ($crlf -gt 0) { 'CRLF' } elseif ($bareLf -gt 0) { 'LF' } else { 'none' }
    return [pscustomobject]@{ Utf16 = $utf16; Bom = $bom; Crlf = $crlf; Lf = $bareLf; Style = $style }
}

function Test-LineEndings
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Base,
        [switch]$Fix,
        [string[]]$Path = @(),
        [string]$ConfigPath
    )

    Assert-IpeAbsolutePath -Path $Worktree -Name 'Worktree'
    $config = Resolve-IpeConfig -Worktree $Worktree -ConfigPath $ConfigPath -Optional
    $logDir = if ($config) { $config.LogDir } else { $script:DefaultLogDir }
    $logPrefix = $logDir.Replace('\', '/').TrimEnd('/') + '/'
    $top = Get-IpeTopLevel -Worktree $Worktree
    $autocrlfResult = Invoke-Git -Worktree $top -Arguments @('config', '--get', 'core.autocrlf') -AllowExitCodes @(0, 1)
    $autocrlf = ($autocrlfResult.Lines.Count -gt 0 -and $autocrlfResult.Lines[0].Trim() -ieq 'true')

    $candidates = @(Get-IpeChangedFiles -Worktree $top -Base $Base -Pathspec $Path | Where-Object {
            $extension = [System.IO.Path]::GetExtension($_.Path)
            $script:TextExtensions -contains $extension.ToLowerInvariant() -and
            -not $_.Path.StartsWith($logPrefix, [System.StringComparison]::OrdinalIgnoreCase)
        })

    $numstat = @{}
    $numstatResult = Invoke-Git -Worktree $top -Arguments @('diff', '--numstat', '--no-renames', '-z', $Base)
    foreach ($entry in (Split-IpeNul $numstatResult.StdOut))
    {
        $parts = $entry.Split("`t", 3)
        if ($parts.Count -eq 3 -and $parts[1] -match '^\d+$')
        {
            $numstat[$parts[2]] = [int]$parts[1]
        }
    }

    $files = [System.Collections.Generic.List[object]]::new()
    $report = [System.Collections.Generic.List[string]]::new()
    $failures = 0
    $warnings = 0
    foreach ($candidate in $candidates)
    {
        $full = Join-IpeTreePath -Root $top -Relative $candidate.Path
        if (-not (Test-Path -LiteralPath $full -PathType Leaf))
        {
            continue
        }

        $bytes = [System.IO.File]::ReadAllBytes($full)
        $shape = Get-IpeTextShape -Bytes $bytes
        if ($shape.Utf16)
        {
            $report.Add("skip $($candidate.Path): UTF-16 file, not checked")
            continue
        }

        $hasBom = $shape.Bom
        $crlf = $shape.Crlf
        $bareLf = $shape.Lf
        $style = $shape.Style
        $problems = [System.Collections.Generic.List[string]]::new()
        $notes = [System.Collections.Generic.List[string]]::new()
        $baseBom = $null
        if ($candidate.State -eq 'modified')
        {
            $blob = Invoke-Git -Worktree $top -Arguments @('cat-file', 'blob', "${Base}:$($candidate.Path)") -Bytes
            $baseBytes = $blob.Bytes
            $baseBom = $baseBytes.Length -ge 3 -and $baseBytes[0] -eq 0xEF -and $baseBytes[1] -eq 0xBB -and $baseBytes[2] -eq 0xBF
            if ($baseBom -and -not $hasBom)
            {
                $problems.Add('BOM removed (the base blob has a UTF-8 BOM)')
            }
            elseif ($hasBom -and -not $baseBom)
            {
                $problems.Add('BOM added (the base blob has none)')
            }

            $baseText = [System.Text.Encoding]::Latin1.GetString($baseBytes)
            $baseLines = $baseText.Length - $baseText.Replace("`n", '').Length
            if ($baseText.Length -gt 0 -and -not $baseText.EndsWith("`n"))
            {
                $baseLines++
            }

            if ($numstat.ContainsKey($candidate.Path) -and $baseLines -ge 20 -and $numstat[$candidate.Path] -ge [math]::Ceiling($baseLines * 0.9))
            {
                $notes.Add("whole-file rewrite (deleted $($numstat[$candidate.Path]) of $baseLines base lines)")
            }
        }

        $fixed = $false
        if ($style -eq 'mixed')
        {
            if ($Fix)
            {
                # Latin-1 maps every byte to one char, so converting newlines never alters other bytes.
                $latin = [System.Text.Encoding]::Latin1.GetString($bytes)
                $target = if ($autocrlf -or $crlf -ge $bareLf) { "`r`n" } else { "`n" }
                $converted = ConvertTo-IpeNewline -Text $latin -Newline $target
                [System.IO.File]::WriteAllBytes($full, [System.Text.Encoding]::Latin1.GetBytes($converted))
                $fixed = $true
                $style = if ($target -eq "`r`n") { 'CRLF' } else { 'LF' }
            }
            else
            {
                $problems.Add("mixed line endings (CRLF $crlf, LF $bareLf)")
            }
        }

        $bomText = if ($hasBom) { 'BOM' } else { 'no BOM' }
        $label = if ($candidate.State -eq 'modified') { 'ok  ' } else { 'new ' }
        if ($fixed)
        {
            $report.Add("fixed $($candidate.Path): converted to $style, $bomText kept")
        }

        if ($problems.Count -gt 0)
        {
            $failures += $problems.Count
            foreach ($problem in $problems)
            {
                $report.Add("FAIL $($candidate.Path): $problem")
            }
        }
        elseif (-not $fixed)
        {
            $report.Add("$label $($candidate.Path) ($style, $bomText)")
        }

        foreach ($note in $notes)
        {
            $warnings++
            $report.Add("warn $($candidate.Path): $note")
        }

        $files.Add([pscustomobject]@{
                Path = $candidate.Path; State = $candidate.State; Style = $style; Bom = $hasBom; BaseBom = $baseBom
                Crlf = $crlf; Lf = $bareLf; Problems = $problems.ToArray(); Warnings = $notes.ToArray(); Fixed = $fixed
            })
    }

    $report.Insert(0, "line endings: $($files.Count) changed or untracked text file(s) checked against $Base")
    if ($autocrlf)
    {
        $report.Add('note: core.autocrlf=true, so blobs are committed as LF: a mixed working file still commits as LF, and only BOM changes and whole-file rewrites reach a commit')
    }

    $verdict = if ($failures -eq 0) { 'line endings: pass' } else { "line endings: FAIL ($failures problem(s))" }
    $report.Add($verdict)
    return [pscustomobject]@{
        ExitCode = if ($failures -eq 0) { 0 } else { 1 }
        Files = $files.ToArray()
        Failures = $failures
        Warnings = $warnings
        AutoCrlf = $autocrlf
        Report = $report.ToArray()
    }
}

function Invoke-Format
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Base,
        [string[]]$Paths = @(),
        [string]$Drive,
        [string]$Tag = 'format',
        [string]$ConfigPath
    )

    Assert-IpeAbsolutePath -Path $Worktree -Name 'Worktree'
    $tree = Get-IpeNormalPath $Worktree
    $config = Resolve-IpeConfig -Worktree $tree -ConfigPath $ConfigPath
    if ($Paths.Count -gt 0)
    {
        $files = @($Paths | ForEach-Object {
                $relative = if ([System.IO.Path]::IsPathFullyQualified($_)) { [System.IO.Path]::GetRelativePath($tree, $_) } else { $_ }
                $relative.Replace('\', '/')
            })
    }
    else
    {
        $files = @(Get-IpeChangedFiles -Worktree $tree -Base $Base -Pathspec @('*.cs') | ForEach-Object { $_.Path })
    }

    $files = @($files | Where-Object { Test-Path -LiteralPath (Join-IpeTreePath -Root $tree -Relative $_) -PathType Leaf } | Sort-Object -Unique)
    if ($files.Count -eq 0)
    {
        return [pscustomobject]@{ ExitCode = 0; Files = [string[]]@(); Passes = @(); Report = [string[]]@('format: nothing to format') }
    }

    $driveArguments = @{ Worktree = $tree; ConfigPath = $config.ConfigPath }
    if ($Drive)
    {
        $driveArguments.Drive = $Drive
    }

    $mapping = Use-Drive @driveArguments
    $report = [System.Collections.Generic.List[string]]::new()
    $passes = [System.Collections.Generic.List[object]]::new()
    $failed = $false
    try
    {
        $root = $mapping.Root
        $logDirectory = Join-IpeTreePath -Root $root -Relative $config.LogDir
        $report.Add("format: $($files.Count) file(s) from $root")
        foreach ($pass in @('whitespace', 'style'))
        {
            $reportDirectory = Join-Path $logDirectory "$Tag-$pass-report"
            if (Test-Path -LiteralPath $reportDirectory)
            {
                Remove-Item -LiteralPath $reportDirectory -Recurse -Force
            }

            $arguments = [string[]](@('format', $pass, $config.Solution, '--verify-no-changes', '--no-restore', '--report', $reportDirectory, '--include') + $files)
            $logPath = Join-Path $logDirectory "$Tag-$pass.log"
            $process = Invoke-IpeProcess -FilePath 'dotnet' -ArgumentList $arguments -WorkingDirectory $root -TimeoutSeconds $config.Timeouts.FormatSeconds -LogPath $logPath
            $verdict = 'pass'
            $remaining = @()
            if ($process.TimedOut)
            {
                $verdict = "FAIL (timed out after $($config.Timeouts.FormatSeconds) s)"
            }
            elseif ($process.ExitCode -ne 0)
            {
                $reportFile = Join-Path $reportDirectory 'format-report.json'
                $parsed = $null
                if (Test-Path -LiteralPath $reportFile -PathType Leaf)
                {
                    try
                    {
                        $parsed = @(Get-Content -LiteralPath $reportFile -Raw | ConvertFrom-Json)
                    }
                    catch
                    {
                        # An unparsable report with a non-zero exit is a failure, handled below.
                        $parsed = $null
                    }
                }

                $total = if ($parsed) { @($parsed | ForEach-Object { @($_.FileChanges) }).Count } else { 0 }
                if (-not $parsed -or $total -eq 0)
                {
                    $verdict = "FAIL (exit $($process.ExitCode), no usable report; see $logPath)"
                }
                else
                {
                    $remaining = Select-IpeFormatChanges -Report $parsed -Exclusions $config.FormatExclusions
                    $verdict = if ($remaining.Count -eq 0) { "pass ($total change(s), all excluded by FormatExclusions)" } else { "FAIL ($($remaining.Count) change(s))" }
                }
            }

            if ($verdict.StartsWith('FAIL'))
            {
                $failed = $true
            }

            $report.Add("format ${pass}: $verdict")
            foreach ($change in $remaining)
            {
                $report.Add("  $($change.FilePath):$($change.Line) $($change.DiagnosticId) $($change.Description)")
            }

            $passes.Add([pscustomobject]@{ Pass = $pass; ExitCode = $process.ExitCode; Verdict = $verdict; LogPath = $logPath; Changes = $remaining })
        }
    }
    finally
    {
        if ($mapping.Created)
        {
            [void](Use-Drive -Worktree $tree -Drive $mapping.Drive -Unmap -ConfigPath $config.ConfigPath)
        }
    }

    $report.Add($(if ($failed) { 'format: FAIL' } else { 'format: pass' }))
    return [pscustomobject]@{ ExitCode = if ($failed) { 1 } else { 0 }; Files = [string[]]$files; Passes = $passes.ToArray(); Report = $report.ToArray() }
}

function Compare-Warnings
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$BuildLog,
        [string]$RepoRoot,
        [int]$TimeoutSeconds = 300,
        [string]$ConfigPath
    )

    Assert-IpeAbsolutePath -Path $Worktree -Name 'Worktree'
    Assert-IpeAbsolutePath -Path $BuildLog -Name 'BuildLog'
    $tree = Get-IpeNormalPath $Worktree
    $config = Resolve-IpeConfig -Worktree $tree -ConfigPath $ConfigPath
    $script = Join-IpeTreePath -Root $tree -Relative $config.Warnings.Script
    if (-not (Test-Path -LiteralPath $script -PathType Leaf))
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.WarningsScriptMissing' -Message "warnings script not found: $script" -Category ObjectNotFound)
    }

    if (-not $RepoRoot)
    {
        $letter = Get-IpeDriveForTree -Worktree $tree -TimeoutSeconds $config.Timeouts.SubstSeconds
        $RepoRoot = if ($letter) { "${letter}:\" } else { $tree }
    }

    $baseline = Join-IpeTreePath -Root $tree -Relative $config.Warnings.Baseline
    $pwsh = (Get-Process -Id $PID).Path
    $arguments = [string[]]@('-NoProfile', '-File', $script, '-BuildLog', $BuildLog, '-Baseline', $baseline, '-RepoRoot', $RepoRoot)
    $process = Invoke-IpeProcess -FilePath $pwsh -ArgumentList $arguments -WorkingDirectory $tree -TimeoutSeconds $TimeoutSeconds
    $report = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Split-IpeLines $process.StdOut))
    {
        $report.Add($line)
    }

    foreach ($line in (Split-IpeLines $process.StdErr))
    {
        $report.Add($line)
    }

    $passed = -not $process.TimedOut -and $process.ExitCode -eq 0
    $report.Add($(if ($passed) { 'warnings: pass' } elseif ($process.TimedOut) { "warnings: FAIL (timed out after $TimeoutSeconds s)" } else { "warnings: FAIL (exit $($process.ExitCode))" }))
    return [pscustomobject]@{
        ExitCode = if ($passed) { 0 } else { 1 }
        ScriptExitCode = $process.ExitCode
        Script = $script
        Report = $report.ToArray()
    }
}

function Remove-LeakedTestDatabases
{
    [CmdletBinding()]
    param(
        [switch]$List,
        [switch]$Drop,
        [string]$Worktree,
        [string]$ConfigPath
    )

    if ($List -and $Drop)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message 'pass -List or -Drop, not both' -Category InvalidArgument)
    }

    $config = Resolve-IpeConfig -Worktree $Worktree -ConfigPath $ConfigPath
    $app = Get-IpeCleanupAppPath
    $arguments = [System.Collections.Generic.List[string]]@('run', '--file', $app, '--', '--env', $config.Sql.EnvVar, '--server', $config.Sql.Server, '--pattern', $config.Sql.LeakedDatabasePattern)
    if ($Drop)
    {
        $arguments.Add('--drop')
    }

    # Run from the tree so its global.json picks the SDK; the app file itself sits outside any repo.
    $workingDirectory = if ($Worktree) { $Worktree } else { [System.IO.Path]::GetDirectoryName($app) }
    $timeout = $config.Timeouts.CleanupSeconds
    $useSqlArguments = @{ ConfigPath = $config.ConfigPath }
    if ($Worktree)
    {
        $useSqlArguments.Worktree = $Worktree
    }

    $process = Use-Sql @useSqlArguments -ScriptBlock {
        Invoke-IpeProcess -FilePath 'dotnet' -ArgumentList $arguments.ToArray() -WorkingDirectory $workingDirectory -TimeoutSeconds $timeout
    }

    $leaked = [System.Collections.Generic.List[string]]::new()
    $dropped = [System.Collections.Generic.List[string]]::new()
    $count = $null
    $report = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Split-IpeLines $process.StdOut))
    {
        if ($line -match '^leaked (.+)$')
        {
            $leaked.Add($Matches[1])
            $report.Add($line)
        }
        elseif ($line -match '^dropped (.+)$')
        {
            $dropped.Add($Matches[1])
            $report.Add($line)
        }
        elseif ($line -match '^count=(\d+)$')
        {
            $count = [int]$Matches[1]
        }
        elseif ($line.StartsWith('refusing:', [System.StringComparison]::Ordinal))
        {
            $report.Add($line)
        }
    }

    $ok = -not $process.TimedOut -and $process.ExitCode -eq 0 -and $null -ne $count
    if ($ok)
    {
        $action = if ($Drop) { "dropped $($dropped.Count)" } else { 'listed only' }
        $report.Add("leaked databases: $count ($action)")
    }
    else
    {
        foreach ($line in (Split-IpeLines $process.StdErr))
        {
            $report.Add($line)
        }

        $why = if ($process.TimedOut) { "timed out after $timeout s" } else { "exit $($process.ExitCode)" }
        $report.Add("leaked databases: FAIL ($why)")
    }

    return [pscustomobject]@{
        ExitCode = if ($ok) { 0 } else { 1 }
        Leaked = $leaked.ToArray()
        Dropped = $dropped.ToArray()
        Report = $report.ToArray()
    }
}

# Runners (test runs, full check, mutations) -------------------------------------------------------------------------

$script:NamePattern = '^[A-Za-z0-9][A-Za-z0-9._-]*$'
$script:MutationStatuses = @('active', 'control', 'stale')
$script:MutationRecordKeys = @('id', 'status', 'staleReason', 'project', 'filter', 'file', 'find', 'replace', 'expectedMatches', 'occurrence', 'edits')
$script:MutationEditKeys = @('file', 'find', 'replace', 'expectedMatches', 'occurrence')
$script:MutationJournalName = 'mutation-journal.json'

function Assert-IpeName
{
    # Tags, ids and feature slugs end up in file names, so they are restricted to a safe character set.
    param([AllowEmptyString()][string]$Value, [Parameter(Mandatory)][string]$Name)

    if ($Value -notmatch $script:NamePattern)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message "-$Name '$Value' must match $($script:NamePattern)" -Category InvalidArgument)
    }
}

function Get-IpeLogDirectory
{
    param([Parameter(Mandatory)][string]$Tree, [Parameter(Mandatory)][hashtable]$Config)

    $directory = Join-IpeTreePath -Root $Tree -Relative $Config.LogDir
    [void][System.IO.Directory]::CreateDirectory($directory)
    return $directory
}

function Get-IpeTestProjectConfig
{
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Name)

    foreach ($project in $Config.TestProjects)
    {
        if ([string]::Equals($project.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase))
        {
            return $project
        }
    }

    $names = ($Config.TestProjects | ForEach-Object { $_.Name }) -join ', '
    throw (New-IpeErrorRecord -ErrorId 'Ipe.UnknownProject' -Message "unknown test project '$Name'; configured: $names" -Category ObjectNotFound)
}

function New-IpeTestFilter
{
    # TUnit tree-node filters take (A|B) alternation but no character classes; xUnit takes VSTest filter syntax.
    param([Parameter(Mandatory)][ValidateSet('xunit', 'tunit')][string]$Kind, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Classes)

    $names = @($Classes | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($names.Count -eq 0)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message '-Classes needs at least one class name' -Category InvalidArgument)
    }

    $pattern = if ($Kind -eq 'tunit') { '^[A-Za-z_][A-Za-z0-9_]*$' } else { '^[A-Za-z_][A-Za-z0-9_.]*$' }
    foreach ($name in $names)
    {
        if ($name -notmatch $pattern)
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message "class name '$name' is not valid in a $Kind filter" -Category InvalidArgument)
        }
    }

    if ($Kind -eq 'tunit')
    {
        if ($names.Count -eq 1)
        {
            return "/*/*/$($names[0])/*"
        }

        return "/*/*/($($names -join '|'))/*"
    }

    return (($names | ForEach-Object { "FullyQualifiedName~$_" }) -join '|')
}

function Resolve-IpeTestFilter
{
    param([Parameter(Mandatory)][string]$Kind, [string[]]$Classes = @(), [string]$Filter)

    if ($Filter -and $Classes.Count -gt 0)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message 'pass -Classes or -Filter, not both' -Category InvalidArgument)
    }

    if ($Filter)
    {
        return $Filter
    }

    if ($Classes.Count -gt 0)
    {
        return New-IpeTestFilter -Kind $Kind -Classes $Classes
    }

    return $null
}

function Get-IpeHead
{
    param([Parameter(Mandatory)][string]$Worktree, [switch]$Short)

    $arguments = if ($Short) { @('rev-parse', '--short', 'HEAD') } else { @('rev-parse', 'HEAD') }
    return (Invoke-Git -Worktree $Worktree -Arguments $arguments).Lines[0].Trim()
}

function Get-IpeDirtyPaths
{
    # Changed, staged and untracked paths (repo-relative, '/'), without the tree's own log directory. UnstagedOnly
    # leaves out changes that are only staged (a merge waiting for its commit), keeping working-tree and untracked ones.
    # NoOptionalLocks stops git status from refreshing the index's stat cache, for callers that must not touch the tree.
    param([Parameter(Mandatory)][string]$Worktree, [Parameter(Mandatory)][hashtable]$Config, [string[]]$Pathspec = @(), [switch]$UnstagedOnly, [switch]$NoOptionalLocks)

    $arguments = [System.Collections.Generic.List[string]]@('status', '--porcelain=v1', '-z', '--untracked-files=all', '--no-renames')
    if ($Pathspec.Count -gt 0)
    {
        $arguments.Add('--')
        $arguments.AddRange([string[]]@($Pathspec | ForEach-Object { $_.Replace('\', '/') }))
    }

    $environment = if ($NoOptionalLocks) { @{ GIT_OPTIONAL_LOCKS = '0' } } else { $null }
    $result = Invoke-Git -Worktree $Worktree -Arguments $arguments.ToArray() -Environment $environment
    $logPrefix = $Config.LogDir.Replace('\', '/').TrimEnd('/') + '/'
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in (Split-IpeNul $result.StdOut))
    {
        if ($entry.Length -gt 3 -and -not ($UnstagedOnly -and $entry[1] -eq ' '))
        {
            $path = $entry.Substring(3)
            if (-not $path.StartsWith($logPrefix, [System.StringComparison]::OrdinalIgnoreCase))
            {
                $paths.Add($path)
            }
        }
    }

    return , $paths.ToArray()
}

function Invoke-IpeSqlScope
{
    # Runs SqlBody inside Use-Sql when SqlNeeded, else directly. The parameter names are unusual on purpose: the body
    # reads its caller's variables through PowerShell's dynamic scoping, and these must not shadow them.
    param([Parameter(Mandatory)][bool]$SqlNeeded, [Parameter(Mandatory)][hashtable]$SqlConfig, [Parameter(Mandatory)][string]$SqlTree, [Parameter(Mandatory)][scriptblock]$SqlBody)

    if (-not $SqlNeeded)
    {
        return & $SqlBody
    }

    return Use-Sql -Worktree $SqlTree -ConfigPath $SqlConfig.ConfigPath -ScriptBlock $SqlBody
}

function Get-IpeProjectVerdict
{
    # Pass/fail of one test run: timeouts, crashes, failures and zero tests fail; AllowEmpty accepts zero tests (TUnit
    # exit 8); skipped tests fail a project that needs SQL unless AllowSkip.
    param(
        [Parameter(Mandatory)][hashtable]$Project,
        [Parameter(Mandatory)][object]$Run,
        [bool]$AllowEmpty,
        [bool]$AllowSkip
    )

    $summary = $Run.Summary
    $zero = $summary.ZeroTests -or ($summary.Found -and $summary.Total -eq 0)
    $reason = $null
    if ($Run.TimedOut)
    {
        $reason = 'timed out'
    }
    elseif ($zero -and $AllowEmpty -and ($Run.ExitCode -eq 0 -or ($Project.Kind -eq 'tunit' -and $Run.ExitCode -eq 8)))
    {
        return [pscustomobject]@{ Passed = $true; Reason = 'zero tests (AllowEmpty)' }
    }
    elseif ($summary.Failed -gt 0)
    {
        $reason = "$($summary.Failed) failed"
    }
    elseif ($zero)
    {
        $reason = 'zero tests ran'
    }
    elseif (-not $summary.Found)
    {
        $reason = "no test summary in the log (exit $($Run.ExitCode))"
    }
    elseif ($Run.ExitCode -ne 0)
    {
        $reason = "exit $($Run.ExitCode)"
    }
    elseif ($Project.NeedsSql -and $summary.Skipped -gt 0 -and -not $AllowSkip)
    {
        $reason = "$($summary.Skipped) skipped in a project that needs SQL"
    }

    if ($reason)
    {
        return [pscustomobject]@{ Passed = $false; Reason = $reason }
    }

    return [pscustomobject]@{ Passed = $true; Reason = 'pass' }
}

function Format-IpeRunCounts
{
    param([Parameter(Mandatory)][object]$Run)

    $summary = $Run.Summary
    return "total $($summary.Total), passed $($summary.Succeeded), failed $($summary.Failed), skipped $($summary.Skipped), exit $($Run.ExitCode)"
}

function Get-IpeTrxResults
{
    param([Parameter(Mandatory)][string]$Path)

    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $reader = [System.Xml.XmlReader]::Create($Path, $settings)
    $document = [System.Xml.XmlDocument]::new()
    try
    {
        $document.Load($reader)
    }
    finally
    {
        $reader.Dispose()
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($node in $document.GetElementsByTagName('UnitTestResult'))
    {
        $duration = [System.TimeSpan]::Zero
        [void][System.TimeSpan]::TryParse($node.GetAttribute('duration'), [System.Globalization.CultureInfo]::InvariantCulture, [ref]$duration)
        $results.Add([pscustomobject]@{ Name = $node.GetAttribute('testName'); Outcome = $node.GetAttribute('outcome'); Duration = $duration })
    }

    return , $results.ToArray()
}

# Front matter: a YAML subset. Scalars (plain, 'single', "double"), integers, | and |- block literals (with an
# optional indentation indicator, |2-, for text that starts with spaces) and one level of a sequence of mappings.
# Anything else throws Ipe.FrontMatterInvalid naming the line.

function New-IpeFrontMatterError
{
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][string]$Problem)

    return New-IpeErrorRecord -ErrorId 'Ipe.FrontMatterInvalid' -Message "$($State.Path): front matter line ${Number}: $Problem" -Category InvalidData
}

function Test-IpeYamlSkippable
{
    param([AllowEmptyString()][string]$Line)

    return ([string]::IsNullOrWhiteSpace($Line) -or $Line.TrimStart().StartsWith('#'))
}

function Get-IpeYamlIndent
{
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][int]$Index)

    $line = $State.Lines[$Index]
    $count = 0
    while ($count -lt $line.Length -and $line[$count] -eq [char]' ')
    {
        $count++
    }

    if ($count -lt $line.Length -and $line[$count] -eq [char]"`t")
    {
        throw (New-IpeFrontMatterError -State $State -Number ($Index + 1) -Problem 'tabs are not allowed in indentation')
    }

    return $count
}

function Read-IpeYamlMapping
{
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][int]$Indent, [switch]$AllowSequence)

    $map = [ordered]@{}
    while ($State.Index -lt $State.End)
    {
        $line = $State.Lines[$State.Index]
        if (Test-IpeYamlSkippable $line)
        {
            $State.Index++
            continue
        }

        $number = $State.Index + 1
        $lineIndent = Get-IpeYamlIndent -State $State -Index $State.Index
        if ($lineIndent -lt $Indent)
        {
            break
        }

        if ($lineIndent -gt $Indent)
        {
            throw (New-IpeFrontMatterError -State $State -Number $number -Problem 'unexpected indentation')
        }

        $content = $line.Substring($lineIndent)
        if ($content -notmatch '^([A-Za-z_][A-Za-z0-9_]*):(?: (.*))?$')
        {
            throw (New-IpeFrontMatterError -State $State -Number $number -Problem "expected 'key: value', found '$content'")
        }

        $key = $Matches[1]
        $raw = if ($null -ne $Matches[2]) { $Matches[2].Trim() } else { '' }
        if ($map.Contains($key))
        {
            throw (New-IpeFrontMatterError -State $State -Number $number -Problem "duplicate key '$key'")
        }

        $State.Index++
        $map[$key] = Read-IpeYamlValue -State $State -Raw $raw -Indent $Indent -Number $number -AllowSequence:$AllowSequence
    }

    return $map
}

function Read-IpeYamlValue
{
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Raw,
        [Parameter(Mandatory)][int]$Indent,
        [Parameter(Mandatory)][int]$Number,
        [switch]$AllowSequence
    )

    if ($Raw -eq '')
    {
        $next = $State.Index
        while ($next -lt $State.End -and (Test-IpeYamlSkippable $State.Lines[$next]))
        {
            $next++
        }

        if ($next -lt $State.End)
        {
            $nextIndent = Get-IpeYamlIndent -State $State -Index $next
            $nextContent = $State.Lines[$next].Substring($nextIndent)
            if ($nextIndent -gt $Indent -and ($nextContent -eq '-' -or $nextContent.StartsWith('- ')))
            {
                if (-not $AllowSequence)
                {
                    throw (New-IpeFrontMatterError -State $State -Number ($next + 1) -Problem 'nested sequences are not supported')
                }

                $State.Index = $next
                return , (Read-IpeYamlSequence -State $State -Indent $nextIndent)
            }
        }

        return ''
    }

    if ($Raw -match '^\|(?<i>[1-9])?(?<c>-)?$' -or $Raw -match '^\|(?<c>-)(?<i>[1-9])$')
    {
        $explicit = if ($Matches['i']) { [int]$Matches['i'] } else { 0 }
        return Read-IpeYamlBlock -State $State -Indent $Indent -Explicit $explicit -Strip ([bool]$Matches['c'])
    }

    if ($Raw.StartsWith("'"))
    {
        $inner = if ($Raw.Length -ge 2 -and $Raw.EndsWith("'")) { $Raw.Substring(1, $Raw.Length - 2) } else { $null }
        if ($null -eq $inner -or $inner.Replace("''", '').Contains("'"))
        {
            throw (New-IpeFrontMatterError -State $State -Number $Number -Problem 'unterminated or malformed single-quoted value')
        }

        return $inner.Replace("''", "'")
    }

    if ($Raw.StartsWith('"'))
    {
        return ConvertFrom-IpeYamlDoubleQuoted -State $State -Raw $Raw -Number $Number
    }

    if ($Raw -match '^-?[0-9]+$')
    {
        # Not $number: PowerShell names are case-insensitive, so that would overwrite the $Number line parameter.
        $parsedInteger = 0
        if (-not [int]::TryParse($Raw, [System.Globalization.NumberStyles]::AllowLeadingSign, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedInteger))
        {
            throw (New-IpeFrontMatterError -State $State -Number $Number -Problem "integer out of range: $Raw")
        }

        return $parsedInteger
    }

    if ($Raw[0] -in @('[', ']', '{', '}', '>', '|', '&', '*', '!', '%', '@', '`', '#') -or $Raw.StartsWith('- ') -or $Raw.Contains(': ') -or $Raw.Contains(' #'))
    {
        throw (New-IpeFrontMatterError -State $State -Number $Number -Problem "unsupported value '$Raw' (quote it, or use a |- block)")
    }

    return $Raw
}

function ConvertFrom-IpeYamlDoubleQuoted
{
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Raw, [Parameter(Mandatory)][int]$Number)

    if ($Raw.Length -lt 2 -or -not $Raw.EndsWith('"'))
    {
        throw (New-IpeFrontMatterError -State $State -Number $Number -Problem 'unterminated double-quoted value')
    }

    $inner = $Raw.Substring(1, $Raw.Length - 2)
    $builder = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $inner.Length; $i++)
    {
        $c = $inner[$i]
        if ($c -eq [char]'"')
        {
            throw (New-IpeFrontMatterError -State $State -Number $Number -Problem 'unescaped " inside a double-quoted value')
        }

        if ($c -ne [char]'\')
        {
            [void]$builder.Append($c)
            continue
        }

        $i++
        if ($i -ge $inner.Length)
        {
            throw (New-IpeFrontMatterError -State $State -Number $Number -Problem 'unfinished escape at the end of a double-quoted value')
        }

        $escaped = switch -CaseSensitive ([string]$inner[$i])
        {
            '\' { '\' }
            '"' { '"' }
            '/' { '/' }
            'n' { "`n" }
            'r' { "`r" }
            't' { "`t" }
            default { $null }
        }

        if ($null -eq $escaped)
        {
            throw (New-IpeFrontMatterError -State $State -Number $Number -Problem "unsupported escape '\$($inner[$i])'")
        }

        [void]$builder.Append($escaped)
    }

    return $builder.ToString()
}

function Read-IpeYamlBlock
{
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][int]$Indent, [int]$Explicit, [bool]$Strip)

    $blockIndent = if ($Explicit -gt 0) { $Indent + $Explicit } else { -1 }
    $collected = [System.Collections.Generic.List[string]]::new()
    while ($State.Index -lt $State.End)
    {
        $line = $State.Lines[$State.Index]
        if ([string]::IsNullOrWhiteSpace($line))
        {
            $collected.Add($(if ($blockIndent -ge 0 -and $line.Length -gt $blockIndent) { $line.Substring($blockIndent) } else { '' }))
            $State.Index++
            continue
        }

        $lineIndent = Get-IpeYamlIndent -State $State -Index $State.Index
        if ($blockIndent -lt 0)
        {
            if ($lineIndent -le $Indent)
            {
                break
            }

            $blockIndent = $lineIndent
        }

        if ($lineIndent -lt $blockIndent)
        {
            if ($lineIndent -gt $Indent)
            {
                throw (New-IpeFrontMatterError -State $State -Number ($State.Index + 1) -Problem 'block line indented less than the block')
            }

            break
        }

        $collected.Add($line.Substring($blockIndent))
        $State.Index++
    }

    while ($collected.Count -gt 0 -and $collected[$collected.Count - 1] -eq '')
    {
        $collected.RemoveAt($collected.Count - 1)
    }

    $text = $collected -join "`n"
    if (-not $Strip -and $text -ne '')
    {
        $text += "`n"
    }

    return $text
}

function Read-IpeYamlSequence
{
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][int]$Indent)

    $items = [System.Collections.Generic.List[object]]::new()
    while ($State.Index -lt $State.End)
    {
        $line = $State.Lines[$State.Index]
        if (Test-IpeYamlSkippable $line)
        {
            $State.Index++
            continue
        }

        $number = $State.Index + 1
        $lineIndent = Get-IpeYamlIndent -State $State -Index $State.Index
        if ($lineIndent -lt $Indent)
        {
            break
        }

        if ($lineIndent -gt $Indent)
        {
            throw (New-IpeFrontMatterError -State $State -Number $number -Problem 'unexpected indentation')
        }

        if ($line.Substring($lineIndent) -notmatch '^-( +)(\S.*)$')
        {
            throw (New-IpeFrontMatterError -State $State -Number $number -Problem "expected a '- key: value' sequence item")
        }

        # The item's first key is read as if the '-' were a space, so the item is a mapping at that column.
        $itemIndent = $Indent + 1 + $Matches[1].Length
        $State.Lines[$State.Index] = (' ' * $itemIndent) + $Matches[2]
        $items.Add((Read-IpeYamlMapping -State $State -Indent $itemIndent))
    }

    return , $items.ToArray()
}

function ConvertFrom-IpeFrontMatter
{
    # Parses the front matter at the top of Text (between a first '---' line and the next '---' line). Returns
    # {Data (ordered dictionary), BodyLine (1-based line after the closing '---')}.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$Path = 'text')

    $lines = $Text.Replace("`r`n", "`n").Split("`n")
    if ($lines[0].TrimEnd() -ne '---')
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.FrontMatterMissing' -Message "${Path}: no front matter (line 1 must be '---')" -Category InvalidData)
    }

    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++)
    {
        if ($lines[$i].TrimEnd() -eq '---')
        {
            $end = $i
            break
        }
    }

    if ($end -lt 0)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.FrontMatterInvalid' -Message "${Path}: front matter opened on line 1 is never closed with '---'" -Category InvalidData)
    }

    $state = @{ Lines = $lines; End = $end; Path = $Path; Index = 1 }
    $data = Read-IpeYamlMapping -State $state -Indent 0 -AllowSequence
    return [pscustomobject]@{ Data = $data; BodyLine = $end + 2 }
}

# Mutation records ---------------------------------------------------------------------------------------------------

function New-IpeRecordError
{
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Problem)

    return New-IpeErrorRecord -ErrorId 'Ipe.RecordInvalid' -Message "${Path}: $Problem" -Category InvalidData
}

function ConvertTo-IpeMutationEdit
{
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Tree, [bool]$Stale, [string]$Where = '')

    foreach ($key in $Data.Keys)
    {
        if ($key -notin $script:MutationEditKeys)
        {
            throw (New-IpeRecordError -Path $Path -Problem "unknown edit key '$key'$Where")
        }
    }

    $file = $Data['file']
    if ($file -isnot [string] -or $file -eq '' -or [System.IO.Path]::IsPathRooted($file) -or @($file -split '[\\/]') -contains '..')
    {
        throw (New-IpeRecordError -Path $Path -Problem "'file'$Where must be a path relative to the tree root, without '..'")
    }

    $find = $Data['find']
    if ($find -isnot [string] -or $find -eq '')
    {
        throw (New-IpeRecordError -Path $Path -Problem "'find'$Where must be a non-empty string (use a |- block)")
    }

    $replace = if ($Data.Contains('replace')) { $Data['replace'] } else { $null }
    if ($replace -isnot [string])
    {
        throw (New-IpeRecordError -Path $Path -Problem "'replace'$Where must be a string (use '' to delete the find text)")
    }

    $expected = $Data['expectedMatches']
    if ($expected -isnot [int] -or $expected -lt 1)
    {
        throw (New-IpeRecordError -Path $Path -Problem "'expectedMatches'$Where must be an integer of at least 1")
    }

    $occurrence = $null
    if ($Data.Contains('occurrence'))
    {
        $occurrence = $Data['occurrence']
        if ($occurrence -isnot [int] -or $occurrence -lt 1 -or $occurrence -gt $expected)
        {
            throw (New-IpeRecordError -Path $Path -Problem "'occurrence'$Where must be an integer from 1 to expectedMatches ($expected)")
        }
    }

    $full = Join-IpeTreePath -Root $Tree -Relative $file
    if (-not $Stale -and -not (Test-Path -LiteralPath $full -PathType Leaf))
    {
        throw (New-IpeRecordError -Path $Path -Problem "file$Where not found: $file")
    }

    return [pscustomobject]@{ File = $file.Replace('\', '/'); Path = $full; Find = $find; Replace = $replace; ExpectedMatches = $expected; Occurrence = $occurrence }
}

function ConvertTo-IpeMutationRecord
{
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Tree, [Parameter(Mandatory)][hashtable]$Config)

    foreach ($key in $Data.Keys)
    {
        if ($key -notin $script:MutationRecordKeys)
        {
            throw (New-IpeRecordError -Path $Path -Problem "unknown key '$key'")
        }
    }

    $id = $Data['id']
    if ($id -isnot [string] -or $id -notmatch $script:NamePattern)
    {
        throw (New-IpeRecordError -Path $Path -Problem "'id' must be a string matching $($script:NamePattern)")
    }

    $status = $Data['status']
    if ($status -notin $script:MutationStatuses)
    {
        throw (New-IpeRecordError -Path $Path -Problem "'status' must be one of $($script:MutationStatuses -join ', ')")
    }

    $staleReason = $null
    if ($status -eq 'stale')
    {
        $staleReason = $Data['staleReason']
        if ($staleReason -isnot [string] -or $staleReason -eq '')
        {
            throw (New-IpeRecordError -Path $Path -Problem "a stale record needs 'staleReason'")
        }
    }

    $projectName = $Data['project']
    if ($projectName -isnot [string] -or $projectName -eq '')
    {
        throw (New-IpeRecordError -Path $Path -Problem "'project' must name a configured test project")
    }

    try
    {
        $project = Get-IpeTestProjectConfig -Config $Config -Name $projectName
    }
    catch
    {
        throw (New-IpeRecordError -Path $Path -Problem $_.Exception.Message)
    }

    $filter = if ($Data.Contains('filter')) { $Data['filter'] } else { $null }
    if ($null -ne $filter -and ($filter -isnot [string] -or $filter -eq ''))
    {
        throw (New-IpeRecordError -Path $Path -Problem "'filter' must be a non-empty string")
    }

    $stale = $status -eq 'stale'
    $edits = [System.Collections.Generic.List[object]]::new()
    if ($Data.Contains('edits'))
    {
        foreach ($key in @('file', 'find', 'replace', 'expectedMatches', 'occurrence'))
        {
            if ($Data.Contains($key))
            {
                throw (New-IpeRecordError -Path $Path -Problem "use either 'edits' or top-level '$key', not both")
            }
        }

        $items = @($Data['edits'])
        if ($items.Count -eq 0 -or @($items | Where-Object { $_ -isnot [System.Collections.IDictionary] }).Count -gt 0)
        {
            throw (New-IpeRecordError -Path $Path -Problem "'edits' must be a sequence of mappings")
        }

        for ($i = 0; $i -lt $items.Count; $i++)
        {
            $edits.Add((ConvertTo-IpeMutationEdit -Data $items[$i] -Path $Path -Tree $Tree -Stale $stale -Where " (edit $($i + 1))"))
        }
    }
    else
    {
        $single = [ordered]@{}
        foreach ($key in $script:MutationEditKeys)
        {
            if ($Data.Contains($key))
            {
                $single[$key] = $Data[$key]
            }
        }

        $edits.Add((ConvertTo-IpeMutationEdit -Data $single -Path $Path -Tree $Tree -Stale $stale))
    }

    return [pscustomobject]@{
        Id = $id
        Status = $status
        StaleReason = $staleReason
        Project = $project
        ProjectName = $project.Name
        Filter = $filter
        Edits = $edits.ToArray()
        RecordPath = $Path
        Expected = if ($status -eq 'control') { 'survived' } elseif ($stale) { 'stale' } else { 'red' }
    }
}

function Read-IpeMutationRecords
{
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Tree, [Parameter(Mandatory)][hashtable]$Config)

    if (-not (Test-Path -LiteralPath $Directory -PathType Container))
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.SpecDirMissing' -Message "mutation record directory not found: $Directory" -Category ObjectNotFound)
    }

    $files = @(Get-ChildItem -LiteralPath $Directory -Filter '*.md' -File | Sort-Object Name)
    if ($files.Count -eq 0)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.RecordInvalid' -Message "no *.md mutation records in $Directory" -Category ObjectNotFound)
    }

    $records = [System.Collections.Generic.List[object]]::new()
    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $files)
    {
        $info = Read-IpeText -Path $file.FullName
        $parsed = ConvertFrom-IpeFrontMatter -Text $info.Text -Path $file.FullName
        $record = ConvertTo-IpeMutationRecord -Data $parsed.Data -Path $file.FullName -Tree $Tree -Config $Config
        if (-not $ids.Add($record.Id))
        {
            throw (New-IpeRecordError -Path $file.FullName -Problem "duplicate id '$($record.Id)'")
        }

        $records.Add($record)
    }

    return , $records.ToArray()
}

function Select-IpeMutationRecords
{
    param([Parameter(Mandatory)][object[]]$Records, [string[]]$Only = @())

    if ($Only.Count -eq 0)
    {
        return , $Records
    }

    $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $Only)
    {
        if (@($Records | Where-Object { $_.Id -ieq $id }).Count -eq 0)
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.UnknownMutation' -Message "unknown mutation id '$id'; known: $(($Records | ForEach-Object { $_.Id }) -join ', ')" -Category ObjectNotFound)
        }

        [void]$wanted.Add($id)
    }

    return , [object[]]@($Records | Where-Object { $wanted.Contains($_.Id) })
}

function Get-IpeMatchCount
{
    # Counts ordinal, non-overlapping matches the way Edit-File does (Find normalised to the file's newline).
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Find)

    $info = Read-IpeText -Path $Path
    $needle = ConvertTo-IpeNewline -Text $Find -Newline $info.Newline
    $count = 0
    $index = 0
    while (($index = $info.Text.IndexOf($needle, $index, [System.StringComparison]::Ordinal)) -ge 0)
    {
        $count++
        $index += $needle.Length
    }

    return $count
}

function Write-IpeMutationJournal
{
    # Original bytes of every file a mutation edits, written before the first edit so an interrupted run can be
    # restored by the next one.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][System.Collections.IDictionary]$Originals)

    $files = @(foreach ($key in $Originals.Keys)
        {
            [ordered]@{ path = $key; bytes = [System.Convert]::ToBase64String([byte[]]$Originals[$key]) }
        })
    $journal = [ordered]@{
        id = $Id
        written = [System.DateTimeOffset]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        files = $files
    }
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path))
    $temporary = "$Path.tmp"
    [System.IO.File]::WriteAllText($temporary, ($journal | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Restore-IpeOriginals
{
    param([Parameter(Mandatory)][string]$Tree, [Parameter(Mandatory)][System.Collections.IDictionary]$Originals)

    foreach ($key in $Originals.Keys)
    {
        $full = Join-IpeTreePath -Root $Tree -Relative $key
        $bytes = [byte[]]$Originals[$key]
        [System.IO.File]::WriteAllBytes($full, $bytes)
        $back = [System.IO.File]::ReadAllBytes($full)
        if (-not [System.Linq.Enumerable]::SequenceEqual($bytes, $back))
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.RestoreFailed' -Message "restoring $full did not reproduce the original bytes; the journal is kept" -Category WriteError -Target $full)
        }
    }
}

function Restore-IpeMutationJournal
{
    # Restores and deletes a journal left by an interrupted run. Returns $null when there is none.
    param([Parameter(Mandatory)][string]$Tree, [Parameter(Mandatory)][string]$JournalPath)

    if (-not (Test-Path -LiteralPath $JournalPath -PathType Leaf))
    {
        return $null
    }

    $journal = Get-Content -LiteralPath $JournalPath -Raw | ConvertFrom-Json
    $originals = [ordered]@{}
    foreach ($file in @($journal.files))
    {
        $originals[[string]$file.path] = [System.Convert]::FromBase64String([string]$file.bytes)
    }

    Restore-IpeOriginals -Tree $Tree -Originals $originals
    Remove-Item -LiteralPath $JournalPath -Force
    return [pscustomobject]@{ Id = [string]$journal.id; Files = [string[]]@($originals.Keys) }
}

function Add-IpeVerdictLine
{
    # Appends one line at the end of a record, in the record's newline style and BOM.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Line)

    $info = Read-IpeText -Path $Path
    $text = $info.Text.TrimEnd([char[]]@("`r", "`n"))
    Write-IpeText -Path $Path -Text ($text + $info.Newline + $Line + $info.Newline) -HasBom $info.HasBom
}

function Test-IpeMutationRecords
{
    # -ValidateOnly: every selected record's edits must match exactly expectedMatches times in the current code.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records, [Parameter(Mandatory)][int]$Parsed, [Parameter(Mandatory)][string]$Directory)

    $report = [System.Collections.Generic.List[string]]::new()
    $checked = 0
    $mismatched = 0
    foreach ($record in $Records)
    {
        if ($record.Status -eq 'stale')
        {
            $report.Add("stale $($record.Id): $($record.StaleReason)")
            continue
        }

        $index = 0
        foreach ($edit in $record.Edits)
        {
            $index++
            $checked++
            $count = Get-IpeMatchCount -Path $edit.Path -Find $edit.Find
            $label = if ($record.Edits.Count -gt 1) { "$($record.Id) edit $index" } else { $record.Id }
            if ($count -eq $edit.ExpectedMatches)
            {
                $report.Add("ok   ${label}: $($edit.File) matches $count (expected $($edit.ExpectedMatches))")
            }
            else
            {
                $mismatched++
                $report.Add("FAIL ${label}: $($edit.File) matches $count, expected $($edit.ExpectedMatches)")
            }
        }
    }

    $counts = foreach ($status in $script:MutationStatuses) { "$(@($Records | Where-Object { $_.Status -eq $status }).Count) $status" }
    $report.Insert(0, "records: $Parsed parsed in $Directory, $($Records.Count) selected ($($counts -join ', '))")
    $report.Add("edits: $checked checked, $($checked - $mismatched) match expectedMatches, $mismatched do not")
    $report.Add($(if ($mismatched -eq 0) { 'validate: pass' } else { 'validate: FAIL' }))
    return [pscustomobject]@{ ExitCode = if ($mismatched -eq 0) { 0 } else { 1 }; Records = $Records; Checked = $checked; Mismatched = $mismatched; Report = $report.ToArray() }
}

function Invoke-IpeMutation
{
    # One mutation: journal, apply, build, test, then restore and prove the bytes are back in finally.
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][object]$Record)

    $cfg = $State.Config
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $originals = [ordered]@{}
    foreach ($edit in $Record.Edits)
    {
        if (-not $originals.Contains($edit.File))
        {
            $originals[$edit.File] = [System.IO.File]::ReadAllBytes($edit.Path)
        }
    }

    $verdict = $null
    $detail = ''
    $failed = 0
    $total = 0
    $logPath = $null
    Write-IpeMutationJournal -Path $State.JournalPath -Id $Record.Id -Originals $originals
    try
    {
        try
        {
            foreach ($edit in $Record.Edits)
            {
                $editArguments = @{ Path = $edit.Path; Find = $edit.Find; Replace = $edit.Replace; ExpectCount = $edit.ExpectedMatches }
                if ($edit.Occurrence)
                {
                    $editArguments.Occurrence = $edit.Occurrence
                }

                [void](Edit-File @editArguments)
            }
        }
        catch
        {
            if ((Get-IpeErrorId $_) -ne 'Ipe.MatchCount')
            {
                throw
            }

            $verdict = 'apply-failed'
            $detail = $_.Exception.Message
        }

        if (-not $verdict)
        {
            $buildLog = Join-Path $State.LogDirectory "$($State.Tag)-$($Record.Id)-build.log"
            [void]$State.Built.Add($Record.ProjectName)
            $build = Invoke-IpeBuild -Root $State.Root -Target $Record.Project.Path -LogPath $buildLog -TimeoutSeconds $cfg.Timeouts.BuildSeconds
            if ($build.TimedOut -or $build.ExitCode -ne 0)
            {
                $verdict = 'build-failed'
                $why = if ($build.TimedOut) { 'timed out' } else { "exit $($build.ExitCode), $($build.Summary.Errors) error(s)" }
                $detail = "$why; log $buildLog"
                $logPath = $buildLog
            }
        }

        if (-not $verdict)
        {
            $logPath = Join-Path $State.LogDirectory "$($State.Tag)-$($Record.Id)-test.log"
            $testArguments = @{
                Root = $State.Root; Project = $Record.Project; Config = $cfg; LogPath = $logPath; NoBuild = $true
                TimeoutSeconds = $State.HangSeconds + 60; InnerTimeout = "$($State.HangSeconds)s"
            }
            if ($Record.Filter)
            {
                $testArguments.Filter = $Record.Filter
            }

            $run = Invoke-IpeTestProject @testArguments
            $summary = $run.Summary
            $failed = $summary.Failed
            $total = $summary.Total
            if ($run.TimedOut)
            {
                $verdict = 'hang-killed'
                $detail = "no result within $($State.HangSeconds + 60) s"
                if ($State.Drive)
                {
                    $stopped = Stop-TestHosts -Drive $State.Drive
                    $detail += "; killed $($stopped.Killed) leftover process(es)"
                }
            }
            elseif ($summary.Failed -gt 0)
            {
                $verdict = 'red'
            }
            elseif ($summary.ZeroTests -or ($summary.Found -and $summary.Total -eq 0))
            {
                $verdict = 'no-tests'
            }
            elseif ($run.ExitCode -eq 0 -and $summary.Found)
            {
                $verdict = 'survived'
            }
            else
            {
                $verdict = 'error'
                $detail = "exit $($run.ExitCode) without failed tests in the log"
            }
        }
    }
    catch
    {
        $verdict = 'error'
        $detail = $_.Exception.Message
    }
    finally
    {
        Restore-IpeOriginals -Tree $State.Tree -Originals $originals
        Remove-Item -LiteralPath $State.JournalPath -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        Id = $Record.Id
        Project = $Record.ProjectName
        Filter = $Record.Filter
        Verdict = $verdict
        Expected = $Record.Expected
        AsExpected = ($verdict -eq $Record.Expected)
        Failed = $failed
        Total = $total
        ElapsedSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
        Detail = $detail
        LogPath = $logPath
    }
}

function Invoke-IpeMutationLoop
{
    param([Parameter(Mandatory)][hashtable]$State)

    $cfg = $State.Config
    foreach ($record in $State.Records)
    {
        if ($record.Status -eq 'stale')
        {
            $State.Results.Add([pscustomobject]@{
                    Id = $record.Id; Project = $record.ProjectName; Filter = $record.Filter; Verdict = 'stale'; Expected = 'stale'; AsExpected = $true
                    Failed = 0; Total = 0; ElapsedSeconds = 0; Detail = $record.StaleReason; LogPath = $null
                })
            continue
        }

        $result = Invoke-IpeMutation -State $State -Record $record
        $State.Results.Add($result)
        if ($State.AppendVerdicts)
        {
            $filterText = if ($record.Filter) { $record.Filter } else { 'none' }
            $date = [System.DateTime]::Now.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
            $line = "- Verified $date at $($State.ShortHead): $($result.Verdict), $($result.Failed) failed of $($result.Total) ($($record.ProjectName), filter $filterText); restored."
            Add-IpeVerdictLine -Path $record.RecordPath -Line $line
        }
    }

    $State.Remnants = Get-IpeDirtyPaths -Worktree $State.Tree -Config $cfg -Pathspec $cfg.SourcePaths -UnstagedOnly:$State.UnstagedOnly
    if ($State.FinalRebuild)
    {
        foreach ($name in ($State.Built | Sort-Object))
        {
            $project = Get-IpeTestProjectConfig -Config $cfg -Name $name
            $log = Join-Path $State.LogDirectory "$($State.Tag)-final-$name.log"
            $build = Invoke-IpeBuild -Root $State.Root -Target $project.Path -LogPath $log -TimeoutSeconds $cfg.Timeouts.BuildSeconds
            $State.Rebuilds.Add([pscustomobject]@{ Project = $name; Passed = (-not $build.TimedOut -and $build.ExitCode -eq 0); LogPath = $log })
        }
    }

    if ($State.SqlUsed)
    {
        try
        {
            $State.Leaked = Remove-LeakedTestDatabases -List -Worktree $State.Tree -ConfigPath $cfg.ConfigPath
        }
        catch
        {
            $State.LeakedError = $_.Exception.Message
        }
    }
}

function Invoke-IpeExtraCheck
{
    # Runs one configured ExtraChecks script as `pwsh -File <script> -Base <sha> -RepoRoot <root>`; it passes only on exit 0.
    param([Parameter(Mandatory)][hashtable]$Check, [Parameter(Mandatory)][string]$Tree, [Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$BaseSha)

    $script = Join-IpeTreePath -Root $Tree -Relative $Check.Script
    $result = [ordered]@{
        Name = $Check.Name; Script = $script; TimeoutSeconds = $Check.TimeoutSeconds; Missing = $false
        ExitCode = $null; TimedOut = $false; Lines = [string[]]@(); Passed = $false
    }
    if (-not (Test-Path -LiteralPath $script -PathType Leaf))
    {
        $result.Missing = $true
        return [pscustomobject]$result
    }

    $pwsh = (Get-Process -Id $PID).Path
    $arguments = [string[]]@('-NoProfile', '-File', $script, '-Base', $BaseSha, '-RepoRoot', $Root)
    $process = Invoke-IpeProcess -FilePath $pwsh -ArgumentList $arguments -WorkingDirectory $Tree -TimeoutSeconds $Check.TimeoutSeconds
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(Split-IpeLines $process.StdOut) + @(Split-IpeLines $process.StdErr))
    {
        $lines.Add($line)
    }

    $result.ExitCode = $process.ExitCode
    $result.TimedOut = $process.TimedOut
    $result.Lines = $lines.ToArray()
    $result.Passed = -not $process.TimedOut -and $process.ExitCode -eq 0
    return [pscustomobject]$result
}

function Invoke-IpeFullCheckSteps
{
    param([Parameter(Mandatory)][hashtable]$State)

    $cfg = $State.Config
    $consoleLog = Join-Path $State.LogDirectory "$($State.Tag)-build.console.log"
    $fileLog = Join-Path $State.LogDirectory "$($State.Tag)-build.log"
    foreach ($stale in @($consoleLog, $fileLog))
    {
        Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue
    }

    $build = Invoke-IpeBuild -Root $State.Root -Target $cfg.Solution -LogPath $consoleLog -TimeoutSeconds $cfg.Timeouts.BuildSeconds -NoIncremental -FileLogPath $fileLog
    $State.Build = $build
    if ($build.TimedOut -or $build.ExitCode -ne 0)
    {
        $State.Failures.Add('build')
        return
    }

    try
    {
        $warnings = Compare-Warnings -Worktree $State.Tree -BuildLog $fileLog -RepoRoot $State.Root -ConfigPath $cfg.ConfigPath
        $State.WarningsVerdict = $warnings.Report[-1]
        $State.WarningsDetail = [string[]]@($warnings.Report | Select-Object -SkipLast 1)
        if ($warnings.ExitCode -ne 0)
        {
            $State.Failures.Add('warnings')
        }
    }
    catch
    {
        if ((Get-IpeErrorId $_) -ne 'Ipe.WarningsScriptMissing')
        {
            throw
        }

        $State.WarningsVerdict = "warnings: FAIL (script missing: $(Join-IpeTreePath -Root $State.Tree -Relative $cfg.Warnings.Script))"
        $State.Failures.Add('warnings')
    }

    foreach ($project in $cfg.TestProjects)
    {
        $log = Join-Path $State.LogDirectory "$($State.Tag)-$($project.Name).log"
        $run = Invoke-IpeTestProject -Root $State.Root -Project $project -Config $cfg -LogPath $log -NoBuild
        $verdict = Get-IpeProjectVerdict -Project $project -Run $run -AllowEmpty $project.AllowEmpty
        $State.Projects[$project.Name] = [pscustomobject]@{ Run = $run; Verdict = $verdict }
        if (-not $verdict.Passed)
        {
            $State.Failures.Add("project $($project.Name)")
        }
    }

    $formatArguments = @{ Worktree = $State.Tree; Base = $State.Base; Tag = $State.Tag; ConfigPath = $cfg.ConfigPath }
    if ($State.Drive)
    {
        $formatArguments.Drive = $State.Drive
    }

    $State.Format = Invoke-Format @formatArguments
    if ($State.Format.ExitCode -ne 0)
    {
        $State.Failures.Add('format')
    }

    $State.LineEndings = Test-LineEndings -Worktree $State.Tree -Base $State.Base -ConfigPath $cfg.ConfigPath
    if ($State.LineEndings.ExitCode -ne 0)
    {
        $State.Failures.Add('line endings')
    }

    foreach ($check in @($cfg.ExtraChecks))
    {
        $result = Invoke-IpeExtraCheck -Check $check -Tree $State.Tree -Root $State.Root -BaseSha $State.BaseSha
        $State.ExtraChecks.Add($result)
        if (-not $result.Passed)
        {
            $State.Failures.Add("extra check $($check.Name)")
        }
    }

    if ($State.SqlUsed)
    {
        try
        {
            $State.Leaked = Remove-LeakedTestDatabases -List -Worktree $State.Tree -ConfigPath $cfg.ConfigPath
        }
        catch
        {
            $State.LeakedError = $_.Exception.Message
        }
    }
}

function Get-IpeFullCheckSummary
{
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][bool]$Passed)

    $cfg = $State.Config
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("full check: $($State.Tag)")
    $lines.Add("head: $($State.Head)")
    $lines.Add("tree: $($State.Tree)")
    $lines.Add("base: $($State.Base) ($($State.BaseSha))")
    $lines.Add("root: $($State.Root)")
    $dirtyText = if ($State.DirtyPaths.Count -eq 0) { 'none' } else { $State.DirtyPaths -join ', ' }
    $lines.Add("dirty paths: $dirtyText")
    $build = $State.Build
    if ($null -eq $build)
    {
        $lines.Add('build: not run')
    }
    else
    {
        $buildVerdict = if ($build.TimedOut) { 'FAIL (timed out)' } elseif ($build.ExitCode -ne 0) { "FAIL (exit $($build.ExitCode))" } else { 'pass' }
        $lines.Add("build: $buildVerdict, $($build.Summary.Errors) error(s), $($build.Summary.Warnings) warning(s), $($build.ElapsedSeconds) s; log $($build.LogPath)")
    }

    $lines.Add($(if ($State.WarningsVerdict) { $State.WarningsVerdict } else { 'warnings: not run' }))
    foreach ($line in $State.WarningsDetail)
    {
        $lines.Add("  $line")
    }

    foreach ($project in $cfg.TestProjects)
    {
        if (-not $State.Projects.Contains($project.Name))
        {
            $lines.Add("project $($project.Name) ($($project.Kind)): not run")
            continue
        }

        $entry = $State.Projects[$project.Name]
        $summary = $entry.Run.Summary
        $verdict = if ($entry.Verdict.Passed) { $entry.Verdict.Reason } else { "FAIL ($($entry.Verdict.Reason))" }
        $lines.Add("project $($project.Name) ($($project.Kind)): passed $($summary.Succeeded), failed $($summary.Failed), skipped $($summary.Skipped), total $($summary.Total), exit $($entry.Run.ExitCode), $($entry.Run.ElapsedSeconds) s - $verdict")
        foreach ($name in $summary.FailedNames)
        {
            $lines.Add("  failed: $name")
        }
    }

    $lines.Add($(if ($State.Format) { $State.Format.Report[-1] } else { 'format: not run' }))
    if ($State.Format)
    {
        foreach ($line in @($State.Format.Report | Where-Object { $_ -like 'format *: FAIL*' -or $_ -like '  *' }))
        {
            $lines.Add("  $($line.Trim())")
        }
    }

    $lines.Add($(if ($State.LineEndings) { $State.LineEndings.Report[-1] } else { 'line endings: not run' }))
    if ($State.LineEndings)
    {
        foreach ($line in @($State.LineEndings.Report | Where-Object { $_.StartsWith('FAIL ') }))
        {
            $lines.Add("  $line")
        }
    }

    foreach ($check in @($cfg.ExtraChecks))
    {
        $entry = @($State.ExtraChecks | Where-Object { $_.Name -eq $check.Name }) | Select-Object -First 1
        $verdict = if ($null -eq $entry) { 'not run' } elseif ($entry.Missing) { "FAIL (script missing: $($entry.Script))" } elseif ($entry.TimedOut) { "FAIL (timed out after $($entry.TimeoutSeconds) s)" } elseif ($entry.ExitCode -ne 0) { "FAIL (exit $($entry.ExitCode))" } else { 'pass' }
        $lines.Add("extra check $($check.Name): $verdict")
        if ($null -ne $entry)
        {
            foreach ($line in $entry.Lines)
            {
                $lines.Add("  $line")
            }
        }
    }

    if ($State.LeakedError)
    {
        $lines.Add("leaked databases: not listed ($($State.LeakedError))")
    }
    elseif ($State.Leaked)
    {
        $lines.Add($State.Leaked.Report[-1])
        foreach ($name in $State.Leaked.Leaked)
        {
            $lines.Add("  leaked $name")
        }
    }
    else
    {
        $lines.Add('leaked databases: not listed (no project needs SQL)')
    }

    $overall = if ($Passed) { 'overall: pass' } else { "overall: FAIL ($($State.Failures -join ', '))" }
    $lines.Add($overall)
    return , $lines.ToArray()
}

function Invoke-Focused
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Project,
        [string[]]$Classes = @(),
        [string]$Filter,
        [switch]$NoBuild,
        [int]$TimeoutSeconds,
        [switch]$Trx,
        [string]$Tag,
        [switch]$AllowSkip,
        [string]$Drive,
        [string]$ConfigPath
    )

    Assert-IpeAbsolutePath -Path $Worktree -Name 'Worktree'
    $tree = Get-IpeNormalPath $Worktree
    $config = Resolve-IpeConfig -Worktree $tree -ConfigPath $ConfigPath
    $row = Get-IpeTestProjectConfig -Config $config -Name $Project
    $testFilter = Resolve-IpeTestFilter -Kind $row.Kind -Classes $Classes -Filter $Filter
    if (-not $Tag)
    {
        $Tag = "focused-$($row.Name)"
    }

    Assert-IpeName -Value $Tag -Name 'Tag'
    if (-not $TimeoutSeconds)
    {
        $TimeoutSeconds = $config.Timeouts.FocusedSeconds
    }

    $logDirectory = Get-IpeLogDirectory -Tree $tree -Config $config
    $driveArguments = @{ Worktree = $tree; ConfigPath = $config.ConfigPath }
    if ($Drive)
    {
        $driveArguments.Drive = $Drive
    }

    $report = [System.Collections.Generic.List[string]]::new()
    $filterText = if ($testFilter) { $testFilter } else { 'none' }
    $mapping = Use-Drive @driveArguments
    try
    {
        if (-not $NoBuild)
        {
            $buildLog = Join-Path $logDirectory "$Tag-build.log"
            $build = Invoke-IpeBuild -Root $mapping.Root -Target $row.Path -LogPath $buildLog -TimeoutSeconds $config.Timeouts.BuildSeconds
            if ($build.TimedOut -or $build.ExitCode -ne 0)
            {
                $report.Add("build $($row.Path): FAIL (exit $($build.ExitCode), $($build.Summary.Errors) error(s)); log $buildLog")
                $report.Add('focused: FAIL (build)')
                return [pscustomobject]@{ ExitCode = 1; Run = $null; Filter = $testFilter; Report = $report.ToArray() }
            }
        }

        $focusedArguments = @{
            Root = $mapping.Root; Project = $row; Config = $config; LogPath = (Join-Path $logDirectory "$Tag.log")
            NoBuild = $true; TimeoutSeconds = $TimeoutSeconds
        }
        if ($testFilter)
        {
            $focusedArguments.Filter = $testFilter
        }

        if ($Trx)
        {
            $focusedArguments.TrxPath = Join-Path $logDirectory "$Tag.trx"
        }

        $focusedRun = Invoke-IpeSqlScope -SqlNeeded $row.NeedsSql -SqlConfig $config -SqlTree $tree -SqlBody { Invoke-IpeTestProject @focusedArguments }
    }
    finally
    {
        if ($mapping.Created)
        {
            [void](Use-Drive -Worktree $tree -Drive $mapping.Drive -Unmap -ConfigPath $config.ConfigPath)
        }
    }

    $verdict = Get-IpeProjectVerdict -Project $row -Run $focusedRun -AllowEmpty $false -AllowSkip ([bool]$AllowSkip)
    $report.Add("focused $($row.Name) ($($row.Kind)) filter ${filterText}: $(Format-IpeRunCounts -Run $focusedRun), $($focusedRun.ElapsedSeconds) s")
    foreach ($name in $focusedRun.Summary.FailedNames)
    {
        $report.Add("failed: $name")
    }

    $report.Add("log: $($focusedRun.LogPath)")
    if ($Trx)
    {
        $report.Add("trx: $($focusedArguments.TrxPath)")
    }

    $report.Add($(if ($verdict.Passed) { "focused: pass ($($verdict.Reason))" } else { "focused: FAIL ($($verdict.Reason))" }))
    return [pscustomobject]@{ ExitCode = if ($verdict.Passed) { 0 } else { 1 }; Run = $focusedRun; Filter = $testFilter; Report = $report.ToArray() }
}

function Repeat-Tests
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Project,
        [string[]]$Classes = @(),
        [string]$Filter,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$Runs,
        [int]$TimeoutSeconds,
        [int]$MaxThreads,
        [int]$MinThreads,
        [switch]$Trx,
        [switch]$NoBuild,
        [int]$Slowest,
        [string]$Tag,
        [string]$Drive,
        [string]$ConfigPath
    )

    Assert-IpeAbsolutePath -Path $Worktree -Name 'Worktree'
    $tree = Get-IpeNormalPath $Worktree
    $config = Resolve-IpeConfig -Worktree $tree -ConfigPath $ConfigPath
    $row = Get-IpeTestProjectConfig -Config $config -Name $Project
    $testFilter = Resolve-IpeTestFilter -Kind $row.Kind -Classes $Classes -Filter $Filter
    if (-not $Tag)
    {
        $Tag = "repeat-$($row.Name)"
    }

    Assert-IpeName -Value $Tag -Name 'Tag'
    if (-not $TimeoutSeconds)
    {
        $TimeoutSeconds = $config.Timeouts.FocusedSeconds
    }

    # The runtime reads DOTNET_ thread-pool knobs as hexadecimal numbers.
    $threadEnvironment = @{}
    if ($MaxThreads -gt 0)
    {
        $threadEnvironment['DOTNET_ThreadPool_ForceMaxWorkerThreads'] = $MaxThreads.ToString('X', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    if ($MinThreads -gt 0)
    {
        $threadEnvironment['DOTNET_ThreadPool_ForceMinWorkerThreads'] = $MinThreads.ToString('X', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    $wantTrx = $Trx -or $Slowest -gt 0
    $logDirectory = Get-IpeLogDirectory -Tree $tree -Config $config
    $driveArguments = @{ Worktree = $tree; ConfigPath = $config.ConfigPath }
    if ($Drive)
    {
        $driveArguments.Drive = $Drive
    }

    $report = [System.Collections.Generic.List[string]]::new()
    $repeatRuns = [System.Collections.Generic.List[object]]::new()
    $mapping = Use-Drive @driveArguments
    try
    {
        if (-not $NoBuild)
        {
            $buildLog = Join-Path $logDirectory "$Tag-build.log"
            $build = Invoke-IpeBuild -Root $mapping.Root -Target $row.Path -LogPath $buildLog -TimeoutSeconds $config.Timeouts.BuildSeconds
            if ($build.TimedOut -or $build.ExitCode -ne 0)
            {
                $report.Add("build $($row.Path): FAIL (exit $($build.ExitCode), $($build.Summary.Errors) error(s)); log $buildLog")
                $report.Add('repeat: FAIL (build)')
                return [pscustomobject]@{ ExitCode = 1; Runs = @(); Report = $report.ToArray() }
            }
        }

        $repeatSettings = @{ Root = $mapping.Root; Row = $row; Config = $config; Filter = $testFilter; Timeout = $TimeoutSeconds; Environment = $threadEnvironment; Count = $Runs; Directory = $logDirectory; Tag = $Tag; Trx = $wantTrx }
        [void](Invoke-IpeSqlScope -SqlNeeded $row.NeedsSql -SqlConfig $config -SqlTree $tree -SqlBody {
                for ($repeatIndex = 1; $repeatIndex -le $repeatSettings.Count; $repeatIndex++)
                {
                    $runArguments = @{
                        Root = $repeatSettings.Root; Project = $repeatSettings.Row; Config = $repeatSettings.Config; NoBuild = $true
                        LogPath = (Join-Path $repeatSettings.Directory "$($repeatSettings.Tag)-run$repeatIndex.log"); TimeoutSeconds = $repeatSettings.Timeout
                        Environment = $repeatSettings.Environment
                    }
                    if ($repeatSettings.Filter)
                    {
                        $runArguments.Filter = $repeatSettings.Filter
                    }

                    if ($repeatSettings.Trx)
                    {
                        $runArguments.TrxPath = Join-Path $repeatSettings.Directory "$($repeatSettings.Tag)-run$repeatIndex.trx"
                    }

                    $repeatRuns.Add([pscustomobject]@{ Index = $repeatIndex; Run = (Invoke-IpeTestProject @runArguments); TrxPath = $runArguments['TrxPath'] })
                }
            })
    }
    finally
    {
        if ($mapping.Created)
        {
            [void](Use-Drive -Worktree $tree -Drive $mapping.Drive -Unmap -ConfigPath $config.ConfigPath)
        }
    }

    $failedRuns = 0
    $filterText = if ($testFilter) { $testFilter } else { 'none' }
    $report.Add("repeat $($row.Name) ($($row.Kind)) filter ${filterText}: $Runs run(s)$(if ($threadEnvironment.Count) { ', ' + (($threadEnvironment.Keys | Sort-Object | ForEach-Object { "$_=0x$($threadEnvironment[$_])" }) -join ' ') })")
    foreach ($entry in $repeatRuns)
    {
        $run = $entry.Run
        $verdict = Get-IpeProjectVerdict -Project $row -Run $run -AllowEmpty $false -AllowSkip $true
        if (-not $verdict.Passed)
        {
            $failedRuns++
        }

        $names = if ($run.Summary.FailedNames.Count -gt 0) { ' [' + ($run.Summary.FailedNames -join ', ') + ']' } else { '' }
        $timedOut = if ($run.TimedOut) { ' timed-out' } else { '' }
        $report.Add("run $($entry.Index)/$Runs exit $($run.ExitCode)$timedOut wall $($run.ElapsedSeconds)s total $($run.Summary.Total) failed $($run.Summary.Failed) skipped $($run.Summary.Skipped)$names")
    }

    if ($Slowest -gt 0)
    {
        $byName = @{}
        foreach ($entry in $repeatRuns)
        {
            if (-not $entry.TrxPath -or -not (Test-Path -LiteralPath $entry.TrxPath -PathType Leaf))
            {
                $report.Add("run $($entry.Index): no TRX file at $($entry.TrxPath)")
                continue
            }

            foreach ($result in (Get-IpeTrxResults -Path $entry.TrxPath))
            {
                if (-not $byName.ContainsKey($result.Name) -or $byName[$result.Name].Duration -lt $result.Duration)
                {
                    $byName[$result.Name] = [pscustomobject]@{ Name = $result.Name; Duration = $result.Duration; Run = $entry.Index }
                }
            }
        }

        foreach ($item in @($byName.Values | Sort-Object -Property @{ Expression = { $_.Duration }; Descending = $true }, Name | Select-Object -First $Slowest))
        {
            $report.Add(('slowest: {0} s  {1} (run {2})' -f $item.Duration.TotalSeconds.ToString('F3', [System.Globalization.CultureInfo]::InvariantCulture), $item.Name, $item.Run))
        }
    }

    $report.Add($(if ($failedRuns -eq 0) { "repeat: pass ($Runs of $Runs runs passed)" } else { "repeat: FAIL ($failedRuns of $Runs runs failed)" }))
    return [pscustomobject]@{ ExitCode = if ($failedRuns -eq 0) { 0 } else { 1 }; Runs = $repeatRuns.ToArray(); Report = $report.ToArray() }
}

function Invoke-FullCheck
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Base,
        [string]$Tag = 'full-check',
        [string]$Drive,
        [string]$ConfigPath
    )

    Assert-IpeAbsolutePath -Path $Worktree -Name 'Worktree'
    Assert-IpeName -Value $Tag -Name 'Tag'
    $tree = Get-IpeNormalPath $Worktree
    $config = Resolve-IpeConfig -Worktree $tree -ConfigPath $ConfigPath
    $baseSha = (Invoke-Git -Worktree $tree -Arguments @('rev-parse', '--verify', "$Base^{commit}")).Lines[0].Trim()
    $logDirectory = Get-IpeLogDirectory -Tree $tree -Config $config
    $fullCheckState = @{
        Config = $config; Tree = $tree; Base = $Base; BaseSha = $baseSha; Tag = $Tag; LogDirectory = $logDirectory
        Head = Get-IpeHead -Worktree $tree; DirtyPaths = (Get-IpeDirtyPaths -Worktree $tree -Config $config)
        SqlUsed = (@($config.TestProjects | Where-Object { $_.NeedsSql }).Count -gt 0)
        Root = $null; Drive = $null; Build = $null; WarningsVerdict = $null; WarningsDetail = [string[]]@()
        Projects = [ordered]@{}; Format = $null; LineEndings = $null; Leaked = $null; LeakedError = $null
        ExtraChecks = [System.Collections.Generic.List[object]]::new()
        Failures = [System.Collections.Generic.List[string]]::new()
    }

    $driveArguments = @{ Worktree = $tree; ConfigPath = $config.ConfigPath }
    if ($Drive)
    {
        $driveArguments.Drive = $Drive
    }

    $mapping = Use-Drive @driveArguments
    try
    {
        $fullCheckState.Root = $mapping.Root
        $fullCheckState.Drive = $mapping.Drive
        [void](Invoke-IpeSqlScope -SqlNeeded $fullCheckState.SqlUsed -SqlConfig $config -SqlTree $tree -SqlBody { Invoke-IpeFullCheckSteps -State $fullCheckState })
    }
    finally
    {
        if ($mapping.Created)
        {
            [void](Use-Drive -Worktree $tree -Drive $mapping.Drive -Unmap -ConfigPath $config.ConfigPath)
        }
    }

    $headAfter = Get-IpeHead -Worktree $tree
    if ($headAfter -ne $fullCheckState.Head)
    {
        $fullCheckState.Failures.Add("HEAD moved from $($fullCheckState.Head) to $headAfter")
    }

    $passed = $fullCheckState.Failures.Count -eq 0
    $summaryPath = Join-Path $logDirectory "$Tag-summary.txt"
    $lines = Get-IpeFullCheckSummary -State $fullCheckState -Passed $passed
    [System.IO.File]::WriteAllText($summaryPath, ($lines -join [System.Environment]::NewLine) + [System.Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $record = [ordered]@{
        result = if ($passed) { 'pass' } else { 'fail' }
        head = $fullCheckState.Head
        tree = $tree
        dirtyPaths = [string[]]$fullCheckState.DirtyPaths
        summaryPath = $summaryPath
        finished = [System.DateTimeOffset]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    $recordPath = Join-Path $logDirectory "$Tag-record.json"
    $json = $record | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText($recordPath, $json, [System.Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath $recordPath -Destination (Join-Path $logDirectory 'last-full-check.json') -Force

    $report = [System.Collections.Generic.List[string]]::new()
    $report.AddRange([string[]]$lines)
    $report.Add("summary: $summaryPath")
    $report.Add("record: $recordPath")
    return [pscustomobject]@{
        ExitCode = if ($passed) { 0 } else { 1 }
        Passed = $passed
        Failures = $fullCheckState.Failures.ToArray()
        SummaryPath = $summaryPath
        RecordPath = $recordPath
        Projects = $fullCheckState.Projects
        Report = $report.ToArray()
    }
}

function Invoke-Mutations
{
    [CmdletBinding(DefaultParameterSetName = 'Feature')]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory, ParameterSetName = 'Feature')][string]$Feature,
        [Parameter(Mandatory, ParameterSetName = 'SpecDir')][string]$SpecDir,
        [string[]]$Only = @(),
        [int]$HangSeconds,
        [switch]$AppendVerdicts,
        [switch]$RestoreOnly,
        [switch]$ValidateOnly,
        [switch]$NoFinalRebuild,
        [switch]$AllowStaged,
        [string]$Tag = 'mutations',
        [string]$Drive,
        [string]$ConfigPath
    )

    Assert-IpeAbsolutePath -Path $Worktree -Name 'Worktree'
    Assert-IpeName -Value $Tag -Name 'Tag'
    if ($ValidateOnly -and ($RestoreOnly -or $AppendVerdicts))
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message '-ValidateOnly cannot be combined with -RestoreOnly or -AppendVerdicts' -Category InvalidArgument)
    }

    $tree = Get-IpeNormalPath $Worktree
    $config = Resolve-IpeConfig -Worktree $tree -ConfigPath $ConfigPath
    $logDirectory = Get-IpeLogDirectory -Tree $tree -Config $config
    $journalPath = Join-Path $logDirectory $script:MutationJournalName
    $report = [System.Collections.Generic.List[string]]::new()
    if ($ValidateOnly)
    {
        if (Test-Path -LiteralPath $journalPath -PathType Leaf)
        {
            return [pscustomobject]@{ ExitCode = 1; Report = [string[]]@("a restore journal from an interrupted run exists ($journalPath): run Invoke-Mutations -RestoreOnly first", 'validate: FAIL') }
        }
    }
    else
    {
        $restored = Restore-IpeMutationJournal -Tree $tree -JournalPath $journalPath
        if ($restored)
        {
            $report.Add("restored $($restored.Files.Count) file(s) left mutated by an interrupted run of $($restored.Id): $($restored.Files -join ', ')")
        }

        if ($RestoreOnly)
        {
            if (-not $restored)
            {
                $report.Add('restore: nothing to restore')
            }

            return [pscustomobject]@{ ExitCode = 0; Results = @(); Report = $report.ToArray() }
        }
    }

    if ($PSCmdlet.ParameterSetName -eq 'Feature')
    {
        Assert-IpeName -Value $Feature -Name 'Feature'
        $specDirectory = Join-IpeTreePath -Root $tree -Relative $config.MutationSpecDir.Replace('{feature}', $Feature)
    }
    else
    {
        Assert-IpeAbsolutePath -Path $SpecDir -Name 'SpecDir'
        $specDirectory = Get-IpeNormalPath $SpecDir
    }

    if (-not $ValidateOnly)
    {
        # AllowStaged: Merge-Ticket mutates a merge that is staged but not yet committed; only unstaged changes count.
        $dirty = Get-IpeDirtyPaths -Worktree $tree -Config $config -Pathspec $config.SourcePaths -UnstagedOnly:$AllowStaged
        if ($dirty.Count -gt 0)
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.DirtyTree' -Message "refusing to mutate a tree with $($dirty.Count) changed path(s) under $($config.SourcePaths -join ', '): $($dirty -join ', ')" -Category InvalidOperation)
        }
    }

    $records = Read-IpeMutationRecords -Directory $specDirectory -Tree $tree -Config $config
    $selected = Select-IpeMutationRecords -Records $records -Only $Only
    if ($ValidateOnly)
    {
        return Test-IpeMutationRecords -Records $selected -Parsed $records.Count -Directory $specDirectory
    }

    if (-not $HangSeconds)
    {
        $HangSeconds = $config.Timeouts.MutationHangSeconds
    }

    $runnable = @($selected | Where-Object { $_.Status -ne 'stale' })
    $mutationState = @{
        Config = $config; Tree = $tree; Records = $selected; JournalPath = $journalPath; LogDirectory = $logDirectory; Tag = $Tag
        HangSeconds = $HangSeconds; AppendVerdicts = [bool]$AppendVerdicts; FinalRebuild = -not $NoFinalRebuild; UnstagedOnly = [bool]$AllowStaged
        SqlUsed = (@($runnable | Where-Object { $_.Project.NeedsSql }).Count -gt 0)
        ShortHead = Get-IpeHead -Worktree $tree -Short; Root = $tree; Drive = $null
        Results = [System.Collections.Generic.List[object]]::new()
        Built = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Rebuilds = [System.Collections.Generic.List[object]]::new()
        Remnants = [string[]]@(); Leaked = $null; LeakedError = $null
    }

    $mapping = $null
    if ($runnable.Count -gt 0)
    {
        $driveArguments = @{ Worktree = $tree; ConfigPath = $config.ConfigPath }
        if ($Drive)
        {
            $driveArguments.Drive = $Drive
        }

        $mapping = Use-Drive @driveArguments
    }

    try
    {
        if ($mapping)
        {
            $mutationState.Root = $mapping.Root
            $mutationState.Drive = $mapping.Drive
        }

        [void](Invoke-IpeSqlScope -SqlNeeded $mutationState.SqlUsed -SqlConfig $config -SqlTree $tree -SqlBody { Invoke-IpeMutationLoop -State $mutationState })
    }
    finally
    {
        if ($mapping -and $mapping.Created)
        {
            [void](Use-Drive -Worktree $tree -Drive $mapping.Drive -Unmap -ConfigPath $config.ConfigPath)
        }
    }

    $results = $mutationState.Results.ToArray()
    $unexpected = @($results | Where-Object { -not $_.AsExpected })
    $failedRebuilds = @($mutationState.Rebuilds | Where-Object { -not $_.Passed })
    $report.Add("mutations: $($selected.Count) of $($records.Count) record(s) from $specDirectory at $($mutationState.ShortHead), hang limit $HangSeconds s")
    $report.Add(('{0,-10} {1,-34} {2,-13} {3,-9} {4,-13} {5}' -f 'id', 'project', 'verdict', 'expected', 'failed/total', 'seconds'))
    foreach ($result in $results)
    {
        $report.Add(('{0,-10} {1,-34} {2,-13} {3,-9} {4,-13} {5}' -f $result.Id, $result.Project, $result.Verdict, $result.Expected, "$($result.Failed)/$($result.Total)", $result.ElapsedSeconds))
        if ($result.Detail -and -not $result.AsExpected -or $result.Verdict -eq 'stale')
        {
            $report.Add("  $($result.Detail)")
        }
    }

    $remnants = [string[]]$mutationState.Remnants
    $report.Add($(if ($remnants.Count -eq 0) { "tree: clean ($($config.SourcePaths -join ', '))" } else { "tree: FAIL, left changed: $($remnants -join ', ')" }))
    if ($mutationState.FinalRebuild)
    {
        $rebuildText = if ($mutationState.Rebuilds.Count -eq 0) { 'nothing built' } elseif ($failedRebuilds.Count -eq 0) { "pass ($(($mutationState.Rebuilds | ForEach-Object { $_.Project }) -join ', '))" } else { "FAIL ($(($failedRebuilds | ForEach-Object { "$($_.Project), log $($_.LogPath)" }) -join '; '))" }
        $report.Add("final rebuild: $rebuildText")
    }

    if ($mutationState.LeakedError)
    {
        $report.Add("leaked databases: not listed ($($mutationState.LeakedError))")
    }
    elseif ($mutationState.Leaked)
    {
        $report.Add($mutationState.Leaked.Report[-1])
    }

    $passed = $unexpected.Count -eq 0 -and $remnants.Count -eq 0 -and $failedRebuilds.Count -eq 0
    $asExpected = $results.Count - $unexpected.Count
    $report.Add($(if ($passed) { "mutations: pass ($asExpected as expected)" } else { "mutations: FAIL ($asExpected as expected, $($unexpected.Count) not)" }))
    return [pscustomobject]@{
        ExitCode = if ($passed) { 0 } else { 1 }
        Results = $results
        Remnants = $remnants
        Report = $report.ToArray()
    }
}

# Workflow: commits, merges, tickets, worktrees, the run ledger and review findings ----------------------------------

$script:WorkflowIdPattern = '^wf_[0-9a-f]{16}\z'
$script:LedgerHeaderPattern = '^\s*\|\s*#\s*\|\s*State\s*\|'
# Ledger column for each Update-Ledger parameter, by header name.
$script:LedgerColumns = [ordered]@{
    State = @('State')
    Worktree = @('Worktree / branch', 'Worktree')
    SourceHead = @('Source HEAD')
    Workflow = @('Workflows')
    Note = @('Notes')
}

function ConvertTo-IpeRepoPath
{
    # Repo-relative '/' form of Path (absolute, or relative to the first root); $null when it is under none of Roots.
    # Several roots because a caller may spell the tree differently from git (a short 8.3 TEMP path, for example).
    param([Parameter(Mandatory)][string[]]$Roots, [Parameter(Mandatory)][string]$Path)

    $full = if ([System.IO.Path]::IsPathFullyQualified($Path)) { [System.IO.Path]::GetFullPath($Path) } else { [System.IO.Path]::GetFullPath((Join-IpeTreePath -Root $Roots[0] -Relative $Path)) }
    foreach ($root in $Roots)
    {
        $relative = [System.IO.Path]::GetRelativePath($root, $full)
        $outside = $relative -eq '.' -or $relative -eq '..' -or [System.IO.Path]::IsPathRooted($relative) -or
            $relative.StartsWith('..' + [System.IO.Path]::DirectorySeparatorChar) -or $relative.StartsWith('../')
        if (-not $outside)
        {
            return $relative.Replace('\', '/')
        }
    }

    return $null
}

function Get-IpeShortSha
{
    param([Parameter(Mandatory)][string]$Worktree, [Parameter(Mandatory)][string]$Revision)

    return (Invoke-Git -Worktree $Worktree -Arguments @('rev-parse', '--short', $Revision)).Lines[0].Trim()
}

function Get-IpeMergeHead
{
    param([Parameter(Mandatory)][string]$Worktree)

    $result = Invoke-Git -Worktree $Worktree -Arguments @('rev-parse', '-q', '--verify', 'MERGE_HEAD') -AllowExitCodes @(0, 1)
    if ($result.ExitCode -ne 0 -or $result.Lines.Count -eq 0)
    {
        return $null
    }

    return $result.Lines[0].Trim()
}

function Get-IpeStagedPaths
{
    # Paths staged in the index (vs HEAD, or vs Against).
    param([Parameter(Mandatory)][string]$Worktree, [string]$Against)

    $arguments = [System.Collections.Generic.List[string]]@('diff', '--cached', '--name-only', '--no-renames', '-z')
    if ($Against)
    {
        $arguments.Add($Against)
    }

    return , (Split-IpeNul (Invoke-Git -Worktree $Worktree -Arguments $arguments.ToArray()).StdOut)
}

function Get-IpeUnmergedPaths
{
    param([Parameter(Mandatory)][string]$Worktree)

    return , (Split-IpeNul (Invoke-Git -Worktree $Worktree -Arguments @('diff', '--name-only', '--diff-filter=U', '-z')).StdOut)
}

function Invoke-IpeCommitMessage
{
    # Commits the index with Message through a temporary UTF-8 (no BOM) file and git commit -F; the file is deleted in
    # finally. Returns the new HEAD and the temporary path (gone by then).
    param([Parameter(Mandatory)][string]$Worktree, [Parameter(Mandatory)][string]$Message, [Parameter(Mandatory)][int]$TimeoutSeconds)

    $messageFile = Join-Path ([System.IO.Path]::GetTempPath()) "ipe-commit-$([guid]::NewGuid().ToString('N')).txt"
    try
    {
        [System.IO.File]::WriteAllText($messageFile, $Message, [System.Text.UTF8Encoding]::new($false))
        [void](Invoke-Git -Worktree $Worktree -Arguments @('commit', '-q', '-F', $messageFile) -TimeoutSeconds $TimeoutSeconds)
    }
    finally
    {
        Remove-Item -LiteralPath $messageFile -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{ Sha = (Get-IpeHead -Worktree $Worktree); MessageFile = $messageFile }
}

function Get-IpeJsonValue
{
    # A property of a ConvertFrom-Json object, or $null when it is absent (strict mode throws on a missing property).
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Object)
    {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property)
    {
        return $null
    }

    return $property.Value
}

function Read-IpeJsonFile
{
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ErrorId)

    try
    {
        return , ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -NoEnumerate)
    }
    catch [System.ArgumentException]
    {
        throw (New-IpeErrorRecord -ErrorId $ErrorId -Message "$Path is not valid JSON: $($_.Exception.Message)" -Category InvalidData)
    }
}

function Split-IpeLineSegments
{
    # Lines with their own terminators ('', LF or CRLF), so a file can be rebuilt byte for byte around one edit.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $segments = [System.Collections.Generic.List[object]]::new()
    foreach ($match in [regex]::Matches($Text, '[^\n]*\n|[^\n]+$'))
    {
        $value = $match.Value
        $terminator = if ($value.EndsWith("`r`n")) { "`r`n" } elseif ($value.EndsWith("`n")) { "`n" } else { '' }
        $segments.Add([pscustomobject]@{ Content = $value.Substring(0, $value.Length - $terminator.Length); Terminator = $terminator })
    }

    return , $segments
}

function Split-IpeTableCells
{
    # Cells of a Markdown table row, trimmed, with escaped pipes ('\|') kept as written.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)

    $body = $Line.Trim()
    if ($body.StartsWith('|'))
    {
        $body = $body.Substring(1)
    }

    if ($body.EndsWith('|') -and -not $body.EndsWith('\|'))
    {
        $body = $body.Substring(0, $body.Length - 1)
    }

    return , [string[]]@([regex]::Split($body, '(?<!\\)\|') | ForEach-Object { $_.Trim() })
}

function ConvertTo-IpeTableValue
{
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    return $Value.Trim().Replace('|', '\|')
}

function Get-IpeMergeMutationIds
{
    # Ids of the non-stale mutation records that edit one of Files. None when the directory holds no records.
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Tree,
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Files
    )

    if ($Files.Count -eq 0 -or -not (Test-Path -LiteralPath $Directory -PathType Container) -or
        @(Get-ChildItem -LiteralPath $Directory -Filter '*.md' -File).Count -eq 0)
    {
        return , [string[]]@()
    }

    $changed = [System.Collections.Generic.HashSet[string]]::new([string[]]$Files, [System.StringComparer]::OrdinalIgnoreCase)
    $records = Read-IpeMutationRecords -Directory $Directory -Tree $Tree -Config $Config
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($record in $records)
    {
        if ($record.Status -eq 'stale')
        {
            continue
        }

        foreach ($edit in $record.Edits)
        {
            if ($changed.Contains($edit.File))
            {
                $ids.Add($record.Id)
                break
            }
        }
    }

    return , $ids.ToArray()
}

function Undo-IpeMerge
{
    param([Parameter(Mandatory)][string]$Worktree, [Parameter(Mandatory)][string]$PreTip)

    [void](Invoke-Git -Worktree $Worktree -Arguments @('merge', '--abort'))
    $head = Get-IpeHead -Worktree $Worktree
    if ($head -ne $PreTip)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.MergeAbortFailed' -Message "after git merge --abort HEAD is $head, expected $PreTip" -Category InvalidResult)
    }

    return "merge aborted; HEAD unchanged at $(Get-IpeShortSha -Worktree $Worktree -Revision $PreTip)"
}

function Invoke-IpeMergeVerification
{
    # Verifies a staged, uncommitted merge. A merged tree equal to the source tree that the implementer's full-check
    # record covers needs only the line-ending check; anything else gets a full check and the affected mutations.
    param(
        [Parameter(Mandatory)][string]$Integration,
        [Parameter(Mandatory)][string]$SourceTree,
        [Parameter(Mandatory)][string]$SourceHead,
        [Parameter(Mandatory)][string]$PreTip,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$SpecDirectory,
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$Drive
    )

    $report = [System.Collections.Generic.List[string]]::new()
    $preShort = Get-IpeShortSha -Worktree $Integration -Revision $PreTip
    $sourceShort = Get-IpeShortSha -Worktree $Integration -Revision $SourceHead
    $mergedTree = (Invoke-Git -Worktree $Integration -Arguments @('write-tree')).Lines[0].Trim()
    $sourceTreeHash = (Invoke-Git -Worktree $Integration -Arguments @('rev-parse', "$SourceHead^{tree}")).Lines[0].Trim()
    $treeEqual = $mergedTree -eq $sourceTreeHash
    $report.Add($(if ($treeEqual) { "merged tree equals the tree of $sourceShort" } else { "merged tree differs from the tree of $sourceShort" }))

    $recordPath = Join-Path (Join-IpeTreePath -Root $SourceTree -Relative $Config.LogDir) 'last-full-check.json'
    $record = $null
    $verified = $false
    if ($treeEqual)
    {
        if (Test-Path -LiteralPath $recordPath -PathType Leaf)
        {
            try
            {
                $record = Read-IpeJsonFile -Path $recordPath -ErrorId 'Ipe.RecordInvalid'
            }
            catch
            {
                if ((Get-IpeErrorId $_) -ne 'Ipe.RecordInvalid')
                {
                    throw
                }

                $report.Add("implementer record ${recordPath}: $($_.Exception.Message)")
            }

            if ($record)
            {
                $result = [string](Get-IpeJsonValue $record 'result')
                $head = [string](Get-IpeJsonValue $record 'head')
                $dirtyCount = @(@(Get-IpeJsonValue $record 'dirtyPaths') | Where-Object { $_ }).Count
                $verified = $result -eq 'pass' -and $head -eq $SourceHead -and $dirtyCount -eq 0
                if (-not $verified)
                {
                    $report.Add("implementer record $recordPath does not cover ${sourceShort}: result '$result', head '$head', $dirtyCount dirty path(s)")
                }
            }
        }
        else
        {
            $report.Add("no implementer record at $recordPath")
        }
    }

    if ($verified)
    {
        $lineEndings = Test-LineEndings -Worktree $Integration -Base $PreTip -ConfigPath $Config.ConfigPath
        $report.AddRange([string[]]$lineEndings.Report)
        return [pscustomobject]@{
            Passed = ($lineEndings.ExitCode -eq 0)
            Line = "verified by the implementer at $sourceShort (record $recordPath); line endings checked against $preShort"
            SummaryPath = [string](Get-IpeJsonValue $record 'summaryPath')
            Report = $report.ToArray()
        }
    }

    $checkArguments = @{ Worktree = $Integration; Base = $PreTip; Tag = "merge-$Id"; ConfigPath = $Config.ConfigPath }
    if ($Drive)
    {
        $checkArguments.Drive = $Drive
    }

    $check = Invoke-FullCheck @checkArguments
    $report.AddRange([string[]]$check.Report)
    if ($check.ExitCode -ne 0)
    {
        return [pscustomobject]@{ Passed = $false; Line = "full check against $preShort failed"; SummaryPath = $check.SummaryPath; Report = $report.ToArray() }
    }

    $changed = Get-IpeStagedPaths -Worktree $Integration -Against $SourceHead
    $ids = Get-IpeMergeMutationIds -Directory $SpecDirectory -Tree $Integration -Config $Config -Files $changed
    if ($ids.Count -eq 0)
    {
        $report.Add("mutations: none selected ($($changed.Count) file(s) differ from $sourceShort and no record edits them)")
        $mutationText = 'mutations: none selected'
    }
    else
    {
        $mutationArguments = @{ Worktree = $Integration; SpecDir = $SpecDirectory; Only = $ids; Tag = "merge-$Id-mutations"; AllowStaged = $true; ConfigPath = $Config.ConfigPath }
        if ($Drive)
        {
            $mutationArguments.Drive = $Drive
        }

        $mutations = Invoke-Mutations @mutationArguments
        $report.AddRange([string[]]$mutations.Report)
        if ($mutations.ExitCode -ne 0)
        {
            return [pscustomobject]@{ Passed = $false; Line = "mutations $($ids -join ', ') failed"; SummaryPath = $check.SummaryPath; Report = $report.ToArray() }
        }

        $mutationText = "mutations $($ids -join ', ') as expected"
    }

    return [pscustomobject]@{
        Passed = $true
        Line = "full check against $preShort passed (tag merge-$Id); $mutationText"
        SummaryPath = $check.SummaryPath
        Report = $report.ToArray()
    }
}

function Get-IpeDeniedPathReasons
{
    # Why a repo-relative '/' path is never committed: a denied path segment, a denied file name, or the log directory.
    param([Parameter(Mandatory)][string]$RelativePath, [Parameter(Mandatory)][hashtable]$Config)

    $reasons = [System.Collections.Generic.List[string]]::new()
    $segments = $RelativePath.Split('/')
    foreach ($deny in @($Config.Commit.DenySegments))
    {
        if (@($segments | Where-Object { $_ -ieq $deny }).Count -gt 0)
        {
            $reasons.Add("$RelativePath has a '$deny' path segment, which is never committed")
        }
    }

    if (@($Config.Commit.DenyNames) -icontains $segments[-1])
    {
        $reasons.Add("$RelativePath is named $($segments[-1]), which is never committed")
    }

    $logPrefix = $Config.LogDir.Replace('\', '/').Trim('/') + '/'
    if ($RelativePath.StartsWith($logPrefix, [System.StringComparison]::OrdinalIgnoreCase))
    {
        $reasons.Add("$RelativePath is under the log directory $($Config.LogDir)")
    }

    return , $reasons.ToArray()
}

function Commit-Change
{
    [CmdletBinding(DefaultParameterSetName = 'Message')]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory, ParameterSetName = 'Message')][string]$Message,
        [Parameter(Mandatory, ParameterSetName = 'MessageFile')][string]$MessageFile,
        [string]$Base = 'HEAD',
        [string]$ConfigPath
    )

    Assert-IpeAbsolutePath -Path $Worktree -Name 'Worktree'
    Assert-IpeName -Value $Id -Name 'Id'
    $config = Resolve-IpeConfig -Worktree $Worktree -ConfigPath $ConfigPath
    $top = Get-IpeTopLevel -Worktree $Worktree
    if ($PSCmdlet.ParameterSetName -eq 'MessageFile')
    {
        Assert-IpeAbsolutePath -Path $MessageFile -Name 'MessageFile'
        $Message = (Read-IpeText -Path $MessageFile).Text
    }

    $text = $Message.Replace("`r`n", "`n").TrimEnd() + "`n"
    $subject = ($text -split "`n", 2)[0]
    $problems = [System.Collections.Generic.List[string]]::new()
    $types = (@($config.Commit.Types) | ForEach-Object { [regex]::Escape($_) }) -join '|'
    if ($subject -cnotmatch "^($types)\(([^)]*)\): \S")
    {
        $problems.Add("the first line '$subject' must be '<type>($Id): <summary>' with type one of $(@($config.Commit.Types) -join ', ')")
    }
    elseif ($Matches[2] -cne $Id)
    {
        $problems.Add("the first line names '$($Matches[2])' but -Id is '$Id'")
    }

    $roots = [string[]]@($top, (Get-IpeNormalPath $Worktree))
    $wanted = [System.Collections.Generic.List[string]]::new()
    $wantedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $Paths)
    {
        $relative = ConvertTo-IpeRepoPath -Roots $roots -Path $path
        if (-not $relative)
        {
            $problems.Add("$path is outside $top")
            continue
        }

        if (-not $wantedSet.Add($relative))
        {
            continue
        }

        $wanted.Add($relative)
        $problems.AddRange([string[]](Get-IpeDeniedPathReasons -RelativePath $relative -Config $config))

        $full = Join-IpeTreePath -Root $top -Relative $relative
        if (Test-Path -LiteralPath $full -PathType Container)
        {
            $problems.Add("$relative is a directory; list the files to commit")
        }
        elseif (-not (Test-Path -LiteralPath $full -PathType Leaf))
        {
            $tracked = Invoke-Git -Worktree $top -Arguments @('ls-files', '--error-unmatch', '--', $relative) -AllowExitCodes @(0, 1)
            if ($tracked.ExitCode -ne 0)
            {
                $problems.Add("$relative is missing: not in the worktree and not tracked")
            }
        }
    }

    if ($problems.Count -gt 0)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.CommitRefused' -Message "Commit-Change refused, nothing staged: $($problems -join '; ')" -Category InvalidArgument)
    }

    $preStaged = @((Get-IpeStagedPaths -Worktree $top) | Where-Object { -not $wantedSet.Contains($_) })
    if ($preStaged.Count -gt 0)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.CommitRefused' -Message "Commit-Change refused, nothing staged: already staged but not in -Paths: $($preStaged -join ', ') (unstage them or list them in -Paths)" -Category InvalidOperation)
    }

    [void](Invoke-Git -Worktree $top -Arguments ([string[]](@('add', '-A', '--') + $wanted.ToArray())))
    $staged = Get-IpeStagedPaths -Worktree $top
    $stagedSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$staged, [System.StringComparer]::OrdinalIgnoreCase)
    $extra = @($staged | Where-Object { -not $wantedSet.Contains($_) })
    $unchanged = @($wanted | Where-Object { -not $stagedSet.Contains($_) })
    if ($extra.Count -gt 0 -or $unchanged.Count -gt 0)
    {
        $parts = @()
        if ($extra.Count -gt 0)
        {
            $parts += "extra staged: $($extra -join ', ')"
        }

        if ($unchanged.Count -gt 0)
        {
            $parts += "no changes in: $($unchanged -join ', ')"
        }

        throw (New-IpeErrorRecord -ErrorId 'Ipe.CommitRefused' -Message "Commit-Change refused, the staged set differs from -Paths ($($parts -join '; ')); the -Paths changes stay staged" -Category InvalidOperation)
    }

    $lineEndings = Test-LineEndings -Worktree $top -Base $Base -Path $wanted.ToArray() -ConfigPath $config.ConfigPath
    if ($lineEndings.ExitCode -ne 0)
    {
        $failures = @($lineEndings.Report | Where-Object { $_ -like 'FAIL *' })
        throw (New-IpeErrorRecord -ErrorId 'Ipe.CommitRefused' -Message "Commit-Change refused, line endings vs ${Base}: $($failures -join '; '); the -Paths changes stay staged" -Category InvalidData)
    }

    $commit = Invoke-IpeCommitMessage -Worktree $top -Message $text -TimeoutSeconds $config.Timeouts.GitSeconds
    $report = [System.Collections.Generic.List[string]]::new()
    $report.AddRange([string[]](Invoke-Git -Worktree $top -Arguments @('log', '-1', '--stat', '--oneline')).Lines)
    $status = (Invoke-Git -Worktree $top -Arguments @('status', '--short')).Lines
    $report.Add($(if ($status.Count -eq 0) { 'status: clean' } else { 'status:' }))
    $report.AddRange([string[]]$status)
    return [pscustomobject]@{
        ExitCode = 0
        Commit = $commit.Sha
        Paths = $wanted.ToArray()
        MessageFile = $commit.MessageFile
        Report = $report.ToArray()
    }
}

function Test-IpeRebaseInProgress
{
    param([Parameter(Mandatory)][string]$Worktree)

    foreach ($name in @('rebase-merge', 'rebase-apply'))
    {
        $path = (Invoke-Git -Worktree $Worktree -Arguments @('rev-parse', '--path-format=absolute', '--git-path', $name)).Lines[0].Trim()
        if (Test-Path -LiteralPath $path)
        {
            return $true
        }
    }

    return $false
}

function Stop-IpeRebase
{
    # Aborts a rebase in progress in Source (if any), then proves nothing moved: Source back on Branch at OrigHead with
    # no rebase in progress, and Integration still at PreTip. Throws Ipe.RebaseAbortFailed with what it saw otherwise.
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$OrigHead,
        [Parameter(Mandatory)][string]$Integration,
        [Parameter(Mandatory)][string]$PreTip,
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$Context = 'after the rebase stopped'
    )

    $aborted = $false
    $abortError = $null
    if (Test-IpeRebaseInProgress -Worktree $Source)
    {
        try
        {
            [void](Invoke-Git -Worktree $Source -Arguments @('rebase', '--abort') -TimeoutSeconds $Config.Timeouts.GitSeconds)
            $aborted = $true
        }
        catch
        {
            $abortError = $_.Exception.Message
        }
    }

    $sourceHead = Get-IpeHead -Worktree $Source
    $branchResult = Invoke-Git -Worktree $Source -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD') -AllowExitCodes @(0, 1)
    $sourceBranch = if ($branchResult.ExitCode -eq 0 -and $branchResult.Lines.Count -gt 0) { $branchResult.Lines[0].Trim() } else { '(detached HEAD)' }
    $inProgress = Test-IpeRebaseInProgress -Worktree $Source
    $integrationHead = Get-IpeHead -Worktree $Integration
    if ($abortError -or $sourceHead -ne $OrigHead -or $sourceBranch -cne $Branch -or $inProgress -or $integrationHead -ne $PreTip)
    {
        $abortText = if ($abortError) { "git rebase --abort failed ($abortError); " } else { '' }
        $message = "$abortText$Context, $Source is on $sourceBranch at $sourceHead (expected $Branch at $OrigHead), rebase in progress: $inProgress, " +
            "and $Integration is at $integrationHead (expected $PreTip); restore both by hand"
        throw (New-IpeErrorRecord -ErrorId 'Ipe.RebaseAbortFailed' -Message $message -Category InvalidResult)
    }

    $unchanged = "$Branch unchanged at $(Get-IpeShortSha -Worktree $Source -Revision $OrigHead)"
    return $(if ($aborted) { "rebase aborted; $unchanged" } else { $unchanged })
}

function New-IpeRebaseStopError
{
    # The error for a rebase that stopped and was aborted: a conflict (exit 3) when paths were unmerged, else a failure.
    param(
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Onto,
        [Parameter(Mandatory)][string]$OntoShort,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Unmerged,
        [AllowEmptyString()][string]$Output = ''
    )

    if ($Unmerged.Count -gt 0)
    {
        $message = "rebase of $Branch onto $OntoShort conflicted in: $($Unmerged -join ', '); rebase aborted, both branches unchanged. " +
            "In $Source, run ``git rebase $Onto``, resolve, run the full check, and rerun Merge-Ticket -FastForwardOnly"
        return (New-IpeErrorRecord -ErrorId 'Ipe.RebaseConflict' -Message $message -Category ResourceExists)
    }

    return (New-IpeErrorRecord -ErrorId 'Ipe.GitFailed' -Message "rebase of $Branch onto $OntoShort stopped without a conflict: $Output; rebase aborted, both branches unchanged")
}

function Invoke-IpeFastForwardMerge
{
    # Merge-Ticket -FastForwardOnly. Rebases the source branch onto the integration tip, verifies the rebased HEAD in the
    # source tree (the same full-check-record rule as a no-ff merge), then fast-forwards the integration branch to it. A
    # rebase that stops is aborted and verified before the integration tree is touched; nothing is pushed or committed.
    param(
        [Parameter(Mandatory)][string]$Integration,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Id,
        [string]$Feature,
        [string]$SpecDir,
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$Drive
    )

    $gitSeconds = $Config.Timeouts.GitSeconds
    $integrationBranchResult = Invoke-Git -Worktree $Integration -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD') -AllowExitCodes @(0, 1)
    if ($integrationBranchResult.ExitCode -ne 0 -or $integrationBranchResult.Lines.Count -eq 0)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message "-Integration $Integration has a detached HEAD; pass the tree where the integration branch is checked out" -Category InvalidArgument)
    }

    $integrationBranch = $integrationBranchResult.Lines[0].Trim()
    $commonDirectories = foreach ($tree in @($Integration, $Source))
    {
        Get-IpeNormalPath (Invoke-Git -Worktree $tree -Arguments @('rev-parse', '--path-format=absolute', '--git-common-dir')).Lines[0].Trim()
    }

    if (-not (Test-IpeSamePath $commonDirectories[0] $commonDirectories[1]))
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message "-Integration $Integration and -Source $Source are not worktrees of one repository" -Category InvalidArgument)
    }

    if (Get-IpeMergeHead -Worktree $Integration)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.MergeInProgress' -Message "a merge is in progress in $Integration; finish or abort it before Merge-Ticket -FastForwardOnly" -Category InvalidOperation)
    }

    if (Test-IpeRebaseInProgress -Worktree $Source)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.RebaseInProgress' -Message "a rebase is in progress in $Source; finish it (git rebase --continue) or abort it (git rebase --abort) first" -Category InvalidOperation)
    }

    foreach ($tree in @($Integration, $Source))
    {
        $dirty = Get-IpeDirtyPaths -Worktree $tree -Config $Config
        if ($dirty.Count -gt 0)
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.DirtyTree' -Message "refusing to fast-forward with $($dirty.Count) changed path(s) in ${tree}: $($dirty -join ', ')" -Category InvalidOperation)
        }
    }

    $preTip = Get-IpeHead -Worktree $Integration
    $origHead = Get-IpeHead -Worktree $Source
    $preShort = Get-IpeShortSha -Worktree $Integration -Revision $preTip
    $origShort = Get-IpeShortSha -Worktree $Source -Revision $origHead
    $merged = Invoke-Git -Worktree $Source -Arguments @('merge-base', '--is-ancestor', $origHead, $preTip) -AllowExitCodes @(0, 1)
    if ($merged.ExitCode -eq 0)
    {
        return [pscustomobject]@{
            ExitCode = 0; Commit = $null; RebasedFrom = $null; Verification = $null; SummaryPath = $null
            Report = [string[]]@("nothing to merge: $Branch at $origShort is already in $integrationBranch at $preShort")
        }
    }

    $report = [System.Collections.Generic.List[string]]::new()
    $stopArguments = @{ Source = $Source; Branch = $Branch; OrigHead = $origHead; Integration = $Integration; PreTip = $preTip; Config = $Config }
    $rebased = $false
    $onTop = Invoke-Git -Worktree $Source -Arguments @('merge-base', '--is-ancestor', $preTip, $origHead) -AllowExitCodes @(0, 1)
    if ($onTop.ExitCode -eq 0)
    {
        $report.Add("already on top of ${preShort}: $Branch at $origShort, no rebase")
    }
    else
    {
        $mergeCount = [int](Invoke-Git -Worktree $Source -Arguments @('rev-list', '--merges', '--count', "$preTip..$origHead")).Lines[0].Trim()
        if ($mergeCount -gt 0)
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message "$Branch contains $mergeCount merge commit(s) since $preShort; a rebase would drop them. Rebase $Branch onto $preShort by hand, or use Merge-Ticket without -FastForwardOnly" -Category InvalidArgument)
        }

        # Onto the sha, not the branch name, so the target cannot move under the rebase.
        try
        {
            $rebase = Invoke-Git -Worktree $Source -Arguments @('rebase', '--no-autostash', '--no-autosquash', '--no-update-refs', $preTip) -TimeoutSeconds $gitSeconds -AllowExitCodes @(0, 1, 128)
        }
        catch
        {
            if ((Get-IpeErrorId $_) -ne 'Ipe.GitTimeout')
            {
                throw
            }

            $timeout = $_.Exception.Message
            [void](Stop-IpeRebase @stopArguments -Context 'after a rebase timeout')
            throw (New-IpeErrorRecord -ErrorId 'Ipe.GitTimeout' -Message "$timeout; rebase aborted, both branches unchanged" -Category OperationTimeout)
        }

        if ($rebase.ExitCode -ne 0)
        {
            $output = ("$($rebase.StdOut) $($rebase.StdErr)").Trim()
            if (Test-IpeRebaseInProgress -Worktree $Source)
            {
                $unmerged = Get-IpeUnmergedPaths -Worktree $Source
                [void](Stop-IpeRebase @stopArguments)
                throw (New-IpeRebaseStopError -Branch $Branch -Onto $preTip -OntoShort $preShort -Source $Source -Unmerged $unmerged -Output $output)
            }

            [void](Stop-IpeRebase @stopArguments)
            throw (New-IpeErrorRecord -ErrorId 'Ipe.GitFailed' -Message "git rebase $preShort exited $($rebase.ExitCode) in ${Source}: $output; both branches unchanged")
        }

        if (Test-IpeRebaseInProgress -Worktree $Source)
        {
            [void](Stop-IpeRebase @stopArguments)
            throw (New-IpeErrorRecord -ErrorId 'Ipe.GitFailed' -Message "git rebase $preShort exited 0 but left a rebase in progress in $Source; rebase aborted, both branches unchanged")
        }

        $rebased = $true
    }

    $newHead = Get-IpeHead -Worktree $Source
    $newShort = Get-IpeShortSha -Worktree $Source -Revision $newHead
    if ($rebased)
    {
        $report.Add("rebased $Branch from $origShort onto ${preShort}: now $newShort")
    }

    if ($Feature)
    {
        $specDirectory = Join-IpeTreePath -Root $Source -Relative $Config.MutationSpecDir.Replace('{feature}', $Feature)
    }
    else
    {
        # The integration copy lacks the ticket's mutation records, so a spec dir inside it maps to the source tree.
        $relative = ConvertTo-IpeRepoPath -Roots @($Integration) -Path $SpecDir
        $specDirectory = if ($null -ne $relative) { Join-IpeTreePath -Root $Source -Relative $relative } else { $SpecDir }
    }

    $verification = Invoke-IpeFastForwardVerification -Source $Source -NewHead $newHead -OrigHead $origHead -PreTip $preTip -Id $Id -SpecDirectory $specDirectory -Config $Config -Drive $Drive
    $report.AddRange([string[]]$verification.Report)
    $rebasedFrom = if ($rebased) { $origHead } else { $null }
    if (-not $verification.Passed)
    {
        $kept = if ($rebased) { "; $Branch stays rebased at $newShort (it was $origShort before the rebase: git reset --hard $origHead in $Source restores it)" } else { '' }
        $report.Add("$integrationBranch untouched at $preShort$kept")
        $report.Add("merge: FAIL ($($verification.Line))")
        return [pscustomobject]@{ ExitCode = 1; Commit = $null; RebasedFrom = $rebasedFrom; Verification = $verification.Line; SummaryPath = $verification.SummaryPath; Report = $report.ToArray() }
    }

    $currentTip = Get-IpeHead -Worktree $Integration
    if ($currentTip -ne $preTip)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.IntegrationMoved' -Message "$integrationBranch moved from $preShort to $(Get-IpeShortSha -Worktree $Integration -Revision $currentTip) during the check; nothing fast-forwarded. Rerun Merge-Ticket -FastForwardOnly" -Category InvalidOperation)
    }

    # The sha, not the branch, so a commit added to the source branch during the check is not taken.
    $fastForward = Invoke-Git -Worktree $Integration -Arguments @('merge', '--ff-only', $newHead) -TimeoutSeconds $gitSeconds -AllowExitCodes @(0, 1, 128)
    $afterTip = Get-IpeHead -Worktree $Integration
    if ($fastForward.ExitCode -ne 0 -or $afterTip -ne $newHead)
    {
        $detail = ("$($fastForward.StdOut) $($fastForward.StdErr)").Trim()
        throw (New-IpeErrorRecord -ErrorId 'Ipe.GitFailed' -Message "git merge --ff-only $newShort exited $($fastForward.ExitCode) in ${Integration}, which is at ${afterTip}: $detail")
    }

    $report.Add("fast-forwarded $integrationBranch from $preShort to $newShort")
    $report.Add("merge: pass ($($verification.Line))")
    return [pscustomobject]@{ ExitCode = 0; Commit = $newHead; RebasedFrom = $rebasedFrom; Verification = $verification.Line; SummaryPath = $verification.SummaryPath; Report = $report.ToArray() }
}

function Invoke-IpeFastForwardVerification
{
    # Verifies the (rebased) source HEAD in the source tree. A passing, clean full-check record for exactly NewHead needs
    # only the line-ending check; otherwise the full check runs, then the mutations whose files the rebase brought in.
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$NewHead,
        [Parameter(Mandatory)][string]$OrigHead,
        [Parameter(Mandatory)][string]$PreTip,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$SpecDirectory,
        [Parameter(Mandatory)][hashtable]$Config,
        [string]$Drive
    )

    $report = [System.Collections.Generic.List[string]]::new()
    $preShort = Get-IpeShortSha -Worktree $Source -Revision $PreTip
    $newShort = Get-IpeShortSha -Worktree $Source -Revision $NewHead
    $recordPath = Join-Path (Join-IpeTreePath -Root $Source -Relative $Config.LogDir) 'last-full-check.json'
    $record = $null
    $covered = $false
    if (Test-Path -LiteralPath $recordPath -PathType Leaf)
    {
        try
        {
            $record = Read-IpeJsonFile -Path $recordPath -ErrorId 'Ipe.RecordInvalid'
        }
        catch
        {
            if ((Get-IpeErrorId $_) -ne 'Ipe.RecordInvalid')
            {
                throw
            }

            $report.Add("implementer record ${recordPath}: $($_.Exception.Message)")
        }

        if ($record)
        {
            $result = [string](Get-IpeJsonValue $record 'result')
            $head = [string](Get-IpeJsonValue $record 'head')
            $dirtyCount = @(@(Get-IpeJsonValue $record 'dirtyPaths') | Where-Object { $_ }).Count
            $covered = $result -eq 'pass' -and $head -eq $NewHead -and $dirtyCount -eq 0
            if (-not $covered)
            {
                $report.Add("implementer record $recordPath does not cover ${newShort}: result '$result', head '$head', $dirtyCount dirty path(s)")
            }
        }
    }
    else
    {
        $report.Add("no implementer record at $recordPath")
    }

    if ($covered)
    {
        $lineEndings = Test-LineEndings -Worktree $Source -Base $PreTip -ConfigPath $Config.ConfigPath
        $report.AddRange([string[]]$lineEndings.Report)
        return [pscustomobject]@{
            Passed = ($lineEndings.ExitCode -eq 0)
            Line = "verified by the implementer at $newShort (record $recordPath); line endings checked against $preShort"
            SummaryPath = [string](Get-IpeJsonValue $record 'summaryPath')
            Report = $report.ToArray()
        }
    }

    $checkArguments = @{ Worktree = $Source; Base = $PreTip; Tag = "ff-$Id"; ConfigPath = $Config.ConfigPath }
    if ($Drive)
    {
        $checkArguments.Drive = $Drive
    }

    $check = Invoke-FullCheck @checkArguments
    $report.AddRange([string[]]$check.Report)
    if ($check.ExitCode -ne 0)
    {
        return [pscustomobject]@{ Passed = $false; Line = "full check of $newShort against $preShort failed"; SummaryPath = $check.SummaryPath; Report = $report.ToArray() }
    }

    $changed = [string[]]@()
    if ($NewHead -ne $OrigHead)
    {
        $changed = Split-IpeLines (Invoke-Git -Worktree $Source -Arguments @('-c', 'core.quotepath=false', 'diff', '--name-only', '--no-renames', $OrigHead, $NewHead)).StdOut
    }

    $ids = Get-IpeMergeMutationIds -Directory $SpecDirectory -Tree $Source -Config $Config -Files $changed
    if ($ids.Count -eq 0)
    {
        $report.Add("mutations: none selected ($($changed.Count) file(s) changed by the rebase and no record edits them)")
        $mutationText = 'mutations: none selected'
    }
    else
    {
        $mutationArguments = @{ Worktree = $Source; SpecDir = $SpecDirectory; Only = $ids; Tag = "ff-$Id-mutations"; ConfigPath = $Config.ConfigPath }
        if ($Drive)
        {
            $mutationArguments.Drive = $Drive
        }

        $mutations = Invoke-Mutations @mutationArguments
        $report.AddRange([string[]]$mutations.Report)
        if ($mutations.ExitCode -ne 0)
        {
            return [pscustomobject]@{ Passed = $false; Line = "mutations $($ids -join ', ') failed"; SummaryPath = $check.SummaryPath; Report = $report.ToArray() }
        }

        $mutationText = "mutations $($ids -join ', ') as expected"
    }

    return [pscustomobject]@{
        Passed = $true
        Line = "full check of $newShort against $preShort passed (tag ff-$Id); $mutationText"
        SummaryPath = $check.SummaryPath
        Report = $report.ToArray()
    }
}

function Merge-Ticket
{
    [CmdletBinding(DefaultParameterSetName = 'Feature')]
    param(
        [Parameter(Mandatory)][string]$Integration,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory, ParameterSetName = 'Feature')][string]$Feature,
        [Parameter(Mandatory, ParameterSetName = 'SpecDir')][string]$SpecDir,
        [switch]$Continue,
        [switch]$FastForwardOnly,
        [string]$Drive,
        [string]$ConfigPath
    )

    Assert-IpeAbsolutePath -Path $Integration -Name 'Integration'
    Assert-IpeAbsolutePath -Path $Source -Name 'Source'
    Assert-IpeName -Value $Id -Name 'Id'
    if ($FastForwardOnly -and $Continue)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message '-FastForwardOnly takes no -Continue: a rebase conflict is aborted, so there is nothing to continue' -Category InvalidArgument)
    }

    $integrationTree = Get-IpeTopLevel -Worktree $Integration
    $sourceTree = Get-IpeTopLevel -Worktree $Source
    if (Test-IpeSamePath $integrationTree $sourceTree)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message "-Integration and -Source are the same tree: $integrationTree" -Category InvalidArgument)
    }

    $config = Resolve-IpeConfig -Worktree $integrationTree -ConfigPath $ConfigPath
    if ($PSCmdlet.ParameterSetName -eq 'Feature')
    {
        Assert-IpeName -Value $Feature -Name 'Feature'
        $specDirectory = Join-IpeTreePath -Root $integrationTree -Relative $config.MutationSpecDir.Replace('{feature}', $Feature)
    }
    else
    {
        Assert-IpeAbsolutePath -Path $SpecDir -Name 'SpecDir'
        $specDirectory = Get-IpeNormalPath $SpecDir
    }

    $branchResult = Invoke-Git -Worktree $sourceTree -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD') -AllowExitCodes @(0, 1)
    if ($branchResult.ExitCode -ne 0 -or $branchResult.Lines.Count -eq 0)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message "-Source $sourceTree has a detached HEAD; check out the ticket branch" -Category InvalidArgument)
    }

    $branch = $branchResult.Lines[0].Trim()
    if ($FastForwardOnly)
    {
        $fastForwardArguments = @{ Integration = $integrationTree; Source = $sourceTree; Branch = $branch; Id = $Id; Config = $config; Drive = $Drive }
        if ($PSCmdlet.ParameterSetName -eq 'Feature')
        {
            $fastForwardArguments.Feature = $Feature
        }
        else
        {
            $fastForwardArguments.SpecDir = $specDirectory
        }

        return Invoke-IpeFastForwardMerge @fastForwardArguments
    }

    $sourceHead = Get-IpeHead -Worktree $sourceTree
    $sourceShort = Get-IpeHead -Worktree $sourceTree -Short
    $mergeHead = Get-IpeMergeHead -Worktree $integrationTree
    $gitSeconds = $config.Timeouts.GitSeconds
    $report = [System.Collections.Generic.List[string]]::new()
    if ($Continue)
    {
        if (-not $mergeHead)
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.NoMergeInProgress' -Message "no merge in progress in $integrationTree; run Merge-Ticket without -Continue" -Category InvalidOperation)
        }

        if ($mergeHead -ne $sourceHead)
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message "the merge in progress is of $mergeHead, but $branch is at $sourceHead" -Category InvalidArgument)
        }

        $conflicts = Get-IpeUnmergedPaths -Worktree $integrationTree
        if ($conflicts.Count -gt 0)
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.MergeConflict' -Message "still conflicted: $($conflicts -join ', '). Resolve each conflict by hand, stage it, then run Merge-Ticket -Continue" -Category ResourceExists)
        }

        $unstaged = Get-IpeDirtyPaths -Worktree $integrationTree -Config $config -UnstagedOnly
        if ($unstaged.Count -gt 0)
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.DirtyTree' -Message "unstaged or untracked changes during the merge: $($unstaged -join ', '). Stage the resolution (or remove the files), then run Merge-Ticket -Continue" -Category InvalidOperation)
        }

        $preTip = Get-IpeHead -Worktree $integrationTree
        $report.Add("continuing the merge of $branch at $sourceShort into $integrationTree")
    }
    else
    {
        if ($mergeHead)
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.MergeInProgress' -Message "a merge is already in progress in $integrationTree; resolve it and run Merge-Ticket -Continue, or git merge --abort" -Category InvalidOperation)
        }

        $dirty = Get-IpeDirtyPaths -Worktree $integrationTree -Config $config
        if ($dirty.Count -gt 0)
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.DirtyTree' -Message "refusing to merge into a tree with $($dirty.Count) changed path(s): $($dirty -join ', ')" -Category InvalidOperation)
        }

        $preTip = Get-IpeHead -Worktree $integrationTree
        $merge = Invoke-Git -Worktree $integrationTree -Arguments @('merge', '--no-ff', '--no-commit', $branch) -AllowExitCodes @(0, 1, 2, 128) -TimeoutSeconds $gitSeconds
        $mergeHead = Get-IpeMergeHead -Worktree $integrationTree
        if ($merge.ExitCode -ne 0)
        {
            $conflicts = Get-IpeUnmergedPaths -Worktree $integrationTree
            if ($mergeHead -and $conflicts.Count -gt 0)
            {
                throw (New-IpeErrorRecord -ErrorId 'Ipe.MergeConflict' -Message "merge of $branch into $integrationTree stopped with conflicts in: $($conflicts -join ', '). Resolve each conflict by hand, stage the resolution, then run Merge-Ticket -Continue (or git merge --abort)" -Category ResourceExists)
            }

            if ($mergeHead)
            {
                [void](Undo-IpeMerge -Worktree $integrationTree -PreTip $preTip)
            }

            $detail = ("$($merge.StdOut) $($merge.StdErr)").Trim()
            throw (New-IpeErrorRecord -ErrorId 'Ipe.GitFailed' -Message "git merge --no-ff --no-commit $branch exited $($merge.ExitCode) in ${integrationTree}: $detail")
        }

        if (-not $mergeHead)
        {
            return [pscustomobject]@{ ExitCode = 0; Commit = $null; Verification = $null; SummaryPath = $null; Report = [string[]]@("nothing to merge: $branch at $sourceShort is already in $integrationTree") }
        }

        $report.Add("merging $branch at $sourceShort into $integrationTree at $(Get-IpeShortSha -Worktree $integrationTree -Revision $preTip) (no commit yet)")
    }

    $verificationArguments = @{
        Integration = $integrationTree; SourceTree = $sourceTree; SourceHead = $sourceHead; PreTip = $preTip; Id = $Id
        SpecDirectory = $specDirectory; Config = $config; Drive = $Drive
    }
    try
    {
        $verification = Invoke-IpeMergeVerification @verificationArguments
    }
    catch
    {
        $failure = $_
        [void](Undo-IpeMerge -Worktree $integrationTree -PreTip $preTip)
        throw $failure
    }

    $report.AddRange([string[]]$verification.Report)
    if (-not $verification.Passed)
    {
        $report.Add((Undo-IpeMerge -Worktree $integrationTree -PreTip $preTip))
        $report.Add("merge: FAIL ($($verification.Line))")
        return [pscustomobject]@{ ExitCode = 1; Commit = $null; Verification = $verification.Line; SummaryPath = $verification.SummaryPath; Report = $report.ToArray() }
    }

    $summary = if ($verification.SummaryPath) { $verification.SummaryPath } else { 'none' }
    $message = "chore($Id): merge $branch`n`nVerification: $($verification.Line)`nSummary: $summary`n"
    $commit = Invoke-IpeCommitMessage -Worktree $integrationTree -Message $message -TimeoutSeconds $gitSeconds
    $report.AddRange([string[]](Invoke-Git -Worktree $integrationTree -Arguments @('log', '-1', '--oneline')).Lines)
    $report.Add("merge: pass ($($verification.Line))")
    return [pscustomobject]@{ ExitCode = 0; Commit = $commit.Sha; Verification = $verification.Line; SummaryPath = $verification.SummaryPath; Report = $report.ToArray() }
}

function Resolve-Ticket
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$TicketFile,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$CommentFile,
        [string]$Status = 'resolved',
        [switch]$NoCommit,
        [string]$ConfigPath
    )

    Assert-IpeAbsolutePath -Path $Worktree -Name 'Worktree'
    Assert-IpeAbsolutePath -Path $TicketFile -Name 'TicketFile'
    Assert-IpeAbsolutePath -Path $CommentFile -Name 'CommentFile'
    Assert-IpeName -Value $Id -Name 'Id'
    if ([string]::IsNullOrWhiteSpace($Status) -or $Status -match '[\r\n]')
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message '-Status must be one non-empty line' -Category InvalidArgument)
    }

    $ticket = Read-IpeText -Path $TicketFile
    $comment = (Read-IpeText -Path $CommentFile).Text.Replace("`r`n", "`n").Trim([char]10)
    if (-not $comment.Trim())
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message "comment file is empty: $CommentFile" -Category InvalidArgument)
    }

    $text = $ticket.Text.Replace("`r`n", "`n")
    $statusMatch = [regex]::Match($text, '(?m)^(\*\*Status:\*\*|Status:)[ \t]*[^\n]*$')
    if (-not $statusMatch.Success)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.TicketInvalid' -Message "no '**Status:**' or 'Status:' line in $TicketFile" -Category InvalidData)
    }

    $text = $text.Substring(0, $statusMatch.Index) + "$($statusMatch.Groups[1].Value) $Status" + $text.Substring($statusMatch.Index + $statusMatch.Length)
    $boxPattern = '(?m)^([ \t]*[-*+][ \t]+)\[ \]'
    $ticked = [regex]::Matches($text, $boxPattern).Count
    $text = [regex]::Replace($text, $boxPattern, '$1[x]')
    $heading = [regex]::Match($text, '(?m)^## Comments[ \t]*$')
    if (-not $heading.Success)
    {
        $text = $text.TrimEnd([char]10) + "`n`n## Comments`n`n" + $comment + "`n"
    }
    else
    {
        $next = [regex]::new('(?m)^## ').Match($text, $heading.Index + $heading.Length)
        $end = if ($next.Success) { $next.Index } else { $text.Length }
        $rest = $text.Substring($end)
        $text = $text.Substring(0, $end).TrimEnd([char]10) + "`n`n" + $comment + "`n" + $(if ($rest) { "`n" + $rest } else { '' })
    }

    Write-IpeText -Path $TicketFile -Text (ConvertTo-IpeNewline -Text $text -Newline $ticket.Newline) -HasBom $ticket.HasBom
    $report = [System.Collections.Generic.List[string]]::new()
    $report.Add("ticket ${TicketFile}: status $Status, ticked $ticked box(es), comment appended under ## Comments")
    if ($NoCommit)
    {
        return [pscustomobject]@{ ExitCode = 0; Commit = $null; Report = $report.ToArray() }
    }

    $commit = Commit-Change -Worktree $Worktree -Id $Id -Paths @($TicketFile) -Message "chore($Id): resolve ticket" -ConfigPath $ConfigPath
    $report.AddRange([string[]]$commit.Report)
    return [pscustomobject]@{ ExitCode = 0; Commit = $commit.Commit; Report = $report.ToArray() }
}

function New-TicketWorktree
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Base,
        [string]$Path,
        [string]$LedgerPath,
        [string]$LedgerKey,
        [string]$ConfigPath
    )

    Assert-IpeAbsolutePath -Path $RepoRoot -Name 'RepoRoot'
    Assert-IpeName -Value $Id -Name 'Id'
    $config = Resolve-IpeConfig -Worktree $RepoRoot -ConfigPath $ConfigPath
    $top = Get-IpeTopLevel -Worktree $RepoRoot
    $refCheck = Invoke-Git -Worktree $top -Arguments @('check-ref-format', '--branch', $Branch) -AllowExitCodes @(0, 1, 128)
    if ($refCheck.ExitCode -ne 0)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message "-Branch '$Branch' is not a valid branch name" -Category InvalidArgument)
    }

    if ($Path)
    {
        Assert-IpeAbsolutePath -Path $Path -Name 'Path'
        $target = Get-IpeNormalPath $Path
    }
    else
    {
        $target = Join-IpeTreePath -Root (Join-IpeTreePath -Root $top -Relative $config.WorktreeDir) -Relative $Id
    }

    if ($LedgerPath)
    {
        Assert-IpeAbsolutePath -Path $LedgerPath -Name 'LedgerPath'
    }

    $existing = Invoke-Git -Worktree $top -Arguments @('rev-parse', '--verify', '--quiet', "refs/heads/$Branch") -AllowExitCodes @(0, 1)
    if ($existing.ExitCode -eq 0)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.BranchExists' -Message "branch $Branch already exists" -Category ResourceExists)
    }

    if (Test-Path -LiteralPath $target)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.PathExists' -Message "worktree path already exists: $target" -Category ResourceExists)
    }

    $baseSha = (Invoke-Git -Worktree $top -Arguments @('rev-parse', '--verify', "$Base^{commit}")).Lines[0].Trim()
    $baseShort = Get-IpeShortSha -Worktree $top -Revision $baseSha
    [void](Invoke-Git -Worktree $top -Arguments @('worktree', 'add', '-b', $Branch, $target, $baseSha) -TimeoutSeconds $config.Timeouts.GitSeconds)
    $report = [System.Collections.Generic.List[string]]::new()
    $report.Add("worktree $target on new branch $Branch at $baseShort ($Base)")
    $mapping = Use-Drive -Worktree $target -ConfigPath $config.ConfigPath
    $report.AddRange([string[]]$mapping.Report)
    $driveText = if ($mapping.Drive) { "drive $($mapping.Drive):" } else { 'no drive' }
    if ($LedgerPath)
    {
        $key = if ($LedgerKey) { $LedgerKey } else { $Id }
        $ledger = Update-Ledger -LedgerPath $LedgerPath -Ticket $key -State 'active' -Worktree "$(Split-Path -Leaf $target) / $Branch" -SourceHead $baseShort -AppendNote $driveText
        $report.AddRange([string[]]$ledger.Report)
    }

    return [pscustomobject]@{ ExitCode = 0; Path = $target; Branch = $Branch; Base = $baseSha; Drive = $mapping.Drive; Report = $report.ToArray() }
}

function Update-Ledger
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LedgerPath,
        [Parameter(Mandatory)][string]$Ticket,
        [string]$State,
        [string]$Worktree,
        [string]$SourceHead,
        [string]$Workflow,
        [string]$WorkflowRole,
        [string]$Note,
        [string]$AppendNote,
        [string]$ConfigPath
    )

    Assert-IpeAbsolutePath -Path $LedgerPath -Name 'LedgerPath'
    $bound = $PSBoundParameters
    if ($bound.ContainsKey('Workflow') -or $bound.ContainsKey('WorkflowRole'))
    {
        if ($Workflow -cnotmatch $script:WorkflowIdPattern)
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.BadWorkflowId' -Message "-Workflow '$Workflow' is not a workflow id (wf_ and 16 hex digits): record ids only from the run_workflow result" -Category InvalidArgument)
        }

        if ([string]::IsNullOrWhiteSpace($WorkflowRole))
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message '-Workflow needs -WorkflowRole (for example impl or merger)' -Category InvalidArgument)
        }
    }

    if ($bound.ContainsKey('Note') -and $bound.ContainsKey('AppendNote'))
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message 'pass -Note or -AppendNote, not both' -Category InvalidArgument)
    }

    foreach ($name in @('Ticket', 'State', 'Worktree', 'SourceHead', 'WorkflowRole', 'Note', 'AppendNote'))
    {
        if ($bound.ContainsKey($name) -and [string]$bound[$name] -match '[\r\n]')
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message "-$name must be a single line" -Category InvalidArgument)
        }
    }

    if ([string]::IsNullOrWhiteSpace($Ticket))
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message '-Ticket must not be empty' -Category InvalidArgument)
    }

    $info = Read-IpeText -Path $LedgerPath
    $segments = Split-IpeLineSegments -Text $info.Text
    $headerIndex = -1
    for ($i = 0; $i -lt $segments.Count; $i++)
    {
        if ($segments[$i].Content -match $script:LedgerHeaderPattern)
        {
            $headerIndex = $i
            break
        }
    }

    if ($headerIndex -lt 0 -or $headerIndex + 1 -ge $segments.Count -or $segments[$headerIndex + 1].Content -notmatch '^\s*\|?\s*:?-{3,}')
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.LedgerInvalid' -Message "no table with a header row starting '| # | State' and a separator row in $LedgerPath" -Category InvalidData)
    }

    $header = Split-IpeTableCells -Line $segments[$headerIndex].Content
    $columns = @{}
    foreach ($key in $script:LedgerColumns.Keys)
    {
        for ($j = 0; $j -lt $header.Count; $j++)
        {
            if (@($script:LedgerColumns[$key]) -icontains $header[$j])
            {
                $columns[$key] = $j
                break
            }
        }
    }

    $requested = @{ State = 'State'; Worktree = 'Worktree'; SourceHead = 'SourceHead'; Workflow = 'Workflow'; Note = 'Note'; AppendNote = 'Note' }
    foreach ($name in $requested.Keys)
    {
        if ($bound.ContainsKey($name) -and -not $columns.ContainsKey($requested[$name]))
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.LedgerInvalid' -Message "the ledger table in $LedgerPath has no '$($script:LedgerColumns[$requested[$name]][0])' column" -Category InvalidData)
        }
    }

    $ticketCell = ConvertTo-IpeTableValue $Ticket
    $end = $headerIndex + 2
    $rowIndex = -1
    while ($end -lt $segments.Count -and $segments[$end].Content.TrimStart().StartsWith('|'))
    {
        if ($rowIndex -lt 0 -and (Split-IpeTableCells -Line $segments[$end].Content)[0] -ceq $ticketCell)
        {
            $rowIndex = $end
        }

        $end++
    }

    $appended = $rowIndex -lt 0
    $cells = [System.Collections.Generic.List[string]]::new()
    if ($appended)
    {
        if ([string]::IsNullOrWhiteSpace($State))
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message "row '$Ticket' is not in the ledger; pass -State to append it" -Category InvalidArgument)
        }

        $cells.Add($ticketCell)
    }
    else
    {
        $cells.AddRange([string[]](Split-IpeTableCells -Line $segments[$rowIndex].Content))
    }

    while ($cells.Count -lt $header.Count)
    {
        $cells.Add('')
    }

    if ($bound.ContainsKey('State'))
    {
        $cells[$columns.State] = ConvertTo-IpeTableValue $State
    }

    if ($bound.ContainsKey('Worktree'))
    {
        $cells[$columns.Worktree] = ConvertTo-IpeTableValue $Worktree
    }

    if ($bound.ContainsKey('SourceHead'))
    {
        $cells[$columns.SourceHead] = ConvertTo-IpeTableValue $SourceHead
    }

    if ($bound.ContainsKey('Workflow'))
    {
        $current = $cells[$columns.Workflow]
        $entry = ConvertTo-IpeTableValue "$($WorkflowRole.Trim()) $Workflow"
        if (-not $current.Contains($Workflow))
        {
            $cells[$columns.Workflow] = if ($current) { "$current; $entry" } else { $entry }
        }
    }

    if ($bound.ContainsKey('Note'))
    {
        $cells[$columns.Note] = ConvertTo-IpeTableValue $Note
    }
    elseif ($bound.ContainsKey('AppendNote'))
    {
        $current = $cells[$columns.Note]
        $addition = ConvertTo-IpeTableValue $AppendNote
        $cells[$columns.Note] = if ($current) { "$current; $addition" } else { $addition }
    }

    $line = '| ' + ($cells -join ' | ') + ' |'
    if ($appended)
    {
        $previous = $segments[$end - 1]
        $terminator = $previous.Terminator
        if (-not $terminator)
        {
            $previous.Terminator = $info.Newline
        }

        $segments.Insert($end, [pscustomobject]@{ Content = $line; Terminator = $terminator })
    }
    else
    {
        $segments[$rowIndex].Content = $line
    }

    $builder = [System.Text.StringBuilder]::new($info.Text.Length + $line.Length + 2)
    foreach ($segment in $segments)
    {
        [void]$builder.Append($segment.Content).Append($segment.Terminator)
    }

    Write-IpeText -Path $LedgerPath -Text $builder.ToString() -HasBom $info.HasBom
    $action = if ($appended) { 'appended' } else { 'updated' }
    return [pscustomobject]@{ ExitCode = 0; Row = $line; Appended = $appended; Report = [string[]]@("ledger ${LedgerPath}: row $Ticket $action", $line) }
}

function Export-ReviewFindings
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][string]$Out,
        [switch]$IncludeDropped,
        [string]$ConfigPath
    )

    Assert-IpeAbsolutePath -Path $RunDir -Name 'RunDir'
    Assert-IpeAbsolutePath -Path $Out -Name 'Out'
    $verifiedPath = Join-Path $RunDir 'verified.json'
    if (-not (Test-Path -LiteralPath $verifiedPath -PathType Leaf))
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.ReviewRunInvalid' -Message "no verified.json in $RunDir" -Category ObjectNotFound)
    }

    $verified = Read-IpeJsonFile -Path $verifiedPath -ErrorId 'Ipe.ReviewRunInvalid'
    if ($null -eq $verified.PSObject.Properties['kept'])
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.ReviewRunInvalid' -Message "$verifiedPath has no 'kept' list" -Category InvalidData)
    }

    $kept = @(Get-IpeJsonValue $verified 'kept' | Where-Object { $null -ne $_ })
    $dropped = @(Get-IpeJsonValue $verified 'dropped' | Where-Object { $null -ne $_ })
    $paramsPath = Join-Path $RunDir 'params.json'
    $params = if (Test-Path -LiteralPath $paramsPath -PathType Leaf) { Read-IpeJsonFile -Path $paramsPath -ErrorId 'Ipe.ReviewRunInvalid' } else { $null }
    $findingsPath = Join-Path $RunDir 'findings.json'
    $scenarios = @()
    if (Test-Path -LiteralPath $findingsPath -PathType Leaf)
    {
        $scenarios = @(Read-IpeJsonFile -Path $findingsPath -ErrorId 'Ipe.ReviewRunInvalid' | ForEach-Object { $_ } | Where-Object { $null -ne $_ })
    }

    $target = [string](Get-IpeJsonValue $params 'target_label')
    $cap = [string](Get-IpeJsonValue $params 'findings_cap')
    $counts = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @('pooled', 'deduplicated'))
    {
        $value = Get-IpeJsonValue $verified $name
        if ($null -ne $value)
        {
            $counts.Add("$name $value")
        }
    }

    $counts.Add("kept $($kept.Count)")
    $counts.Add("dropped $($dropped.Count)")
    $listed = if ($IncludeDropped) { $kept.Count + $dropped.Count } else { $kept.Count }
    $capText = if ($cap) { "; the review's findings cap ($cap) is not applied" } else { '' }
    $droppedText = if ($IncludeDropped) { " and all $($dropped.Count) dropped" } else { '' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Review findings')
    $lines.Add('')
    $lines.Add("- Target: $(if ($target) { $target } else { 'unknown (no params.json target_label)' })")
    $lines.Add("- Run: $RunDir")
    $lines.Add("- Counts: $($counts -join ', ')")
    $lines.Add("- Listed: $listed (all $($kept.Count) kept$droppedText$capText)")
    $number = 0
    $entries = @($kept | ForEach-Object { [pscustomobject]@{ Finding = $_; Dropped = $false } })
    if ($IncludeDropped)
    {
        $entries += @($dropped | ForEach-Object { [pscustomobject]@{ Finding = $_; Dropped = $true } })
    }

    foreach ($entry in $entries)
    {
        $number++
        $finding = $entry.Finding
        $file = [string](Get-IpeJsonValue $finding 'file')
        $line = Get-IpeJsonValue $finding 'line'
        $scenario = [string](Get-IpeJsonValue $finding 'failure_scenario')
        if (-not $scenario)
        {
            foreach ($candidate in $scenarios)
            {
                $candidateFile = [string](Get-IpeJsonValue $candidate 'file')
                if ([string]::Equals($candidateFile.Replace('\', '/'), $file.Replace('\', '/'), [System.StringComparison]::OrdinalIgnoreCase) -and
                    [string](Get-IpeJsonValue $candidate 'line') -eq [string]$line)
                {
                    $scenario = [string](Get-IpeJsonValue $candidate 'failure_scenario')
                    break
                }
            }
        }

        $label = if ($entry.Dropped) { ' (dropped)' } else { '' }
        $location = if ($null -ne $line -and "$line" -ne '') { "${file}:$line" } else { $file }
        $lines.Add('')
        $lines.Add("## $number. $([string](Get-IpeJsonValue $finding 'id'))${label}: $location")
        $lines.Add('')
        $lines.Add("- Category: $([string](Get-IpeJsonValue $finding 'category'))")
        $lines.Add("- Verdict: $([string](Get-IpeJsonValue $finding 'verdict'))")
        $angles = @(Get-IpeJsonValue $finding 'angles' | Where-Object { $_ })
        if ($angles.Count -gt 0)
        {
            $lines.Add("- Angles: $($angles -join ', ')")
        }

        foreach ($part in @(@('Summary', [string](Get-IpeJsonValue $finding 'summary')), @('Failure scenario', $scenario), @('Evidence', [string](Get-IpeJsonValue $finding 'evidence'))))
        {
            if ($part[1])
            {
                $lines.Add('')
                $lines.Add("$($part[0]): $($part[1].Replace("`r`n", "`n").Trim())")
            }
        }
    }

    $outDirectory = [System.IO.Path]::GetDirectoryName((Get-IpeNormalPath $Out))
    [void][System.IO.Directory]::CreateDirectory($outDirectory)
    [System.IO.File]::WriteAllText($Out, ($lines -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
    $notListed = if ($IncludeDropped) { '' } else { ", $($dropped.Count) dropped not listed" }
    return [pscustomobject]@{
        ExitCode = 0
        Count = $listed
        Kept = $kept.Count
        Dropped = $dropped.Count
        OutPath = $Out
        Report = [string[]]@("review findings: $($kept.Count) kept$notListed; wrote $listed finding section(s) to $Out")
    }
}

# ReviewBundle -------------------------------------------------------------------------------------------------------

$script:BundleFiles = @('index.md', 'log.txt', 'diffstat.txt', 'diff.patch', 'files.md', 'denied-paths.txt', 'status.txt')
$script:BundleCheckDirectory = 'full-check'
$script:BundleTitle = '# Review bundle '

function Invoke-IpeReadOnlyGit
{
    # A git call for ReviewBundle: unquoted paths, and GIT_OPTIONAL_LOCKS=0 so no command refreshes the index.
    param(
        [Parameter(Mandatory)][string]$Tree,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [int[]]$AllowExitCodes = @(0),
        [switch]$Bytes
    )

    $allArguments = [string[]](@('-c', 'core.quotepath=false') + $Arguments)
    return Invoke-Git -Worktree $Tree -Arguments $allArguments -TimeoutSeconds $TimeoutSeconds -AllowExitCodes $AllowExitCodes -Bytes:$Bytes -Environment @{ GIT_OPTIONAL_LOCKS = '0' }
}

function Write-IpeBundleText
{
    # Bundle text files are UTF-8 without a BOM, with LF newlines and a final newline.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

    $text = ($Lines -join "`n").Replace("`r`n", "`n") + "`n"
    [System.IO.File]::WriteAllText($Path, $text, [System.Text.UTF8Encoding]::new($false))
}

function Get-IpeBundleBlob
{
    # The bytes of Path at Revision, or $null when the entry is not a blob (a submodule, for example).
    param([Parameter(Mandatory)][string]$Tree, [Parameter(Mandatory)][string]$Revision, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][int]$TimeoutSeconds)

    $result = Invoke-IpeReadOnlyGit -Tree $Tree -Arguments @('cat-file', 'blob', "${Revision}:$Path") -TimeoutSeconds $TimeoutSeconds -AllowExitCodes @(0, 128) -Bytes
    if ($result.ExitCode -ne 0)
    {
        return $null
    }

    return , [byte[]]$result.Bytes
}

function Get-IpeBundleSide
{
    # The BOM and line-ending cells of one side (before or after) of a changed file; $null Bytes means it is absent.
    param([AllowNull()][byte[]]$Bytes, [Parameter(Mandatory)][bool]$IsText)

    if ($null -eq $Bytes)
    {
        return [pscustomobject]@{ Checked = $false; Bom = $false; Style = $null; BomCell = '-'; EndingCell = '-' }
    }

    if (-not $IsText)
    {
        return [pscustomobject]@{ Checked = $false; Bom = $false; Style = $null; BomCell = 'not checked (extension)'; EndingCell = 'not checked (extension)' }
    }

    $shape = Get-IpeTextShape -Bytes $Bytes
    if ($shape.Utf16)
    {
        return [pscustomobject]@{ Checked = $false; Bom = $false; Style = $null; BomCell = 'UTF-16, not checked'; EndingCell = 'UTF-16, not checked' }
    }

    $ending = switch ($shape.Style)
    {
        'mixed' { "mixed (CRLF $($shape.Crlf), LF $($shape.Lf))" }
        'CRLF' { "CRLF ($($shape.Crlf))" }
        'LF' { "LF ($($shape.Lf))" }
        default { 'none' }
    }

    return [pscustomobject]@{ Checked = $true; Bom = $shape.Bom; Style = $shape.Style; BomCell = $(if ($shape.Bom) { 'BOM' } else { 'no BOM' }); EndingCell = $ending }
}

function Assert-IpeBundleOut
{
    # Applies ReviewBundle's -Out rules before anything is deleted or written. Returns the normalised path and whether
    # it holds a previous bundle, whose own entries may then be replaced.
    param([Parameter(Mandatory)][string]$Out, [Parameter(Mandatory)][string]$Top, [Parameter(Mandatory)][string]$Worktree, [Parameter(Mandatory)][int]$TimeoutSeconds)

    $full = Get-IpeNormalPath $Out
    $roots = [string[]]@($Top, (Get-IpeNormalPath $Worktree))
    $insideMessage = "-Out $Out is inside $Top and not ignored; it would change the tree"
    foreach ($root in $roots)
    {
        if (Test-IpeSamePath $full $root)
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message $insideMessage -Category InvalidArgument)
        }
    }

    foreach ($flag in @('--git-dir', '--git-common-dir'))
    {
        $lines = (Invoke-IpeReadOnlyGit -Tree $Top -Arguments @('rev-parse', '--path-format=absolute', $flag) -TimeoutSeconds $TimeoutSeconds).Lines
        $gitDirectory = Get-IpeNormalPath $lines[0]
        if ((Test-IpeSamePath $full $gitDirectory) -or $null -ne (ConvertTo-IpeRepoPath -Roots @($gitDirectory) -Path $full))
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message "-Out $Out is inside the git directory $gitDirectory" -Category InvalidArgument)
        }
    }

    $relative = ConvertTo-IpeRepoPath -Roots $roots -Path $full
    if ($null -ne $relative)
    {
        # Fails closed: anything but "ignored" (exit 0), including a git error, refuses the path.
        $ignored = Invoke-IpeReadOnlyGit -Tree $Top -Arguments @('check-ignore', '-q', '--', $relative) -TimeoutSeconds $TimeoutSeconds -AllowExitCodes @(0, 1, 128)
        if ($ignored.ExitCode -ne 0)
        {
            throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message $insideMessage -Category InvalidArgument)
        }
    }

    if (Test-Path -LiteralPath $full -PathType Leaf)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message "-Out $Out is a file" -Category InvalidArgument)
    }

    $previous = $false
    if (Test-Path -LiteralPath $full -PathType Container)
    {
        $entries = @(Get-ChildItem -LiteralPath $full -Force)
        if ($entries.Count -gt 0)
        {
            $foreign = [System.Collections.Generic.List[string]]::new()
            foreach ($entry in $entries)
            {
                if (-not $entry.PSIsContainer -and $script:BundleFiles -contains $entry.Name)
                {
                    continue
                }

                if ($entry.PSIsContainer -and $entry.Name -ieq $script:BundleCheckDirectory)
                {
                    foreach ($inner in @(Get-ChildItem -LiteralPath $entry.FullName -Force))
                    {
                        if ($inner.PSIsContainer -or -not ($inner.Name -like '*-summary.txt' -or $inner.Name -ieq 'last-full-check.json'))
                        {
                            $foreign.Add("$($script:BundleCheckDirectory)\$($inner.Name)")
                        }
                    }

                    continue
                }

                $foreign.Add($entry.Name)
            }

            $indexPath = Join-Path $full 'index.md'
            $titled = $false
            if (Test-Path -LiteralPath $indexPath -PathType Leaf)
            {
                $reader = [System.IO.StreamReader]::new($indexPath, [System.Text.UTF8Encoding]::new($false), $true)
                try
                {
                    $first = $reader.ReadLine()
                }
                finally
                {
                    $reader.Dispose()
                }

                $titled = $null -ne $first -and $first.StartsWith($script:BundleTitle, [System.StringComparison]::Ordinal)
            }

            $names = @(if ($titled) { $foreign.ToArray() } else { $entries | ForEach-Object { $_.Name } })
            if ($names.Count -gt 0)
            {
                throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message "-Out $Out holds files that are not a review bundle: $(@($names | Select-Object -First 5) -join ', '); pass a new or empty directory" -Category InvalidArgument)
            }

            $previous = $true
        }
    }

    return [pscustomobject]@{ Path = $full; Previous = $previous }
}

function ReviewBundle
{
    # Writes the evidence a reviewer reads into -Out without changing the tree: log, diff stat, byte-exact diff, per-file
    # BOM and line endings before and after, denied paths, uncommitted paths, full-check summaries, and an index.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$Out,
        [string]$Tag = 'review',
        [string]$ConfigPath
    )

    Assert-IpeAbsolutePath -Path $Worktree -Name 'Worktree'
    Assert-IpeAbsolutePath -Path $Out -Name 'Out'
    Assert-IpeName -Value $Tag -Name 'Tag'
    $top = Get-IpeTopLevel -Worktree $Worktree
    $config = Resolve-IpeConfig -Worktree $Worktree -ConfigPath $ConfigPath -Optional
    $seconds = if ($config) { $config.Timeouts.GitSeconds } else { $script:DefaultGitSeconds }
    $denySegments = [System.Collections.Generic.List[string]]::new()
    $denyNames = [string[]]@()
    if ($config)
    {
        $denySegments.AddRange([string[]]@($config.Commit.DenySegments))
        $denyNames = [string[]]@($config.Commit.DenyNames)
    }

    if (-not ($denySegments -icontains '.vs'))
    {
        $denySegments.Add('.vs')
    }

    $logDir = if ($config) { $config.LogDir } else { $script:DefaultLogDir }
    $rules = @{ LogDir = $logDir; Commit = @{ DenySegments = $denySegments.ToArray(); DenyNames = $denyNames } }

    $notCommit = "-Base '$Base' is not a commit in $top"
    if ($Base.StartsWith('-'))
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message $notCommit -Category InvalidArgument)
    }

    $baseResult = Invoke-IpeReadOnlyGit -Tree $top -Arguments @('rev-parse', '--verify', '--quiet', "$Base^{commit}") -TimeoutSeconds $seconds -AllowExitCodes @(0, 1, 128)
    if ($baseResult.ExitCode -ne 0 -or $baseResult.Lines.Count -eq 0)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message $notCommit -Category InvalidArgument)
    }

    $baseSha = $baseResult.Lines[0].Trim()
    $head = (Invoke-IpeReadOnlyGit -Tree $top -Arguments @('rev-parse', 'HEAD') -TimeoutSeconds $seconds).Lines[0].Trim()
    $mergeBaseResult = Invoke-IpeReadOnlyGit -Tree $top -Arguments @('merge-base', $baseSha, $head) -TimeoutSeconds $seconds -AllowExitCodes @(0, 1)
    if ($mergeBaseResult.ExitCode -ne 0 -or $mergeBaseResult.Lines.Count -eq 0)
    {
        throw (New-IpeErrorRecord -ErrorId 'Ipe.BadArguments' -Message "-Base '$Base' ($baseSha) and HEAD have no common ancestor in $top" -Category InvalidArgument)
    }

    $mergeBase = $mergeBaseResult.Lines[0].Trim()
    $target = Assert-IpeBundleOut -Out $Out -Top $top -Worktree $Worktree -TimeoutSeconds $seconds

    # Everything is read before -Out is touched, so a failing git call leaves no partial bundle.
    $branchResult = Invoke-IpeReadOnlyGit -Tree $top -Arguments @('symbolic-ref', '--short', '-q', 'HEAD') -TimeoutSeconds $seconds -AllowExitCodes @(0, 1)
    $branch = if ($branchResult.ExitCode -eq 0 -and $branchResult.Lines.Count -gt 0) { $branchResult.Lines[0].Trim() } else { '(detached HEAD)' }
    $logLines = Split-IpeLines (Invoke-IpeReadOnlyGit -Tree $top -Arguments @('log', '--no-color', '--no-decorate', '--format=fuller', "$baseSha..$head") -TimeoutSeconds $seconds).StdOut
    $commitCount = [int](Invoke-IpeReadOnlyGit -Tree $top -Arguments @('rev-list', '--count', "$baseSha..$head") -TimeoutSeconds $seconds).Lines[0].Trim()
    $statLines = Split-IpeLines (Invoke-IpeReadOnlyGit -Tree $top -Arguments @('diff', '--no-color', '--no-ext-diff', '-M', '--stat=200', $mergeBase, $head) -TimeoutSeconds $seconds).StdOut
    $patch = (Invoke-IpeReadOnlyGit -Tree $top -Arguments @('diff', '--no-color', '--no-ext-diff', '--no-textconv', '-M', $mergeBase, $head) -TimeoutSeconds $seconds -Bytes).Bytes
    $tokens = Split-IpeNul (Invoke-IpeReadOnlyGit -Tree $top -Arguments @('diff', '--name-status', '--no-renames', '-z', $mergeBase, $head) -TimeoutSeconds $seconds).StdOut

    $mergeShort = $mergeBase.Substring(0, 12)
    $headShort = $head.Substring(0, 12)
    $fileLines = [System.Collections.Generic.List[string]]::new()
    $fileLines.Add("# Changed files ($mergeShort..$headShort)")
    $fileLines.Add('')
    $deniedLines = [System.Collections.Generic.List[string]]::new()
    $flagCounts = [ordered]@{ 'BOM added' = 0; 'BOM removed' = 0; 'mixed' = 0 }
    $changedCount = 0
    $deniedCount = 0
    for ($i = 0; $i + 1 -lt $tokens.Count; $i += 2)
    {
        $status = $tokens[$i]
        $path = $tokens[$i + 1]
        if ($changedCount -eq 0)
        {
            $fileLines.Add('| Path | Status | BOM before | BOM after | Line endings before | Line endings after | Flags |')
            $fileLines.Add('|---|---|---|---|---|---|---|')
        }

        $changedCount++
        $isText = $script:TextExtensions -contains [System.IO.Path]::GetExtension($path).ToLowerInvariant()
        $beforeBytes = $null
        if ($status -ne 'A')
        {
            $beforeBytes = Get-IpeBundleBlob -Tree $top -Revision $mergeBase -Path $path -TimeoutSeconds $seconds
        }

        $afterBytes = $null
        if ($status -ne 'D')
        {
            $afterBytes = Get-IpeBundleBlob -Tree $top -Revision $head -Path $path -TimeoutSeconds $seconds
        }

        $before = Get-IpeBundleSide -Bytes $beforeBytes -IsText $isText
        $after = Get-IpeBundleSide -Bytes $afterBytes -IsText $isText
        $flags = [System.Collections.Generic.List[string]]::new()
        if ($before.Checked -and $after.Checked -and $after.Bom -and -not $before.Bom)
        {
            $flags.Add('BOM added')
        }
        elseif ($before.Checked -and $after.Checked -and $before.Bom -and -not $after.Bom)
        {
            $flags.Add('BOM removed')
        }

        if ($after.Checked -and $after.Style -eq 'mixed')
        {
            $flags.Add('mixed')
        }

        foreach ($flag in $flags)
        {
            $flagCounts[$flag]++
        }

        $cells = @((ConvertTo-IpeTableValue $path), $status, $before.BomCell, $after.BomCell, $before.EndingCell, $after.EndingCell, ($flags -join ', '))
        $fileLines.Add('| ' + ($cells -join ' | ') + ' |')
        $reasons = Get-IpeDeniedPathReasons -RelativePath $path -Config $rules
        if ($reasons.Count -gt 0)
        {
            $deniedCount++
            $deniedLines.Add("${path}: $($reasons -join '; ')")
        }
    }

    if ($changedCount -eq 0)
    {
        $fileLines.Add('no changes')
    }

    if ($deniedLines.Count -eq 0)
    {
        $deniedLines.Add('none')
    }

    $dirty = Get-IpeDirtyPaths -Worktree $top -Config $rules -NoOptionalLocks
    $statusLines = if ($dirty.Count -eq 0) { [string[]]@('clean') } else { $dirty }
    $logDirectory = Join-IpeTreePath -Root $top -Relative $logDir
    $copies = [System.Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $logDirectory -PathType Container)
    {
        foreach ($file in @(Get-ChildItem -LiteralPath $logDirectory -File -Force | Where-Object { $_.Name -like '*-summary.txt' -or $_.Name -ieq 'last-full-check.json' } | Sort-Object Name))
        {
            $copies.Add([pscustomobject]@{ Name = $file.Name; Bytes = [System.IO.File]::ReadAllBytes($file.FullName) })
        }
    }

    $recordLine = 'no record'
    $recordPath = Join-Path $logDirectory 'last-full-check.json'
    if (Test-Path -LiteralPath $recordPath -PathType Leaf)
    {
        try
        {
            $record = Read-IpeJsonFile -Path $recordPath -ErrorId 'Ipe.RecordInvalid'
            $recordHead = [string](Get-IpeJsonValue $record 'head')
            $headText = if ($recordHead -eq $head) { 'head equals HEAD' } else { "head $recordHead is not HEAD" }
            $recordDirty = @(@(Get-IpeJsonValue $record 'dirtyPaths') | Where-Object { $_ }).Count
            $recordLine = "result $([string](Get-IpeJsonValue $record 'result')), $headText, $recordDirty dirty path(s)"
        }
        catch
        {
            if ((Get-IpeErrorId $_) -ne 'Ipe.RecordInvalid')
            {
                throw
            }

            $recordLine = "unreadable: $($_.Exception.Message)"
        }
    }

    $flagTotal = ($flagCounts.Values | Measure-Object -Sum).Sum
    $flagText = ($flagCounts.Keys | ForEach-Object { "$_ $($flagCounts[$_])" }) -join ', '
    $index = [System.Collections.Generic.List[string]]::new()
    $index.Add("$($script:BundleTitle)$Tag")
    $index.Add('')
    $index.Add('| Field | Value |')
    $index.Add('|---|---|')
    $index.Add("| Tree | $(ConvertTo-IpeTableValue $top) |")
    $index.Add("| Branch | $(ConvertTo-IpeTableValue $branch) |")
    $index.Add("| Base | $(ConvertTo-IpeTableValue $Base) ($baseSha) |")
    $index.Add("| Merge base | $mergeBase |")
    $index.Add("| HEAD | $head |")
    $index.Add("| Commits (base..HEAD) | $commitCount |")
    $index.Add("| Changed files (merge-base..HEAD) | $changedCount |")
    $index.Add("| Line-ending flags | $flagTotal ($flagText) |")
    $index.Add("| Denied paths | $deniedCount |")
    $index.Add("| Uncommitted paths | $($dirty.Count) |")
    $index.Add("| Full-check record | $(ConvertTo-IpeTableValue $recordLine) |")
    $index.Add('')
    $index.Add('| File | Content |')
    $index.Add('|---|---|')
    $index.Add('| `log.txt` | commits in base..HEAD (`git log --format=fuller`) |')
    $index.Add('| `diffstat.txt` | `git diff --stat` of merge-base..HEAD |')
    $index.Add('| `diff.patch` | the full diff of merge-base..HEAD, byte for byte |')
    $index.Add('| `files.md` | each changed file: status, BOM and line endings before and after, flags |')
    $index.Add('| `denied-paths.txt` | changed paths that are never committed, with the reason |')
    $index.Add('| `status.txt` | uncommitted paths in the tree (listed, not diffed) |')
    if ($copies.Count -gt 0)
    {
        $index.Add("| ``$($script:BundleCheckDirectory)/`` | copies of $(ConvertTo-IpeTableValue $logDir)\*-summary.txt and last-full-check.json |")
    }

    $index.Add('')
    $index.Add('The bundle covers committed state only. Line endings are those of the committed blobs.')

    $outPath = $target.Path
    $report = [System.Collections.Generic.List[string]]::new()
    try
    {
        if ($target.Previous)
        {
            foreach ($name in $script:BundleFiles)
            {
                $previousFile = Join-Path $outPath $name
                if (Test-Path -LiteralPath $previousFile -PathType Leaf)
                {
                    Remove-Item -LiteralPath $previousFile -Force
                }
            }

            $previousChecks = Join-Path $outPath $script:BundleCheckDirectory
            if (Test-Path -LiteralPath $previousChecks -PathType Container)
            {
                Remove-Item -LiteralPath $previousChecks -Recurse -Force
            }
        }

        [void][System.IO.Directory]::CreateDirectory($outPath)
        $texts = [ordered]@{
            'log.txt' = $(if ($logLines.Count -gt 0) { $logLines } else { [string[]]@('no commits') })
            'diffstat.txt' = $(if ($statLines.Count -gt 0) { $statLines } else { [string[]]@('no changes') })
            'files.md' = $fileLines.ToArray()
            'denied-paths.txt' = $deniedLines.ToArray()
            'status.txt' = [string[]]$statusLines
        }
        foreach ($name in $texts.Keys)
        {
            $path = Join-Path $outPath $name
            Write-IpeBundleText -Path $path -Lines ([string[]]@($texts[$name]))
            $report.Add("wrote $path")
        }

        $patchPath = Join-Path $outPath 'diff.patch'
        [System.IO.File]::WriteAllBytes($patchPath, [byte[]]$patch)
        $report.Add("wrote $patchPath")
        if ($copies.Count -gt 0)
        {
            $checkDirectory = Join-Path $outPath $script:BundleCheckDirectory
            [void][System.IO.Directory]::CreateDirectory($checkDirectory)
            foreach ($copy in $copies)
            {
                $path = Join-Path $checkDirectory $copy.Name
                [System.IO.File]::WriteAllBytes($path, [byte[]]$copy.Bytes)
                $report.Add("wrote $path")
            }
        }

        $indexPath = Join-Path $outPath 'index.md'
        Write-IpeBundleText -Path $indexPath -Lines $index.ToArray()
        $report.Add("wrote $indexPath")
    }
    catch
    {
        throw (New-IpeErrorRecord -ErrorId (Get-IpeErrorId $_) -Message "$($_.Exception.Message); partial bundle left in $outPath" -Category WriteError)
    }

    $report.Add("bundle: $indexPath")
    return [pscustomobject]@{
        ExitCode = 0
        Out = $outPath
        IndexPath = $indexPath
        Changed = $changedCount
        Denied = $deniedCount
        Report = $report.ToArray()
    }
}

Export-ModuleMember -Function @(
    'Invoke-Git'
    'Search-Worktree'
    'Edit-File'
    'Get-RunSummary'
    'Use-Drive'
    'Use-Sql'
    'Stop-TestHosts'
    'Test-LineEndings'
    'Invoke-Format'
    'Compare-Warnings'
    'Remove-LeakedTestDatabases'
    'Invoke-Focused'
    'Repeat-Tests'
    'Invoke-FullCheck'
    'Invoke-Mutations'
    'Commit-Change'
    'Merge-Ticket'
    'Resolve-Ticket'
    'New-TicketWorktree'
    'Update-Ledger'
    'Export-ReviewFindings'
    'ReviewBundle'
)
