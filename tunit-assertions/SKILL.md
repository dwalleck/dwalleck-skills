---
name: tunit-assertions
description: "Chooses, writes, reviews and fixes TUnit assertions (await Assert.That(...)) using behaviour verified against TUnit 1.77.0. USE FOR: which TUnit assertion to use; reviewing or grading the assertions in TUnit tests; assertions that pass when they should fail; CS1061 or CS0618 on assertion methods (HasCount, HasLength, ThrowsAsync, HasMember, IsCancelled); TUnitAssertions0001-0005, 0014, 0015 diagnostics; MixedAndOrAssertionsException; IsEqualTo vs IsEquivalentTo on collections or objects; Throws, WithMessage, WithMessageMatching, WithParameterName, WithInnerException; Within tolerance; IsTypeOf vs IsAssignableTo; Assert.Multiple; Member; Satisfies and Because; custom assertions with GenerateAssertion. DO NOT USE FOR: TUnit attributes, data sources, hooks, parallelism or project setup (writing-tunit-tests); running tests (run-tests); language-neutral assertion depth metrics (assertion-quality); whole-suite smell audits (test-anti-patterns); xUnit, NUnit or MSTest assertions."
---

# TUnit Assertions

Pick the TUnit assertion that fails for the right reason with a useful message, and find the ones in existing tests that cannot fail, fail for the wrong reason, or will not compile. Every behavioural claim below was observed by running `scripts/probe` against TUnit 1.77.0 (the newest release on 2026-10-31) and 1.65.63, with identical outcomes; `references/probe-baseline.txt` holds the evidence line for each claim (ids such as `B04a` are cited inline).

## When to Use

- Writing assertions in a TUnit test, or choosing between two assertion forms.
- Reviewing, grading or fixing the assertions in TUnit test files or a TUnit diff.
- A TUnit assertion does not compile, is obsolete, raises a `TUnitAssertions*` diagnostic, or passes when the code is wrong.

## When Not to Use

- Test structure: `[Test]`, `[Arguments]`, data sources, hooks, parallelism, project setup. Use `writing-tunit-tests`.
- Running or filtering tests. Use `run-tests`.
- Framework-neutral assertion depth or variety metrics. Use `assertion-quality`.
- Tests in xUnit, NUnit or MSTest, even in a solution that also has TUnit projects.

## Inputs

| Input | Required | Description |
|-------|----------|-------------|
| Test code or diff | Yes | The TUnit tests to write, review or fix. |
| Mode | No | `write`, `review` (report only) or `fix` (edit, build, run). Infer from the request; reviews never edit. |

Discover the TUnit version yourself from the test project's `PackageReference Include="TUnit"` or `Directory.Packages.props`. Do not ask for it.

## Workflow

### Step 1: Check the version

Read the TUnit version. If it is older than 1.65.63 or newer than 1.77.0 and a finding depends on a behaviour in the tables below, run the probe once:

```powershell
pwsh -NoProfile -File scripts/Invoke-AssertionProbe.ps1 -Version <version> -WorkDir <scratch dir outside the skill>
```

It prints each probe outcome and a `Differences` list against the baseline. Treat a differing probe as "claim does not hold for this version" and say so in the report. If the probe build or run fails, report that; do not fall back to the tables as if they were verified.

### Step 2: Apply the decision rules

These are the choices an unaided model gets wrong. They hold for 1.65.63 and 1.77.0.

| Situation | Use | Not | Why (probe) |
|---|---|---|---|
| Compare two collections by contents | `IsEquivalentTo(expected)`; add `CollectionOrdering.Matching` when order matters | `IsEqualTo` | `IsEqualTo` on `List`/arrays is reference equality and fails on equal contents (B04a, B04b). `IsEquivalentTo` ignores order by default (B17a) and counts duplicates (B17c). |
| Compare objects whose type does not override `Equals` | `IsEquivalentTo(expected)`; `.IgnoringMember(nameof(X.Prop))` to skip a member | `IsEqualTo`, or one assertion per property | `IsEquivalentTo` compares members deeply and names the failing path, e.g. `Property Lines.[0].Age did not match` (B05c). It also accepts an anonymous object as the expected shape (C09). `IsEqualTo` is reference equality there (B06). Records are fine with `IsEqualTo` (B31). |
| Find an object without `Equals` in a collection | `Contains(x => x.Id == id)` (returns the item) | `Contains(new Thing { ... })` | Item `Contains` uses `Equals` and fails on an equal-valued copy (B32). |
| Assert a count | `Count().IsEqualTo(n)`; filtered: `Count(x => x.IsGreaterThan(1)).IsEqualTo(n)` | `HasCount(n)` (obsolete, CS0618); `Count(x => x > 1)` (CS0019) | `Count(...)` takes an assertion builder, not a `bool` predicate (B16). |
| Assert string length | `Length().IsEqualTo(n)` / `Length().IsGreaterThan(n)` | `HasLength()` / `HasLength(n)` (obsolete); `HasLength().GreaterThan(n)` (CS1061) | |
| Floating point, `decimal`, dates | `IsEqualTo(x).Within(tolerance)`; `Within(TimeSpan)` for `DateTime` | Plain `IsEqualTo` on computed doubles | `0.1 + 0.2` vs `0.3` fails without `Within` (B14a, B14b, B23, B33). |
| Expect an exception | `Throws<SpecificException>()`; `ThrowsExactly<T>()` when a subclass would be a bug | `Throws<Exception>()` | `Throws<T>` accepts subclasses (B09a), so `Throws<Exception>` passes on a `NullReferenceException` (C08). |
| Async code that throws | `Assert.That(async () => await M()).Throws<T>()`; `Assert.That(() => M())` and `Assert.That(task)` also work | `.ThrowsAsync<T>()` on the chain (CS1061) | B18, B19a, B19b. The static `Assert.ThrowsAsync<T>(Func<Task>)` exists if a returned exception is all you need. |
| Exception message | `WithMessage("exact")`, `WithMessageContaining("part")`, `WithMessageMatching("wild*card")` | `WithMessage("*part*")` | `WithMessage` is exact; `*` is literal there (B08a, B08b). `ArgumentException` messages end with ` (Parameter 'name')`, so an exact `WithMessage` on one fails (B08c): use `WithParameterName("name")` plus `WithMessageContaining`. |
| Inner exception | `.WithInnerException<FormatException>()` | `.WithInnerException().Throws<T>()` (CS1929) | B34 |
| Exception properties | `var ex = await Assert.That(...).Throws<T>();` then assert on `ex!.Prop` | `try`/`catch` with `Assert.Fail` | `Throws<T>` returns `T?` (B22). |
| Exact runtime type | `Assert.That(x.GetType()).IsEqualTo(typeof(Dog))` | `IsTypeOf<Dog>()` | Despite the docs, `IsTypeOf<Animal>()` passes on a `Dog` (B15a, C01) and `IsTypeOf<object>()` passes on a string (C04b): it is an `is` check. `IsNotTypeOf<Animal>()` also passes on a `Dog` (C03). Use `IsTypeOf<T>()` only to narrow and capture: `var dog = await Assert.That(x).IsTypeOf<Dog>();` returns `Dog?`. |
| Several facts about one result | `using (Assert.Multiple()) { ... }` with only assertions inside | Arrange or act inside the scope | All failures are reported together (B11, B30). A non-assertion exception thrown inside the scope after a failure is dropped from the report (C11). |
| Custom condition | `Satisfies(v => ...)` then `.Because("reason")` | `Satisfies(pred, "reason")` | The second parameter is a `CallerArgumentExpression`: the message becomes `Expected to satisfy must be even` and TUnitAssertions0003 warns (B20). `.Because` appends `, because ...` (B21, C19). |
| Boolean derived from the subject | The specific assertion (`IsNotEmpty`, `Contains`, `IsNull`, `IsGreaterThan`) | `Assert.That(list.Count > 0).IsTrue()` | `IsTrue` reports only `Expected to be true but found False` (B12a); `IsNotEmpty` reports `received empty collection` (B12b). |
| Alternatives | `.Or` only, or `.And` only, per chain | `.And` and `.Or` in one chain | Mixed on a value chain throws `MixedAndOrAssertionsException` at run time (B02). On `Member` chains it does not throw and evaluates as `(A and B) or C` (B03, C13). TUnitAssertions0001 warns in both cases. Split the chain or assert a single boolean. |
| Regex with options | `Matches(new Regex(pattern, RegexOptions.IgnoreCase))` or inline `(?i)`, `(?m)` | `Matches(pattern).IgnoringCase()` or `.WithOptions(...)` | Both modifiers compile and are ignored: `Matches("^hello").IgnoringCase()` fails on `Hello World`, and `.WithOptions(RegexOptions.Multiline)` does not enable multiline (D01, D02, D05). A `Regex` object or inline option works (D03, D04). `IgnoringCase()` on `Contains` and `IsEqualTo` does work (B35). |
| Polling for eventual state | `Assert.That(() => flag).WaitsFor(f => f.IsTrue(), timeout: ...)` | `Task.Delay` then assert | B27 |
| `Task<T>` result | `await Assert.That(GetAsync()).IsEqualTo(42)` or await first | | The task is awaited and its result asserted (C05, C07). |

Names that do not exist (CS1061 or CS1929 on 1.77.0): `HasMember`, `HasProperty`, `IsCancelled` (use `IsCanceled`), `IsSequenceEqualTo`, `IsStructurallyEqualTo`, `ContainsAll`, collection `IsSubsetOf`, `IsOnOrAfter`/`IsOnOrBefore` (`IsAfter`/`IsBefore` exist), `WithExclusiveBounds`, `ContainsKey(k).WithValue(v)` (use `ContainsKeyWithValue(k, v)`), and the old `IValueSource`/`IInvokableValueAssertionBuilder` extension types. `references/api-reference.md` lists what does exist, with the exact forms.

### Step 3: Write mode

Write `await Assert.That(actual).<assertion>(expected)` with the rules above. Assert exact expected values, not "not null" or "not equal to the old value". Then build: the TUnit analyzers report misuse at compile time (table in Step 4). Run the tests with `run-tests` and confirm the new tests ran.

### Step 4: Review mode

1. List the TUnit test files in scope. Skip files that do not import TUnit.
2. Build the test project once and collect `TUnitAssertions*`, CS0618 and CS1061 diagnostics on assertion lines. These are findings with no judgment needed.

   | Id | Default | Meaning |
   |---|---|---|
   | TUnitAssertions0001 | warning | `.And` and `.Or` mixed in one chain |
   | TUnitAssertions0002 | error | Assertion not awaited. `_ = Assert.That(...)` still raises it; a `#pragma` or `NoWarn` that hides it makes the assertion never run (B01) |
   | TUnitAssertions0003 | warning | A value was passed to a `CallerArgumentExpression` parameter (usually `Satisfies(pred, "text")`) |
   | TUnitAssertions0004 | error | `Assert.Multiple()` without `using` |
   | TUnitAssertions0005 | warning | `Assert.That(...)` on a constant: the test checks nothing about the code |
   | TUnitAssertions0014 | warning | `IsEqualTo(null)`; use `IsNull()` |
   | TUnitAssertions0015 | warning | `IsEqualTo(true/false)`; use `IsTrue()`/`IsFalse()` |

3. Search the files for the patterns the compiler does not catch:

   | Pattern (regex) | Check |
   |---|---|
   | `Matches\([^)]*\)\.(IgnoringCase\|WithOptions)` | The modifier is ignored: the assertion checks the pattern as written. |
   | `Throws<Exception>\(` | Can the specific type be named? |
   | `IsTypeOf<` | Is exactness intended? Then it is a false pass for subclasses. |
   | `IsNotTypeOf<` | Passes for subclasses of the named type; is that intended? |
   | `WithMessage\("[^"]*\*` | Wildcard in an exact-match assertion: fails or was never run. |
   | `WithMessage\(` after `Throws<Argument` | Exact match against a message that ends in `(Parameter '...')`. |
   | `\.IsEqualTo\(` whose subject is a collection or a class without `Equals` | Reference equality where contents were meant. |
   | `\)\.Is(True\|False)\(\)` with `==`, `!=`, `<`, `>`, `.Count`, `.Any(`, `.Contains(`, `is null` inside `That(...)` | Weak diagnostics; name the specific assertion. |
   | `IsEqualTo\(` on `double`/`float` results without `Within` | Flaky or wrong. |
   | `Assert\.Multiple` | Non-assertion statements inside the scope. |
   | `catch` or `Assert\.Fail` in a test | Hand-rolled exception assertion. |
   | `IsNotNull\(\)` as the only assertion on a result | Proves almost nothing; assert the value. |

4. Classify each finding:
   - **Cannot fail**: the assertion passes for wrong code (hidden TUnitAssertions0002, constant subject, `IsTypeOf` meant as exact, `Throws<Exception>`, sole `IsNotNull`).
   - **Wrong check**: it fails for correct code or checks a different property (`IsEqualTo` on collections, wildcard `WithMessage`, exact message on `ArgumentException`, missing `Within`, `Matches(...).IgnoringCase()`).
   - **Will break**: obsolete or nonexistent API.
   - **Weak message**: correct but the failure output will not say what went wrong (`IsTrue` on a derived boolean, `Satisfies` with a string argument).

Output contract, scaled to the input (one table, no dashboard for a handful of tests):

```
TUnit <version> (assertion behaviour verified | probe differences: <ids>)
| File:line | Current | Category | Problem | Replacement |
Verdict: <n> cannot-fail, <n> wrong-check, <n> will-break, <n> weak-message
```

If there are no findings, say so in one line with the files reviewed. Do not list style preferences as findings.

### Step 5: Fix mode

Apply the replacements from Step 4, build with zero new warnings, and run the affected tests with `run-tests`. A strengthened assertion that now fails has found a real defect or a wrong expectation: report it with the failure message. Never loosen the assertion back to make the run green, and never add `#pragma`/`NoWarn` for a `TUnitAssertions*` diagnostic.

## Validation

- [ ] The TUnit version was read from the project, and the probe was run if it is outside 1.65.63 to 1.77.0 and a finding depends on it.
- [ ] Every replacement compiles; the build shows no new `TUnitAssertions*`, CS0618 or CS1061 on assertion lines.
- [ ] Fix mode: the affected tests ran (counts checked) and any newly failing test is reported, not suppressed.
- [ ] Review mode: each finding has a category and a concrete replacement; nothing was edited.

## Common Pitfalls

| Pitfall | Solution |
|---|---|
| Trusting tunit.dev examples for type checks and regex options | The docs call `IsTypeOf` exact and show `Matches(...).IgnoringCase()`; 1.65.63 and 1.77.0 behave otherwise (B15a, D01). Compare `GetType()` for exactness; put regex options in the pattern or a `Regex`. |
| Copying examples that use `Satisfies(pred, "message")` | Use `.Because("message")`. |
| Copying `HasCount`, `HasLength().GreaterThan`, `HasMember`, `.ThrowsAsync<T>()` from older guides | Use the forms in Step 2; check `references/api-reference.md`. |
| Rewriting `IsNotNull().And.IsNotEmpty()` chains into `Assert.Multiple` for taste | Chains and scopes are both fine; change only what a rule above names. |
| Treating `IsEqualTo` failure on equal collections as a product bug | The message says `same contents, different reference - use IsEquivalentTo` (B04a); fix the test. |
| Reporting probe results as verified after the probe failed to build | Report the build failure and the missing API instead. |
