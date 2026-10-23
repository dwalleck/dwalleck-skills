<!-- Source: system-prompts/agent-prompt-code-review-minimal-mode.md:20-22 (review pass; tool names made generic). Diff gathering is the shared Phase 0 in SKILL.md, which is identical to minimal-mode:13-18. The tool call and restate step (22-24) are replaced by the skill's markdown Output. -->
## Minimal — single careful diff pass

No subagents, no verification. Review the diff yourself.

Review the diff as a careful senior engineer would: read every hunk, open the
surrounding files for context as needed (read files, search for symbols, git
log/blame/show), and hunt for correctness issues — wrong or inverted
conditions, off-by-one, null/undefined dereference, missing `await`, dropped
error handling, removed guards or validations, broken callers of changed
functions, races. Prefer real failure modes over style; every finding needs a
concrete scenario in which the code misbehaves.

Quality over quantity: include everything you genuinely believe is a real
issue, and nothing you don't. Give every finding the `correctness` category
(or a more specific slug) and no verdict, then go to Output.
