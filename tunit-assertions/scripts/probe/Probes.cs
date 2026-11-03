using TUnit.Assertions.Enums;

[assembly: NotInParallel]

namespace AssertionProbe;

public class Animal
{
    public string Name { get; set; } = "";
}

public sealed class Dog : Animal
{
}

public sealed class Thing
{
    public string Name { get; set; } = "";
    public int Age { get; set; }
}

public sealed class Order
{
    public int Id { get; set; }
    public List<Thing> Lines { get; set; } = [];
}

internal static class Recorder
{
    private static readonly object s_lock = new();
    private static readonly string s_path = Path.Combine(AppContext.BaseDirectory, "probe-results.txt");

    public static async Task Run(string name, Func<Task> probe)
    {
        string outcome;
        try
        {
            await probe();
            outcome = "PASS";
        }
        catch (Exception ex)
        {
            string message = ex.Message.Replace("\r", "").Replace("\n", " | ");
            outcome = "FAIL " + ex.GetType().FullName + " :: " + message;
        }

        lock (s_lock)
        {
            File.AppendAllText(s_path, name + " => " + outcome + Environment.NewLine);
        }
    }
}

public class Probes
{
    private static int Five() => 5;

    private static async Task FailAsync()
    {
        await Task.Yield();
        throw new InvalidOperationException("async boom");
    }

    private static Task FailSyncReturningTask() => Task.FromException(new InvalidOperationException("sync task boom"));

    // Not a test: exists only so the analyzers report on these statements at build time.
    public static async Task AnalyzerBait()
    {
        int value = Five();
#pragma warning disable TUnitAssertions0002, TUnitAssertions0004, CS4014
        Assert.That(value).IsEqualTo(2);
        Assert.Multiple();
#pragma warning restore TUnitAssertions0002, TUnitAssertions0004, CS4014
        string? s = null;
        await Assert.That(s).IsEqualTo(null);
        bool b = value > 1;
        await Assert.That(b).IsEqualTo(true);
        List<int> list = [1];
        await Assert.That(list).IsEqualTo(new List<int> { 1 });
        await Assert.That(value).IsPositive().And.IsLessThan(10).Or.IsEqualTo(100);
        object o = value;
        await Assert.That(o.Equals(5)).IsTrue();
    }

    [Test]
    public async Task B01_UnawaitedAssertionDoesNotFail() => await Recorder.Run("B01 unawaited IsEqualTo(2) on 5", () =>
    {
#pragma warning disable TUnitAssertions0002
        _ = Assert.That(Five()).IsEqualTo(2);
#pragma warning restore TUnitAssertions0002
        return Task.CompletedTask;
    });

    [Test]
    public async Task B02_MixedAndOr() => await Recorder.Run("B02 value .And then .Or", async () =>
        await Assert.That(Five()).IsPositive().And.IsLessThan(10).Or.IsEqualTo(100));

    [Test]
    public async Task B03_MemberMixedAndOr() => await Recorder.Run("B03 Member .And then .Or", async () =>
        await Assert.That(new Thing { Name = "a", Age = 1 })
            .Member(t => t.Name, n => n.IsEqualTo("a"))
            .And.Member(t => t.Age, a => a.IsGreaterThan(0))
            .Or.Member(t => t.Age, a => a.IsEqualTo(99)));

    [Test]
    public async Task B04a_IsEqualToListSameContents() => await Recorder.Run("B04a List IsEqualTo List same contents", async () =>
        await Assert.That(new List<int> { 1, 2 }).IsEqualTo(new List<int> { 1, 2 }));

    [Test]
    public async Task B04b_IsEqualToArraySameContents() => await Recorder.Run("B04b int[] IsEqualTo int[] same contents", async () =>
        await Assert.That(new[] { 1, 2 }).IsEqualTo(new[] { 1, 2 }));

    [Test]
    public async Task B05_ObjectIsEquivalentTo() => await Recorder.Run("B05 Thing IsEquivalentTo Thing same values (no Equals override)", async () =>
        await Assert.That(new Thing { Name = "a", Age = 1 }).IsEquivalentTo(new Thing { Name = "a", Age = 1 }));

    [Test]
    public async Task B05b_ObjectIsEquivalentToDiffers() => await Recorder.Run("B05b Thing IsEquivalentTo Thing different Age", async () =>
        await Assert.That(new Thing { Name = "a", Age = 1 }).IsEquivalentTo(new Thing { Name = "a", Age = 2 }));

    [Test]
    public async Task B05c_NestedObjectIsEquivalentTo() => await Recorder.Run("B05c nested Order IsEquivalentTo, inner Age differs", async () =>
        await Assert.That(new Order { Id = 1, Lines = [new Thing { Name = "a", Age = 1 }] })
            .IsEquivalentTo(new Order { Id = 1, Lines = [new Thing { Name = "a", Age = 2 }] }));

    [Test]
    public async Task B05d_IgnoringMember() => await Recorder.Run("B05d IsEquivalentTo IgnoringMember(Age)", async () =>
        await Assert.That(new Thing { Name = "a", Age = 1 }).IsEquivalentTo(new Thing { Name = "a", Age = 2 }).IgnoringMember(nameof(Thing.Age)));

    [Test]
    public async Task B06_ObjectIsEqualTo() => await Recorder.Run("B06 Thing IsEqualTo Thing same values (no Equals override)", async () =>
        await Assert.That(new Thing { Name = "a", Age = 1 }).IsEqualTo(new Thing { Name = "a", Age = 1 }));

    [Test]
    public async Task B07_CollectionOfObjectsIsEquivalentTo() => await Recorder.Run("B07 Thing[] IsEquivalentTo Thing[] same values, reversed", async () =>
        await Assert.That(new[] { new Thing { Name = "a" }, new Thing { Name = "b" } })
            .IsEquivalentTo(new[] { new Thing { Name = "b" }, new Thing { Name = "a" } }));

    [Test]
    public async Task B08a_WithMessageWildcard() => await Recorder.Run("B08a WithMessage(\"*input*\") on 'bad input here'", async () =>
        await Assert.That(() => throw new ArgumentException("bad input here")).Throws<ArgumentException>().WithMessage("*input*"));

    [Test]
    public async Task B08b_WithMessageMatchingWildcard() => await Recorder.Run("B08b WithMessageMatching(\"*input*\") on 'bad input here'", async () =>
        await Assert.That(() => throw new ArgumentException("bad input here")).Throws<ArgumentException>().WithMessageMatching("*input*"));

    [Test]
    public async Task B08c_WithMessageArgumentExceptionParamSuffix() => await Recorder.Run("B08c WithMessage exact on ArgumentException(msg, paramName)", async () =>
        await Assert.That(() => throw new ArgumentException("bad", "p")).Throws<ArgumentException>().WithMessage("bad"));

    [Test]
    public async Task B09a_ThrowsAcceptsSubclass() => await Recorder.Run("B09a Throws<ArgumentException> on ArgumentNullException", async () =>
        await Assert.That(() => throw new ArgumentNullException("p")).Throws<ArgumentException>());

    [Test]
    public async Task B09b_ThrowsExactlyRejectsSubclass() => await Recorder.Run("B09b ThrowsExactly<ArgumentException> on ArgumentNullException", async () =>
        await Assert.That(() => throw new ArgumentNullException("p")).ThrowsExactly<ArgumentException>());

    [Test]
    public async Task B10_ThrowsWhenNothingThrown() => await Recorder.Run("B10 Throws<> when nothing thrown", async () =>
        await Assert.That(() => Five()).Throws<InvalidOperationException>());

    [Test]
    public async Task B11_AssertMultiple() => await Recorder.Run("B11 Assert.Multiple two failures", async () =>
    {
        using (Assert.Multiple())
        {
            await Assert.That(Five()).IsEqualTo(1);
            await Assert.That("abc").IsEqualTo("abd");
        }
    });

    [Test]
    public async Task B12a_IsTrueMessage() => await Recorder.Run("B12a IsTrue(list.Count > 0) message", async () =>
    {
        List<int> list = [];
        await Assert.That(list.Count > 0).IsTrue();
    });

    [Test]
    public async Task B12b_IsNotEmptyMessage() => await Recorder.Run("B12b IsNotEmpty() message", async () =>
    {
        List<int> list = [];
        await Assert.That(list).IsNotEmpty();
    });

    [Test]
    public async Task B12c_StringEqualMessage() => await Recorder.Run("B12c string IsEqualTo message", async () =>
        await Assert.That("The quick brown fox").IsEqualTo("The quick brawn fox"));

    [Test]
    public async Task B12d_CollectionEquivalentMessage() => await Recorder.Run("B12d IsEquivalentTo message", async () =>
        await Assert.That(new[] { 1, 2, 3 }).IsEquivalentTo(new[] { 1, 2, 4 }));

    [Test]
    public async Task B13_IsBetweenInclusive() => await Recorder.Run("B13 IsBetween(0,10) on 10", async () =>
        await Assert.That(Five() * 2).IsBetween(0, 10));

    [Test]
    public async Task B14a_DoubleWithoutWithin() => await Recorder.Run("B14a 0.1+0.2 IsEqualTo 0.3", async () =>
    {
        double d = 0.1;
        await Assert.That(d + 0.2).IsEqualTo(0.3);
    });

    [Test]
    public async Task B14b_DoubleWithin() => await Recorder.Run("B14b 0.1+0.2 IsEqualTo 0.3 Within 1e-9", async () =>
    {
        double d = 0.1;
        await Assert.That(d + 0.2).IsEqualTo(0.3).Within(1e-9);
    });

    [Test]
    public async Task B15a_IsTypeOfBase() => await Recorder.Run("B15a IsTypeOf<Animal> on Dog", async () =>
    {
        object o = new Dog();
        await Assert.That(o).IsTypeOf<Animal>();
    });

    [Test]
    public async Task B15b_IsAssignableToBase() => await Recorder.Run("B15b IsAssignableTo<Animal> on Dog", async () =>
    {
        object o = new Dog();
        await Assert.That(o).IsAssignableTo<Animal>();
    });

    [Test]
    public async Task B16_CountWithInnerAssertion() => await Recorder.Run("B16 Count(i => i.IsGreaterThan(1)).IsEqualTo(2) on [1,2,3]", async () =>
        await Assert.That(new[] { 1, 2, 3 }).Count(i => i.IsGreaterThan(1)).IsEqualTo(2));

    [Test]
    public async Task B17a_EquivalentDefaultIgnoresOrder() => await Recorder.Run("B17a IsEquivalentTo reversed (default)", async () =>
        await Assert.That(new[] { 1, 2, 3 }).IsEquivalentTo(new[] { 3, 2, 1 }));

    [Test]
    public async Task B17b_EquivalentMatchingOrder() => await Recorder.Run("B17b IsEquivalentTo reversed (Matching)", async () =>
        await Assert.That(new[] { 1, 2, 3 }).IsEquivalentTo(new[] { 3, 2, 1 }, CollectionOrdering.Matching));

    [Test]
    public async Task B17c_EquivalentDuplicates() => await Recorder.Run("B17c [1,1,2] IsEquivalentTo [1,2,2]", async () =>
        await Assert.That(new[] { 1, 1, 2 }).IsEquivalentTo(new[] { 1, 2, 2 }));

    [Test]
    public async Task B18_TaskDirectlyThrows() => await Recorder.Run("B18 Assert.That(faultedTask).Throws<>", async () =>
        await Assert.That(FailSyncReturningTask()).Throws<InvalidOperationException>());

    [Test]
    public async Task B19a_SyncLambdaReturningTask() => await Recorder.Run("B19a Assert.That(() => FailAsync()).Throws<>", async () =>
        await Assert.That(() => FailAsync()).Throws<InvalidOperationException>());

    [Test]
    public async Task B19b_AsyncLambda() => await Recorder.Run("B19b Assert.That(async () => await FailAsync()).Throws<>", async () =>
        await Assert.That(async () => await FailAsync()).Throws<InvalidOperationException>());

    [Test]
    public async Task B20_SatisfiesWithStringSecondArg() => await Recorder.Run("B20 Satisfies(pred, \"must be even\") failure", async () =>
        await Assert.That(Five()).Satisfies(v => v % 2 == 0, "must be even"));

    [Test]
    public async Task B21_Because() => await Recorder.Run("B21 Because(...) failure", async () =>
        await Assert.That(Five()).IsEqualTo(6).Because("the fee is fixed"));

    [Test]
    public async Task B22_ThrowsReturnsException() => await Recorder.Run("B22 Throws<> returns exception with ParamName", async () =>
    {
        ArgumentNullException? ex = await Assert.That(() => throw new ArgumentNullException("p")).Throws<ArgumentNullException>();
        await Assert.That(ex!.ParamName).IsEqualTo("p");
    });

    [Test]
    public async Task B23_DateWithin() => await Recorder.Run("B23 DateTime IsEqualTo Within 2s (1s apart)", async () =>
    {
        DateTime d = new(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        await Assert.That(d.AddSeconds(1)).IsEqualTo(d).Within(TimeSpan.FromSeconds(2));
    });

    [Test]
    public async Task B24_HasSingleItemTwo() => await Recorder.Run("B24 HasSingleItem on two items", async () =>
        await Assert.That(new[] { 1, 2 }).HasSingleItem());

    [Test]
    public async Task B25_IsNotNullFlow() => await Recorder.Run("B25 IsNotNull then dereference", async () =>
    {
        string? s = Five() > 0 ? "abc" : null;
        await Assert.That(s).IsNotNull();
        _ = s.Length;
    });

    [Test]
    public async Task B26_StringIsEqualToIgnoringWhitespace() => await Recorder.Run("B26 'a  b' IsEqualTo 'a b' IgnoringWhitespace", async () =>
        await Assert.That("a  b").IsEqualTo("a b").IgnoringWhitespace());

    [Test]
    public async Task B27_WaitsFor() => await Recorder.Run("B27 WaitsFor flag set after 200ms", async () =>
    {
        bool flag = false;
        _ = Task.Run(async () => { await Task.Delay(200); flag = true; });
        await Assert.That(() => flag).WaitsFor(f => f.IsTrue(), timeout: TimeSpan.FromSeconds(5));
    });

    [Test]
    public async Task B28_AndChainShortCircuits() => await Recorder.Run("B28 IsNotNull().And.IsEqualTo on null", async () =>
    {
        string? s = Five() > 10 ? "x" : null;
        await Assert.That(s).IsNotNull().And.IsEqualTo("x");
    });

    [Test]
    public async Task B29_ThrowsNothingReturnsValue() => await Recorder.Run("B29 ThrowsNothing returns delegate value", async () =>
    {
        int v = await Assert.That(() => Five()).ThrowsNothing();
        await Assert.That(v).IsEqualTo(5);
    });

    [Test]
    public async Task B30_MultipleImplicitScope() => await Recorder.Run("B30 using var Assert.Multiple; two failures", async () =>
    {
        using var scope = Assert.Multiple();
        await Assert.That(Five()).IsEqualTo(1);
        await Assert.That(Five()).IsEqualTo(2);
    });

    [Test]
    public async Task B31_RecordIsEqualTo() => await Recorder.Run("B31 record IsEqualTo same values", async () =>
        await Assert.That(new Point(1, 2)).IsEqualTo(new Point(1, 2)));

    [Test]
    public async Task B32_CollectionContainsObjectNoEquals() => await Recorder.Run("B32 Thing[] Contains(new Thing same values)", async () =>
        await Assert.That(new[] { new Thing { Name = "a" } }).Contains(new Thing { Name = "a" }));

    [Test]
    public async Task B33_IsEqualToDecimalWithin() => await Recorder.Run("B33 decimal Within", async () =>
    {
        decimal m = 19.995m;
        await Assert.That(m).IsEqualTo(20.00m).Within(0.01m);
    });

    [Test]
    public async Task B34_ThrowsWithInnerException() => await Recorder.Run("B34 WithInnerException<FormatException> when inner is ArgumentException", async () =>
        await Assert.That(() => throw new InvalidOperationException("o", new ArgumentException("i")))
            .Throws<InvalidOperationException>()
            .WithInnerException<FormatException>());

    [Test]
    public async Task B35_StringContainsIgnoringCase() => await Recorder.Run("B35 Contains('WORLD').IgnoringCase", async () =>
        await Assert.That("hello world").Contains("WORLD").IgnoringCase());

    [Test]
    public async Task B36_ExceptionInsideAssertThatValue() => await Recorder.Run("B36 failing assertion exception type", async () =>
        await Assert.That(Five()).IsEqualTo(4));

    [Test]
    public async Task B37_NullableIntPositive() => await Recorder.Run("B37 IsEqualTo on two List<Thing> via IsEquivalentTo with Using predicate", async () =>
        await Assert.That(new[] { new Thing { Name = "A" } })
            .IsEquivalentTo(new[] { new Thing { Name = "a" } })
            .Using((x, y) => string.Equals(x!.Name, y!.Name, StringComparison.OrdinalIgnoreCase)));
}

public sealed record Point(int X, int Y);
