namespace SecureRequestClassifier.Functions.Configuration;

/// <summary>
/// Business-rule configuration. Bound from the <c>Classifier__*</c> application settings
/// so the demo can be tuned without code changes, but with safe defaults so the
/// Function App runs correctly with no configuration at all.
/// </summary>
public sealed class ClassifierOptions
{
    public const string SectionName = "Classifier";

    /// <summary>Inclusive hour (UTC) at which the business day starts.</summary>
    public int BusinessDayStartUtcHour { get; set; } = 9;

    /// <summary>Exclusive hour (UTC) at which the business day ends.</summary>
    public int BusinessDayEndUtcHour { get; set; } = 17;

    public string ServiceName { get; set; } = "Secure Request Classifier";

    /// <summary>
    /// Optional defence-in-depth allow-list of Microsoft Entra ID application (client) IDs.
    /// App Service Authentication already enforces <c>allowedApplications</c> at the platform
    /// layer; when this is populated the function additionally rejects any other caller.
    /// Comma separated.
    /// </summary>
    public string AllowedClientAppIds { get; set; } = string.Empty;

    public int BusinessHoursPerDay => Math.Max(1, BusinessDayEndUtcHour - BusinessDayStartUtcHour);

    public IReadOnlySet<string> AllowedClientAppIdSet =>
        AllowedClientAppIds
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

    public void Validate()
    {
        if (BusinessDayStartUtcHour is < 0 or > 23)
        {
            throw new InvalidOperationException(
                $"{SectionName}:{nameof(BusinessDayStartUtcHour)} must be between 0 and 23.");
        }

        if (BusinessDayEndUtcHour is < 1 or > 24)
        {
            throw new InvalidOperationException(
                $"{SectionName}:{nameof(BusinessDayEndUtcHour)} must be between 1 and 24.");
        }

        if (BusinessDayEndUtcHour <= BusinessDayStartUtcHour)
        {
            throw new InvalidOperationException(
                $"{SectionName}:{nameof(BusinessDayEndUtcHour)} must be greater than {nameof(BusinessDayStartUtcHour)}.");
        }
    }
}
