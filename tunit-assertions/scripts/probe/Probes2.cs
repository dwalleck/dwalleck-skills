namespace AssertionProbe;

public class Probes2
{
    private static async Task<int> GetAsync()
    {
        await Task.Yield();
        return 42;
    }

    [Test]
    public async Task C01_IsTypeOfBaseStaticAnimal() => await Recorder.Run("C01 IsTypeOf<Animal> on Dog, static type Animal", async () =>
    {
        Animal a = new Dog();
        await Assert.That(a).IsTypeOf<Animal>();
    });

    [Test]
    public async Task C02_IsTypeOfExactDog() => await Recorder.Run("C02 IsTypeOf<Dog> on Dog, static object", async () =>
    {
        object o = new Dog();
        await Assert.That(o).IsTypeOf<Dog>();
    });

    [Test]
    public async Task C03_IsNotTypeOfBase() => await Recorder.Run("C03 IsNotTypeOf<Animal> on Dog", async () =>
    {
        object o = new Dog();
        await Assert.That(o).IsNotTypeOf<Animal>();
    });

    [Test]
    public async Task C04_IsTypeOfWrong() => await Recorder.Run("C04 IsTypeOf<Dog> on Animal instance", async () =>
    {
        object o = new Animal();
        await Assert.That(o).IsTypeOf<Dog>();
    });

    [Test]
    public async Task C04b_IsTypeOfObjectOnString() => await Recorder.Run("C04b IsTypeOf<object> on string", async () =>
    {
        object o = "s";
        await Assert.That(o).IsTypeOf<object>();
    });

    [Test]
    public async Task C05_TaskOfTIsEqualTo() => await Recorder.Run("C05 Assert.That(Task<int> 42).IsEqualTo(42)", async () =>
        await Assert.That(GetAsync()).IsEqualTo(42));

    [Test]
    public async Task C06_AsyncLambdaIsEqualTo() => await Recorder.Run("C06 Assert.That(async () => await GetAsync()).IsEqualTo(42)", async () =>
        await Assert.That(async () => await GetAsync()).IsEqualTo(42));

    [Test]
    public async Task C07_TaskOfTWrong() => await Recorder.Run("C07 Assert.That(Task<int> 42).IsEqualTo(41)", async () =>
        await Assert.That(GetAsync()).IsEqualTo(41));

    [Test]
    public async Task C08_ThrowsExceptionBase() => await Recorder.Run("C08 Throws<Exception> on NullReferenceException", async () =>
        await Assert.That(() => throw new NullReferenceException()).Throws<Exception>());

    [Test]
    public async Task C09_EquivalentToAnonymous() => await Recorder.Run("C09 Thing IsEquivalentTo anonymous {Name, Age}", async () =>
        await Assert.That(new Thing { Name = "a", Age = 1 }).IsEquivalentTo(new { Name = "a", Age = 1 }));

    [Test]
    public async Task C10_DelegateValueIsEqualTo() => await Recorder.Run("C10 Assert.That(() => 5).IsEqualTo(5)", async () =>
        await Assert.That(() => 5).IsEqualTo(5));

    [Test]
    public async Task C11_MultipleWithNonAssertionException() => await Recorder.Run("C11 Assert.Multiple: failure then NRE", async () =>
    {
        using (Assert.Multiple())
        {
            await Assert.That(1 + 1).IsEqualTo(3);
            string? s = null;
            _ = s!.Length;
        }
    });

    [Test]
    public async Task C12_MemberOrOnly() => await Recorder.Run("C12 Member .Or only, first fails second passes", async () =>
        await Assert.That(new Thing { Name = "a", Age = 1 })
            .Member(t => t.Age, a => a.IsEqualTo(99))
            .Or.Member(t => t.Name, n => n.IsEqualTo("a")));

    [Test]
    public async Task C13_MemberAndThenOrFalseFalse() => await Recorder.Run("C13 Member A(true).And B(false).Or C(false)", async () =>
        await Assert.That(new Thing { Name = "a", Age = 1 })
            .Member(t => t.Name, n => n.IsEqualTo("a"))
            .And.Member(t => t.Age, a => a.IsEqualTo(2))
            .Or.Member(t => t.Age, a => a.IsEqualTo(3)));

    [Test]
    public async Task C14_CountThenAndContains() => await Recorder.Run("C14 Count().IsEqualTo(3).And.Contains(9)", async () =>
        await Assert.That(new[] { 1, 2, 3 }).Count().IsEqualTo(3).And.Contains(9));

    [Test]
    public async Task C15_IsEquivalentToDictionaryOrder() => await Recorder.Run("C15 dictionary IsEquivalentTo reordered", async () =>
        await Assert.That(new Dictionary<string, int> { ["a"] = 1, ["b"] = 2 })
            .IsEquivalentTo(new Dictionary<string, int> { ["b"] = 2, ["a"] = 1 }));

    [Test]
    public async Task C16_AllPredicateMessage() => await Recorder.Run("C16 All(predicate) failure message", async () =>
        await Assert.That(new[] { 1, -2, 3 }).All(x => x > 0));

    [Test]
    public async Task C17_AllSatisfyMessage() => await Recorder.Run("C17 All().Satisfy(builder) failure message", async () =>
        await Assert.That(new[] { 1, -2, 3 }).All().Satisfy(x => x.IsPositive()));

    [Test]
    public async Task C19_SatisfiesBecause() => await Recorder.Run("C19 Satisfies(pred).Because(reason) failure", async () =>
        await Assert.That(1 + 4).Satisfies(v => v % 2 == 0).Because("the batch size must be even"));

    [Test]
    public async Task C20_ExactTypeViaGetType() => await Recorder.Run("C20 GetType() IsEqualTo typeof(Animal) on Dog", async () =>
    {
        object o = new Dog();
        await Assert.That(o.GetType()).IsEqualTo(typeof(Animal));
    });

    [Test]
    public async Task D01_MatchesIgnoringCase() => await Recorder.Run("D01 Matches(\"^hello\").IgnoringCase() on 'Hello World'", async () =>
        await Assert.That("Hello " + "World").Matches("^hello").IgnoringCase());

    [Test]
    public async Task D02_MatchesWithOptionsIgnoreCase() => await Recorder.Run("D02 Matches(\"^hello\").WithOptions(IgnoreCase) on 'Hello World'", async () =>
        await Assert.That("Hello " + "World").Matches("^hello").WithOptions(System.Text.RegularExpressions.RegexOptions.IgnoreCase));

    [Test]
    public async Task D03_MatchesRegexObject() => await Recorder.Run("D03 Matches(new Regex(\"^hello\", IgnoreCase)) on 'Hello World'", async () =>
        await Assert.That("Hello " + "World").Matches(new System.Text.RegularExpressions.Regex("^hello", System.Text.RegularExpressions.RegexOptions.IgnoreCase)));

    [Test]
    public async Task D04_MatchesInlineOption() => await Recorder.Run("D04 Matches(\"(?i)^hello\") on 'Hello World'", async () =>
        await Assert.That("Hello " + "World").Matches("(?i)^hello"));

    [Test]
    public async Task D05_MatchesMultilineOption() => await Recorder.Run("D05 Matches(\"^Line 2$\").WithOptions(Multiline) on 3 lines", async () =>
        await Assert.That("Line 1\nLine 2\nLine 3").Matches("^Line 2$").WithOptions(System.Text.RegularExpressions.RegexOptions.Multiline));

    [Test]
    public async Task C18_WithParameterNameWrong() => await Recorder.Run("C18 WithParameterName wrong", async () =>
        await Assert.That(() => throw new ArgumentNullException("actual")).Throws<ArgumentNullException>().WithParameterName("expected"));
}
