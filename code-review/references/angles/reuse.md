<!-- Reconstructed: this angle's text was never extracted from Claude Code. Rewritten from `git show 8f898b3^:system-prompts/skill-simplify.md` lines 20-27 ("Agent 1: Code Reuse Review", plus the existing-constants item from line 36), narrowed to the scope of system-prompts/agent-prompt-code-review-part-2-low-effort-mode.md:29-30 ("new code that duplicates an existing helper"). -->
### Reuse

For each piece of new code in the diff, search for existing utilities and
helpers that could replace it. Look for similar patterns elsewhere in the
codebase — common locations are utility directories, shared modules, and files
adjacent to the changed ones. Flag:

- a new function that duplicates existing functionality — name the existing
  function to use instead;
- inline logic that could use an existing utility — hand-rolled string
  manipulation, manual path handling, custom environment checks, ad-hoc type
  guards, and similar patterns are common candidates;
- raw strings where constants, enums (string unions), or branded types for the
  same values already exist in the codebase.

Only flag duplication the diff introduces, and only when you can point at the
existing code (file and symbol) that should be used instead.
