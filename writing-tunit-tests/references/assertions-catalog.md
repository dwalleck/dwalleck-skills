# TUnit Assertion Catalog

Reference for the full TUnit assertion library. Use this when the SKILL.md basics are not enough — for unfamiliar types, exception inspection, custom comparers, or advanced chaining.

## Canonical shape

Every assertion follows the same three-part pattern:

```csharp
await Assert.That(actualValue).SomeAssertion(expected);
```

- Wrap the value being checked in `Assert.That(...)`.
- Chain one or more assertion methods.
- **Always `await` the result.** Without `await`, the assertion never executes and the test passes silently. The built-in analyzer warns, but treat the warning as a blocker.

Combine with `.And` (all must hold) or `.Or` (any may hold):

```csharp
await Assert.That(username)
    .IsNotNull()
    .And.IsNotEmpty()
    .And.HasLength().GreaterThan(3);
```

## Equality & comparison

| Method | Use |
|---|---|
| `.IsEqualTo(x)` | Value equality |
| `.IsNotEqualTo(x)` | Negated value equality |
| `.IsSameReferenceAs(x)` | Reference equality |
| `.IsGreaterThan(x)` | `>` |
| `.IsGreaterThanOrEqualTo(x)` | `>=` |
| `.IsLessThan(x)` | `<` |
| `.IsLessThanOrEqualTo(x)` | `<=` |
| `.IsBetween(low, high)` | Inclusive range |

```csharp
await Assert.That(result).IsEqualTo(42);
await Assert.That(actual).IsBetween(1, 10);
```

For custom equality, pass a comparer or selector overload where supported. For deep equality on complex objects, prefer `.IsEquivalentTo(...)` (under collections) when comparing record-like data.

## Null & default

| Method | Use |
|---|---|
| `.IsNull()` | Value is null |
| `.IsNotNull()` | Value is non-null |
| `.IsDefault()` | Equals `default(T)` |
| `.IsNotDefault()` | Differs from `default(T)` |

```csharp
await Assert.That(maybeUser).IsNotNull();
await Assert.That(default(int)).IsDefault();
```

`.IsNotNull()` flows-types correctly: subsequent chained assertions see the value as non-nullable.

## Booleans

```csharp
await Assert.That(isLoggedIn).IsTrue();
await Assert.That(hasErrors).IsFalse();
```

Reach for a specialized assertion before `.IsTrue()`. `await Assert.That(list.Count > 0).IsTrue()` is worse than `await Assert.That(list).IsNotEmpty()` — the latter produces a much better failure message.

## Numerics

| Method | Use |
|---|---|
| `.IsPositive()` | `> 0` |
| `.IsNegative()` | `< 0` |
| `.IsZero()` / `.IsNotZero()` | Exactly zero |
| `.IsEven()` / `.IsOdd()` | Parity (integer types) |

```csharp
await Assert.That(balance).IsPositive();
await Assert.That(count).IsEven();
```

Floating-point: combine `.IsBetween(...)` with explicit tolerance bounds rather than `.IsEqualTo(...)` for non-deterministic computations.

## Strings

| Method | Use |
|---|---|
| `.Contains(substring)` | Substring presence |
| `.DoesNotContain(substring)` | Substring absence |
| `.StartsWith(prefix)` | Prefix match |
| `.EndsWith(suffix)` | Suffix match |
| `.IsEmpty()` / `.IsNotEmpty()` | Length 0 |
| `.HasLength().IsEqualTo(n)` | Length check |
| `.Matches(regex)` | Regex match |

```csharp
await Assert.That(message).StartsWith("ERR:").And.Contains("timeout");
await Assert.That(phone).Matches(@"^\d{3}-\d{4}$");
```

## Collections

`Assert.That(IEnumerable<T>)` exposes:

| Method | Use |
|---|---|
| `.Contains(item)` | Item present |
| `.Contains(x => predicate)` | Returns the matching item |
| `.DoesNotContain(item)` or `.DoesNotContain(predicate)` | Item absent |
| `.HasCount(n)` or `.Count().IsEqualTo(n)` | Size check |
| `.IsEmpty()` / `.IsNotEmpty()` | |
| `.HasSingleItem()` | Returns the single element |
| `.HasDistinctItems()` | No duplicates |
| `.IsInOrder()` | Naturally ordered |
| `.IsOrderedBy(x => x.Property)` | Ordered by selector |
| `.IsEquivalentTo(other)` | Same items, ignoring order |
| `.IsNotEquivalentTo(other)` | |

```csharp
// Returns the matching item — chain further assertions on it
var alice = await Assert.That(users).Contains(u => u.Name == "Alice");
await Assert.That(alice.Email).EndsWith("@example.com");

// Single-item shortcut also returns the item
var only = await Assert.That(results).HasSingleItem();
await Assert.That(only.Status).IsEqualTo(Status.Done);
```

## Dictionaries

```csharp
await Assert.That(dict).ContainsKey("alice");
await Assert.That(dict).DoesNotContainKey("bob");
await Assert.That(dict).ContainsValue(42);
```

## DateTime / TimeSpan

| Method | Use |
|---|---|
| `.IsAfter(dt)` / `.IsBefore(dt)` | Strict |
| `.IsOnOrAfter(dt)` / `.IsOnOrBefore(dt)` | Inclusive |
| `.IsBetween(start, end)` | Within range |

```csharp
await Assert.That(timestamp).IsAfter(processStart).And.IsBefore(processEnd);
```

## Type checking

| Method | Use |
|---|---|
| `.IsTypeOf<T>()` | Exact type |
| `.IsAssignableTo<T>()` | Type or subclass / interface impl |
| `.IsAssignableFrom<T>()` | Reverse direction |
| `.IsNotAssignableFrom<T>()` | |

```csharp
await Assert.That(handler).IsAssignableTo<IRequestHandler>();
```

To narrow and inspect, await first then use `as`/`is`:

```csharp
var typed = await Assert.That(result).IsTypeOf<MyHandler>();
typed.DoWork();
```

## Exceptions

The shape: pass a `Func` (sync) or `async Func` to `Assert.That(...)`, then chain a throw assertion.

| Method | Use |
|---|---|
| `.Throws<T>()` | Throws T or derived |
| `.ThrowsExactly<T>()` | Throws exactly T |
| `.ThrowsException<T>()` | Equivalent to `.Throws<T>()` (legacy) |
| `.ThrowsNothing()` | Does not throw |

```csharp
// Sync
await Assert.That(() => int.Parse("not a number")).Throws<FormatException>();

// Async
await Assert.That(async () => await FailingOperationAsync())
    .Throws<HttpRequestException>();

// Verifies it does NOT throw
await Assert.That(() => int.Parse("42")).ThrowsNothing();
```

### Inspecting the thrown exception

`.Throws<T>()` returns the exception, so capture it and assert further:

```csharp
var ex = await Assert.That(() => throw new BusinessRuleException("BR001", "Rule violated"))
    .Throws<BusinessRuleException>();

await Assert.That(ex.Code).IsEqualTo("BR001");
```

### Message and inner exception

```csharp
// Exact message
await Assert.That(() => throw new InvalidOperationException("Operation failed"))
    .Throws<InvalidOperationException>()
    .WithMessage("Operation failed");

// Substring match
await Assert.That(() => throw new ArgumentException("Parameter 'userId' is invalid"))
    .Throws<ArgumentException>()
    .WithMessageContaining("userId");

// Inner exception chain
await Assert.That(() => ThrowWithInner())
    .Throws<InvalidOperationException>()
    .WithInnerException()
    .Throws<FormatException>();
```

## Tasks & async state

| Method | Use |
|---|---|
| `.IsCompleted()` | Task ran to completion |
| `.IsNotCompleted()` | Task still running |
| `.IsFaulted()` | Task threw |
| `.IsCancelled()` | Task was cancelled |

```csharp
await Assert.That(longRunningTask).IsNotCompleted();
```

For testing the *result* of an async operation, await the operation first and assert on the value:

```csharp
var result = await GetAsync();
await Assert.That(result).IsNotNull();
```

## Member assertions

Project into a property and assert on it without breaking the chain:

```csharp
await Assert.That(user)
    .HasMember(u => u.Email).EqualTo("alice@example.com")
    .And.HasMember(u => u.Roles).Contains("Admin");
```

This composes well with `Contains(predicate)` for collection navigation.

## F# syntax

For F# test projects, `TUnit.Assertions.FSharp` exposes a pipe-friendly API. See the TUnit docs for current shape.

## Custom assertions

When you need an assertion that doesn't exist, write an extension method on `IValueSource<T>` that returns `IInvokableValueAssertionBuilder<T>`. TUnit's source-gen extensibility lets you produce AOT-safe custom assertions — see the `extensibility/custom-assertions` page on tunit.dev for the full pattern.

## Choosing the right assertion

| If you're tempted to write... | Use instead |
|---|---|
| `Assert.That(x != null).IsTrue()` | `Assert.That(x).IsNotNull()` |
| `Assert.That(list.Count > 0).IsTrue()` | `Assert.That(list).IsNotEmpty()` |
| `Assert.That(list.Single(p)).IsNotNull()` | `var item = await Assert.That(list).Contains(p);` |
| `try { ... } catch { Assert.That(true).IsTrue(); }` | `await Assert.That(() => ...).Throws<T>()` |
| Casting and asserting on cast result | `var typed = await Assert.That(x).IsTypeOf<T>();` |
| `Assert.That(s.Contains("x")).IsTrue()` | `await Assert.That(s).Contains("x")` |

The pattern: prefer the specialized assertion. Failure messages are dramatically better, and the intent of the test is clearer at the call site.
