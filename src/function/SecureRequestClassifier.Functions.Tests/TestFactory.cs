using Microsoft.Extensions.Options;
using SecureRequestClassifier.Functions.Configuration;
using SecureRequestClassifier.Functions.Services;

namespace SecureRequestClassifier.Functions.Tests;

internal static class TestFactory
{
    /// <summary>Default demo business day: 09:00-17:00 UTC, Monday to Friday.</summary>
    public static ClassifierOptions DefaultOptions() => new()
    {
        BusinessDayStartUtcHour = 9,
        BusinessDayEndUtcHour = 17,
        ServiceName = "Secure Request Classifier (test)",
    };

    public static RequestClassifier CreateClassifier(ClassifierOptions? options = null) =>
        new(Options.Create(options ?? DefaultOptions()));

    /// <summary>Wednesday 2026-09-16, 10:00:00 UTC - inside the business day.</summary>
    public static readonly DateTimeOffset WednesdayMorning =
        new(2026, 9, 16, 10, 0, 0, TimeSpan.Zero);
}
