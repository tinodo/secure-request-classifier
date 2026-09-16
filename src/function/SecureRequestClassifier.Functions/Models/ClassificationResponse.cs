using System.Text.Json.Serialization;

namespace SecureRequestClassifier.Functions.Models;

/// <summary>
/// The deterministic classification result returned to Power Automate.
/// </summary>
public sealed record ClassificationResponse
{
    [JsonPropertyName("requestId")]
    public required string RequestId { get; init; }

    [JsonPropertyName("status")]
    public required string Status { get; init; }

    [JsonPropertyName("priority")]
    public required string Priority { get; init; }

    [JsonPropertyName("priorityRank")]
    public required int PriorityRank { get; init; }

    [JsonPropertyName("assignedTeam")]
    public required string AssignedTeam { get; init; }

    [JsonPropertyName("normalizedCategory")]
    public required string NormalizedCategory { get; init; }

    [JsonPropertyName("normalizedImpact")]
    public required string NormalizedImpact { get; init; }

    [JsonPropertyName("targetResponseDate")]
    public required DateTimeOffset TargetResponseDate { get; init; }

    [JsonPropertyName("slaBusinessHours")]
    public required int SlaBusinessHours { get; init; }

    [JsonPropertyName("receivedAtUtc")]
    public required DateTimeOffset ReceivedAtUtc { get; init; }

    [JsonPropertyName("requesterName")]
    public required string RequesterName { get; init; }

    [JsonPropertyName("requesterEmail")]
    public required string RequesterEmail { get; init; }

    [JsonPropertyName("title")]
    public required string Title { get; init; }

    /// <summary>Human readable explanation of why this priority was chosen. Useful in the demo UI.</summary>
    [JsonPropertyName("classificationReason")]
    public required string ClassificationReason { get; init; }

    /// <summary>Non-fatal normalization notes, e.g. an unrecognised category mapped to <c>Other</c>.</summary>
    [JsonPropertyName("notes")]
    public IReadOnlyList<string> Notes { get; init; } = [];

    [JsonPropertyName("correlationId")]
    public required string CorrelationId { get; init; }
}
