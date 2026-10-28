## Workflow route (medium, high, max)

The default route at medium, high, and max when the `run_workflow` tool is
available. The main agent gathers the diff once, writes it and the run
parameters into a run folder, installs the skill's recipes and step agents,
launches a saved recipe in the background, and prints the findings when the
run finishes. Each finder, the verifier, the sweep, and the report run in their
own fresh sessions, so verification is independent of the finders.

| Level | Recipe | Shape |
|---|---|---|
| medium, high | `code-review-8` | 8 parallel finders (A, B, C + reuse, simplification, efficiency, altitude, conventions) → verify → report |
| max | `code-review-10` | 10 parallel finders (A–E + the same 5) → verify → sweep → report |

Every path below is absolute: step agents do not run in the reviewed repository.

### W1 — Run folder

Location: `~/.local/state/kiro-code-review/runs/<repo>-<target>-<stamp>/`,
spelled out with the absolute home directory (for example
`/home/<user>/.local/state/kiro-code-review/runs/cyril-pr193-20260101T120000Z`).

- `<repo>`: the basename of the checkout the skill was invoked in.
- `<target>`: `pr<n>`; `branch-<name with / replaced by ->`; `path-<slug>`; or
  `diff` for the current diff.
- `<stamp>`: `date -u +%Y%m%dT%H%M%SZ`.

It is outside the reviewed repository on purpose: a review must not add
untracked files to the tree it reviews. It is durable (unlike `/tmp`), so
`findings.md` can be re-read later, and it matches the fixed write permission
of the step agents (`~/.local/state/kiro-code-review/runs/**`), so do not move
it (and do not honor `XDG_STATE_HOME`).

Create it with `mkdir -p "<run_dir>/candidates"`. The folder holds:

| File | Written by |
|---|---|
| `diff.patch` | main agent: the diff under review |
| `diff.full.patch` | main agent, only when a scope filter ran: the unfiltered diff |
| `pr.json` | main agent, PR targets: the `gh pr view` JSON |
| `instructions.md` | main agent: the user's extra free text verbatim, or `None.` |
| `params.json` | main agent: the run parameters (below) |
| `candidates/<angle-key>.json` | one finder each (`a-line-scan`, `b-removed-behavior`, …, `conventions`) |
| `verified.json` | verify step: pooled, deduplicated, judged candidates, plus the verify `mode` |
| `sweep.json` | sweep step (max only) |
| `findings.md`, `findings.json` | report step: the review in the Output format, and the same findings as JSON |

**Diff.** Phase 0 already wrote the diff. Save it as `<run_dir>/diff.patch`
(for a PR: `gh pr diff <pr> [--repo <owner>/<repo>] --color never --allow-escape-sequences > <run_dir>/diff.patch`;
for local targets redirect the same `git diff` commands Phase 0 ran). Never
print the raw diff to the terminal.

**Scope filter.** When the extra instructions limit the review to files by
glob or type ("only Rust files" → `*.rs`), write the unfiltered diff to
`diff.full.patch` instead, then run:

```sh
python3 <skill_dir>/scripts/filter-diff.py <run_dir>/diff.full.patch <run_dir>/diff.patch '<glob>' ['<glob>' ...]
```

It prints `kept K of N files`. Add the note "As you asked, only the <…> files
were reviewed: K of N changed files." If K is 0, say there is nothing to
review and stop. If `python3` is missing, keep the full diff as `diff.patch`,
rely on the free-text instruction alone, and say so in the notes. The free text
still goes into `instructions.md`.

**Checkout (`repo_dir`).** The checkout the skill was invoked in, by absolute
path (`git rev-parse --show-toplevel`). For a PR, if that checkout's `HEAD` is
not the PR's `headRefOid`, look for a worktree that is:
`git worktree list --porcelain` lists each worktree's `HEAD`. Use such a
worktree as `repo_dir` if one exists. Set `repo_matches_head` to whether
`repo_dir`'s `HEAD` equals `headRefOid`. Never check out, switch, or create
anything to make it match.

**`params.json`** (one JSON object; step agents read it for display data):

```json
{
  "recipe": "code-review-8",
  "level": "high",
  "pipeline": "3+5 angles → 1-vote verify (recall-biased)",
  "verify_policy": "recall",
  "candidate_cap": 6,
  "findings_cap": "10",
  "target_kind": "pr",
  "target_label": "PR #193 (fix/cyril-tqr8 @ 2d1c9384)",
  "pr": {"number": 193, "repo": "owner/repo", "url": "https://github.com/owner/repo/pull/193", "base": "main", "head": "fix/cyril-tqr8", "head_sha": "<full sha>"},
  "repo_dir": "/abs/path/to/checkout",
  "repo_matches_head": true,
  "diff": {"path": "<run_dir>/diff.patch", "full_path": "<run_dir>/diff.full.patch", "files_total": 215, "files_kept": 18, "include": ["*.rs"]},
  "notes": ["As you asked, only the Rust files were reviewed: 18 of 215 changed files."],
  "comment_requested": false,
  "created_utc": "20260101T120000Z"
}
```

- `pipeline` is the level's Pipeline cell from the matrix; `findings_cap` is a
  positive integer as a string, or `all`.
- `pr` is `null` for non-PR targets; `target_label` is then `current diff`, the
  branch name, or the path.
- `notes` holds every note Phase 0 and argument parsing produced (unknown
  level, ignored flags, invalid values, scope restriction, the diff base).
  Use `[]` when there are none.
- `diff.full_path` is `null` and `diff.include` is `[]` when no filter ran.

### W2 — Install the recipes and step agents

**`skill_dir`.** The directory that holds this skill's `SKILL.md`. If you do
not know it, try `<workspace>/.kiro/skills/code-review` and then
`~/.kiro/skills/code-review` (resolve each with `realpath`). Accept a directory
only if it contains both `references/angles/a-line-scan.md` and
`assets/workflows/code-review-8.workflow.json` — another skill named
code-review may be installed.

Shipped copies live in `<skill_dir>/assets/`; Kiro reads recipes only from
`~/.kiro/workflows/` (or a workspace's `.kiro/workflows/`) and agents from
`~/.kiro/agents/`. The recipe JSON is generated by
`<skill_dir>/scripts/build-recipes.py` (edit the script, rerun it, and check
with `--check`; never hand-edit the JSON). On every workflow-route run,
compare and copy (works in bash and fish):

```sh
mkdir -p ~/.kiro/workflows ~/.kiro/agents
cmp -s "<skill_dir>/assets/workflows/code-review-8.workflow.json" ~/.kiro/workflows/code-review-8.workflow.json || cp -v "<skill_dir>/assets/workflows/code-review-8.workflow.json" ~/.kiro/workflows/code-review-8.workflow.json
cmp -s "<skill_dir>/assets/workflows/code-review-10.workflow.json" ~/.kiro/workflows/code-review-10.workflow.json || cp -v "<skill_dir>/assets/workflows/code-review-10.workflow.json" ~/.kiro/workflows/code-review-10.workflow.json
cmp -s "<skill_dir>/assets/agents/code-review-worker.json" ~/.kiro/agents/code-review-worker.json || cp -v "<skill_dir>/assets/agents/code-review-worker.json" ~/.kiro/agents/code-review-worker.json
cmp -s "<skill_dir>/assets/agents/code-review-verifier.json" ~/.kiro/agents/code-review-verifier.json || cp -v "<skill_dir>/assets/agents/code-review-verifier.json" ~/.kiro/agents/code-review-verifier.json
```

- `cmp -s` fails when the target is missing or differs, so `cp -v` runs and
  prints what it copied. Install all four even though one recipe runs, so the
  pair stays in sync. Kiro always asks before writes under `~/.kiro/agents/`
  and `~/.kiro/workflows/`; that approval is expected.
- If anything was copied, tell the user once, before the handoff: "Installed
  or updated Kiro config managed by this skill: <files>. Edit the copies under
  `<skill_dir>/assets/`, not these." Say nothing when nothing changed.
- If a recipe was just copied and a `validate_workflow` tool is available, run
  it once on the installed file. On errors, do not launch: report them and
  offer the in-context fallback (`references/fallback-inline.md`).
- Never edit other files in `~/.kiro/agents/` or `~/.kiro/workflows/`.

The step agents are `code-review-worker` (finders, sweep, report, and the
per-candidate verifier sub-agents) and `code-review-verifier` (the verify
step; it may start `code-review-worker` sub-agents). Both read anywhere, write
only under the run folder glob, run only read-only `git -C` commands and
`gh pr view` without asking, and have no edit, web, MCP, or Powers tools.

### W3 — Launch

```text
run_workflow(
  workflowPath = "<home>/.kiro/workflows/<recipe>.workflow.json",
  runLabel     = "code-review-<level>-<repo>-<target>",
  inputs       = { …the ten inputs below, all strings… })
```

| Input | Value |
|---|---|
| `skill_dir` | absolute `skill_dir` (no trailing slash) |
| `run_dir` | absolute run folder (no trailing slash) |
| `repo_dir` | absolute checkout from W1 |
| `diff_path` | `<run_dir>/diff.patch` |
| `instructions_path` | `<run_dir>/instructions.md` |
| `level` | `medium`, `high`, or `max` |
| `level_intro` | the level's intro line from the SKILL.md matrix section, verbatim, joined into one line with single spaces (keep the `**` markup) |
| `verify_policy` | `precision`, `recall`, or `max`, after any `--verify` override |
| `candidate_cap` | `6` (medium, high) or `8` (max) |
| `findings_cap` | the cap after any `--max-findings`: a positive integer, or `all` (default: SKILL.md Arguments) |

If `run_workflow` fails because it does not know `code-review-worker` or
`code-review-verifier`, the agents were installed after this session loaded
its agents: tell the user to restart kiro-cli (or open a new session) and run
the review again, and offer the in-context fallback meanwhile. Any other launch
error: go to W6.

### W4 — Hand off and end the turn

`run_workflow` returns as soon as the run starts. Reply with one short message,
then end your turn:

> Review running in the background: workflow `<recipe>`, run `<workflow id>`,
> run folder `<run_dir>`. I'll print the findings here when it finishes (watch
> it with `/workflow`).

Do not poll: no `inspect_workflow` loop, no sleeping, no waiting.

### W5 — Completion

Only the report step signals: it ends with `code review findings ready:
<run_dir>/findings.md`. When that message arrives, or a notification says the
run completed:

1. Read `<run_dir>/findings.md` and print it verbatim as your reply. If the run
   completed but `findings.md` is missing or empty, treat it as a failed run:
   go to W6, which lists what the run did produce and offers to finish the
   missing phases.
2. If `--comment` was given, follow `references/github-comment.md`, taking each
   finding's fields from `<run_dir>/findings.json`.

Any other progress message while the run is still going gets at most one short
line, or none.

### W6 — Failed or paused run

When a notification says the run failed or paused, the launch failed, or the run
completed without a usable `findings.md` (W5):

1. Call `inspect_workflow` once and list which steps failed or paused, and why.
2. List what exists in the run folder: which `candidates/*.json`, and whether
   `verified.json`, `sweep.json`, and `findings.md` exist. If `findings.md`
   exists, print it.
3. Offer two options and wait for the user's choice:
   1. Fix it in the workflow: retry the failed step from the `/workflow`
      monitor, or answer the paused step there (a paused step usually waits on
      a permission prompt).
   2. Finish in this context with `references/fallback-inline.md`, starting at
      the first missing phase (its partial-fallback paragraph): missing
      `candidates/*.json` → run only those angles; no `verified.json` →
      self-check the pooled candidates; max with no `sweep.json` → sweep in
      context. The run line then says `route: workflow (<recipe>), then
      in-context for <phases>` (see `references/output.md`).
