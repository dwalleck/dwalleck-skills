---
inclusion: always
---

# .NET Correctness

## Exceptions & validation
- Validate public and externally supplied input at entry points. Throw the most specific exception with an actionable message (parameter via `nameof`, plus the offending value/key/path). Never throw bare `Exception` or an exception with no message.
- Use guard helpers: `ArgumentNullException.ThrowIfNull`, `ArgumentException.ThrowIfNullOrEmpty`/`ThrowIfNullOrWhiteSpace`, `ArgumentOutOfRangeException.ThrowIfNegative`/`ThrowIfGreaterThan`/…, `ObjectDisposedException.ThrowIf`.
- Internal invariants (callers you control): `Debug.Assert`, not exceptions. Paths reachable at runtime must throw, not assert.
- `throw new UnreachableException()` for the impossible `default` arm of an exhaustive switch.
- `Try*` methods return `false` only for the expected failure; they still throw for invalid arguments and unexpected errors. Initialize `out` parameters on every path.
- Don't swallow exceptions (`catch { }`, `catch { return null; }`) unless the exception is a known, expected, recoverable condition. Catch specific types; catch `Exception` only at top-level boundaries, and log it there.
- Don't expose internal type names, private field names, or stack traces in user-facing messages.

## Async & cancellation
- Async all the way: no `.Result`, `.Wait()`, or `GetAwaiter().GetResult()` over async work.
- Accept and flow `CancellationToken` through async I/O and long-running calls.
- `ConfigureAwait(false)` in library code; unnecessary in ASP.NET Core app code (no synchronization context).
- Fire-and-forget work must observe its exceptions. No `async void` except event handlers.
- `OperationCanceledException` from a requested cancellation is normal flow, not an error to log.
- Use `IAsyncDisposable` / `await using` when cleanup is async; don't block in teardown.

## Resources & disposal
- Make ownership explicit: whoever creates a stream/handle/subscription/timer disposes it — on success, failure, and cancellation paths. Document when ownership transfers.
- Sealed classes need only a simple `Dispose()`, not the full dispose pattern. Avoid finalizers.
- Elapsed time and timeouts: `Stopwatch.GetElapsedTime`, `Environment.TickCount64`, or `TimeProvider` — not `DateTime.Now` or `Environment.TickCount` (overflows).

## Thread safety
- Shared mutable state needs a lock, `Interlocked`, `Volatile`, an immutable snapshot, or a concurrent collection. `??=` is not thread-safe.
- Don't hold a lock while invoking callbacks, awaiting, or resolving services.
- Don't dispose or null a shared `CancellationTokenSource` or cache while other work may still observe it; cancel first, then coordinate completion.
- Singleton and static-state rules live in `dotnet-service-lifetimes`.

## Strings, culture, paths
- Choose string comparison explicitly: `Ordinal`/`OrdinalIgnoreCase` for identifiers, keys, paths, headers, and protocol values; culture-aware only for text shown to users. Pass a comparer to string-keyed dictionaries/sets when ordinal case-sensitive isn't the contract.
- Format and parse persisted/protocol data with `CultureInfo.InvariantCulture`.
- `Path.Combine`/`Path.Join`, never hard-coded separators. File names are case-sensitive on Linux — match casing exactly in code and project files.
- Files can vanish, be locked, or be replaced between an existence check and use; handle the I/O exception rather than relying on `File.Exists`.
- `AppContext.BaseDirectory`, not `Assembly.Location` or the current working directory, to locate files shipped with the app.

## Security
- Treat request data, configuration values, deserialized data, and file paths as untrusted. Normalize paths and check them against an allowed root before use (traversal, symlinks).
- Build process invocations with `ProcessStartInfo.ArgumentList`, never concatenated command strings. Parameterize queries.
- Never log, or put in exception messages or responses: secrets, tokens, connection strings, credentials, PII, request/response bodies.
- Compare secrets, signatures, and API keys with `CryptographicOperations.FixedTimeEquals`.
- Security-sensitive defaults fail closed.

## Equality
- Structs used as dictionary/set keys implement `IEquatable<T>` and `GetHashCode` (avoids boxing and reflection-based equality).
