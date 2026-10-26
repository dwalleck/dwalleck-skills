---
inclusion: always
---

# .NET Tests

Skills: `tdd` to build test-first, `run-tests` for the exact test command,
`test-value-evidence` for red/green proof, `test-anti-patterns` to audit a suite,
`testability-obstacle` for time/file/environment seams.

## What to test
- Every bug fix and behavior change gets a regression test that fails without the change for the intended reason and passes with it (see `dotnet-workflow`).
- Assert observable behavior — return values, responses, exceptions, logs, persisted state — not implementation details. Tests should survive a behavior-preserving refactor.
- Prefer a scenario test through the real component over exhaustive unit tests of internals. A test that injects the event or callback directly only proves the downstream reaction.
- Cover edge cases: null/empty, boundaries, error paths, both values of boolean options, and culture-sensitive text where strings are parsed or compared.
- Pick inputs that can't pass by accident: a transformation test needs an input that must change, and the assertion checks the exact expected value — never just `actual != oldValue` or "not null".
- Don't add product hooks or test-only interfaces unless the scenario is critical and otherwise unreachable.

## How to write
- Match the project's framework, naming, fixtures, and folder layout. Add to an existing test class when one covers the type; name new files after their class (`FooTests` for `Foo`).
- Parameterize near-duplicate tests (`[Theory]`/`[DataRow]`/`[Arguments]`, per framework) instead of copy-pasting. Separate tests for genuinely different boundaries are fine.
- Assert exact values. Assert a single element directly rather than checking a count and then indexing.
- Exceptions: assert the specific type (and message or parameter name where it matters) with the framework's throws assertion. Never `Throws<Exception>`, and never `try { …; Assert.Fail(); } catch { }`.
- Await every async assertion (`await Assert.ThrowsAsync(...)`, TUnit's `await Assert.That(...)`); an un-awaited assertion passes silently. Async tests return `Task`.
- Keep arrange/act/assert phases distinct, but don't write `// Arrange` / `// Act` / `// Assert` comments. No XML docs on tests.
- Raw string literals (`"""..."""`) for multi-line input.
- Deterministic: no sleep-based synchronization (use `TaskCompletionSource`, `FakeTimeProvider`); no wall-clock reads, hard-coded ports, or machine paths; no dependence on test order; explicit culture; seeded randomness.
- Isolate or restore process-wide state (env vars, statics, culture). Dispose what tests create; temp paths are unique and cleaned up.
- Platform-specific tests use the framework's skip mechanism, not an early `return`.
- Fake secrets use an obvious placeholder (`PLACEHOLDER`).

## Flakiness
- Don't add tests known to be flaky. Fix the nondeterminism, or delete a low-value flaky test, rather than adding retries.
- Don't leave tests disabled that weren't before. If a quarantine is unavoidable, record why with an issue link.
