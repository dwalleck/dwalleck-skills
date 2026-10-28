<!-- Sources: system-prompts/agent-prompt-code-review-unavailable-agent-inline-mode.md:22-36 (phases); agent-prompt-code-review-inline-gap-sweep-phase.md:9-13 (same-context sweep); disclosure modelled on agent-prompt-simplify-unavailable-agent-inline-mode.md:19-21 and 43-45. -->
## Fallback — in context, no workflow or sub-agents

Use this at medium, high, and max when neither the `run_workflow` tool nor the
`invoke_sub_agent` tool is available in this session; when a workflow run or a
sub-agent dispatch cannot start; or when the user chose to finish in context
after a workflow run failed or paused. The usual fan-out can't run, so work
through the level's angles yourself, in this same context — do not skip an
angle for lack of fan-out.

**Partial fallback.** If the finders finished (dispatch 1 succeeded, or the
workflow's `candidates/*.json` files exist in its run folder) but verification
or the sweep could not start or failed, do not rerun those angles. Run only the
angles whose finder file is missing or unparsable (Phase 1, limited to them),
keep the deduplicated finder candidates, and start at the first phase that did
not complete: Phase 2 if verification failed (self-check every candidate that
has no sub-agent vote; keep votes that did come back), Phase 3 if only the
sweep failed. The disclosure still applies, limited to the phases you ran in
context (for example, "verification was self-checked, not independent").

Read `references/inline-bundle.md` once, in full (it holds finder-rules,
dedup, verify, gap-sweep, output and every angle). On this route it replaces
the separate reference files: each `references/<file>` below names a section
of it.

### Phase 1 — Find candidates (single pass)

Work through the level's angles (8 at medium and high, 10 at max) yourself, in
sequence, in this same context — do not spawn sub-agents. For each angle in
the SKILL.md matrix, take its `references/angles/<key>.md` section and apply
it under the `references/finder-rules.md` section, up to the level's
candidate cap.

### Phase 2 — Dedup and self-check (no sub-agent verify)

Dedup by the rule in the `references/dedup.md` section. Re-check each remaining candidate yourself
against the diff before keeping it: vote it CONFIRMED, PLAUSIBLE, or REFUTED by
the definitions in the `references/verify.md` section, and keep or drop it by the verify policy in
effect (precision, recall, or max). Record the vote as the verdict, marked
`(self-check)`.

### Phase 3 — Sweep for gaps (max only)

Take one more pass yourself (same context, no sub-agent) as a fresh reviewer
who has the deduplicated list. Follow the `references/gap-sweep.md` section, but run its prompt
yourself instead of handing it to a sub-agent.

### Disclosure

State in the output's run line what actually ran (see the `references/output.md` section).
For a full fallback: `route: in-context` and `verification: self-checked in
context — not independent` — the angles ran in sequence in one context and
each candidate was self-checked, so no independent verification ran. For a
partial fallback: `route: workflow (<recipe>), then in-context for <phases>` or
`route: sub-agents, then in-context for <phases>`, and `verification: partial —
<phases> self-checked in context; not independent` (or the workflow's or
sub-agents' verification value when only the sweep ran in context). Whoever
reads the review should not be misled about what actually ran.
