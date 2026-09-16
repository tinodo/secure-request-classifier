using System.Text.Json.Serialization;

namespace SecureRequestClassifier.Functions.Models;

/// <summary>
/// Response body for <c>GET /api/health</c>.
/// </summary>
public sealed record HealthResponse
{
    [JsonPropertyName("status")]
    public required string Status { get; init; }

    [JsonPropertyName("service")]
    public required string Service { get; init; }

    [JsonPropertyName("version")]
    public required string Version { get; init; }

    [JsonPropertyName("utcNow")]
    public required DateTimeOffset UtcNow { get; init; }

    [JsonPropertyName("runtime")]
    public required string Runtime { get; init; }

    /// <summary>
    /// Indicates whether the request arrived carrying an App Service Authentication
    /// (Microsoft Entra ID) principal. Lets the demo distinguish "network reachable"
    /// from "authenticated" when probing from inside the virtual network.
    /// </summary>
    [JsonPropertyName("authenticated")]
    public required bool Authenticated { get; init; }

    [JsonPropertyName("callerAppId")]
    public string? CallerAppId { get; init; }
}
