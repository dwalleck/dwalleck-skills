<!-- Sources: dispatch — system-prompts/skill-code-review-phase-2-verify-3-state.md:9-18 and skill-code-review-phase-2-verify-recall-biased.md:9-18; vote definitions — agent-prompt-code-review-part-4-three-state-verification-phase.md:6-11 (verbatim); recall rubric — agent-prompt-code-review-part-5-recall-biased-verification-phase.md:6-15 (verbatim); max override — agent-prompt-code-review-part-3-extra-high-and-maximum-effort-modes.md:35-36 (verbatim). -->
## Phase 2 — Verify (1 vote per candidate)

For each deduplicated candidate, run **one verifier** subagent: give it the
diff (or the exact diff command), the relevant file(s), and the candidate, and
have it return exactly one of **CONFIRMED / PLAUSIBLE / REFUTED**. One
verifier judges one candidate — never hand several candidates to one verifier.
Dispatch all verifiers in parallel in one dispatch; if the session limits how
many subagents run at once, run them in batches, still one candidate each.

### Verifier prompt

Give each verifier the text below, then the policy's rubric addition (if any),
then the candidate.

> You are verifying one candidate finding from a code review. Read the diff and
> the file(s) it points at — open callers, guards, and types as you need. Do not
> edit files. Return exactly one of:
>
> - **CONFIRMED** — can name the inputs/state that trigger it and the wrong
>   output or crash. Quote the line.
> - **PLAUSIBLE** — mechanism is real, trigger is uncertain (timing, env,
>   config). State what would confirm it.
> - **REFUTED** — factually wrong (code doesn't say that) or guarded elsewhere.
>   Quote the line that proves it.
>
> Reply in exactly this form:
>
> ```text
> VOTE: CONFIRMED | PLAUSIBLE | REFUTED
> EVIDENCE: <the quoted line, and what it shows or what would confirm it>
> ```

### Verify policies

The level picks a default policy; `--verify precision|recall|max` overrides it
at medium, high, and max.

**precision** (default at medium). The verifier gets the vote definitions
only. Keep candidates where the vote is CONFIRMED or PLAUSIBLE. A verifier
that returns no clear vote counts as REFUTED.

**recall** (default at high). Append this rubric to the verifier prompt:

> **PLAUSIBLE by default** — do not refute a candidate for being "speculative" or
> "depends on runtime state" when the state is realistic: concurrency races,
> nil/undefined on a rare-but-reachable path (error handler, cold cache, missing
> optional field), falsy-zero treated as missing, off-by-one on a boundary the
> code does not exclude, retry storms / partial failures, regex/allowlist that
> lost an anchor. These are PLAUSIBLE.
>
> **REFUTED** only when constructible from the code: factually wrong (quote the
> actual line); provably impossible (type/constant/invariant — show it); already
> handled in this diff (cite the guard); or pure style with no observable effect.

Keep **CONFIRMED and PLAUSIBLE**. Drop REFUTED. A verifier that returns no
clear vote counts as PLAUSIBLE.

**max** (default at max). The verifier gets the vote definitions only, as
under precision. Then the coordinator applies this rule:

> This is recall mode — a single non-REFUTED vote carries the finding. Do NOT
> drop on uncertainty.

Keep every candidate whose vote is not a clear REFUTED, including one whose
verifier returned no clear vote (keep it as PLAUSIBLE).

Record each kept candidate's vote as its `verdict`.
