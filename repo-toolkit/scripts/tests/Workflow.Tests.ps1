# Workflow: Commit-Change, Merge-Ticket, Resolve-Ticket, New-TicketWorktree, Update-Ledger, Export-ReviewFindings.
# Every git-mutating command runs only against throwaway repos under TEMP. Merge-Ticket's full check and mutation
# runner are replaced in module scope; their outcome comes from $global:IpeMergeTest.

function New-WorkflowConfig
{
    param([Parameter(Mandatory)][string]$Directory, [string]$Letter = 'Z')

    return New-TestConfig -Directory $Directory -Overrides @{
        DrivePool = "@('$Letter')"
        Commit = "@{ Types = @('feat', 'fix', 'chore'); DenyNames = @('HANDOFF.md', 'CODE-REVIEW.md'); DenySegments = @('.vs') }"
    }
}

function Get-TestRevision
{
    param([Parameter(Mandatory)][string]$Repo, [string]$Revision = 'HEAD')

    return [string](Invoke-TestGit -Repo $Repo -Arguments @('rev-parse', $Revision))
}

function Get-TestCommitMessage
{
    # The stored message of a commit, byte for byte (git log would reformat it).
    param([Parameter(Mandatory)][string]$Repo, [string]$Revision = 'HEAD')

    $raw = (Invoke-Git -Worktree $Repo -Arguments @('cat-file', 'commit', $Revision)).StdOut
    return $raw.Substring($raw.IndexOf("`n`n", [System.StringComparison]::Ordinal) + 2)
}

function Get-TestCommitFiles
{
    param([Parameter(Mandatory)][string]$Repo)

    return , [string[]](Invoke-Git -Worktree $Repo -Arguments @('diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD')).Lines
}

function Get-TestStatus
{
    param([Parameter(Mandatory)][string]$Repo)

    return , [string[]](Invoke-Git -Worktree $Repo -Arguments @('status', '--porcelain', '--untracked-files=all')).Lines
}

function Get-TestTempMessageFiles
{
    return , [string[]]@(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'ipe-commit-*.txt' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
}

function Test-CommitChangeRefusesDeniedPathsBadMessagesAndStrayStaging
{
    Import-IpeForTest
    $repo = New-TempRepo
    $configDir = New-TempDir
    try
    {
        $config = New-WorkflowConfig -Directory $configDir
        Write-TestBytes -Path (Join-Path $repo 'src\a.cs') -Text "class A`r`n{`r`n}`r`n"
        New-TempCommit -Repo $repo -Message 'base'
        $head = Get-TestRevision $repo
        Write-TestBytes -Path (Join-Path $repo 'src\a.cs') -Text "class A`r`n{`r`n    int X;`r`n}`r`n"
        Write-TestBytes -Path (Join-Path $repo '.vs\settings.json') -Text "{}`r`n"
        Write-TestBytes -Path (Join-Path $repo 'docs\HANDOFF.md') -Text "# handoff`r`n"
        Write-TestBytes -Path (Join-Path $repo 'docs\CODE-REVIEW.md') -Text "# review`r`n"
        Write-TestBytes -Path (Join-Path $repo '.ipe-logs\run.md') -Text "log`r`n"
        $cases = @(
            @{ Paths = @('src/a.cs', '.vs/settings.json'); Message = 'feat(01): change a'; Like = "*.vs/settings.json has a '.vs' path segment*" }
            @{ Paths = @('docs/HANDOFF.md'); Message = 'feat(01): add handoff'; Like = '*docs/HANDOFF.md is named HANDOFF.md*' }
            @{ Paths = @('docs\CODE-REVIEW.md'); Message = 'feat(01): add review'; Like = '*docs/CODE-REVIEW.md is named CODE-REVIEW.md*' }
            @{ Paths = @('.ipe-logs/run.md'); Message = 'feat(01): add log'; Like = '*.ipe-logs/run.md is under the log directory*' }
            @{ Paths = @('src/a.cs'); Message = 'change a'; Like = "*the first line 'change a' must be '<type>(01): <summary>'*" }
            @{ Paths = @('src/a.cs'); Message = 'docs(01): change a'; Like = "*the first line 'docs(01): change a' must be*feat, fix, chore*" }
            @{ Paths = @('src/a.cs'); Message = 'feat(01):change a'; Like = "*the first line 'feat(01):change a' must be*" }
            @{ Paths = @('src/a.cs'); Message = 'feat(02): change a'; Like = "*the first line names '02' but -Id is '01'*" }
            @{ Paths = @('src/a.cs', 'src/missing.cs'); Message = 'feat(01): change a'; Like = '*src/missing.cs is missing*' }
        )
        foreach ($case in $cases)
        {
            Assert-Throws { Commit-Change -Worktree $repo -Id '01' -Paths $case.Paths -Message $case.Message -ConfigPath $config } -ErrorId 'Ipe.CommitRefused' -MessageLike $case.Like | Out-Null
        }

        Assert-Equal 0 @((Invoke-Git -Worktree $repo -Arguments @('diff', '--cached', '--name-only')).Lines).Count ' (a refusal staged something)'
        Write-TestBytes -Path (Join-Path $repo 'src\b.cs') -Text "class B`r`n{`r`n}`r`n"
        Invoke-TestGit -Repo $repo -Arguments @('add', 'src/b.cs') | Out-Null
        Assert-Throws { Commit-Change -Worktree $repo -Id '01' -Paths @('src/a.cs') -Message 'feat(01): change a' -ConfigPath $config } -ErrorId 'Ipe.CommitRefused' -MessageLike '*already staged but not in -Paths: src/b.cs*' | Out-Null
        Assert-Equal @('src/b.cs') @((Invoke-Git -Worktree $repo -Arguments @('diff', '--cached', '--name-only')).Lines)
        Assert-Equal $head (Get-TestRevision $repo)
    }
    finally
    {
        Remove-TempDir $repo
        Remove-TempDir $configDir
    }
}

function Test-CommitChangeCommitsExactlyThePathsWithTheExactMessage
{
    Import-IpeForTest
    $repo = New-TempRepo
    $configDir = New-TempDir
    try
    {
        $config = New-WorkflowConfig -Directory $configDir
        Write-TestBytes -Path (Join-Path $repo 'src\a.cs') -Text "class A`r`n{`r`n}`r`n"
        Write-TestBytes -Path (Join-Path $repo 'src\other.cs') -Text "class Other`r`n{`r`n}`r`n"
        New-TempCommit -Repo $repo -Message 'base'
        $head = Get-TestRevision $repo
        Write-TestBytes -Path (Join-Path $repo 'src\a.cs') -Text "class A`r`n{`r`n    int X;`r`n}`r`n"
        Write-TestBytes -Path (Join-Path $repo 'src\new.cs') -Text "class New`r`n{`r`n}`r`n"
        Write-TestBytes -Path (Join-Path $repo 'src\other.cs') -Text "class Other`r`n{`r`n    int Y;`r`n}`r`n"
        $messageFile = Join-Path $configDir 'message.txt'
        Write-TestBytes -Path $messageFile -Text "feat(01): change a and add new`r`n`r`nBody line.`r`n`r`n"
        $tempBefore = Get-TestTempMessageFiles
        $result = Use-TestEnvironment -Variables (Get-TestGitIdentity) -ScriptBlock {
            Commit-Change -Worktree $repo -Id '01' -Paths @('src/a.cs', (Join-Path $repo 'src\new.cs')) -MessageFile $messageFile -ConfigPath $config
        }
        Assert-Equal 0 $result.ExitCode
        Assert-Equal (Get-TestRevision $repo) $result.Commit
        Assert-Equal $head (Get-TestRevision $repo 'HEAD~1')
        Assert-Equal '2' ([string](Invoke-TestGit -Repo $repo -Arguments @('rev-list', '--count', 'HEAD')))
        Assert-Equal "feat(01): change a and add new`n`nBody line.`n" (Get-TestCommitMessage $repo)
        Assert-Equal @('src/a.cs', 'src/new.cs') (Get-TestCommitFiles $repo)
        Assert-Equal @(' M src/other.cs') (Get-TestStatus $repo)
        Assert-True (-not (Test-Path -LiteralPath $result.MessageFile)) 'the temporary message file was left behind'
        Assert-Equal $tempBefore (Get-TestTempMessageFiles)
        Assert-Contains $result.Report 'status:'
        Assert-Contains $result.Report ' M src/other.cs'
    }
    finally
    {
        Remove-TempDir $repo
        Remove-TempDir $configDir
    }
}

function Install-MergeSeams
{
    & (Get-Module ipe) {
        function script:Invoke-FullCheck
        {
            param([string]$Worktree, [string]$Base, [string]$Tag, [string]$Drive, [string]$ConfigPath)

            $state = $global:IpeMergeTest
            $state.Checks.Add([pscustomobject]@{ Worktree = $Worktree; Base = $Base; Tag = $Tag })
            return [pscustomobject]@{
                ExitCode = $state.CheckExit; Passed = ($state.CheckExit -eq 0); Failures = [string[]]@()
                SummaryPath = (Join-Path $Worktree ".ipe-logs\$Tag-summary.txt"); Report = [string[]]@("fake full check: exit $($state.CheckExit)")
            }
        }

        function script:Invoke-Mutations
        {
            param(
                [string]$Worktree, [string]$Feature, [string]$SpecDir, [string[]]$Only, [string]$Tag, [string]$Drive,
                [string]$ConfigPath, [switch]$AllowStaged, [switch]$NoFinalRebuild
            )

            $state = $global:IpeMergeTest
            $state.Mutations.Add([pscustomobject]@{ Only = $Only; SpecDir = $SpecDir; Tag = $Tag; AllowStaged = [bool]$AllowStaged })
            return [pscustomobject]@{ ExitCode = $state.MutationExit; Results = @(); Remnants = [string[]]@(); Report = [string[]]@("fake mutations: $($Only -join ', ')") }
        }
    }
}

function New-MergeState
{
    param([int]$CheckExit = 0, [int]$MutationExit = 0)

    $global:IpeMergeTest = @{
        Checks = [System.Collections.Generic.List[object]]::new()
        Mutations = [System.Collections.Generic.List[object]]::new()
        CheckExit = $CheckExit
        MutationExit = $MutationExit
    }
    return $global:IpeMergeTest
}

function Write-WorkflowRecord
{
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][string]$Find)

    $text = "---`r`nid: $Id`r`nstatus: active`r`nproject: Unit`r`nfile: $File`r`nexpectedMatches: 1`r`nfind: |-`r`n  $Find`r`nreplace: ''`r`n---`r`n# $Id`r`n"
    Write-TestBytes -Path (Join-Path $Repo ".scratch\demo\mutations\$Id.md") -Text $text
}

function New-MergeFixture
{
    # main holds src/Calc.cs, src/Other.cs and two mutation records; branch ticket/01 (a worktree outside the repo)
    # changes Calc.cs. -IntegrationMoves commits a change to Other.cs on main afterwards; -Conflict commits a
    # conflicting change to the same Calc.cs line.
    param([switch]$IntegrationMoves, [switch]$Conflict)

    $fixture = @{ Repo = (New-TempRepo); ConfigDir = (New-TempDir); SourceParent = (New-TempDir); Letter = @(Get-FreeTestDriveLetter)[0] }
    $fixture.Source = Join-Path $fixture.SourceParent 'wt'
    $fixture.Config = New-WorkflowConfig -Directory $fixture.ConfigDir -Letter $fixture.Letter
    $repo = $fixture.Repo
    Write-TestBytes -Path (Join-Path $repo 'src\Calc.cs') -Text "class Calc`r`n{`r`n    int Add(int a, int b) => a + b;`r`n}`r`n"
    Write-TestBytes -Path (Join-Path $repo 'src\Other.cs') -Text "class Other`r`n{`r`n    int Twice(int a) => a * 2;`r`n}`r`n"
    Write-WorkflowRecord -Repo $repo -Id 'm-calc' -File 'src/Calc.cs' -Find 'a + b'
    Write-WorkflowRecord -Repo $repo -Id 'm-other' -File 'src/Other.cs' -Find 'a * 2'
    New-TempCommit -Repo $repo -Message 'base'
    Invoke-TestGit -Repo $repo -Arguments @('worktree', 'add', '-q', '-b', 'ticket/01', $fixture.Source, 'main') | Out-Null
    Write-TestBytes -Path (Join-Path $fixture.Source 'src\Calc.cs') -Text "class Calc`r`n{`r`n    int Add(int a, int b) => a + b; // checked`r`n    int Sub(int a, int b) => a - b;`r`n}`r`n"
    New-TempCommit -Repo $fixture.Source -Message 'feat(01): add Sub'
    if ($IntegrationMoves)
    {
        Write-TestBytes -Path (Join-Path $repo 'src\Other.cs') -Text "class Other`r`n{`r`n    int Twice(int a) => a * 2;`r`n    int Thrice(int a) => a * 3;`r`n}`r`n"
        New-TempCommit -Repo $repo -Message 'feat(00): add Thrice'
    }

    if ($Conflict)
    {
        Write-TestBytes -Path (Join-Path $repo 'src\Calc.cs') -Text "class Calc`r`n{`r`n    long Add(int a, int b) => a + b;`r`n}`r`n"
        New-TempCommit -Repo $repo -Message 'feat(00): widen Add'
    }

    $fixture.SourceHead = Get-TestRevision $fixture.Source
    $fixture.PreTip = Get-TestRevision $repo
    return $fixture
}

function Remove-MergeFixture
{
    param([hashtable]$Fixture)

    Remove-Variable -Name IpeMergeTest -Scope Global -ErrorAction SilentlyContinue
    if (-not $Fixture)
    {
        return
    }

    Remove-TestSubst -Letter $Fixture.Letter -Target $Fixture.Repo
    Remove-TempDir $Fixture.SourceParent
    Remove-TempDir $Fixture.Repo
    Remove-TempDir $Fixture.ConfigDir
}

function Write-ImplementerRecord
{
    param([Parameter(Mandatory)][hashtable]$Fixture, [Parameter(Mandatory)][string]$Head, [string]$Result = 'pass')

    $record = [ordered]@{
        result = $Result; head = $Head; tree = $Fixture.Source; dirtyPaths = [string[]]@()
        summaryPath = (Join-Path $Fixture.Source '.ipe-logs\full-check-summary.txt'); finished = '2026-01-01T00:00:00.0000000+00:00'
    }
    Write-TestBytes -Path (Join-Path $Fixture.Source '.ipe-logs\last-full-check.json') -Text ($record | ConvertTo-Json -Depth 3)
    return $record.summaryPath
}

function Invoke-TestMerge
{
    param([Parameter(Mandatory)][hashtable]$Fixture, [switch]$Continue)

    return Use-TestEnvironment -Variables (Get-TestGitIdentity) -ScriptBlock {
        Merge-Ticket -Integration $Fixture.Repo -Source $Fixture.Source -Id '01' -Feature demo -Continue:$Continue -ConfigPath $Fixture.Config
    }
}

function Test-MergeTicketTreeEqualWithImplementerRecordCommitsWithoutTheCheck
{
    Import-IpeForTest
    Install-MergeSeams
    $fixture = $null
    try
    {
        $fixture = New-MergeFixture
        $state = New-MergeState
        $summaryPath = Write-ImplementerRecord -Fixture $fixture -Head $fixture.SourceHead
        $result = Invoke-TestMerge -Fixture $fixture
        Assert-Equal 0 $result.ExitCode
        Assert-Equal 0 $state.Checks.Count ' (full check calls)'
        Assert-Equal 0 $state.Mutations.Count ' (mutation runs)'
        Assert-Equal $fixture.PreTip (Get-TestRevision $fixture.Repo 'HEAD^1')
        Assert-Equal $fixture.SourceHead (Get-TestRevision $fixture.Repo 'HEAD^2')
        $short = [string](Invoke-TestGit -Repo $fixture.Repo -Arguments @('rev-parse', '--short', $fixture.SourceHead))
        $message = Get-TestCommitMessage $fixture.Repo
        Assert-Equal 'chore(01): merge ticket/01' ($message -split "`n")[0]
        Assert-Contains $message "`n`nVerification: verified by the implementer at $short (record "
        Assert-Contains $message "`nSummary: $summaryPath`n"
        Assert-Contains $result.Report 'line endings: pass'
        Assert-Equal @() (Get-TestStatus $fixture.Repo)
    }
    finally
    {
        Remove-MergeFixture $fixture
    }
}

function Test-MergeTicketRecordForAnotherHeadRunsTheCheck
{
    Import-IpeForTest
    Install-MergeSeams
    $fixture = $null
    try
    {
        $fixture = New-MergeFixture
        $state = New-MergeState
        [void](Write-ImplementerRecord -Fixture $fixture -Head $fixture.PreTip)
        $result = Invoke-TestMerge -Fixture $fixture
        Assert-Equal 0 $result.ExitCode
        Assert-Equal 1 $state.Checks.Count ' (full check calls)'
        Assert-Equal $fixture.PreTip $state.Checks[0].Base
        Assert-Equal 'merge-01' $state.Checks[0].Tag
        Assert-Equal 0 $state.Mutations.Count ' (no file differs from the source tree, so no mutation is selected)'
        Assert-True (@($result.Report | Where-Object { $_ -like 'implementer record * does not cover *' }).Count -eq 1) 'the stale record is not reported'
        $message = Get-TestCommitMessage $fixture.Repo
        Assert-Equal 'chore(01): merge ticket/01' ($message -split "`n")[0]
        Assert-Contains $message 'passed (tag merge-01); mutations: none selected'
        Assert-Equal $fixture.SourceHead (Get-TestRevision $fixture.Repo 'HEAD^2')
    }
    finally
    {
        Remove-MergeFixture $fixture
    }
}

function Test-MergeTicketDifferentTreeRunsTheCheckAndOnlyTheAffectedMutation
{
    Import-IpeForTest
    Install-MergeSeams
    $fixture = $null
    try
    {
        $fixture = New-MergeFixture -IntegrationMoves
        $state = New-MergeState
        [void](Write-ImplementerRecord -Fixture $fixture -Head $fixture.SourceHead)
        $result = Invoke-TestMerge -Fixture $fixture
        Assert-Equal 0 $result.ExitCode
        Assert-Equal 1 $state.Checks.Count ' (full check calls)'
        Assert-Equal 1 $state.Mutations.Count ' (mutation runs)'
        Assert-Equal @('m-other') $state.Mutations[0].Only
        Assert-Equal $true $state.Mutations[0].AllowStaged
        Assert-Contains $result.Report "merged tree differs from the tree of $([string](Invoke-TestGit -Repo $fixture.Repo -Arguments @('rev-parse', '--short', $fixture.SourceHead)))"
        Assert-Contains (Get-TestCommitMessage $fixture.Repo) 'mutations m-other as expected'
        Assert-Equal @($fixture.PreTip, $fixture.SourceHead) @((Get-TestRevision $fixture.Repo 'HEAD^1'), (Get-TestRevision $fixture.Repo 'HEAD^2'))
    }
    finally
    {
        Remove-MergeFixture $fixture
    }
}

function Test-MergeTicketFailedCheckAbortsTheMerge
{
    Import-IpeForTest
    Install-MergeSeams
    $fixture = $null
    try
    {
        $fixture = New-MergeFixture -IntegrationMoves
        $state = New-MergeState -CheckExit 1
        $calcBefore = [System.IO.File]::ReadAllBytes((Join-Path $fixture.Repo 'src\Calc.cs'))
        $result = Invoke-TestMerge -Fixture $fixture
        Assert-Equal 1 $result.ExitCode
        Assert-Equal 1 $state.Checks.Count
        Assert-Equal 0 $state.Mutations.Count
        Assert-Equal $fixture.PreTip (Get-TestRevision $fixture.Repo)
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Repo '.git\MERGE_HEAD'))) 'the merge is still in progress'
        Assert-Equal @() (Get-TestStatus $fixture.Repo)
        Assert-Equal $calcBefore ([System.IO.File]::ReadAllBytes((Join-Path $fixture.Repo 'src\Calc.cs')))
        Assert-True (@($result.Report | Where-Object { $_ -like 'merge aborted; HEAD unchanged at *' }).Count -eq 1) 'the abort is not reported'
        Assert-True (@($result.Report | Where-Object { $_ -like 'merge: FAIL (full check against * failed)' }).Count -eq 1) 'the failure is not reported'
    }
    finally
    {
        Remove-MergeFixture $fixture
    }
}

function Test-MergeTicketConflictExitsThreeAndContinueCommits
{
    Import-IpeForTest
    Install-MergeSeams
    $fixture = $null
    try
    {
        $fixture = New-MergeFixture -Conflict
        $state = New-MergeState
        $output = & $script:PwshPath -NoProfile -File $script:IpeEntryPath Merge-Ticket -Integration $fixture.Repo -Source $fixture.Source -Id 01 -Feature demo -ConfigPath $fixture.Config 2>&1
        Assert-Equal 3 $LASTEXITCODE
        Assert-Contains (($output | ForEach-Object { "$_" }) -join "`n") 'conflicts in: src/Calc.cs'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Repo '.git\MERGE_HEAD')) 'MERGE_HEAD is missing after the conflict'
        Assert-Equal $fixture.PreTip (Get-TestRevision $fixture.Repo)
        Assert-Throws { Invoke-TestMerge -Fixture $fixture -Continue } -ErrorId 'Ipe.MergeConflict' -MessageLike 'still conflicted: src/Calc.cs*' | Out-Null
        Write-TestBytes -Path (Join-Path $fixture.Repo 'src\Calc.cs') -Text "class Calc`r`n{`r`n    long Add(int a, int b) => a + b; // checked`r`n    int Sub(int a, int b) => a - b;`r`n}`r`n"
        Invoke-TestGit -Repo $fixture.Repo -Arguments @('add', 'src/Calc.cs') | Out-Null
        $result = Invoke-TestMerge -Fixture $fixture -Continue
        Assert-Equal 0 $result.ExitCode
        Assert-Equal 1 $state.Checks.Count
        Assert-Equal @('m-calc') $state.Mutations[0].Only
        Assert-Equal @($fixture.PreTip, $fixture.SourceHead) @((Get-TestRevision $fixture.Repo 'HEAD^1'), (Get-TestRevision $fixture.Repo 'HEAD^2'))
        Assert-Equal 'chore(01): merge ticket/01' ((Get-TestCommitMessage $fixture.Repo) -split "`n")[0]
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Repo '.git\MERGE_HEAD'))) 'MERGE_HEAD is left after the commit'
    }
    finally
    {
        Remove-MergeFixture $fixture
    }
}

function Test-ResolveTicketFlipsStatusTicksBoxesAppendsTheCommentAndCommitsOnlyTheTicket
{
    Import-IpeForTest
    $repo = New-TempRepo
    $configDir = New-TempDir
    try
    {
        $config = New-WorkflowConfig -Directory $configDir
        $ticket = Join-Path $repo '.scratch\demo\issues\01-demo.md'
        Write-TestBytes -Path $ticket -Bom -Text ("# 01 Demo`r`n`r`n**Status:** ready-for-agent`r`n`r`n## Acceptance criteria`r`n`r`n- [ ] First`r`n- [x] Second`r`n  - [ ] Nested`r`n`r`n" +
            "## Comments`r`n`r`n### Earlier`r`n`r`n- old comment`r`n")
        Write-TestBytes -Path (Join-Path $repo 'src\a.cs') -Text "class A`r`n{`r`n}`r`n"
        New-TempCommit -Repo $repo -Message 'base'
        Write-TestBytes -Path (Join-Path $repo 'src\a.cs') -Text "class A`r`n{`r`n    int X;`r`n}`r`n"
        $commentFile = Join-Path $configDir 'comment.md'
        Write-TestBytes -Path $commentFile -Text "### 2026-01-01 merged`n`n- Merge: abc1234`n"
        $result = Use-TestEnvironment -Variables (Get-TestGitIdentity) -ScriptBlock {
            Resolve-Ticket -Worktree $repo -TicketFile $ticket -Id '01' -CommentFile $commentFile -ConfigPath $config
        }
        Assert-Equal 0 $result.ExitCode
        $expected = "# 01 Demo`r`n`r`n**Status:** resolved`r`n`r`n## Acceptance criteria`r`n`r`n- [x] First`r`n- [x] Second`r`n  - [x] Nested`r`n`r`n" +
        "## Comments`r`n`r`n### Earlier`r`n`r`n- old comment`r`n`r`n### 2026-01-01 merged`r`n`r`n- Merge: abc1234`r`n"
        $expectedBytes = [byte[]](@(0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes($expected))
        Assert-Equal $expectedBytes ([System.IO.File]::ReadAllBytes($ticket))
        Assert-Equal "chore(01): resolve ticket`n" (Get-TestCommitMessage $repo)
        Assert-Equal @('.scratch/demo/issues/01-demo.md') (Get-TestCommitFiles $repo)
        Assert-Equal @(' M src/a.cs') (Get-TestStatus $repo)

        $head = Get-TestRevision $repo
        $second = Join-Path $repo '.scratch\demo\issues\02-demo.md'
        Write-TestBytes -Path $second -Text "Status: needs-triage`n`n## Comments`n`n- first`n`n## Notes`n`nkeep`n"
        Write-TestBytes -Path $commentFile -Text "- second`r`n"
        $plain = Resolve-Ticket -Worktree $repo -TicketFile $second -Id '02' -CommentFile $commentFile -NoCommit -ConfigPath $config
        Assert-Equal 0 $plain.ExitCode
        Assert-Equal "Status: resolved`n`n## Comments`n`n- first`n`n- second`n`n## Notes`n`nkeep`n" ([System.IO.File]::ReadAllText($second))
        Assert-Equal $head (Get-TestRevision $repo)
    }
    finally
    {
        Remove-TempDir $repo
        Remove-TempDir $configDir
    }
}

function Test-NewTicketWorktreeCreatesBranchWorktreeDriveAndLedgerRow
{
    Import-IpeForTest
    $repo = New-TempRepo
    $configDir = New-TempDir
    $letter = @(Get-FreeTestDriveLetter)[0]
    $worktree = Join-Path $repo '.worktrees\03'
    try
    {
        $config = New-WorkflowConfig -Directory $configDir -Letter $letter
        Write-TestBytes -Path (Join-Path $repo 'base.txt') -Text "base`r`n"
        New-TempCommit -Repo $repo -Message 'base'
        $base = Get-TestRevision $repo
        $short = [string](Invoke-TestGit -Repo $repo -Arguments @('rev-parse', '--short', $base))
        $ledger = Join-Path $configDir 'ledger.md'
        Copy-Item -LiteralPath (Join-Path $script:FixturesRoot 'ledger.md') -Destination $ledger
        $result = New-TicketWorktree -RepoRoot $repo -Id '03' -Branch 'demo/03-third' -Base 'main' -LedgerPath $ledger -ConfigPath $config
        Assert-Equal 0 $result.ExitCode
        Assert-Equal $base (Get-TestRevision $repo 'demo/03-third')
        Assert-Equal $base $result.Base
        Assert-True (Test-Path -LiteralPath (Join-Path $worktree 'base.txt')) 'the worktree was not checked out'
        Assert-Contains @(Invoke-TestGit -Repo $repo -Arguments @('worktree', 'list', '--porcelain')) 'branch refs/heads/demo/03-third'
        Assert-Equal $letter $result.Drive
        Assert-True (Test-Path -LiteralPath "${letter}:\base.txt") 'the drive does not show the worktree'
        $row = @([System.IO.File]::ReadAllLines($ledger) | Where-Object { $_.StartsWith('| 03 |') })
        Assert-Equal @("| 03 | active | 03 / demo/03-third | $short |  | drive ${letter}: |") $row
        Assert-Throws { New-TicketWorktree -RepoRoot $repo -Id '04' -Branch 'demo/03-third' -Base 'main' -ConfigPath $config } -ErrorId 'Ipe.BranchExists' | Out-Null
        Assert-Throws { New-TicketWorktree -RepoRoot $repo -Id '03' -Branch 'demo/03-other' -Base 'main' -ConfigPath $config } -ErrorId 'Ipe.PathExists' | Out-Null
        Assert-Equal 1 @(Invoke-TestGit -Repo $repo -Arguments @('branch', '--list', 'demo/*')).Count ' (a refused call created a branch)'
    }
    finally
    {
        Remove-TestSubst -Letter $letter -Target $worktree
        if (Test-Path -LiteralPath $worktree)
        {
            Invoke-TestGit -Repo $repo -Arguments @('worktree', 'remove', '--force', $worktree) | Out-Null
        }

        Remove-TempDir $repo
        Remove-TempDir $configDir
    }
}

function Get-TestLedgerText
{
    # The fixture ledger as CRLF text, whatever the checkout's line endings.
    return [System.IO.File]::ReadAllText((Join-Path $script:FixturesRoot 'ledger.md')).Replace("`r`n", "`n").Replace("`n", "`r`n")
}

function Read-TestLedgerLines
{
    # Lines of a BOM + CRLF ledger; throws if the BOM is gone or a bare LF crept in.
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    Assert-True ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'the BOM was lost'
    $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    Assert-True (-not $text.Replace("`r`n", '').Contains("`n")) 'a bare LF was written'
    return , [string[]]($text -split "`r`n")
}

function Test-UpdateLedgerEditsOnlyTheTargetedRow
{
    Import-IpeForTest
    $dir = New-TempDir
    try
    {
        $path = Join-Path $dir 'ledger.md'
        Write-TestBytes -Path $path -Text (Get-TestLedgerText) -Bom
        $before = Read-TestLedgerLines $path
        $index = [array]::IndexOf($before, '| 02 | active | demo-02 / demo/02-second | 3333333c | impl wf_fedcba9876543210 | pipe \| inside |')
        Assert-True ($index -gt 0) 'fixture row 02 not found'
        $result = Update-Ledger -LedgerPath $path -Ticket '02' -State 'resolved' -Workflow 'wf_00112233445566aa' -WorkflowRole 'merger' -AppendNote 'merged'
        Assert-Equal 0 $result.ExitCode
        $after = Read-TestLedgerLines $path
        $expected = [string[]]$before.Clone()
        $expected[$index] = '| 02 | resolved | demo-02 / demo/02-second | 3333333c | impl wf_fedcba9876543210; merger wf_00112233445566aa | pipe \| inside; merged |'
        Assert-Equal $expected $after

        [void](Update-Ledger -LedgerPath $path -Ticket '02' -Workflow 'wf_00112233445566aa' -WorkflowRole 'merger')
        Assert-Equal $expected (Read-TestLedgerLines $path) ' (a repeated workflow id was appended twice)'

        [void](Update-Ledger -LedgerPath $path -Ticket '01' -SourceHead '9999999d')
        $ticketsRow = [array]::IndexOf($expected, '| 01 | resolved | demo-01 / demo/01-first | 1111111a | impl wf_0123456789abcdef | merge 2222222b |')
        $expected[$ticketsRow] = '| 01 | resolved | demo-01 / demo/01-first | 9999999d | impl wf_0123456789abcdef | merge 2222222b |'
        Assert-Equal $expected (Read-TestLedgerLines $path) ' (row 01 of the tickets table, not of the checks table, must change)'
    }
    finally
    {
        Remove-TempDir $dir
    }
}

function Test-UpdateLedgerRefusesUnconfirmedWorkflowIdsAndAppendsMissingRows
{
    Import-IpeForTest
    $dir = New-TempDir
    try
    {
        $path = Join-Path $dir 'ledger.md'
        Write-TestBytes -Path $path -Text (Get-TestLedgerText) -Bom
        $bytes = [System.IO.File]::ReadAllBytes($path)
        foreach ($bad in @('wf_123', 'wf_0123456789abcdef?', 'unconfirmed', 'WF_0123456789ABCDEF'))
        {
            Assert-Throws { Update-Ledger -LedgerPath $path -Ticket '01' -Workflow $bad -WorkflowRole 'impl' } -ErrorId 'Ipe.BadWorkflowId' -MessageLike '*record ids only from the run_workflow result*' | Out-Null
        }

        Assert-Equal $bytes ([System.IO.File]::ReadAllBytes($path))
        & $script:PwshPath -NoProfile -File $script:IpeEntryPath Update-Ledger -LedgerPath $path -Ticket 01 -Workflow wf_bad -WorkflowRole impl 2>$null | Out-Null
        Assert-Equal 1 $LASTEXITCODE
        Assert-Throws { Update-Ledger -LedgerPath $path -Ticket '04' -Note 'new' } -ErrorId 'Ipe.BadArguments' -MessageLike "row '04' is not in the ledger*" | Out-Null
        Assert-Equal $bytes ([System.IO.File]::ReadAllBytes($path))

        $before = Read-TestLedgerLines $path
        $result = Update-Ledger -LedgerPath $path -Ticket '04' -State 'pending' -Note 'new'
        Assert-Equal $true $result.Appended
        $index = [array]::IndexOf($before, '| 03 | pending | | | | |')
        $expected = [System.Collections.Generic.List[string]]::new([string[]]$before)
        $expected.Insert($index + 1, '| 04 | pending |  |  |  | new |')
        Assert-Equal $expected.ToArray() (Read-TestLedgerLines $path)
    }
    finally
    {
        Remove-TempDir $dir
    }
}

function Test-ExportReviewFindingsListsEveryKeptFinding
{
    Import-IpeForTest
    $dir = New-TempDir
    try
    {
        $run = Join-Path $dir 'run'
        [void][System.IO.Directory]::CreateDirectory($run)
        foreach ($name in @('verified.json', 'findings.json', 'params.json'))
        {
            Copy-Item -LiteralPath (Join-Path $script:FixturesRoot $name) -Destination $run
        }

        $out = Join-Path $dir 'out\findings.md'
        $result = Export-ReviewFindings -RunDir $run -Out $out
        Assert-Equal @(0, 12, 12, 2) @($result.ExitCode, $result.Count, $result.Kept, $result.Dropped)
        $text = [System.IO.File]::ReadAllText($out)
        Assert-Equal 12 ([regex]::Matches($text, '(?m)^## \d+\. ').Count)
        Assert-Contains $text "- Target: integration/contoso-demo @ 1234abcd vs main`n"
        Assert-Contains $text "- Counts: pooled 18, deduplicated 14, kept 12, dropped 2`n"
        Assert-Contains $text "## 1. K01: src/Contoso.Api/Controllers/OrderController.cs:41`n"
        Assert-Contains $text "## 12. K12: src/Contoso.Domain/Clients/ShippingClient.cs:120`n"
        Assert-Contains $text "Failure scenario: The caller disconnects during the lookup and the log shows OrderLookupFailed for an aborted request.`n"
        Assert-Contains $text "Failure scenario: Own scenario: 2.345 is billed as 2.34.`n"
        Assert-NotContains $text '2.345 becomes 2.34 instead of 2.35'
        Assert-Contains $text "- Angles: a-line-scan, spec`n"
        Assert-Contains $text "Evidence: No Timeout set and no token passed.`n"
        Assert-NotContains $text 'D01'

        $all = Export-ReviewFindings -RunDir $run -Out $out -IncludeDropped
        Assert-Equal 14 $all.Count
        $text = [System.IO.File]::ReadAllText($out)
        Assert-Equal 14 ([regex]::Matches($text, '(?m)^## \d+\. ').Count)
        Assert-Contains $text "## 13. D01 (dropped): src/Contoso.Data/Entities/Order.cs:8`n"

        # -Out is a prefix of the common parameters -OutVariable/-OutBuffer; the entry point must still pass it on.
        $entryOut = Join-Path $dir 'entry\findings.md'
        $output = & $script:PwshPath -NoProfile -File $script:IpeEntryPath Export-ReviewFindings -RunDir $run -Out $entryOut 2>&1
        Assert-Equal 0 $LASTEXITCODE
        Assert-Contains (($output | ForEach-Object { "$_" }) -join "`n") 'wrote 12 finding section(s)'
        Assert-Equal 12 ([regex]::Matches([System.IO.File]::ReadAllText($entryOut), '(?m)^## \d+\. ').Count)
    }
    finally
    {
        Remove-TempDir $dir
    }
}
