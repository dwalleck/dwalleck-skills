---
inclusion: always
---

# .NET Working Rules

Process rules for .NET changes, distilled from the dotnet/runtime, dotnet/roslyn, and
dotnet/aspnetcore agent instructions. Companion steering: `dotnet-csharp-style`,
`dotnet-correctness`, `dotnet-nullability`, `dotnet-testing`, `dotnet-service-lifetimes`,
`dotnet-lambda`.

## Before changing code
- Reproduce a reported bug on the current branch first and establish the smallest faithful repro. If asked only to investigate, don't change shipping code.
- Define acceptance criteria before implementing. For non-trivial changes (cross-project, public contract, behavior change, non-obvious approach) write a short plan: scope, non-goals, affected projects, approach, acceptance, exact build/test commands.
- Read `README.md`/`AGENTS.md` in the working directory and its parents. Check `.editorconfig`, `Directory.Build.props`, `Directory.Packages.props`, and `global.json` before assuming conventions or SDK version.
- For bug fixes, look for existing code that already handles the scenario — the bug is more likely in existing logic than a missing feature. Reuse existing helpers before writing new ones.

## Scope
- Prefer the simplest solution that works; complexity must justify itself. Every new abstraction, option, or flag is a permanent maintenance cost.
- Fix the root cause, not the symptom. Don't suppress warnings to make a build pass.
- One concern per change. No drive-by refactors, renames, or reformatting mixed into a functional change; mechanical renames go in their own change.
- Minimal diffs: preserve untouched code exactly. When an existing statement must change, keep its locals and branch structure unless the behavior requires otherwise. Before finishing, re-read changed lines for edits that neither change behavior nor support the task.
- The existing style of the file you're editing overrides general guidelines. Don't restyle code you aren't otherwise changing.
- A reported case is a sample, not a list. Grep for other instances of the same bug class and handle them, or name the ones you're leaving.
- Rename and move by symbol bindings (the `csharp-refactoring` skill), not text search-and-replace.
- No caches, object pools, or `Unsafe`/pointer code without a measured need. Performance claims need before/after numbers from a Release build.
- Don't hand-edit generated files; change the generator or its source. Don't change `global.json`, `NuGet.config`, lock files, or package versions unless asked.

## Definition of done
1. Format changed files per `.editorconfig` (`dotnet format`).
2. Build the affected project(s); no new warnings.
3. Run targeted tests and confirm the expected tests actually ran (check the counts). Use the `run-tests` skill for the exact command — VSTest and Microsoft.Testing.Platform take different arguments.
4. Bug fixes: show the regression test fails without the fix for the intended reason and passes with it (`test-value-evidence`). For a parameterized test, check every case — a red run only proves at least one failed, and a case whose scenario never executed proves nothing. If red/green isn't practical, say so and don't call the fix verified.
5. Regenerate generated outputs and resources the change affects.
6. Review the final diff for unrelated edits; report exactly what was built and run, and what wasn't.
- Never finish with tests newly commented out, skipped, or disabled.
- Redirect long builds/test runs to a log and inspect the tail or grep for errors rather than streaming full output.
