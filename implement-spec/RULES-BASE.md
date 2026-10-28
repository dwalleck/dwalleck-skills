# Baseline rules

Start every run's rules file from these, then add the run's concrete commands, build slots, hosts and paths. Each
line came from a retro of an earlier run.

## Rules file

- The rules file is the single source of truth. Prompts point to it and add only the ticket's facts; a prompt that
  needs a different behaviour changes the rules file (with a dated log entry) instead of saying it in the prompt.
- Give the rules file a version line, bumped on every edit. Agents re-read it before reporting and name the version
  they followed.
- Every rule names the command, script or check that carries it out. A rule nobody can run is a wish.

## Toolkit

- Build, test, check, commit and merge only through `scripts/ipe.ps1` (see [scripts/README.md](scripts/README.md)).
  The repo's `.kiro/implement-spec.psd1` configures it. When it lacks a job, add the job to the toolkit instead of
  writing a one-off script.
- Commit only with `Commit-Change`.
- Search worktrees and paths outside the workspace with `Search-Worktree`.

## Checks

- A failure in a test the diff does not touch: rerun that test alone, record both results and the load, and add it to
  the run's known-intermittent list (`Invoke-Focused`, or `Repeat-Tests` to rerun it several times). Rerun the full
  check only when the focused rerun fails too.
- One full check per verified state; a second only after a failure.
- While an independent review of your code is pending, run focused tests only; the full check follows that review's
  repairs.
- Run no full check while your own end-to-end run or a load test is running.
- Run a batch of focused runs (several test classes, isolated reruns, a red→green pair, a mutation sweep) inside one
  hold of the build lock.
- Count warnings from a non-incremental build and compare the set against a stored baseline file, not a number in
  prose. `Invoke-FullCheck` does this through `Compare-Warnings`.
- A test project that skipped tests it needs (database, containers, a service) has not passed. The full check
  (`Invoke-FullCheck`) reports skips per project and fails on any skip the run did not plan for.
- Give every test command its own timeout, shorter than the tool call's timeout, so a hang fails the run instead of
  killing the script mid-step. Every toolkit command does this, with the limits from the config's `Timeouts`.

## End-to-end evidence

- Run the final end-to-end (native) evidence once, after the last review verdict and the integration-tip merge. Before
  that, at most one smoke run of a new scenario on one host.
- Build a candidate only for the commit you will run.
- Measure timings only for a target the ticket or design names.
- Start a new driver or scenario from the run's shared driver template, not from another ticket's copy.
- A ticket split into tracks runs on one candidate at a time: the code track builds it, pins it by source tree, and
  hands the pin to every host track. A code change makes a new candidate, and every track reruns on it.

## Mutations

- Name a mutation only for a claim whose tests could not run red first; a red-first run is the sensitivity proof.
- A mutation's RED stays valid while its mutated line and the assertions that turned it red are unchanged. Cite it
  with an applicability line; never rerun the set as a final pass.
- Check a ticket's mutations into the repo's mutation spec directory in the ticket's last code commit, in a form the
  run's mutation runner reads (file, original text, mutated text, expected match count, test filter), so mergers
  rerun them instead of rewriting them. The runner is `Invoke-Mutations`, and the record format is its front matter
  (scripts/README.md).
- A mutation run restores every file byte for byte in a `finally`, runs each test under its own timeout, and ends by
  checking the tree is clean. A run killed from outside skips its `finally`: after any timeout or kill, restore and
  check the tree before doing anything else (`Invoke-Mutations -RestoreOnly`, then `Stop-TestHosts`).

## Reviews

- Give your reviewer this file. A reviewer works in its own clone or worktree, runs mutations and repros with the
  focused filter of the affected tests, and reports to the implementer that started it.
- While a reviewer runs, keep working or end your turn, and let its notification wake you. If the notification
  arrives without the report, read the reviewer's output file.
- A review in the implementer's own context is a self-check, not a review. A ticket's independent review comes from
  root (`code-review-8`, medium, cap `all`), which can start workflows when its subagents cannot. Every CONFIRMED
  finding it lists is fixed before merge, or left only by a recorded user decision. Mergers block on any other.

## Handoff and messages

- Keep your handoff as the implement-spec skill's SKILL.md step 4 says; root checks it at each gate.
- A message can arrive twice: act on a numbered decision once.

## Research notes

- One file per question; each claim is marked `verified (<how>)` or `unverified`. Treat an unverified claim as a
  question: run a spike or ask root before building on it.

## Merges and waiting

- Merge with `Merge-Ticket`, which carries out the next three rules. A conflict stops it with the merge in progress:
  resolve, stage, then run `Merge-Ticket -Continue`.
- Merge with `git merge --no-ff --no-commit` and resolve each conflict by hand; commit only after the check passes,
  and `git merge --abort` on failure, so a failed check never leaves a commit on the integration branch. `-X theirs`
  and `-X ours` silently drop your own edits.
- When the merged tree equals the source branch's HEAD tree and the source's handoff records a passing full check on
  that HEAD, record "verified by the implementer at <sha>" and skip the full check. Otherwise run it once.
- A merger reruns only the checked-in mutations whose files the merge changed relative to the source HEAD; on a
  tree-equal merge that is none. Each must still go red, except a record declared `control`, which must survive.
- Run long jobs (checks, builds, end-to-end runs) in the foreground from a script, with per-command timeouts. Use
  background jobs or a Monitor only where the run's rules file says the harness supports them.
