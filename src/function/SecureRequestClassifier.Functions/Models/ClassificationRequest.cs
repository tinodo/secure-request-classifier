using System.Text.Json.Serialization;

namespace SecureRequestClassifier.Functions.Models;

/// <summary>
/// The payload submitted by the Power Automate cloud flow on behalf of the
/// <c>Secure Request Classifier</c> canvas app.
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

    /// <summary>Optional caller-supplied correlation id; echoed back for end-to-end tracing.</summary>
    [JsonPropertyName("correlationId")]
    public string? CorrelationId { get; init; }
}
