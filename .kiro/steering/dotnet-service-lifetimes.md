---
inclusion: always
---

# .NET Service Lifetimes, Shared State & HttpClient

For any long-lived .NET process that serves many requests from the same objects:
ASP.NET Core, worker services, and warm AWS Lambda execution environments (singletons
and statics survive between invocations).

## Dependency injection
- Never inject a scoped service (including `DbContext` and `IOptionsSnapshot<T>`) into a singleton — a captive dependency. Keep `ValidateScopes`/`ValidateOnBuild` on (the default in Development).
- Library and extension registration methods use `TryAdd*`/`TryAddEnumerable` so user registrations win and repeated calls are idempotent.
- For single-service resolution the last `Add*` registration wins; order matters.
- Transient `IDisposable`s resolved from the root provider are held until the container is disposed (a leak). Prefer scoped, or a factory whose result the caller disposes.
- Inject the specific dependency, not `IServiceProvider` (no service locator). In singletons, create scopes with `IServiceScopeFactory` and dispose them.
- Decorators sharing an interface must not resolve themselves recursively.

## Singletons & static state
- Singletons and statics serve many requests — concurrently in ASP.NET Core, and across warm invocations in Lambda. Make them thread-safe and keep per-request data out of them.
- Never store request, user, or tenant data in a singleton field or a static; it leaks into the next request.
- Shared mutable state needs a lock, `Interlocked`, an immutable snapshot, or a concurrent collection. `??=` lazy initialization isn't thread-safe; use `Lazy<T>` or `LazyInitializer`.
- Prefer DI singletons over mutable statics so tests can replace them; two hosts or tests in one process must not interfere.
- Don't dispose or null shared state while other work may still be using it.

## HttpClient & service clients
- Use `IHttpClientFactory` (named or typed clients), or one long-lived `HttpClient` with `SocketsHttpHandler.PooledConnectionLifetime` set so DNS changes are picked up. Never `new HttpClient()` per request — it exhausts sockets and discards warm connections.
- Typed clients are transient. Don't capture one in a singleton (it pins the handler and defeats rotation); inject `IHttpClientFactory` there instead.
- Create AWS SDK and other service clients once, as singletons, and reuse them; they're thread-safe and expensive to construct.
- Set explicit timeouts and flow the caller's `CancellationToken` to every request.
- Don't send credentials before a server challenge unless the API requires it.
