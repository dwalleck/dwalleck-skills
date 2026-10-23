<!-- Source: system-prompts/skill-code-review-conventions-dimension.md:6-18, retargeted from Claude Code's memory files to Kiro's convention files (AGENTS.md, steering, CONTRIBUTING). The quote-the-rule requirement and the return-nothing exit are kept word for word. -->
### Conventions (AGENTS.md, steering, CONTRIBUTING)

Find the convention files that govern the changed code:

- the user-level steering files `~/.kiro/steering/*.md`;
- the workspace steering files `.kiro/steering/*.md`;
- the repo-root `AGENTS.md`, plus any `AGENTS.md` in a directory that is an
  ancestor of a changed file (a directory's `AGENTS.md` only applies to files at
  or below it);
- the repo's contributing guide (`CONTRIBUTING.md` at the root, in `.github/`,
  or in `docs/`).

A steering file applies according to its front matter: `inclusion: always` (or
no front matter) applies to every changed file; `inclusion: fileMatch` applies
only to changed files that match its `fileMatchPattern`; `inclusion: auto`
applies only when its `description` covers the changed code; `inclusion:
manual` applies only when the user named it for this review. Read each one
that exists and applies, then check the diff for clear violations of the rules
they state.

Only flag a violation when you can quote the exact rule and the exact line
that breaks it — no style preferences, no vague "spirit of the doc"
inferences. In the finding, name the convention file's path and quote the rule
so the report can cite it. If no convention file applies, return nothing for
this angle.
