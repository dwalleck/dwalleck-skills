---
name: code-review
description: "Review the current diff, a GitHub PR number, a branch, or a path for correctness bugs, plus reuse, simplification, efficiency, altitude, and conventions cleanups, at an effort level: minimal | low | medium | high | max (default medium). Use for code review, reviewing a PR or pull request, reviewing a branch or changes before commit, or finding bugs in a diff. At medium and above, runs parallel finders and an independent verifier as a background Kiro workflow (falling back to sub-agents, then to a single in-context pass). Flags: --comment posts findings as inline GitHub PR comments; --max-findings n|all sets the findings cap; --verify precision|recall|max overrides the verify policy."
---

Review the current diff, or a PR number/branch/path target, for correctness
bugs plus reuse/simplification/efficiency cleanups at the given effort level:
from few high-confidence findings at `minimal` up to many, some of them
uncertain, at `max`.

Arguments: `$ARGUMENTS`

## Arguments

Parse the text after `/code-review` (above, or the user's request if it was not
substituted). Tokens can come in any order.

- **Level**: `minimal`, `low`, `medium`, `high`, or `max`, case-insensitive.
  `xhigh` means `max`. No level → `medium`. Treat a token as a misspelled level
  only when it is a single word that is not a flag, PR, branch, or path and is
  clearly meant as a level (e.g. `hihg`, `maximum`, `med`, in any position):
  use the closest level, or `medium` if none is close, and say so in the
  output's notes. Any other word is free text (see below), not a level.
- **Target**: a PR number (`123`, `#123`) or GitHub PR URL; a branch name; or a
  file or directory path. No target → the current diff.
- **`--comment`**: after the output, post the findings as inline GitHub PR
  comments.
- **`--max-findings n|all`**: the output cap — a positive integer, or `all` for
  no cap. Default: the level's cap in the matrix. An invalid value → the level's
  default, with a note.
- **`--verify precision|recall|max`**: override the level's verify policy. It
  applies at medium, high, and max. At minimal and low there is no verify step,
  so ignore it with a note. An invalid value → the level's default, with a note.
- **Anything else**: an unknown `--flag` is ignored with a note. Remaining
  free text (a scope restriction, files to focus on, things to skip) is extra
  instructions: pass it to every finder and honor it.

## Level matrix

| Level | Pipeline | Angles | Candidates per angle | Verify policy (default) | Sweep | Default cap |
|---|---|---|---|---|---|---|
| minimal | single careful diff pass, no subagents | one pass: `references/minimal-pass.md` | — | none | no | 15 |
| low | 1 diff pass, no subagents, no verify | one pass: `references/low-pass.md` | — | none | no | 4 |
| medium | 3+5 angles → 1-vote verify | A, B, C + reuse, simplification, efficiency, altitude, conventions (8) | up to 6 | precision | no | 8 |
| high | 3+5 angles → 1-vote verify (recall-biased) | same 8 | up to 6 | recall | no | 10 |
| max | 5+5 angles → 1-vote verify → sweep | A, B, C, D, E + the same 5 (10) | up to 8 | max | yes, up to 8 more | 15 |

Level intro line (give it to every finder):

- **medium**: You are reviewing for **precision** at medium effort: every
  finding you surface should be one a maintainer would act on.
- **high**: You are reviewing for **recall** at high effort: catch every real
  bug a careful reviewer would catch in one sitting. At this level, catching
  real bugs matters more than avoiding false positives. Err on the side of
  surfacing.
- **max**: You are reviewing for **recall** at maximum effort: catch every real
  bug. At this level, catching real bugs matters more than avoiding false
  positives — a missed bug ships. Err on the side of surfacing.

Angle files:

| Angle | File |
|---|---|
| A — line-by-line diff scan | `references/angles/a-line-scan.md` |
| B — removed-behavior auditor | `references/angles/b-removed-behavior.md` |
| C — cross-file tracer | `references/angles/c-cross-file.md` |
| D — language-pitfall specialist | `references/angles/d-language-pitfall.md` |
| E — wrapper/proxy correctness | `references/angles/e-wrapper-proxy.md` |
| Reuse | `references/angles/reuse.md` |
| Simplification | `references/angles/simplification.md` |
| Efficiency | `references/angles/efficiency.md` |
| Altitude | `references/angles/altitude.md` |
| Conventions | `references/angles/conventions.md` |

## Run order

The main agent parses the arguments, gathers the diff once, and prints the
output. At medium and above, finding, verifying, and sweeping run in a
background Kiro workflow by default; in sub-agents, or in this context, only
when no workflow can run.

1. **Phase 0 — Gather the diff** (below). At low, the pass file's one-call
   read replaces it (for a PR target, that read is the Phase 0 PR command).
2. **minimal / low**: read the level's pass file from the matrix, run it
   yourself, and go to Output (`route: inline`, `verification: none at this
   level`).
3. **Choose the route** (medium, high, max). Take the first that applies:
   1. **Workflow route** — the `run_workflow` tool is available (listed among
      your tools, or loadable through tool search). This is the default. Follow
      "Workflow route" below.
   2. **Sub-agent route** — only if `run_workflow` is not available but
      `invoke_sub_agent` is. Follow "Sub-agent route" below.
   3. **In-context** — neither tool is available. Read
      `references/fallback-inline.md` and follow it.

   `subagent` is only the tools-config and permissions name of the sub-agent
   capability; the tool you call is `invoke_sub_agent`. In Kiro CLI with
   Workflows enabled, the main chat often has only `run_workflow`; that is
   expected, not an error.
4. **Output**: read `references/output.md` and follow it. On the workflow
   route, the workflow's report step writes the output for you (W5).
5. **`--comment`**: after the output is printed, read
   `references/github-comment.md` and follow it.

## Workflow route

Details, commands, and file formats: `references/workflow-route.md`. Read it
before W1.

- **W1 — Run folder.** Create
  `~/.local/state/kiro-code-review/runs/<repo>-<target>-<stamp>/` (absolute
  path; outside the reviewed repository). Write `diff.patch` (and
  `diff.full.patch` when a scope filter ran), `pr.json` for a PR,
  `instructions.md` (the extra free text, or `None.`), and `params.json`.
- **W2 — Install.** Compare `<skill_dir>/assets/workflows/*.workflow.json`
  with `~/.kiro/workflows/` and `<skill_dir>/assets/agents/*.json` with
  `~/.kiro/agents/`; copy what is missing or different. If anything was
  copied, tell the user once which files were installed or updated.
- **W3 — Launch** `run_workflow` with `workflowPath` set to the absolute path
  of `~/.kiro/workflows/code-review-8.workflow.json` (medium, high) or
  `~/.kiro/workflows/code-review-10.workflow.json` (max), passing the ten
  string inputs: `skill_dir`, `run_dir`, `repo_dir`, `diff_path`,
  `instructions_path`, `level`, `level_intro`, `verify_policy` (after
  `--verify`), `candidate_cap`, `findings_cap` (after `--max-findings`).
- **W4 — Hand off.** `run_workflow` returns at once. Reply in one short
  message that the review is running in the background, with the workflow id
  and the run folder, then **end your turn**. Do not poll.
- **W5 — Completion.** When the report step's `code review findings ready:
  <run_dir>/findings.md` message or a run-completed notification arrives, read
  `<run_dir>/findings.md` and print it verbatim. Then, if `--comment` was
  given, follow `references/github-comment.md` using `<run_dir>/findings.json`.
- **W6 — Failure.** If the run failed or paused, or the launch failed, report
  which steps failed and what the run folder holds, and offer to retry in the
  workflow or to finish in context with `references/fallback-inline.md` (its
  partial-fallback paragraph).

## Sub-agent route

Kiro fixes a sub-agent task graph before it starts, and the number of
verifiers depends on dedup, so use separate dispatches. If dispatch 1 cannot
start, follow `references/fallback-inline.md` instead. If dispatch 2 or 3
fails after dispatch 1 succeeded, keep the finder candidates you already have
and finish only the remaining phases in context, as that file describes.

1. **Dispatch 1 — finders.** Read `references/finder-rules.md` and the
   level's angle files. Start one general-purpose sub-agent per angle with
   `invoke_sub_agent`, all in one parallel dispatch with no dependencies
   between them. Each prompt holds: the level intro line; the diff text (if it
   is too large to paste, the path of a file holding it, or the exact diff
   command and target — every finder must review the same diff, so never let
   a finder pick its own target); the user's extra instructions; the text of
   `references/finder-rules.md`; the text of exactly one angle file; and the
   candidate cap.
2. **Dedup** the pooled candidates by `references/dedup.md`.
3. **Dispatch 2 — verifiers.** Read `references/verify.md` and run one
   verifier sub-agent per deduplicated candidate, under the policy in effect.
   If no candidates remain, skip this step.
4. **Dispatch 3 — sweep (max only).** Read `references/gap-sweep.md` and run
   one fresh sweep sub-agent with the current list.

The run line says `route: sub-agents` and `verification: independent — one
verifier sub-agent per candidate`.

## Phase 0 — Gather the diff

Run `git diff @{upstream}...HEAD` (or `git diff main...HEAD` / `git diff HEAD~1`
if there's no upstream) to get the unified diff under review. If there are
uncommitted changes, or the range diff is empty, also run `git diff HEAD` and
include the working-tree changes in scope — the review often runs before the
commit. If a PR number, branch name, or file path was passed as an argument,
review that target instead. Treat this diff as the review scope.

- **PR**: always run `gh pr view <pr> --json title,body,baseRefName,headRefName,headRefOid,url`
  for context and `gh pr diff <pr> --color never --allow-escape-sequences > <file>`
  for the unified diff, then read the file (`gh pr diff` refuses to write
  escape sequences to a pipe without that flag, and the raw diff must not go
  to the terminal). For a PR URL, add `--repo <owner>/<repo>` to both. On the
  workflow route the file is `<run_dir>/diff.patch`; otherwise put it in a run
  folder named as in `references/workflow-route.md` (W1). The PR's diff is the
  only review scope — local working-tree changes are out of scope. Never
  substitute a local `git diff` for it (not against `main` or `origin/main`,
  and not even when a local branch looks the same). When you need surrounding
  code, read the files in this checkout, or in a worktree of it, if its
  `HEAD` is the PR's `headRefOid`; otherwise fetch file contents with `gh` or
  `git show <headRefOid>:<path>`. If `gh` is missing or not authenticated,
  say so and ask for a branch or path target.
- **Branch**: `git diff main...<branch>` (use the repo's default branch if it
  is not `main`).
- **Path**: the default commands above, limited with `-- <path>`.
- **Scope restriction**: when the extra instructions limit the review to files
  by glob or type (for example "only Rust files" → `*.rs`), filter the diff
  with `scripts/filter-diff.py` as `references/workflow-route.md` (W1)
  describes, and say in the notes how many changed files were kept.

If the diff is empty, say there is nothing to review and stop.

## Dedup

The rule is in `references/dedup.md`. On the workflow route the verify step
applies it; on the sub-agent and in-context routes you do.

## Output

The format, the cap, and the ranking order (most severe first; CONFIRMED
before PLAUSIBLE; correctness before cleanup unless a cleanup finding is
clearly more severe) are in `references/output.md`. The run line, Target, and
Notes are separate list items, and the run line names the route and whether
verification was independent.

## Future extensions (not implemented)

- GitLab `--comment`: one general MR note via `glab mr note`.
