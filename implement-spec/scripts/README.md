# implement-spec toolkit (`ipe.ps1`)

One PowerShell module for the chores every implement-spec agent repeats: building, testing, the full check, mutation
runs, commits, merges, ticket resolution, worktrees, the run ledger and review findings. Agents call these commands
instead of writing their own scripts. When the toolkit lacks a job, add the job to the toolkit.

Every external process runs with a timeout and through `ArgumentList`, so there is no string concatenation. A timeout
kills the whole process tree. Every git call adds `-c core.longpaths=true -C <tree>`. Repo-specific values live only
in the repo's config file. The module names no repo and no machine.

## Requirements

- PowerShell 7.2 or later (`pwsh`).
- git.
- The .NET SDK the repo builds with. `Remove-LeakedTestDatabases` runs `cleanup-test-databases.cs` as a file-based
  app (`dotnet run --file`), so it needs .NET 10 or later.
- Windows for `Use-Drive` (subst) and `Stop-TestHosts`. On other systems Use-Drive returns the tree unchanged, and
  Stop-TestHosts throws NotSupported.

## Running

```
pwsh -NoProfile -File <skill dir>\scripts\ipe.ps1 <Command> -Name value [-Switch] ...
pwsh -NoProfile -File <skill dir>\scripts\ipe.ps1 help
```

- Pass every path as an absolute path.
- A `[string[]]` parameter takes one comma-delimited string, for example `-Only 'a-1,b-2'` or
  `-Classes 'FooTests,BarTests'`. The entry point splits it. This works around `pwsh -File` passing a comma list as
  one string.
- Each command prints its report lines. The process exit code is the command's `ExitCode`.

| Exit | Meaning |
|---|---|
| 0 | pass |
| 1 | fail, or an error (the message is on stderr) |
| 2 | drive conflict (`Ipe.DriveConflict`): the requested letter maps another tree or is a real drive |
| 3 | merge conflict (`Ipe.MergeConflict`): the merge is left in progress for the merger to resolve |

## Config

Commands look for the config in this order:

1. `-ConfigPath <abs>`.
2. `$env:IPE_CONFIG`.
3. `<main repo root>\.kiro\implement-spec.psd1`. The main repo root is the parent of
   `git rev-parse --git-common-dir` for `-Worktree`, so a worktree finds the main checkout's config even when the
   config is not committed.

The config is validated when it is loaded. A missing key, a wrong type or an unknown key throws an error that names
the key. Relative paths resolve against the targeted tree. `Sql.ConnectionFile` goes through environment-variable
expansion, and a relative `ConnectionFile` resolves against the config's directory. The file's contents are never
printed or logged.

```powershell
@{
    SchemaVersion   = 1
    Solution        = 'src\<Product>.sln'
    SourcePaths     = @('src', 'tests')            # dirty-tree and remnant checks
    LogDir          = '.ipe-logs'                  # per tree; Commit-Change refuses paths under it
    WorktreeDir     = '.worktrees'
    DrivePool       = @('W', 'X', 'Y', 'Z')        # subst letters, tried in order
    MutationSpecDir = '.scratch\{feature}\mutations'
    UseSubst        = $true                        # $false when the repo sits at a short path and builds in place
    TestProjects    = @(
        @{ Name = '<Short>'; Path = 'tests\<Project>\<Project>.csproj'; Kind = 'xunit'; NeedsSql = $false; AllowEmpty = $false }
        @{ Name = '<Short2>'; Path = 'tests\<Project2>\<Project2>.csproj'; Kind = 'tunit'; NeedsSql = $true; AllowEmpty = $false }
    )
    Sql = @{
        EnvVar                = '<CONNECTION_ENV_VAR>'
        ConnectionFile        = '%LOCALAPPDATA%\<path>\<connection>.txt'   # the PATH of a private file
        Server                = '127.0.0.1,<port>'
        StartCommand          = @('<tool>', 'start', '<container>')        # must be idempotent; never a restart
        LeakedDatabasePattern = '^<prefix>_[0-9a-f]{32}$'
    }
    FormatExclusions = @()                         # @{ Path = '<file suffix>'; Code = '<diagnostic id>' }
    Warnings  = @{ Script = 'eng\check-warnings.ps1'; Baseline = 'eng\warnings-baseline.txt' }
    ExtraChecks = @(@{ Name = '<name>'; Script = 'eng\<check>.ps1' })   # optional; TimeoutSeconds defaults to 300
    Commit    = @{ Types = @('feat', 'fix', 'test', 'chore'); DenyNames = @('HANDOFF.md', 'CODE-REVIEW.md'); DenySegments = @('.vs') }
    Timeouts  = @{ BuildSeconds = 1200; XunitSeconds = 900; TunitSeconds = 900; TunitInner = '10m'; FormatSeconds = 600;
                   GitSeconds = 120; SubstSeconds = 30; SqlStartSeconds = 120; SqlProbeSeconds = 60; CleanupSeconds = 300;
                   FocusedSeconds = 900; MutationHangSeconds = 300 }
}
```

- `Kind` is `xunit` (run with `dotnet test`) or `tunit` (run with `dotnet run --project ... -- --no-ansi --no-progress
  --timeout <TunitInner>`).
- `NeedsSql` runs the project inside `Use-Sql`. With `NeedsSql` set, a skipped test fails the project unless the
  command takes `-AllowSkip`.
- `AllowEmpty` lets the project pass with zero tests.
- `Warnings.Script` is the repo's own warnings check. It is called as `-BuildLog <log> -Baseline <file> -RepoRoot
  <root>` and passes only when it exits 0.
- `ExtraChecks` (optional) adds repo checks to Invoke-FullCheck. Each `Script` is called as `-Base <base sha>
  -RepoRoot <root>` from the tree and passes only when it exits 0 within `TimeoutSeconds`.
- Add `LogDir` (`.ipe-logs/`) to the repo's `.gitignore`: every tree writes its logs and full-check records there.

## Commands

Every command also takes `-ConfigPath`.

### Core and checks

| Command | Behaviour |
|---|---|
| `Invoke-Git -Worktree -Arguments [-TimeoutSeconds] [-AllowExitCodes] [-Bytes] [-Environment]` | Runs git with long paths on. Throws with git's stderr when the exit code is not allowed. |
| `Search-Worktree -Worktree -Pattern [-Path] [-Fixed] [-IgnoreCase]` | Runs `git grep -n -I --untracked -E` and supports `\|` alternation. Searches worktrees and paths outside the workspace. No match returns an empty result with exit 0. |
| `Edit-File -Path -Find -Replace -ExpectCount [-Occurrence]` | Replaces ordinal text and keeps the file's BOM and newline style. If the match count differs from `-ExpectCount`, it throws `Ipe.MatchCount` and leaves the file untouched. |
| `Get-RunSummary -Path [-Kind auto\|tunit\|xunit\|msbuild]` | Parses a test or build log: totals, failed names, zero tests, warnings and errors. |
| `Use-Drive -Worktree [-Drive] [-Unmap]` | Maps the tree to a free `DrivePool` letter, or reuses an existing mapping. A conflict exits 2. `-Unmap` removes only this tree's mapping. With `UseSubst = $false`, it returns the tree unchanged. |
| `Use-Sql (-ScriptBlock \| -Check) [-Worktree]` | Runs `Sql.StartCommand`, probes `Sql.Server` over TCP, and sets `Sql.EnvVar` from `ConnectionFile` for the block only. A missing file fails closed. The value is never printed. |
| `Stop-TestHosts (-Drive \| -Path) [-ListOnly]` | Lists or kills processes whose command line or executable is under the drive or path, with their child processes. |
| `Test-LineEndings -Worktree -Base [-Path] [-Fix]` | Checks changed and untracked text files against `-Base`. A BOM change fails, and so do mixed CRLF/LF endings. A whole-file rewrite is a warning. `-Fix` normalises mixed files and keeps each file's BOM. |
| `Invoke-Format -Worktree -Base [-Paths] [-Drive]` | Runs `dotnet format whitespace` and then `style` with `--verify-no-changes` on the changed `*.cs` files, or on `-Paths`, filtered through `FormatExclusions`. An empty file set passes. |
| `Compare-Warnings -Worktree -BuildLog [-RepoRoot]` | Runs `Warnings.Script` on a build log. A missing script throws `Ipe.WarningsScriptMissing`. |
| `Remove-LeakedTestDatabases [-List] [-Drop] [-Worktree]` | Lists the databases that match `LeakedDatabasePattern` on the configured loopback server, or drops them with `-Drop`. Lists by default. |

### Runners

| Command | Behaviour |
|---|---|
| `Invoke-Focused -Worktree -Project [-Classes] [-Filter] [-NoBuild] [-TimeoutSeconds] [-Trx] [-Tag] [-AllowSkip]` | Builds and runs one configured project, filtered by class: TUnit `/*/*/(A\|B)/*`, xUnit `FullyQualifiedName~A\|...`. It fails on a test failure, zero tests, or a skip in a `NeedsSql` project. |
| `Repeat-Tests -Worktree -Project -Runs [-Classes] [-Filter] [-MaxThreads] [-MinThreads] [-Slowest] [-Trx] [-NoBuild]` | Builds once, then runs n times and prints one line per run. Thread caps apply to the child process only. `-Slowest n` prints the slowest tests, read from the TRX files. |
| `Invoke-FullCheck -Worktree -Base [-Tag] [-Drive]` | Runs a non-incremental solution build, then Compare-Warnings, then every configured project in order with SQL, then Invoke-Format, Test-LineEndings, then each `ExtraChecks` script, and a leaked-database list. Writes `<LogDir>\<tag>-summary.txt` and the full-check record. It never commits. |
| `Invoke-Mutations -Worktree (-Feature \| -SpecDir) [-Only] [-HangSeconds] [-AppendVerdicts] [-RestoreOnly] [-ValidateOnly] [-NoFinalRebuild]` | Runs the checked-in mutation records. It journals each file, applies the edits, builds, runs the filter under a hang limit and restores the bytes. It refuses a dirty tree and ends with a clean-tree check and a rebuild. `-ValidateOnly` checks match counts only. `-RestoreOnly` restores the journal of a killed run. |

### Workflow

| Command | Behaviour |
|---|---|
| `Commit-Change -Worktree -Id -Paths (-Message \| -MessageFile) [-Base]` | The first line must be `<type>(<Id>): ...`. Refuses denied names, segments and LogDir paths. The staged set must equal `-Paths`. Runs Test-LineEndings and then `git commit -F`. |
| `Merge-Ticket -Integration -Source -Id (-Feature \| -SpecDir) [-Continue] [-Drive]` | Runs `merge --no-ff --no-commit`. A conflict exits 3, leaves the merge in progress, and resumes with `-Continue`. A tree-equal merge with a passing full-check record skips the checks. Otherwise it runs the full check and the mutations whose files the merge changed. It commits on a pass and runs `merge --abort` on a failure. |
| `Resolve-Ticket -Worktree -TicketFile -Id -CommentFile [-Status] [-NoCommit]` | Sets the status line, ticks the checkboxes, appends the comment under `## Comments`, and commits only that file. |
| `New-TicketWorktree -RepoRoot -Id -Branch -Base [-Path] [-LedgerPath] [-LedgerKey]` | Runs `git worktree add -b`, maps a drive, and records the ledger row. |
| `Update-Ledger -LedgerPath -Ticket [-State] [-Worktree] [-SourceHead] [-Workflow -WorkflowRole] [-Note \| -AppendNote]` | Edits one row of the `\| # \| State ...` table and keeps every other byte. Accepts only workflow ids that match `wf_<16 hex>`. |
| `Export-ReviewFindings -RunDir -Out [-IncludeDropped]` | Writes every kept finding of a code-review run (`verified.json`) to Markdown, with no cap, and adds the failure scenario from `findings.json`. |

## Mutation records

Each record is a Markdown file in `MutationSpecDir`. It opens with YAML front matter, and the prose stays below it.
The parser reads a small subset of YAML: scalars (plain, single- or double-quoted), integers, `|` and `|-` blocks, and
one `edits:` list of mappings. Write `find` and `replace` as `|-` blocks, so backslashes and quotes need no escaping.

Single edit:

```yaml
---
id: 01-m1
status: active                  # active (expected red) | control (expected to survive) | stale
project: <Short>                # a TestProjects name
filter: '/*/*/<TestClass>/*'    # the test filter for the project's Kind
file: src/<Project>/<File>.cs
expectedMatches: 1
occurrence: 1                   # optional; 1-based; mutate only that match
find: |-
  if (value is null)
replace: |-
  if (false)
---
# 01-m1: <what the mutation breaks>
```

Several edits:

```yaml
---
id: 01-m2
status: active
project: <Short>
filter: '/*/*/(<ClassA>|<ClassB>)/*'
edits:
  - file: src/<Project>/<File>.cs
    expectedMatches: 1
    find: |-
      <original line>
    replace: |-
      <mutated line>
  - file: src/<Project>/<Other>.cs
    expectedMatches: 1
    find: |-
      <original line>
    replace: |-
      <original line>
      <added line>
---
```

A `stale` record needs `staleReason: <why the mutated logic no longer exists>`, and the run skips it. Verdicts are
`red`, `survived`, `build-failed`, `apply-failed`, `hang-killed`, `no-tests` and `error`. `-AppendVerdicts` appends
`- Verified <yyyy-MM-dd> at <short sha>: <verdict>, <failed> failed of <total> (<project>, filter <filter>); restored.`
to each record.

## Full-check record

`Invoke-FullCheck` writes `<tree>\<LogDir>\<tag>-record.json` and copies it to `last-full-check.json`:

```json
{
  "result": "pass",
  "head": "<40-hex sha>",
  "tree": "<absolute tree path>",
  "dirtyPaths": [],
  "summaryPath": "<tree>\\.ipe-logs\\<tag>-summary.txt",
  "finished": "<ISO 8601 UTC>"
}
```

Merge-Ticket accepts the record only when `result` is `pass`, `head` equals the source HEAD and `dirtyPaths` is empty.
An implementer's handoff points to this record instead of restating the results.

## Self-tests

```
pwsh -NoProfile -File <skill dir>\scripts\tests\Run-SelfTests.ps1 [-Name <wildcard>]
```

The runner prints `PASS`/`FAIL` for each test and a total, and exits 1 on any failure. Tests that change git state run
only in throwaway repos under `%TEMP%`. Fixtures are synthetic. The log fixtures are `fixtures\*.txt`, because repos
often gitignore `*.log`.

Run one self-test run at a time. Two copies of the toolkit (for example the skills repo's and a repo's `.kiro\skills`
copy) share the test drive letter `Z:` and the `dotnet run` file cache, so concurrent runs collide.
