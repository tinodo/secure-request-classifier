using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Options;
using SecureRequestClassifier.Functions.Configuration;
using SecureRequestClassifier.Functions.Models;

namespace SecureRequestClassifier.Functions.Services;

/// <summary>
/// The deterministic business rules for the demo.
///
/// There is no AI, no database and no external call here on purpose: given the same
/// inputs and the same received timestamp this class always produces the same output,
/// which makes the demo reproducible and the tests exact.
/// </summary>
public sealed class RequestClassifier(IOptions<ClassifierOptions> options)
{
    private readonly ClassifierOptions _options = options.Value;

    public static readonly IReadOnlyList<string> SupportedCategories =
        ["IT", "Facilities", "HR", "Other"];

    public static readonly IReadOnlyList<string> SupportedImpacts =
        ["Low", "Medium", "High"];

    /// <summary>Category -> fictional owning team.</summary>
    private static readonly Dictionary<string, string> TeamByCategory = new(StringComparer.Ordinal)
    {
        ["IT"] = "Digital Workplace Support",
        ["Facilities"] = "Workplace Services",
        ["HR"] = "People Operations",
        ["Other"] = "Business Support Desk",
    };

    /// <summary>
    /// Priority matrix. Rows are the normalized category, columns are the normalized impact.
    /// P1 is the most urgent.
    /// </summary>
    private static readonly Dictionary<(string Category, string Impact), string> PriorityMatrix =
        new()
        {
            [("IT", "High")] = "P1",
            [("IT", "Medium")] = "P2",
            [("IT", "Low")] = "P3",

            [("Facilities", "High")] = "P2",
            [("Facilities", "Medium")] = "P3",
            [("Facilities", "Low")] = "P4",

            [("HR", "High")] = "P2",
            [("HR", "Medium")] = "P3",
            [("HR", "Low")] = "P4",

            [("Other", "High")] = "P3",
            [("Other", "Medium")] = "P3",
            [("Other", "Low")] = "P4",
        };

    /// <summary>Priority -> SLA expressed in business hours.</summary>
    private static readonly Dictionary<string, int> SlaBusinessHoursByPriority = new(StringComparer.Ordinal)
    {
        ["P1"] = 4,
        ["P2"] = 8,
        ["P3"] = 24,
        ["P4"] = 40,
    };

    public ClassificationResponse Classify(
        ClassificationRequest request,
        DateTimeOffset receivedAtUtc,
        string correlationId)
    {
        ArgumentNullException.ThrowIfNull(request);

        var notes = new List<string>();

        var requesterName = request.RequesterName!.Trim();
        var requesterEmail = request.RequesterEmail!.Trim();
        var title = CollapseWhitespace(request.Title!);

        var normalizedCategory = NormalizeCategory(request.Category, notes);

        if (!TryNormalizeImpact(request.Impact, out var normalizedImpact))
        {
            // Unreachable when RequestValidator ran first; guards direct service use.
            throw new ArgumentOutOfRangeException(
                nameof(request),
                request.Impact,
                "Impact must be validated before classification.");
        }

        var priority = PriorityMatrix[(normalizedCategory, normalizedImpact)];
        var slaBusinessHours = SlaBusinessHoursByPriority[priority];
        var assignedTeam = TeamByCategory[normalizedCategory];

        var targetResponseDate = AddBusinessHours(receivedAtUtc, slaBusinessHours);

        var requestId = BuildRequestId(
            requesterEmail, title, normalizedCategory, normalizedImpact, receivedAtUtc);

        var reason =
            $"Category '{normalizedCategory}' with '{normalizedImpact}' impact maps to {priority}; " +
            $"{priority} carries a {slaBusinessHours} business-hour response target.";

        return new ClassificationResponse
        {
            RequestId = requestId,
            Status = "Accepted",
            Priority = priority,
            PriorityRank = int.Parse(priority[1..], CultureInfo.InvariantCulture),
            AssignedTeam = assignedTeam,
            NormalizedCategory = normalizedCategory,
            NormalizedImpact = normalizedImpact,
            TargetResponseDate = targetResponseDate,
            SlaBusinessHours = slaBusinessHours,
            ReceivedAtUtc = receivedAtUtc,
            RequesterName = requesterName,
            RequesterEmail = requesterEmail,
            Title = title,
            ClassificationReason = reason,
            Notes = notes,
            CorrelationId = correlationId,
        };
    }

    /// <summary>
    /// Maps free-text category input onto the four supported values. Anything
    /// unrecognised becomes <c>Other</c> and produces a note rather than an error.
    /// </summary>
    internal static string NormalizeCategory(string? category, List<string> notes)
    {
        var candidate = (category ?? string.Empty).Trim();

        var match = SupportedCategories.FirstOrDefault(
            c => string.Equals(c, candidate, StringComparison.OrdinalIgnoreCase));

        if (match is not null)
        {
            return match;
        }

        notes.Add($"Category '{candidate}' was not recognised and has been normalized to 'Other'.");

        return "Other";
    }

    internal static bool TryNormalizeImpact(string? impact, out string normalized)
    {
        var candidate = (impact ?? string.Empty).Trim();

        var match = SupportedImpacts.FirstOrDefault(
            i => string.Equals(i, candidate, StringComparison.OrdinalIgnoreCase));

        normalized = match ?? string.Empty;

        return match is not null;
    }

    /// <summary>
    /// Advances <paramref name="from"/> by <paramref name="businessHours"/>, counting only
    /// Monday-Friday between the configured UTC business-day start and end hours.
    /// A submission made outside business hours is treated as arriving at the start of the
    /// next business day.
    /// </summary>
    internal DateTimeOffset AddBusinessHours(DateTimeOffset from, int businessHours)
    {
        var cursor = MoveToNextBusinessMoment(from.ToUniversalTime());

        var remaining = TimeSpan.FromHours(businessHours);

        while (remaining > TimeSpan.Zero)
        {
            var endOfDay = StartOfBusinessDay(cursor).AddHours(_options.BusinessHoursPerDay);

            var availableToday = endOfDay - cursor;

            if (remaining <= availableToday)
            {
                return cursor + remaining;
            }

            remaining -= availableToday;
            cursor = MoveToNextBusinessMoment(endOfDay);
        }

        return cursor;
    }

    /// <summary>
    /// Returns the supplied instant if it already sits inside a business day; otherwise the
    /// start of the next business day.
    /// </summary>
    private DateTimeOffset MoveToNextBusinessMoment(DateTimeOffset instant)
    {
        var cursor = instant.ToUniversalTime();

        while (true)
        {
            if (IsWeekend(cursor))
            {
                cursor = StartOfBusinessDay(cursor.AddDays(1));
                continue;
            }

            var startOfDay = StartOfBusinessDay(cursor);

            if (cursor < startOfDay)
            {
                return startOfDay;
            }

            var endOfDay = startOfDay.AddHours(_options.BusinessHoursPerDay);

            if (cursor >= endOfDay)
            {
                cursor = StartOfBusinessDay(cursor.AddDays(1));
                continue;
            }

            return cursor;
        }
    }

    private DateTimeOffset StartOfBusinessDay(DateTimeOffset instant) =>
        new(instant.Year, instant.Month, instant.Day,
            _options.BusinessDayStartUtcHour, 0, 0, TimeSpan.Zero);

    private static bool IsWeekend(DateTimeOffset instant) =>
        instant.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday;

    /// <summary>
    /// Builds a stable, human-readable request id. The suffix is derived from a SHA-256 hash
    /// of the normalized submission so that identical submissions at the same instant always
    /// yield the same id — which keeps the demo reproducible and the tests exact.
    /// </summary>
    internal static string BuildRequestId(
        string requesterEmail,
        string title,
        string category,
        string impact,
        DateTimeOffset receivedAtUtc)
    {
        var seed = string.Join(
            '|',
            requesterEmail.ToUpperInvariant(),
            title.ToUpperInvariant(),
            category,
            impact,
            receivedAtUtc.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture));

        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(seed));

        var suffix = Convert.ToHexString(hash.AsSpan(0, 4));

        return $"SRC-{receivedAtUtc.ToUniversalTime():yyyyMMdd}-{suffix}";
    }

    private static string CollapseWhitespace(string value) =>
        string.Join(' ', value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
}
