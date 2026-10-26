---
inclusion: always
---

# C# Style

`.editorconfig` is authoritative, and the existing style of a file beats these rules.
Apply to new and changed code only.

## Layout
- File-scoped namespaces. `using` directives at the top, outside the namespace, `System.*` first, then alphabetical.
- Allman braces (opening brace on its own line), 4-space indent, no tabs, no trailing whitespace, blank lines contain no whitespace, never two blank lines in a row.
- Braces on every `if`/`else`/`for`/`foreach`/`while`/`using` body, even single statements (`.editorconfig` enforces this as IDE0011). Never put a body on the same line as its condition.
- Early-return for error/short cases; success path last. A method's final `return` is on its own line.
- Fields first in a type; local functions at the end of the containing method.
- No `#region`. Avoid `using static`.
- Non-ASCII characters in source as `\uXXXX` escapes.

## Naming
- PascalCase: types, methods (including local functions), properties, events, constants (fields and locals).
- camelCase: parameters, locals, primary-constructor parameters (no `_` prefix; in larger types assign them to `_fields`).
- `_camelCase` private/internal instance fields, `s_` static fields, `t_` thread-static fields. Write `static readonly`, not `readonly static`.
- `I` prefix for interfaces; `T` or `TName` for type parameters. Acronyms longer than two letters are PascalCase (`HtmlButton`, but `IO`).
- Booleans positive and descriptive (`_hasCurrent`, not `valid`). Method names match behavior: `Get*` returns a value; `ThrowIf*`, not `ThrowExceptionIf*`. Rename when behavior changes.

## Language usage
- Keywords over BCL names: `int`, `string`, `int.Parse`.
- Always write the accessibility modifier, and put it first. Avoid `this.` unless required.
- `var` only when the type is apparent on the right (`new Foo()`, a cast, a literal) — not for method results, never for numeric types. Target-typed `new()` only when the type is named on the left of the same declaration. Defer to `.editorconfig` if it says otherwise.
- `is null` / `is not null`, never `== null` / `!= null`.
- Pattern matching (`is`, `and`/`or`/`not`, property patterns) and switch expressions over manual type checks and if-chains.
- `nameof(...)` instead of member-name string literals. Use `?.` where it fits (`scope?.Dispose()`).
- Named arguments for boolean literals: `Process(input, validate: true)`.
- Seal private/internal classes unless derivation is needed; make them `static` if they hold no instance state.
- Don't initialize fields to their default value (`= 0`, `= null`, `= false`).
- Named constants instead of magic numbers; don't duplicate a constant across files.
- Named types instead of `ValueTuple` across file or API boundaries.
- Scope `#pragma warning disable` to the specific line with a matching `restore`; no file-wide suppressions.

## Comments
- Explain why, not what. Delete comments that restate the code; don't narrate the previous implementation.
- Update or delete comments your change makes stale.
- XML docs on public types and members other projects consume: a one-sentence `<summary>` starting with a third-person verb ("Gets…", "Creates…"). Use `<inheritdoc/>` on implementations rather than duplicating interface docs. No XML docs in test code.
- TODOs reference a tracking issue (`// TODO(#123): ...`) or don't exist.
