using System.Text.Json.Serialization;

namespace SecureRequestClassifier.Functions.Models;

/// <summary>
/// RFC 9457 style error payload, served as <c>application/problem+json</c>.
/// </summary>
public sealed record ValidationProblem
{
    [JsonPropertyName("type")]
    public string Type { get; init; } = "https://datatracker.ietf.org/doc/html/rfc9457";

    [JsonPropertyName("title")]
    public string Title { get; init; } = "One or more validation errors occurred.";

    [JsonPropertyName("status")]
    public int Status { get; init; } = 400;

    [JsonPropertyName("detail")]
    public string? Detail { get; init; }

    [JsonPropertyName("errors")]
    public required IReadOnlyDictionary<string, string[]> Errors { get; init; }

    [JsonPropertyName("correlationId")]
    public required string CorrelationId { get; init; }
}
