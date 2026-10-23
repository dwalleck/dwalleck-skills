<!-- Sources: system-prompts/agent-prompt-code-review-unavailable-agent-inline-mode.md:22-36 (phases); agent-prompt-code-review-inline-gap-sweep-phase.md:9-13 (same-context sweep); disclosure modelled on agent-prompt-simplify-unavailable-agent-inline-mode.md:19-21 and 43-45. -->
## Fallback — no subagents

Use this at medium, high, and max when the `subagent` tool is not available in
this session, or when a dispatch cannot start. The usual fan-out can't run, so
work through the level's angles yourself, in this same context — do not skip an
angle for lack of fan-out.

**Partial fallback.** If dispatch 1 (finders) succeeded but dispatch 2
(verifiers) or dispatch 3 (sweep) could not start or failed, do not rerun the
angles. Keep the deduplicated finder candidates and start at the first phase
that did not complete: Phase 2 if verification failed (self-check every
candidate that has no subagent vote; keep votes that did come back), Phase 3 if
only the sweep failed. The disclosure still applies, limited to the phases you
ran in context (for example, "verification was self-checked, not
independent").

### Phase 1 — Find candidates (single pass)

Work through the level's angles (8 at medium and high, 10 at max) yourself, in
sequence, in this same context — do not spawn subagents. For each angle, read
its file from the matrix in SKILL.md and apply it under the rules in
`references/finder-rules.md`, up to the level's candidate cap.

### Phase 2 — Dedup and self-check (no subagent verify)

Dedup by the rule in SKILL.md. Re-check each remaining candidate yourself
against the diff before keeping it: vote it CONFIRMED, PLAUSIBLE, or REFUTED by
the definitions in `references/verify.md`, and keep or drop it by the verify policy in
effect (precision, recall, or max). Record the vote as the verdict, marked
`(self-check)`.

### Phase 3 — Sweep for gaps (max only)

Take one more pass yourself (same context, no subagent) as a fresh reviewer
who has the deduplicated list. Follow `references/gap-sweep.md`, but run its prompt
yourself instead of handing it to a subagent.

### Disclosure

In the output's run line, state clearly that this was a single-pass review
done without subagents: the angles ran in sequence in one context and each
candidate was self-checked, so no independent verification ran. Whoever reads
the review should not be misled about what actually ran.
