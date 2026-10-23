<!-- Sources: system-prompts/skill-code-review-phase-3-sweep-for-gaps.md:8-16; the miss list is system-prompts/skill-code-review-inline-xhigh-mode.md:65-68 (verbatim). Sweep candidates go to output without a second verify, as in part-3:38-39. -->
## Phase 3 — Sweep for gaps (max only)

Run **one more finder** as a fresh reviewer who has the current list: one
subagent, in its own dispatch after verification, given the diff (or the
exact diff command), the finder rules, and the kept candidates with their
`file`, `line`, and `summary`. Give it this prompt:

> Re-read the diff and enclosing functions looking ONLY for defects not already
> listed. Do not re-derive or re-confirm anything already there — the job is
> gaps. Focus on what the first pass tends to miss: moved/extracted code that dropped a guard
> or anchor; second-tier footguns (dataclass default evaluated once, `hash()`
> non-determinism, lock-scope shrink, predicate methods with side effects);
> setup/teardown asymmetry in tests; config defaults flipped.
>
> Surface **up to 8 additional candidates**, each naming a defect not already on
> the list. If nothing new, return an empty sweep — do not pad.

Sweep candidates are not sent back through verification. Add them to the list
with the verdict `unverified (sweep)`, then go to Output.
