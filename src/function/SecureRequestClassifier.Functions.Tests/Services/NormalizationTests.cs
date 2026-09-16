using SecureRequestClassifier.Functions.Models;
using SecureRequestClassifier.Functions.Services;
using Xunit;

namespace SecureRequestClassifier.Functions.Tests.Services;

public sealed class NormalizationTests
{
    private static ClassificationRequest Request(string? category, string impact = "Medium") => new()
    {
        RequesterName = "  Alan   Turing  ",
        RequesterEmail = "  alan@contoso.com  ",
        Title = "  Badge   reader   offline  ",
        Category = category,
        Impact = impact,
    };

    [Theory]
    [InlineData("it", "IT")]
    [InlineData("IT", "IT")]
    [InlineData("  facilities  ", "Facilities")]
    [InlineData("hr", "HR")]
    [InlineData("Other", "Other")]
    public void Known_categories_are_normalized_to_canonical_casing(string input, string expected)
    {
        var result = TestFactory.CreateClassifier()
            .Classify(Request(input), TestFactory.WednesdayMorning, "c");

        Assert.Equal(expected, result.NormalizedCategory);
        Assert.Empty(result.Notes);
    }

    [Theory]
    [InlineData("Payroll")]
    [InlineData("Catering")]
    [InlineData("¯\\_(ツ)_/¯")]
    public void Unknown_categories_fall_back_to_Other_with_an_explanatory_note(string input)
    {
        var result = TestFactory.CreateClassifier()
            .Classify(Request(input), TestFactory.WednesdayMorning, "c");

        Assert.Equal("Other", result.NormalizedCategory);
        Assert.Single(result.Notes);
        Assert.Contains("normalized to 'Other'", result.Notes[0], StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("low", "Low")]
    [InlineData("MEDIUM", "Medium")]
    [InlineData("  High  ", "High")]
    public void Impact_is_normalized_to_canonical_casing(string input, string expected)
    {
        var result = TestFactory.CreateClassifier()
            .Classify(Request("IT", input), TestFactory.WednesdayMorning, "c");

        Assert.Equal(expected, result.NormalizedImpact);
    }

    [Fact]
    public void Free_text_fields_are_trimmed_and_internal_whitespace_collapsed()
    {
        var result = TestFactory.CreateClassifier()
            .Classify(Request("Facilities"), TestFactory.WednesdayMorning, "c");

        Assert.Equal("Alan   Turing", result.RequesterName);
        Assert.Equal("alan@contoso.com", result.RequesterEmail);
        Assert.Equal("Badge reader offline", result.Title);
    }

    [Fact]
    public void TryNormalizeImpact_reports_failure_for_unknown_values()
    {
        Assert.False(RequestClassifier.TryNormalizeImpact("Critical", out var normalized));
        Assert.Equal(string.Empty, normalized);
    }
}
