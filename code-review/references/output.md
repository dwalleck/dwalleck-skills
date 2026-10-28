<!-- Moved from SKILL.md `## Output` (c03df8c:135-170). Changed: the header lines are a markdown list (so terminals cannot merge them), `fallback:` became `route:` + `verification:`, the ranking order is spelled out, and the workflow route's findings.md / findings.json are named. The field rules and the empty-case sentence are unchanged. -->
## Output

The markdown below is the report. On the in-context and sub-agent routes, and
at minimal and low, it is the main agent's reply: no tool call, no file. On the
workflow route, the workflow's report step writes it to `<run_dir>/findings.md`
(and the same findings to `<run_dir>/findings.json`), and the main agent prints
that file verbatim.

### Cap and ranking

Apply the cap in effect (`--max-findings`, else the default in SKILL.md
Arguments) first. If more than the cap survive, keep the cap's number of most
severe; with `all`, keep every finding that survives — there is no maximum.
Correctness bugs always outrank cleanup and altitude findings when the cap
forces a cut.

Then list the kept findings in this order:

1. **Group.** The correctness group first: `correctness` and any slug that is
   not a cleanup slug (for example `test-coverage`). Then the cleanup group:
   `reuse`, `simplification`, `efficiency`, `altitude`, `conventions`. A
   cleanup finding moves above correctness findings only when it is clearly
   more severe than they are.
2. **Verdict**, within a group: CONFIRMED, then PLAUSIBLE, then
   `unverified (sweep)`. A `(self-check)` vote ranks as the vote it carries.
3. **Severity**, within the same group and verdict: most severe first.
   Severity is consequence × likelihood: a crash, data loss, security hole, or
   silently wrong result first; then wrong behavior on a reachable path; then
   cost (duplication, waste, maintenance).

With no verdicts (minimal, low), use 1 and 3.

### Format

Put the run line, Target, and Notes on separate list items exactly as below, so
a terminal cannot run them together.

```markdown
## Code review — <level> effort

- **Run:** <pipeline from the matrix> · verify policy: <precision | recall | max | none> · cap: <n | all> · route: <route> · verification: <verification>
- **Target:** <current diff | PR #n (<head branch> @ <short sha>) | branch | path>
- **Notes:** <scope restriction, unknown level, ignored flags, invalid values, failed finders — omit this item if none>

### 1. `path/to/file.ext:123` — <short summary>

- **Category:** correctness
- **Verdict:** CONFIRMED
- **Summary:** <one-sentence statement of the issue>
- **Failure scenario:** <concrete inputs/state → wrong output or crash; for a cleanup, the concrete cost>
```

`route:` says which route ran:

- `inline` — minimal and low;
- `workflow (code-review-8)` or `workflow (code-review-10)`;
- `workflow (<recipe>), then in-context for <phases>` — the run failed or
  paused and the remaining phases ran in this context;
- `sub-agents`;
- `sub-agents, then in-context for <phases>`;
- `in-context`.

`verification:` says whether verification was independent:

- `independent — one verifier sub-agent per candidate` — the workflow's verify
  step ran mode `sub-agents`, or the sub-agent route ran;
- `separate verify session — candidates judged one at a time, independent of the finders`
  — the workflow's verify step ran mode `one-at-a-time`;
- `mixed — <n> by sub-agents, <m> judged in turn by the verify session` — mode
  `mixed`;
- `self-checked in context — not independent` — the in-context route;
- `partial — <phases> self-checked in context; not independent` — a partial
  fallback;
- `none — no candidates` — mode `none` (nothing was pooled);
- `none at this level` — minimal and low.

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
