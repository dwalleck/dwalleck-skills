---
inclusion: always
---

# .NET on AWS Lambda

Lambda reuses an execution environment for many invocations, freezes it between them,
and recycles it without notice. Singletons and statics persist across warm invocations;
see `dotnet-service-lifetimes`.

- Await all work before returning. The environment freezes once the response is returned, so fire-and-forget tasks, `BackgroundService`s, timers, and buffered logs/telemetry may never run, or may resume during a later invocation. Flush telemetry before returning.
- Respect the invocation timeout: create a `CancellationTokenSource` from `ILambdaContext.RemainingTime` minus a safety margin, and pass its token to all I/O. Set downstream HTTP/SDK timeouts below the function timeout.
- Make handlers idempotent. Async invocations, event sources (SQS, Kinesis, DynamoDB Streams), and retries can deliver the same event more than once. Deduplicate on a stable key (message ID or idempotency key); for batches, report partial batch failures instead of failing the whole batch.
- Only `/tmp` is writable, and nothing on disk survives a new environment. Never use it as a durable store, and clean up per-invocation files so warm reuse doesn't fill it or leak data between requests.
- Load secrets from environment variables, Secrets Manager, or Parameter Store — never `appsettings.json` or source. Fetch them once at init, cache with a refresh interval, and never log them.
- Do one-time expensive setup (DI container, SDK clients, configuration, secrets) during init, not per invocation.
