using SecureRequestClassifier.Functions.Models;
using SecureRequestClassifier.Functions.Services;
using Xunit;

namespace SecureRequestClassifier.Functions.Tests.Services;

public sealed class RequestClassifierPriorityTests
{
    private static ClassificationRequest Request(string category, string impact) => new()
    {
        RequesterName = "Ada Lovelace",
        RequesterEmail = "ada@contoso.com",
        Title = "Laptop will not start",
        Category = category,
        Impact = impact,
        Description = "Nothing happens when I press the power button.",
    };

    [Theory]
    // IT escalates fastest because it carries the widest blast radius in the demo model.
    [InlineData("IT", "High", "P1", 4)]
    [InlineData("IT", "Medium", "P2", 8)]
    [InlineData("IT", "Low", "P3", 24)]
    [InlineData("Facilities", "High", "P2", 8)]
    [InlineData("Facilities", "Medium", "P3", 24)]
    [InlineData("Facilities", "Low", "P4", 40)]
    [InlineData("HR", "High", "P2", 8)]
    [InlineData("HR", "Medium", "P3", 24)]
    [InlineData("HR", "Low", "P4", 40)]
    [InlineData("Other", "High", "P3", 24)]
    [InlineData("Other", "Medium", "P3", 24)]
    [InlineData("Other", "Low", "P4", 40)]
    public void Classify_uses_the_documented_priority_matrix(
        string category, string impact, string expectedPriority, int expectedSlaHours)
    {
        var result = TestFactory.CreateClassifier()
            .Classify(Request(category, impact), TestFactory.WednesdayMorning, "corr-1");

        Assert.Equal(expectedPriority, result.Priority);
        Assert.Equal(expectedSlaHours, result.SlaBusinessHours);
        Assert.Equal(int.Parse(expectedPriority[1..]), result.PriorityRank);
    }

    [Theory]
    [InlineData("IT", "Digital Workplace Support")]
    [InlineData("Facilities", "Workplace Services")]
    [InlineData("HR", "People Operations")]
    [InlineData("Other", "Business Support Desk")]
    public void Classify_assigns_the_owning_team_from_the_normalized_category(
        string category, string expectedTeam)
    {
        var result = TestFactory.CreateClassifier()
            .Classify(Request(category, "Medium"), TestFactory.WednesdayMorning, "corr-1");

        Assert.Equal(expectedTeam, result.AssignedTeam);
    }

    [Fact]
    public void Classify_always_reports_Accepted_status_for_a_valid_request()
    {
        var result = TestFactory.CreateClassifier()
            .Classify(Request("IT", "High"), TestFactory.WednesdayMorning, "corr-1");

        Assert.Equal("Accepted", result.Status);
    }

    [Fact]
    public void Classify_explains_the_decision_for_display_in_the_app()
    {
        var result = TestFactory.CreateClassifier()
            .Classify(Request("IT", "High"), TestFactory.WednesdayMorning, "corr-1");

        Assert.Contains("P1", result.ClassificationReason, StringComparison.Ordinal);
        Assert.Contains("IT", result.ClassificationReason, StringComparison.Ordinal);
        Assert.Contains("High", result.ClassificationReason, StringComparison.Ordinal);
    }

    [Fact]
    public void Classify_echoes_the_correlation_id_for_end_to_end_tracing()
    {
        var result = TestFactory.CreateClassifier()
            .Classify(Request("HR", "Low"), TestFactory.WednesdayMorning, "abc-123");

        Assert.Equal("abc-123", result.CorrelationId);
    }

    [Fact]
    public void Classify_rejects_an_unvalidated_impact_rather_than_guessing()
    {
        var classifier = TestFactory.CreateClassifier();

        Assert.Throws<ArgumentOutOfRangeException>(
            () => classifier.Classify(
                Request("IT", "Catastrophic"), TestFactory.WednesdayMorning, "corr-1"));
    }
}
