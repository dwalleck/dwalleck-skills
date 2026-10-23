---
name: code-review
description: "Review the current diff, a GitHub PR number, a branch, or a path for correctness bugs, plus reuse, simplification, efficiency, altitude, and conventions cleanups, at an effort level: minimal | low | medium | high | max (default medium). Use for code review, reviewing a PR or pull request, reviewing a branch or changes before commit, or finding bugs in a diff. Fans out finder and verifier subagents at medium and above. Flags: --comment posts findings as inline GitHub PR comments; --max-findings n|all sets the findings cap; --verify precision|recall|max overrides the verify policy."
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

The main agent gathers the diff, dedups, and writes the output. Subagents only
find, verify, and sweep. Kiro fixes a subagent task graph before it starts,
and the number of verifiers depends on dedup, so use separate dispatches.

1. **Phase 0 — Gather the diff** (below). At low, the pass file's one-call
   read replaces it.
2. **minimal / low**: read the level's pass file from the matrix, run it
   yourself, and go to Output.
3. **Subagents available?** If the `subagent` tool is not available in this
   session, or dispatch 1 cannot start, read `references/fallback-inline.md`
   and follow it instead of steps 4-7. If dispatch 2 or 3 fails after
   dispatch 1 succeeded, keep the finder candidates you already have and
   finish only the remaining phases in context, as that file describes.
4. **Dispatch 1 — finders.** Read `references/finder-rules.md` and the
   level's angle files. Start one general-purpose subagent per angle, all in
   one parallel dispatch with no dependencies between them. Each prompt holds:
   the level intro line; the diff text (if it is too large to paste, the exact
   diff command and target — every finder must review the same diff, so never
   let a finder pick its own target); the user's extra instructions; the text
   of `references/finder-rules.md`; the text of exactly one angle file; and the
   candidate cap.
5. **Dedup** the pooled candidates (below).
6. **Dispatch 2 — verifiers.** Read `references/verify.md` and run one
   verifier subagent per deduplicated candidate, under the policy in effect.
   If no candidates remain, skip this step.
7. **Dispatch 3 — sweep (max only).** Read `references/gap-sweep.md` and run
   one fresh sweep subagent with the current list.
8. **Output** (below).
9. **`--comment`**: read `references/github-comment.md` and follow it.

## Phase 0 — Gather the diff

Run `git diff @{upstream}...HEAD` (or `git diff main...HEAD` / `git diff HEAD~1`
if there's no upstream) to get the unified diff under review. If there are
uncommitted changes, or the range diff is empty, also run `git diff HEAD` and
include the working-tree changes in scope — the review often runs before the
commit. If a PR number, branch name, or file path was passed as an argument,
review that target instead. Treat this diff as the review scope.

- **PR**: run `gh pr view <pr> --json title,body,baseRefName,headRefName,url`
  for context and `gh pr diff <pr>` for the unified diff. The PR's diff is the
  only review scope — local working-tree changes are out of scope. When you
  need surrounding code, read the files in this checkout if it matches the PR's
  branch; otherwise fetch file contents with `gh`. If `gh` is missing or not
  authenticated, say so and ask for a branch or path target.
- **Branch**: `git diff main...<branch>` (use the repo's default branch if it
  is not `main`).
- **Path**: the default commands above, limited with `-- <path>`.

If the diff is empty, say there is nothing to review and stop.

## Dedup

Pool all candidates. Dedup near-duplicates only: same defect, same location,
same reason → keep one, the one with the most concrete failure scenario. Do
NOT let one angle's conclusions suppress another's — if two angles flag the
same line for different reasons, record both.

## Output

Write the review as plain markdown in your reply. The markdown is the report:
no tool call, no file.

Rank findings most-severe first. If more than the cap survive, keep the cap's
number of most severe; with `all`, keep every finding that survives — there is
no maximum. Correctness bugs always outrank cleanup and altitude findings when
the cap forces a cut.

```markdown
## Code review — <level> effort

Run: <pipeline from the matrix> · verify policy: <precision | recall | max | none> · cap: <n | all> · fallback: <no | yes — single pass without subagents; no independent verification ran | partial — <phases> ran in context; not independent>
Target: <current diff | PR #n | branch | path>
Notes: <unknown level, ignored flags, invalid values — omit the line if none>

### 1. `path/to/file.ext:123` — <short summary>

- **Category:** correctness
- **Verdict:** CONFIRMED
- **Summary:** <one-sentence statement of the issue>
- **Failure scenario:** <concrete inputs/state → wrong output or crash; for a cleanup, the concrete cost>
```

- Every finding cites `file:line`.
- The short summary is the claim compressed to ≤60 characters, no rationale or
  consequence clause.
- Category is the slug from the finder: `correctness`, `simplification`,
  `efficiency`, `reuse`, `altitude`, `conventions`, or a more specific slug like
  `test-coverage`.
- Include **Verdict** only when a verify pass produced one: the verifier's vote,
  `<vote> (self-check)` in the fallback, or `unverified (sweep)` for sweep
  additions.
- If nothing survives, write the header lines and then exactly: No findings
  survived verification.

## Future extensions (not implemented)

- GitLab `--comment`: one general MR note via `glab mr note`.
- A workflow-backed `max` run (find → verify → sweep → report as separate
  steps with durable intermediate files) for very large diffs.
