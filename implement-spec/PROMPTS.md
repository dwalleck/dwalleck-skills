# Subagent prompt templates

Fill the `<…>` slots. Each prompt is pointers plus the few facts the agent cannot look up; standing rules stay in the
run's **rules file** and are never restated. A prompt never adds a rule or overrides one: if a ticket needs different
behaviour, change the rules file first and point to the changed section.

Fill `<stack skills>` from the installed skills for the project's language and test framework: the test-quality
skill (anti-patterns, smells), the test-running skill, and the diagnostics and performance skills. Agents load only
the skills a prompt or rules file names, so an unnamed skill goes unused. Map each to its branch in the rules file
(e.g. "a hang or starvation → <diagnostics skill>").

## Implementer

```
You are the implementer for ticket <NN> ("<title>") in the <spec> implement-spec run. Use the Skill tool with `tdd`
to build it<, and `<review skill>` for review>. Load <stack skills> when the work reaches their branch, as the rules
file maps them; run <test-quality skill> on your tests before reporting ready.

Rules: read <rules file> first and follow it; it is the single source of truth for shared resources, hosts and
reporting.

Worktree <path>, branch <branch>, created from the integration branch at <sha>; confirm the base.
Ticket: <ticket path>. Spec: <spec path>. Builds on: <resolved tickets / handoffs worth reading>.
User decisions that bind this ticket: <pointers>. If the ticket or a decision reads differently from what the code
shows you, stop and report it as a user decision needed.

Done means: the ticket's checkboxes are met with evidence, the integration tip is merged into your branch,
`Invoke-FullCheck` passes on it, and your handoff is current, pointing to the check's record and including its
Friction list. Then report ready to merge, with the Friction list. Root then runs the ticket review; fix its findings
as the rules file's "Reviews" section says, and report ready again under the same Done means.
```

For a split ticket's code track, add: "You are the code track; the host tracks are <agent names and hosts>. Send each
of them every pinned candidate you will run, and report ready only when every track reports pass on the same pin."

## Host track (e.g. Windows)

```
You are the <host> track for ticket <NN> ("<title>") in the <spec> implement-spec run. You run the ticket's <host>
native evidence; the code track (<agent name>) owns all code and candidates. Change no code: report a defect to the
code track with the run that shows it.

Rules: read <rules file> first and follow it; it is the single source of truth for leases, hosts and reporting.

Track dir <path>. Ticket: <ticket path>. Native scenarios: <the acceptance items this host covers>. Driver template:
<path>.

For each pinned candidate the code track sends you: confirm the pin, run the scenarios, and report to the code track
the pin, a pass or fail per scenario, and the evidence paths. Between candidates, release the host and end your turn.
Keep a dated handoff in your track dir, including its Friction list.

Done means: every scenario passes on the code track's final pin. Then report to the code track, with the Friction list.
```

## Merger

```
You are a merger subagent in the <spec> implement-spec run and the only agent writing to the integration branch.
Merge <ticket or track> and <resolve the ticket | record the merge> on the integration branch, following the form of
<earlier resolution commit>.

Rules: read <rules file> first and follow it (mergers use <merger slot or priority>).

Integration: <path>, branch <branch>, HEAD <sha>, clean. Source: <worktree>, branch <branch>, HEAD <sha>
(<contains / lacks> the integration tip). Read: <track handoff, review log, evidence index>, ticket review
<worktree>\CODE-REVIEW.md.

Do:
1. Check the ticket review against the rules file's "Reviews" section; if it leaves any finding blocking, report each
   one and stop. Review <base>..<source> read-only for <the ticket's specific risks>, stray files and unapproved
   bindings; run <test-quality skill> on the diff's tests. Every assertion the diff removes needs a finding or ticket
   behind it (<assertion-diff tool, if the rules file names one> lists them); report each one that has none.
2. Merge with `Merge-Ticket`, as the rules file's "Merges and waiting" section says. It runs or skips the full check
   and the affected mutations, and it commits or aborts. On a conflict (exit 3), resolve each file by hand, stage it,
   and run `Merge-Ticket -Continue`. On a failure, report it.
3. <Resolve the ticket with `Resolve-Ticket` | record the merge>, covering the merge, checks, mutations, evidence and
   decisions. Leave the tree clean.

Report: integration HEAD, check totals with loads, mutation verdicts, blocking findings, and a Friction list (anything
that cost time, failed unexpectedly or broke a rule, one line each).
```

## Ticket review

Root's own launch, not a subagent prompt. Prepare the run folder as code-review `references/workflow-route.md` W1-W2
say, with the diff from `git -C <worktree> diff <base>...<branch>` and this `instructions.md`:

```
Ticket <NN>: <ticket path>. Spec: <spec path>. Rules: <rules file>.
```

Launch per W3 with level `medium` (cross-ticket: `high`, verify_policy `recall`) and findings_cap `all`. Record the
workflow id from the result with `Update-Ledger -Workflow <id> -WorkflowRole review`. On completion, run
`Export-ReviewFindings -RunDir <run dir> -Out <worktree>\CODE-REVIEW.md` and send the implementer that pointer.

## Exploration

```
One note file per question in <dir>, in the form the rules file's "Research notes" section gives. Questions: <list>.
```

## Decision

```
Decision <run>-D<n> (supersedes <id> | new): <the settled answer>. Recorded at <path>.
```
