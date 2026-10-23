<!-- Reconstructed: this angle's text was never extracted from Claude Code. Rewritten from `git show 8f898b3^:system-prompts/skill-simplify.md` lines 28-40 ("Agent 2: Code Quality Review"), narrowed to the scope of system-prompts/agent-prompt-code-review-part-2-low-effort-mode.md:29-30 ("dead code the diff leaves behind"). Items 4 (leaky abstractions, covered by Altitude), 5 (stringly-typed, moved to Reuse), 6 (JSX-specific) and 8 (comments, a style matter) were dropped. -->
### Simplification

Review the code the diff adds or touches for needless complexity, and for dead
code the diff leaves behind. Flag:

- **Dead code**: functions, branches, parameters, imports, or flags that nothing
  reaches any more once the diff lands
- **Redundant state**: state that duplicates existing state, cached values that
  could be derived, observers/effects that could be direct calls
- **Parameter sprawl**: adding new parameters to a function instead of
  generalizing or restructuring existing ones
- **Copy-paste with slight variation**: near-duplicate code blocks that should
  be unified with a shared abstraction
- **Nested conditionals**: ternary chains (`a ? x : b ? y : ...`), nested
  if/else, or nested switch 3+ levels deep — flatten with early returns, guard
  clauses, a lookup table, or an if/else-if cascade

Name the simpler equivalent for each. Only flag complexity the diff introduces
or leaves behind, not untouched code, style, or naming.
