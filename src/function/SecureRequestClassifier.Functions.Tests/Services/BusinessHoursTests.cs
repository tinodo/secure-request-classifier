using SecureRequestClassifier.Functions.Models;
using Xunit;

namespace SecureRequestClassifier.Functions.Tests.Services;

/// <summary>
/// The response target is expressed in <em>business</em> hours (Mon-Fri, 09:00-17:00 UTC by
/// default). These tests pin the arithmetic, including submissions that arrive out of hours
/// or at the weekend.
///
/// 2026-09-16 is a Wednesday.
/// </summary>
public sealed class BusinessHoursTests
{
    private static ClassificationRequest Request(string category = "IT", string impact = "High") => new()
    {
        RequesterName = "Grace Hopper",
        RequesterEmail = "grace@contoso.com",
        Title = "Meeting room projector is dead",
        Category = category,
        Impact = impact,
    };

    private static DateTimeOffset Utc(int year, int month, int day, int hour, int minute = 0) =>
        new(year, month, day, hour, minute, 0, TimeSpan.Zero);

    [Fact]
    public void P1_submitted_midweek_lands_the_same_day()
    {
        var result = TestFactory.CreateClassifier()
            .Classify(Request(), Utc(2026, 9, 16, 10), "c");

        Assert.Equal("P1", result.Priority);
        Assert.Equal(Utc(2026, 9, 16, 14), result.TargetResponseDate);
    }

    [Fact]
    public void P2_rolls_over_into_the_next_business_day_when_the_day_runs_out()
    {
        // 8 business hours from Wed 10:00 => 7h left on Wednesday, 1h on Thursday.
        var result = TestFactory.CreateClassifier()
            .Classify(Request("IT", "Medium"), Utc(2026, 9, 16, 10), "c");

        Assert.Equal("P2", result.Priority);
        Assert.Equal(Utc(2026, 9, 17, 10), result.TargetResponseDate);
    }

    [Fact]
    public void P3_skips_the_weekend()
    {
        // 24 business hours from Wed 10:00: 7h Wed, 8h Thu, 8h Fri, 1h Mon.
        var result = TestFactory.CreateClassifier()
            .Classify(Request("IT", "Low"), Utc(2026, 9, 16, 10), "c");

        Assert.Equal("P3", result.Priority);
        Assert.Equal(Utc(2026, 9, 21, 10), result.TargetResponseDate);
        Assert.Equal(DayOfWeek.Monday, result.TargetResponseDate.DayOfWeek);
    }

    [Fact]
    public void P4_spans_a_full_working_week()
    {
        // 40 business hours from Wed 10:00 lands the following Wednesday.
        var result = TestFactory.CreateClassifier()
            .Classify(Request("HR", "Low"), Utc(2026, 9, 16, 10), "c");

        Assert.Equal("P4", result.Priority);
        Assert.Equal(Utc(2026, 9, 23, 10), result.TargetResponseDate);
    }

    [Fact]
    public void A_request_submitted_after_hours_starts_the_clock_next_morning()
    {
        var result = TestFactory.CreateClassifier()
            .Classify(Request(), Utc(2026, 9, 16, 20), "c");

        Assert.Equal(Utc(2026, 9, 17, 13), result.TargetResponseDate);
    }

    [Fact]
    public void A_request_submitted_before_hours_starts_the_clock_at_opening_time()
    {
        var result = TestFactory.CreateClassifier()
            .Classify(Request(), Utc(2026, 9, 16, 6), "c");

        Assert.Equal(Utc(2026, 9, 16, 13), result.TargetResponseDate);
    }

    [Theory]
    [InlineData(19)] // Saturday
    [InlineData(20)] // Sunday
    public void A_weekend_request_starts_the_clock_on_Monday_morning(int dayOfMonth)
    {
        var result = TestFactory.CreateClassifier()
            .Classify(Request(), Utc(2026, 9, dayOfMonth, 12), "c");

        Assert.Equal(Utc(2026, 9, 21, 13), result.TargetResponseDate);
    }

    [Fact]
    public void The_business_day_window_is_configurable()
    {
        var options = TestFactory.DefaultOptions();
        options.BusinessDayStartUtcHour = 8;
        options.BusinessDayEndUtcHour = 20; // 12-hour day

        var result = TestFactory.CreateClassifier(options)
            .Classify(Request("IT", "Medium"), Utc(2026, 9, 16, 10), "c");

        // 8 business hours now fit inside a single 12-hour day.
        Assert.Equal(Utc(2026, 9, 16, 18), result.TargetResponseDate);
    }

    [Fact]
    public void The_target_response_date_is_always_returned_in_UTC()
    {
        var submitted = new DateTimeOffset(2026, 9, 16, 12, 0, 0, TimeSpan.FromHours(2));

        var result = TestFactory.CreateClassifier().Classify(Request(), submitted, "c");

        Assert.Equal(TimeSpan.Zero, result.TargetResponseDate.Offset);
    }
}
