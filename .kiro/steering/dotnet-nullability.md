---
inclusion: always
---

# Nullable Reference Types

- Enable `<Nullable>enable</Nullable>` in every project. Decide each member's intended contract first, then annotate — don't let warnings drive annotations (`?` everywhere and `!` everywhere both hide the contract).
- Trust annotations internally: no null checks where the type says non-null. Keep `ArgumentNullException.ThrowIfNull` on public entry points — callers can still pass null at runtime.
- `!` only where the code has proven non-null and the compiler can't see it; prefer a real check or `Debug.Assert(x is not null)`.
- Never `return null!` or `default!` to keep a return type non-nullable. If null can be returned, the return type is `T?` — a non-nullable return is a promise to every caller.
- Late-initialized fields: one `= null!` on the declaration (plus `[MemberNotNull]` on the initializing method), not `!` at every use.
- Serializers and model binders bypass constructors, so a non-nullable DTO property can still be null at runtime. Use `required` members and validate request models at the boundary.
- Fixing a warning must not change behavior by accident: `x.M()` → `x?.M()` silently skips the call, and `?` on a value type turns `T` into `Nullable<T>`.
- `Where(x => x is not null)` doesn't narrow `T?` to `T`; use `OfType<T>()`.
- Don't annotate and refactor in the same commit.

## Annotations
- Parameter non-nullable if null throws or is documented to; nullable if null is accepted, normalized, or the default. Return/`out` nullable if null is possible under any circumstance.
- `Try*` outs: `[NotNullWhen(true)] out Foo? value`; generic: `[MaybeNullWhen(false)] out T value`. Add `[NotNullWhen(true)]` to `Equals(object?)` overrides and to inputs a `true` result proves non-null.
- `[DoesNotReturn]` on throw helpers; `[MemberNotNull(nameof(_field))]` on initialization helpers; `[return: NotNullIfNotNull(nameof(input))]` for pass-through nullability.
- Unconstrained generic that may return `default`: `T?` (C# 9+) over `[MaybeNull]`.
