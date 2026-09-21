using System.Text.Json.Serialization;

namespace SecureRequestClassifier.Functions.Models;

/// <summary>
/// The payload submitted by the <c>Classify and Notify</c> Power Automate cloud flow. The flow's
/// PowerApps (V2) trigger collects these fields; there is no canvas app.
/// </summary>
public sealed record ClassificationRequest
{
    [JsonPropertyName("requesterName")]
    public string? RequesterName { get; init; }

    [JsonPropertyName("requesterEmail")]
    public string? RequesterEmail { get; init; }

    [JsonPropertyName("title")]
    public string? Title { get; init; }

    /// <summary>IT, Facilities, HR or Other. Unknown values are normalized to <c>Other</c>.</summary>
    [JsonPropertyName("category")]
    public string? Category { get; init; }

    /// <summary>Low, Medium or High. Unknown values are rejected because impact drives priority.</summary>
    [JsonPropertyName("impact")]
    public string? Impact { get; init; }

    [JsonPropertyName("description")]
    public string? Description { get; init; }

    /// <summary>
    /// Optional caller-supplied correlation id, echoed back for end-to-end tracing. The
    /// <c>x-correlation-id</c> header takes precedence when both are supplied; when neither is,
    /// one is generated. Trimmed and capped at 128 characters.
    /// </summary>
    [JsonPropertyName("correlationId")]
    public string? CorrelationId { get; init; }
}
