---
name: writing-tunit-tests
description: "Best practices for writing TUnit unit and integration tests. Use whenever the user is writing, fixing, reviewing, or modernizing TUnit tests, or asks about [Test], [Arguments], [Before(Test)]/[After(Test)], [MethodDataSource], [ClassDataSource], [MatrixDataSource], hooks, lifecycle, parallelism, timeouts, or `await Assert.That(...)`. Also use when the user references TUnit attributes without naming the framework, or when test files import `TUnit.Core` / `TUnit.Assertions`. Covers project setup on Microsoft.Testing.Platform, the async-by-default model, data-driven tests, lifecycle hooks at four scopes, parallelism control, retries, skipping, and the awaited-assertion pattern."
---

# Writing TUnit Tests

Help users write effective, modern unit and integration tests with TUnit, leveraging its source-generated, async-first model on Microsoft.Testing.Platform.

## When to Use

- User wants to write new TUnit tests
- User wants to improve, modernize, or review existing TUnit tests
- User asks about TUnit attributes, data sources, hooks, or assertions
- User mixes test frameworks and is choosing/converting to TUnit

## When Not to Use

- User wants to run or filter tests (use the `run-tests` skill)
- User wants to migrate from xUnit/NUnit/MSTest to TUnit (use `migrate-to-tunit`)
- User is configuring AOT publishing or trim-safe tests (use `tunit-aot-compatibility`)
- User is mocking with TUnit's source-gen mock framework (use `tunit-mocking`)
- User is using xUnit, NUnit, or MSTest (use the matching framework skill)

## Inputs

| Input | Required | Description |
|-------|----------|-------------|
| Code under test | No | The production code to be tested |
| Existing test code | No | Current TUnit tests to review or improve |
| Test scenario description | No | What behavior the user wants to test |

## Workflow

### Step 1: Set up the test project

TUnit runs on **Microsoft.Testing.Platform (MTP)**, not VSTest. The compiled test project is a standalone executable, which changes how you run it:

```bash
# Run TUnit tests with `dotnet run`, NOT `dotnet test`
dotnet run --project tests/MyProject.Tests/

# Filter (args after --)
dotnet run --project tests/MyProject.Tests/ -- --filter "FullyQualifiedName~Login"
```

`dotnet test` requires extra opt-in (a `global.json` switch) on .NET 10 SDK and fails without it. Default to `dotnet run`.

A minimal TUnit project file:

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework>
    <OutputType>Exe</OutputType>
    <IsPackable>false</IsPackable>
    <LangVersion>latest</LangVersion>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="TUnit" Version="*" />
  </ItemGroup>
</Project>
```

`OutputType=Exe` is required — MTP needs a `Main` entry point, which TUnit's source generator produces.

### Step 2: Write tests with TUnit conventions

Three things differ from MSTest/NUnit and one thing differs from xUnit:

- **No `[TestClass]` attribute**. Just put `[Test]` on test methods. The class is plain.
- **Async by default**. Test methods almost always return `Task` and start with `public async Task`. Sync tests work, but async is idiomatic because assertions are awaited.
- **Tests run in parallel by default** and a **new instance** of the test class is created per test (xUnit-like). Don't rely on instance state surviving between tests — see Pitfalls.
- **Assertions must be awaited.** `await Assert.That(value).IsEqualTo(expected);` — without `await`, the test passes silently. A built-in analyzer warns, but reviews should still check.

```csharp
using TUnit.Assertions;
using TUnit.Assertions.Extensions;
using TUnit.Core;

namespace MyProject.Tests;

public class CalculatorTests
{
    [Test]
    public async Task Add_WithTwoNumbers_ReturnsSum()
    {
        var calculator = new Calculator();

        var result = calculator.Add(2, 3);

        await Assert.That(result).IsEqualTo(5);
    }
}
```

Naming convention: `MethodUnderTest_Scenario_ExpectedBehavior`, matching the rest of this repo.

### Step 3: Use the awaited-assertion pattern

Every assertion goes through `Assert.That(...)` and is awaited. Chain conditions with `.And` / `.Or`.

```csharp
// Equality and null
await Assert.That(result).IsEqualTo(42);
await Assert.That(result).IsNotEqualTo(other);
await Assert.That(value).IsNotNull();

// Booleans
await Assert.That(condition).IsTrue();

// Chained
await Assert.That(username)
    .IsNotNull()
    .And.IsNotEmpty()
    .And.HasLength().GreaterThan(3);

// Exceptions — assert throws and inspect the exception
await Assert.That(() => service.Process(null!))
    .Throws<ArgumentNullException>()
    .WithMessage("*input*");

// Async exceptions
await Assert.That(async () => await service.ProcessAsync(null!))
    .ThrowsAsync<ArgumentNullException>();

// Collections
await Assert.That(items).Contains(expectedItem);
await Assert.That(items).HasCount(3);
await Assert.That(items).IsEmpty();
```

Prefer specialized assertions over `Assert.That(condition).IsTrue()` — they give better failure messages:

| Instead of | Use |
|---|---|
| `Assert.That(list.Count > 0).IsTrue()` | `Assert.That(list).IsNotEmpty()` |
| `Assert.That(list.Count == 3).IsTrue()` | `Assert.That(list).HasCount(3)` |
| `Assert.That(x != null).IsTrue()` | `Assert.That(x).IsNotNull()` |
| `Assert.That(s.Contains("x")).IsTrue()` | `Assert.That(s).Contains("x")` |

TUnit's assertion library covers ~50+ specialized assertions across equality, comparison, collections, dictionaries, strings, numerics, exceptions (with inner-exception and message inspection), DateTime, type checking, tasks, and member projection. For the full catalog with examples, custom assertions, and advice on choosing the right one, see [`references/assertions-catalog.md`](references/assertions-catalog.md).

### Step 4: Parameterize with data sources

TUnit offers four data-source attributes. Pick by data shape, not by habit.

#### `[Arguments(...)]` — inline values

```csharp
[Test]
[Arguments(1, 1, 2)]
[Arguments(2, 2, 4)]
[Arguments(5, 5, 10)]
public async Task Add_ReturnsExpectedSum(int a, int b, int expected)
{
    await Assert.That(Calculator.Add(a, b)).IsEqualTo(expected);
}
```

`[Arguments]` supports `DisplayName` (with `$paramName` substitution), `Categories`, and per-row `Skip`:

```csharp
[Arguments(2, 3, 5, DisplayName = "$a + $b = $expected")]
[Arguments("", "", DisplayName = "Empty creds", Skip = "Edge case not implemented")]
```

#### `[MethodDataSource(...)]` — programmatic data

Return `IEnumerable<Func<T>>` (not `IEnumerable<T>` directly) so each row produces a fresh instance per test. This is TUnit's signature pattern and prevents state bleeding between rows.

```csharp
public class MyTests
{
    [Test]
    [MethodDataSource(typeof(MyTestData), nameof(MyTestData.AdditionCases))]
    public async Task Add_ReturnsExpected(int a, int b, int expected)
    {
        await Assert.That(Calculator.Add(a, b)).IsEqualTo(expected);
    }
}

public static class MyTestData
{
    public static IEnumerable<Func<(int, int, int)>> AdditionCases()
    {
        yield return () => (1, 2, 3);
        yield return () => (2, 2, 4);
        yield return () => (5, 5, 10);
    }
}
```

Async data sources use `IAsyncEnumerable<Func<T>>`.

#### `[ClassDataSource<T>(Shared = ...)]` — shared/expensive fixtures

Use this when the data is an expensive object (e.g. a `WebApplicationFactory`, a database container) and you want to control its lifetime. The type can implement `IAsyncInitializer` and `IAsyncDisposable`:

```csharp
[Test]
[ClassDataSource<WebApplicationFactory>(Shared = SharedType.PerTestSession)]
public async Task Endpoint_Returns200(WebApplicationFactory factory)
{
    using var client = factory.CreateClient();
    var response = await client.GetAsync("/health");
    await Assert.That((int)response.StatusCode).IsEqualTo(200);
}

public sealed record WebApplicationFactory : IAsyncInitializer, IAsyncDisposable
{
    public async Task InitializeAsync() => await StartServer();
    public async ValueTask DisposeAsync() => await StopServer();
}
```

`SharedType` values: `None` (fresh per test), `PerClass`, `PerTestSession`, `Keyed` (shared by string key).

#### `[MatrixDataSource]` — combinatorial

```csharp
[Test]
[MatrixDataSource]
public async Task Combine(
    [Matrix(1, 2, 3)] int x,
    [Matrix("a", "b")] string y)
{
    // Runs 3 × 2 = 6 times
}
```

### Step 5: Inject fixtures and dependencies

Beyond passing data into individual tests, TUnit has three ways to get fixtures and dependencies into the test class itself:

#### Constructor injection

`[ClassDataSource<T>]` on a method parameter (above) covers per-test injection. For class-level fixtures, the same attribute on a primary-constructor parameter:

```csharp
public class EndpointTests(WebApplicationFactory factory)
{
    [Test]
    [ClassDataSource<WebApplicationFactory>(Shared = SharedType.PerTestSession)]
    public async Task Health_Returns200() { /* uses factory */ }
}
```

#### Property injection — `required` properties with data-source attributes

Useful when you have several fixtures, want different sharing scopes per fixture, or want a base class to declare an injection point that subclasses inherit. Each property must be `public required ... { get; init; }` and carry a data-source attribute:

```csharp
public class IntegrationTests
{
    [ClassDataSource<DatabaseFixture>(Shared = SharedType.PerTestSession)]
    public required DatabaseFixture Database { get; init; }

    [ClassDataSource<HttpClientFixture>(Shared = SharedType.PerClass)]
    public required HttpClientFixture Http { get; init; }

    [MethodDataSource(nameof(GetTenantId))]
    public required Guid TenantId { get; init; }

    [Test]
    public async Task FindUser_ReturnsRecord()
    {
        var user = await Database.FindUserAsync(TenantId, "alice");
        await Assert.That(user).IsNotNull();
    }

    public static Guid GetTenantId() => Guid.Parse("11111111-1111-1111-1111-111111111111");
}
```

The `required` keyword is load-bearing — without it, the property may be `null` when the test runs.

#### DI container integration

For a real DI container (Microsoft.Extensions.DependencyInjection, Autofac, etc.), write a one-time `DependencyInjectionDataSourceAttribute<TScope>` and apply it to your test classes. A new scope is created per test:

```csharp
[MicrosoftDI]
public class UserServiceTests(IUserRepository repo, IEmailService email) { /* ... */ }
```

For sharing modes (`SharedType.None` / `PerClass` / `PerTestSession` / `Keyed`), positional `Shared = [...]` arrays for multi-type fixtures, async fixture initialization (`IAsyncInitializer`), and the full `IClassConstructor` / `DependencyInjectionDataSourceAttribute<TScope>` patterns, see [`references/dependency-injection.md`](references/dependency-injection.md).

### Step 6: Manage lifecycle with hooks

TUnit hooks have **four scopes**, set by the argument to `[Before]` / `[After]`:

| Scope | Hook | Method must be | Runs |
|---|---|---|---|
| `Test` | `[Before(Test)]` / `[After(Test)]` | **instance** | Around each test in this class |
| `Class` | `[Before(Class)]` / `[After(Class)]` | static | Once per class |
| `Assembly` | `[Before(Assembly)]` / `[After(Assembly)]` | static | Once per assembly |
| `TestSession` | `[Before(TestSession)]` / `[After(TestSession)]` | static | Once per `dotnet run` invocation |

Use `[BeforeEvery(...)]` / `[AfterEvery(...)]` to run a hook for *every* test/class/assembly in the session, not just the one that owns it — useful for cross-cutting setup (e.g. logging).

```csharp
public class RepositoryTests
{
    private FakeDatabase _db = null!;

    [Before(Test)]
    public async Task SetUp()
    {
        _db = new FakeDatabase();
        await _db.SeedAsync();
    }

    [After(Test)]
    public void TearDown() => _db.Reset();

    [Test]
    public async Task Find_ReturnsSeededUser()
    {
        var user = await _db.FindAsync("alice");
        await Assert.That(user).IsNotNull();
    }
}
```

Cleanup is resilient: all `[After]` hooks and `IAsyncDisposable.DisposeAsync` calls run even if earlier ones throw — exceptions are collected and rethrown as a group, so a failing teardown won't skip later cleanup.

### Step 7: Control parallelism

Tests run in parallel by default. Opt out where it matters.

```csharp
// Single-key constraint: tests sharing a key never run concurrently
[Test]
[NotInParallel("Database")]
public async Task Test1() { }

[Test]
[NotInParallel("Database")]
public async Task Test2() { }

// Multi-key constraint
[Test]
[NotInParallel(["Database", "Registration"])]
public async Task Test3() { }

// Disable globally for an assembly
[assembly: NotInParallel]
```

When you need a *cap* (not a serial constraint), use `[ParallelLimiter<T>]`:

```csharp
[ParallelLimiter<DbConnections>]
public class IntegrationTests
{
    [Test, Repeat(10)]
    public async Task UsesDb() { }
}

public sealed record DbConnections : IParallelLimit
{
    public int Limit => 4;  // at most 4 concurrent
}
```

Tip: `[NotInParallel]` also accepts an `Order` property when you need deterministic sequencing within a constraint group.

### Step 8: Apply timeouts, retries, and skipping

```csharp
// Timeout — fails the test if it runs longer than the limit
[Test]
[Timeout(5000)]
public async Task FetchData_ReturnsWithinFiveSeconds() { }

// Retry — only for genuinely flaky external dependencies (network, etc.).
// Don't use it to paper over race conditions in your own code.
[Test]
[Retry(3)]
public async Task ExternalService_EventuallyResponds() { }

// Repeat — runs the test N additional times (so [Repeat(3)] = 4 runs total)
[Test]
[Repeat(3)]
public async Task IsDeterministic() { }

// Skip — conditionally exclude a test
[Test]
[Skip("Tracked by issue #1234")]
public async Task NotYetImplemented() { }

// Explicit — only runs when explicitly selected (great for slow/destructive tests)
[Test]
[Explicit]
public async Task DropsAndRecreatesDatabase() { }
```

For cancellation inside a test, accept a `CancellationToken` parameter — TUnit will provide one bound to the test's timeout:

```csharp
[Test]
[Timeout(5000)]
public async Task Fetch_RespectsCancellation(CancellationToken ct)
{
    var result = await _client.GetAsync("/", ct);
    await Assert.That(result.IsSuccessStatusCode).IsTrue();
}
```

### Step 9: Manage test ordering and dependencies

TUnit doesn't sort tests by name. When a test must follow another (rare — usually a smell), use `[DependsOn]`:

```csharp
[Test]
public async Task CreateUser() { }

[Test]
[DependsOn(nameof(CreateUser))]
public async Task DeleteUser() { }
```

`[DependsOn]` makes the dependent test wait, and skips it if the dependency failed. Prefer designing tests to be independent — order-dependent tests are a common source of "passes locally, fails in CI" flakiness.

## References

For depth on topics this SKILL.md only summarizes, read the file relevant to the user's task:

| Topic | File |
|---|---|
| Full assertion library — every `.That(...).Method(...)` form, exception inspection, custom assertions, F# syntax | [`references/assertions-catalog.md`](references/assertions-catalog.md) |
| Property injection rules, `[ClassDataSource<T>]` sharing modes, multi-fixture positional arrays, `IAsyncInitializer`, `IClassConstructor`, plugging in Microsoft.Extensions.DependencyInjection | [`references/dependency-injection.md`](references/dependency-injection.md) |

Read the reference only when the user's question requires that depth. The SKILL.md content above covers the everyday surface.

## Validation

- [ ] Test project uses `<OutputType>Exe</OutputType>` and references `TUnit`
- [ ] Tests are run with `dotnet run`, not `dotnet test`
- [ ] No `[TestClass]` (TUnit doesn't need it)
- [ ] All assertions use `Assert.That(...)` and are **awaited**
- [ ] Test method names follow `MethodUnderTest_Scenario_ExpectedBehavior`
- [ ] Data sources use `IEnumerable<Func<T>>` (not `IEnumerable<T>` directly) so each row gets a fresh instance
- [ ] Property-injected fixtures are declared `public required T { get; init; }` with a data-source attribute
- [ ] Parallel-incompatible tests carry `[NotInParallel(...)]` with a meaningful constraint key
- [ ] `[Retry]` is only on tests with genuine external flakiness, not race conditions
- [ ] `CancellationToken` parameters are forwarded into async calls in tests with `[Timeout]`

## Common Pitfalls

| Pitfall | Solution |
|---------|----------|
| Forgetting `await` on `Assert.That(...)` — test passes silently | Always `await`. Treat the analyzer warning as a blocker, not a hint. |
| Using `[TestClass]` (carried over from MSTest) | Remove it — TUnit doesn't need it; it's a no-op at best, a source of confusion at worst. |
| Storing fixture state in instance fields and expecting it to persist between tests | Each test gets a new instance. Use `[Before(Test)]` to re-init, `[ClassDataSource<T>]` for shared expensive resources, or `static` for genuinely shared state. |
| `IEnumerable<T>` from `[MethodDataSource]` instead of `IEnumerable<Func<T>>` | Wrap each row in `Func<T>` so mutations in one test don't bleed into the next. |
| `dotnet test` fails with cryptic error on .NET 10 | Use `dotnet run --project ...` instead. Microsoft.Testing.Platform projects are standalone executables. |
| Tests fail intermittently after introducing a `static` cache or `IClassFixture`-style sharing | TUnit runs in parallel by default. Either add `[NotInParallel("YourKey")]` to the affected tests or use `[ClassDataSource<T>(Shared = SharedType.PerClass)]` with proper isolation. |
| `[Retry(3)]` masking a race condition rather than a flaky network call | Diagnose the actual failure mode. `[Retry]` on logic bugs makes the suite slower and the bug harder to find. |
| Hook on `[Before(Class)]` is an instance method | `[Before(Class)]`, `[Before(Assembly)]`, `[Before(TestSession)]`, `[Before(TestDiscovery)]` all require **static** methods. Only `[Before(Test)]` is instance-scoped. |
| Property-injected fixture is `null` at runtime | Property must be `public required T { get; init; }` with a data-source attribute. Missing `required` is the usual culprit — without it, TUnit's source generator skips the wiring. |
| Expecting `[DependsOn]` to enforce order across `[ParallelLimiter]` groups | TUnit doesn't guarantee ordering when dependent tests live in different parallel groups. Keep `[DependsOn]` chains within the same class and limiter scope. |
| Using `Thread.Sleep` to "wait" in async tests | Use `await Task.Delay(..., cancellationToken)` so the test still respects `[Timeout]` and cancellation. |
