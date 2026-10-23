<!-- Source: system-prompts/agent-prompt-code-review-part-2-low-effort-mode.md:14-33 (verbatim apart from the target wording). Its output lines (35-44) are replaced by the skill's markdown Output. -->
## Low — one diff pass, hunk only

This level replaces Phase 0 with its own one-call read.

### Turn 1 — read

One tool call: read the unified diff (`git diff @{upstream}...HEAD; git diff HEAD`
to cover both committed and uncommitted changes, or `git diff main...HEAD` /
the target's diff command from Phase 0). Skip test/fixture
hunks (`test/`, `spec/`, `__tests__/`, `*_test.*`, `*.test.*`,
`fixtures/`, `testdata/`) — test-file changes are not reviewed at this level.
No subagents, no full-file reads.

### Turn 2 — findings

Flag runtime-correctness bugs visible from the hunk alone: inverted/wrong
condition, off-by-one, null/undefined deref where adjacent lines show the value
can be absent, removed guard, falsy-zero check, missing `await`,
wrong-variable copy-paste, error swallowed in a catch that should propagate.
Also flag — still from the hunk alone — new code that duplicates an existing
helper visible in the diff context, and dead code the diff leaves behind.

Do **not** flag style, naming, perf, missing tests, or anything outside the
hunk.

Give each finding a category (`correctness`, `reuse`, or `simplification`) and
no verdict, then go to Output.
