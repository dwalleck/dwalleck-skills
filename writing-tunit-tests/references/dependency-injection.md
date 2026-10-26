# Dependency Injection & Property Injection in TUnit

Reference for getting test fixtures and dependencies into a TUnit test class. Three approaches, picked by what you need:

| Approach | Use when |
|---|---|
| **Constructor injection** via `[ClassDataSource<T>]` | Fixture is shared/expensive (web factory, DB container) and the class needs it as a parameter |
| **Property injection** via `[ClassDataSource<T>]` / `[MethodDataSource(...)]` on `required` properties | You want fixtures available without threading them through every constructor, or you want different sharing scopes per fixture |
| **`IClassConstructor`** or `DependencyInjectionDataSourceAttribute<TScope>` | You want to plug in a real DI container (Microsoft.Extensions.DependencyInjection, Autofac, etc.) and have the framework resolve test classes |

All three are AOT-compatible.

## Constructor injection (basic)

`[ClassDataSource<T>]` on a test method passes the fixture in as a parameter. For test-class–level fixtures, put the attribute on a constructor parameter via the test's primary constructor:

```csharp
public class EndpointTests(WebApplicationFactory factory)
{
    [Test]
    [ClassDataSource<WebApplicationFactory>(Shared = SharedType.PerTestSession)]
    public async Task Health_Returns200()
    {
        using var client = factory.CreateClient();
        var res = await client.GetAsync("/health");
        await Assert.That((int)res.StatusCode).IsEqualTo(200);
    }
}

public sealed record WebApplicationFactory : IAsyncInitializer, IAsyncDisposable
{
    public async Task InitializeAsync() => await StartServer();
    public async ValueTask DisposeAsync() => await StopServer();
}
```

## Property injection

Property injection lets a fixture flow into the test class without going through the constructor. Each injectable property must:

1. Be `public`
2. Have an `init` accessor (`{ get; init; }`)
3. Be marked `required`
4. Carry a data-source attribute (`[ClassDataSource<T>]`, `[MethodDataSource(...)]`, or a custom `DataSourceGeneratorAttribute`)

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

The `required` modifier matters: it tells the C# compiler the property must be set during object initialization, which is exactly when TUnit sets it via the source-generated wiring. Without `required`, the property may be uninitialized when the test runs.

### Property injection vs. constructor injection — when to choose which

- **Constructor**: when there's exactly one fixture (or a small fixed set), and the dependency is genuinely a parameter of the test class.
- **Property**: when you have several fixtures, want different sharing scopes per fixture, or want subclasses/base classes to share an injection point without restating constructor signatures.

Property injection composes especially well with shared base classes:

```csharp
public abstract class IntegrationTestBase
{
    [ClassDataSource<DatabaseFixture>(Shared = SharedType.PerTestSession)]
    public required DatabaseFixture Database { get; init; }
}

public class UserRepositoryTests : IntegrationTestBase
{
    [Test]
    public async Task Find_ReturnsSeededUser() { /* uses Database */ }
}
```

## Async fixture initialization

Fixtures that need async setup/teardown implement `IAsyncInitializer` and `IAsyncDisposable`. TUnit calls `InitializeAsync` after constructing the fixture and `DisposeAsync` when the fixture's lifetime ends (per the `Shared` setting).

```csharp
public sealed class DatabaseFixture : IAsyncInitializer, IAsyncDisposable
{
    public string ConnectionString { get; private set; } = "";

    public async Task InitializeAsync()
    {
        ConnectionString = await ProvisionDatabaseAsync();
    }

    public async ValueTask DisposeAsync()
    {
        await TearDownDatabaseAsync(ConnectionString);
    }
}
```

There's also `IAsyncDiscoveryInitializer` for fixtures that need to run during *test discovery* (before TUnit enumerates tests) — typically only relevant when an `InstanceMethodDataSource` returns dynamically-loaded data. Use `IAsyncInitializer` for almost everything else.

Initialization is **depth-first**: nested fixtures initialize before their containers. So if `WebApplicationFactory` depends on `DatabaseFixture`, the database initializes first.

## Sharing modes (`SharedType`)

`[ClassDataSource<T>(Shared = ...)]` accepts:

| Value | Lifetime | Use for |
|---|---|---|
| `SharedType.None` | Fresh per test | Lightweight isolated state |
| `SharedType.PerClass` | One per test class, all tests in the class share | Mid-cost fixtures (in-memory DB) |
| `SharedType.PerTestSession` | One per `dotnet run`, shared across all tests | Expensive fixtures (web factory, real DB container) |
| `SharedType.Keyed` | Shared by string key | Multiple distinct shared instances of the same type |

Multi-fixture form lets you mix sharing strategies in one declaration:

```csharp
[ClassDataSource<Cache, Db, Http>(
    Shared = [SharedType.PerTestSession, SharedType.PerClass, SharedType.None])]
public class MyTests(Cache cache, Db db, Http http) { }
```

The `Shared` array is **positional** — index N matches type parameter N.

For `SharedType.Keyed`, supply a `Keys` array — same positional rule:

```csharp
[ClassDataSource<Db, Db>(
    Shared = [SharedType.Keyed, SharedType.Keyed],
    Keys = ["primary", "replica"])]
public class ReplicationTests(Db primary, Db replica) { }
```

## Plugging in Microsoft.Extensions.DependencyInjection (or any DI container)

When you want test classes constructed via a real DI container — with full scope/lifetime semantics — write a `DependencyInjectionDataSourceAttribute<TScope>` once and apply it to test classes. TUnit calls into your container to resolve constructor parameters.

```csharp
public sealed class MicrosoftDIAttribute : DependencyInjectionDataSourceAttribute<IServiceScope>
{
    private static readonly IServiceProvider Provider = BuildProvider();

    public override IServiceScope CreateScope(DataGeneratorMetadata _)
        => Provider.CreateScope();

    public override object? Create(IServiceScope scope, Type type)
        => scope.ServiceProvider.GetService(type);

    private static IServiceProvider BuildProvider() => new ServiceCollection()
        .AddSingleton<IUserRepository, UserRepository>()
        .AddTransient<IEmailService, FakeEmailService>()
        .BuildServiceProvider();
}

[MicrosoftDI]
public class UserServiceTests(IUserRepository repo, IEmailService email)
{
    [Test]
    public async Task CreateUser_SendsWelcomeEmail()
    {
        var service = new UserService(repo, email);
        await service.CreateAsync("alice@example.com");
    }
}
```

A new scope is created per test, so scoped services behave correctly and disposables are cleaned up at end-of-test.

## `IClassConstructor` for manual construction control

If you don't need full DI but want custom `Activator.CreateInstance` logic (e.g. picking a non-default constructor, post-construction wiring), implement `IClassConstructor`:

```csharp
public sealed class CustomConstructor : IClassConstructor
{
    public Task<object> Create(
        [DynamicallyAccessedMembers(DynamicallyAccessedMemberTypes.PublicConstructors)] Type type,
        ClassConstructorMetadata metadata)
    {
        return Task.FromResult(Activator.CreateInstance(type)!);
    }
}

[ClassConstructor<CustomConstructor>]
public class MyTestClass(SomeDependency dep)
{
    [Test]
    public async Task MyTest() { }
}
```

The `DynamicallyAccessedMembers` attribute on the `Type` parameter is required for AOT compatibility — it tells the trimmer to keep the test class's public constructors.

## Choosing between the three approaches

```
Need a real DI container with scopes?
  → DependencyInjectionDataSourceAttribute<TScope>

Need to customize how the test class is constructed (which ctor, custom logic)?
  → IClassConstructor

Just need a fixture or two passed in?
  → [ClassDataSource<T>] on constructor params or required properties.
```

In practice: most projects start with `[ClassDataSource<T>]` and only graduate to a DI attribute when constructor wiring genuinely becomes painful.

## Common pitfalls

| Pitfall | Solution |
|---|---|
| Property injected as `null` at runtime | Property must be `public required ... { get; init; }`. Missing `required` is the usual culprit. |
| Fixture's `InitializeAsync` never runs | The fixture type must implement `IAsyncInitializer`. Check the interface, not just a method name. |
| Shared fixture state leaks between tests | `SharedType.PerTestSession` shares one instance across the whole run. If the fixture is stateful, either reset it in `[Before(Test)]` or drop to `SharedType.PerClass` / `None`. |
| `[ClassConstructor<T>]` test class fails to construct under AOT | Add `DynamicallyAccessedMemberTypes.PublicConstructors` (or the constructors you need) to the `Type` parameter so the trimmer keeps them. |
| Multi-fixture `Shared = [...]` array length mismatch | The `Shared` and `Keys` arrays are positional — they must have exactly one entry per type parameter. |
