# TUnit assertion API reference (verified forms)

Every form below compiled against TUnit 1.77.0 on 2026-10-31 and, where it is a passing form, passed at run time; the compile checks are not bundled (they are expected to fail on missing names), only the behaviour probe in `scripts/probe` is. "Obsolete" means it compiles with CS0618 and the given replacement. "Missing" means CS1061 or CS1929. Read this when SKILL.md's decision table does not name the assertion you need. Behaviour notes cite ids in `probe-baseline.txt`.

All assertions start with `await Assert.That(subject)`. `Assert.That` accepts a value, a `Func<T>`, an `async` lambda, a `Task` or a `Task<T>`; delegates and tasks are run or awaited before the assertion (C05, C10).

## Equality, comparison, null

| Form | Notes |
|---|---|
| `IsEqualTo(x)` / `IsNotEqualTo(x)` | Uses `Equals`. Reference equality for collections and classes without `Equals` (B04a, B06). |
| `IsEqualTo(x).Within(tol)` | `double`, `float`, `decimal`, `long`; `TimeSpan` tolerance for `DateTime`, `DateTimeOffset`, `TimeOnly`; `WithinDays(n)` for `DateOnly`. |
| `IsEquivalentTo(x)` / `IsNotEquivalentTo(x)` | Deep member comparison for objects (B05, B05c), anonymous expected shapes (C09), collections (order ignored, duplicates counted) and dictionaries (C15). |
| `IsEquivalentTo(x).IgnoringMember(nameof(T.P))` | B05d |
| `IsEquivalentTo(x, CollectionOrdering.Matching)` | Needs `using TUnit.Assertions.Enums;` (B17b). |
| `IsEquivalentTo(x).Using(IEqualityComparer<T>)` / `.Using((a, b) => ...)` | B37 |
| `IsSameReferenceAs(x)` / `IsNotSameReferenceAs(x)` | |
| `IsGreaterThan`, `IsGreaterThanOrEqualTo`, `IsLessThan`, `IsLessThanOrEqualTo` | Any `IComparable`. |
| `IsBetween(lo, hi)` | Inclusive (B13). No `WithExclusiveBounds`. |
| `IsPositive()`, `IsNegative()`, `IsZero()`, `IsNotZero()`, `IsEven()`, `IsOdd()` | |
| `IsNull()`, `IsNotNull()` | `IsNotNull()` narrows nullability for later lines (B25) and returns the non-null value: `string v = await Assert.That(s).IsNotNull();`. |
| `IsDefault()`, `IsNotDefault()` | |
| `IsTrue()`, `IsFalse()` | Prefer a specific assertion when the boolean is computed from the subject (B12a). |

## Strings

| Form | Notes |
|---|---|
| `Contains(s)`, `DoesNotContain(s)`, `StartsWith(s)`, `EndsWith(s)` | Modifiers: `.IgnoringCase()`, `.WithComparison(StringComparison)`, `.WithTrimming()`. |
| `IsEqualTo(s).IgnoringCase()` / `.IgnoringWhitespace()` / `.WithComparison(...)` | B26 |
| `IsEmpty()`, `IsNotEmpty()`, `IsNotNullOrEmpty()`, `IsNotNullOrWhiteSpace()` | `IsEmpty` means `""`, not null. |
| `Length().IsEqualTo(n)`, `Length().IsGreaterThan(n)`, `Length().IsBetween(a, b)` | Obsolete: `HasLength()`, `HasLength(n)`. Missing: `HasLength().GreaterThan(n)`. |
| `Matches(pattern)` / `Matches(regex)`, `DoesNotMatch(pattern)` | Pass options in a `Regex` or inline (`(?i)`). `.IgnoringCase()` and `.WithOptions(...)` after `Matches(string)` compile but have no effect (D01, D02, D05). |
| `WhenParsedInto<T>()` | Returns the parsed value and chains: `.WhenParsedInto<int>().IsEqualTo(42)`. |

## Collections and dictionaries

| Form | Notes |
|---|---|
| `Contains(item)`, `DoesNotContain(item)` | Uses `Equals` (B32). |
| `Contains(x => ...)`, `DoesNotContain(x => ...)` | The `Contains` predicate form returns the matching item. |
| `Count().IsEqualTo(n)` (and any numeric assertion after `Count()`) | Obsolete: `HasCount(n)`. |
| `Count(x => x.IsGreaterThan(1)).IsEqualTo(n)` | The lambda builds an assertion; `Count(x => x > 1)` does not compile. |
| `IsEmpty()`, `IsNotEmpty()`, `HasSingleItem()` | `HasSingleItem` returns the item (B24 shows the failure message). |
| `All(x => ...)`, `Any(x => ...)` | `All` failure names the index and value (C16). |
| `All().Satisfy(x => x.IsPositive())`, `All().Satisfy(x => x.Prop, p => p.IsGreaterThan(0))` | Failure includes the inner assertion's message (C17). |
| `IsInOrder()`, `IsInDescendingOrder()`, `IsOrderedBy(x => x.P)`, `IsOrderedByDescending(x => x.P)` | |
| `HasDistinctItems()` | |
| `ContainsKey(k)`, `DoesNotContainKey(k)`, `ContainsValue(v)`, `ContainsKeyWithValue(k, v)` | Missing: `ContainsKey(k).WithValue(v)`. `ContainsKey(k).Using(comparer)`. |
| Missing | `ContainsAll`, `IsSubsetOf` (collections), `IsSequenceEqualTo`. Use `IsEquivalentTo` or several `Contains`. |

## Exceptions

| Form | Notes |
|---|---|
| `Throws<T>()` | Accepts subclasses (B09a). Returns `T?` (B22). Works on sync delegates, async lambdas, `Func<Task>` and `Task` values (B18, B19a, B19b). |
| `ThrowsExactly<T>()` | Rejects subclasses (B09b). |
| `Throws(Type)` | On async delegates. For sync delegates use static `Assert.Throws(Type, Action)`. |
| `ThrowsNothing()` | Returns the delegate's value (B29). |
| `.WithMessage("exact")` | Exact; `*` is literal (B08a). |
| `.WithMessageContaining("part")` (optional `StringComparison`), `.WithMessageNotContaining("part")` | |
| `.WithMessageMatching("wild*card")` or `.WithMessageMatching(StringMatcher.AsWildcard("...").IgnoringCase())` | B08b |
| `.WithParameterName("p")` | `ArgumentException` family (C18 shows the failure message). |
| `.WithInnerException()`, `.WithInnerException<T>()` | Missing: `.WithInnerException().Throws<T>()` (B34 shows the failure message). |
| Static `Assert.Throws<T>(Action)`, `Assert.ThrowsAsync<T>(Func<Task>)` | Missing: `.ThrowsAsync<T>()` on an `Assert.That` chain. |

## Types

| Form | Notes |
|---|---|
| `IsTypeOf<T>()` | Passes when the value is a `T` or a subclass of `T` (B15a, C01, C04b); fails for an unrelated or base instance (C04). Returns `T?`. |
| `IsNotTypeOf<T>()` | Passes for a subclass of `T` (C03). |
| `IsAssignableTo<T>()`, `IsNotAssignableTo<T>()`, `IsAssignableFrom<T>()`, `IsNotAssignableFrom<T>()` | |
| Exact type | `Assert.That(x.GetType()).IsEqualTo(typeof(T))` (C20). |

## Tasks, time, other types

| Form | Notes |
|---|---|
| `IsCompleted()`, `IsNotCompleted()`, `IsCanceled()`, `IsNotCanceled()`, `IsFaulted()`, `IsNotFaulted()`, `IsCompletedSuccessfully()` | Missing: `IsCancelled`. |
| `CompletesWithin(TimeSpan)` | |
| `WaitsFor(src => src.IsEqualTo(x), timeout: ...)`, alias `Eventually(...)` | B27 |
| `IsAfter(d)`, `IsBefore(d)`, `IsInPast()`, `IsInPastUtc()`, `IsInFutureUtc()`, `IsUtc()` | Missing: `IsOnOrAfter`, `IsOnOrBefore`. Wall-clock assertions (`IsInPast`, `IsInFutureUtc`) make tests time-dependent; prefer a fixed expected value. |
| `IsSuccess()`, `IsClientError()`, `IsServerError()`, `IsRedirection()` on `HttpStatusCode` | |
| `IsEmptyGuid()`, `IsNotEmptyGuid()` | |
| `IsCancellationRequested()`, `CanBeCanceled()` on `CancellationToken` | |

## Composition and messages

| Form | Notes |
|---|---|
| `.And.<assertion>`, `.Or.<assertion>` | One kind per chain (B02, C13). |
| `Member(x => x.P, p => p.IsEqualTo(v))` | Keeps the parent subject for further `.And.Member(...)`. Nested paths allowed: `x => x.Address.City`. Missing: `HasMember`, `HasProperty`. |
| `using (Assert.Multiple()) { ... }` or `using var _ = Assert.Multiple();` | B11, B30, C11 |
| `.Because("reason")` | Appends `, because reason` to the expectation (B21, C19). |
| `Satisfies(v => ...)` | Do not pass a second string argument (B20, TUnitAssertions0003). |
| `Assert.Fail("reason")` | For unreachable branches only; not for exception tests. |

## Custom assertions

The current extension point is `IAssertionSource<T>` and `Assertion<T>` in `TUnit.Assertions.Core`; the old `IValueSource<T>` / `IInvokableValueAssertionBuilder<T>` types are gone. Prefer the source generator for simple predicates:

```csharp
using System.ComponentModel;
using TUnit.Assertions.Attributes;

public static partial class OrderAssertionExtensions
{
    [EditorBrowsable(EditorBrowsableState.Never)]
    [GenerateAssertion(ExpectationMessage = "to have {count} lines")]
    public static bool HasLineCount(this Order order, int count) => order.Lines.Count == count;
}
// await Assert.That(order).HasLineCount(2);
```

The method must be `static`, take the subject as its first parameter, and return `bool`, `AssertionResult`, `Task<bool>` or `Task<AssertionResult>`; the containing class must be `partial`. The generator's analyzer reports violations at build time. For assertions that change the subject type, derive from `Assertion<TTo>` and pass `context.Map<TTo>(...)` to the base constructor; see tunit.dev `docs/assertions/extensibility/extensibility-chaining-and-converting.md`. The `[GenerateAssertion]` example above compiled and passed against 1.77.0. The type-converting `Assertion<TTo>` pattern comes from the tunit.dev docs and was not compiled.
