using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Http;

namespace SecureRequestClassifier.Functions.Services;

/// <summary>
/// The Microsoft Entra ID identity of the caller, as established by App Service
/// Authentication ("Easy Auth") <em>before</em> the request reaches this code.
/// </summary>
/// <param name="IsAuthenticated">True when Easy Auth injected a client principal.</param>
/// <param name="AppId">The calling application's client id (<c>azp</c> or <c>appid</c>).</param>
/// <param name="ObjectId">The caller's object id (<c>oid</c>).</param>
/// <param name="TenantId">The caller's tenant id (<c>tid</c>). Part of the identity contract; not currently consumed.</param>
/// <param name="DisplayName">
/// A best-effort display name, parsed so the identity is complete. Deliberately NOT logged: it is
/// the only personally identifying field here, and nothing needs it to correlate a request.
/// </param>
public sealed record CallerIdentity(
    bool IsAuthenticated,
    string? AppId,
    string? ObjectId,
    string? TenantId,
    string? DisplayName)
{
    public static readonly CallerIdentity Anonymous = new(false, null, null, null, null);
}

/// <summary>
/// Reads the Easy Auth client-principal headers. This code never validates a token itself:
/// token validation is performed by the App Service Authentication platform layer, which is
/// configured in Bicep. Reading the resulting headers keeps the application free of any
/// secret, certificate or signing-key material.
/// </summary>
public static class CallerIdentityReader
{
    private const string PrincipalHeader = "X-MS-CLIENT-PRINCIPAL";
    private const string PrincipalNameHeader = "X-MS-CLIENT-PRINCIPAL-NAME";
    private const string PrincipalIdHeader = "X-MS-CLIENT-PRINCIPAL-ID";

    private static readonly string[] AppIdClaimTypes = ["azp", "appid"];
    private static readonly string[] ObjectIdClaimTypes =
        ["oid", "http://schemas.microsoft.com/identity/claims/objectidentifier"];
    private static readonly string[] TenantIdClaimTypes =
        ["tid", "http://schemas.microsoft.com/identity/claims/tenantid"];

    public static CallerIdentity Read(HttpRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);

        var encoded = request.Headers[PrincipalHeader].ToString();

        if (string.IsNullOrWhiteSpace(encoded))
        {
            return CallerIdentity.Anonymous;
        }

        var claims = TryDecodeClaims(encoded);

        if (claims is null)
        {
            // Header present but unparsable: treat as unauthenticated rather than trusting it.
            return CallerIdentity.Anonymous;
        }

        return new CallerIdentity(
            IsAuthenticated: true,
            AppId: FirstClaim(claims, AppIdClaimTypes),
            ObjectId: FirstClaim(claims, ObjectIdClaimTypes)
                      ?? NullIfEmpty(request.Headers[PrincipalIdHeader].ToString()),
            TenantId: FirstClaim(claims, TenantIdClaimTypes),
            DisplayName: NullIfEmpty(request.Headers[PrincipalNameHeader].ToString()));
    }

    internal static IReadOnlyList<(string Type, string Value)>? TryDecodeClaims(string encodedPrincipal)
    {
        try
        {
            var json = Encoding.UTF8.GetString(Convert.FromBase64String(encodedPrincipal));

            using var document = JsonDocument.Parse(json);

            if (!document.RootElement.TryGetProperty("claims", out var claimsElement)
                || claimsElement.ValueKind != JsonValueKind.Array)
            {
                return [];
            }

            var claims = new List<(string, string)>(claimsElement.GetArrayLength());

            foreach (var claim in claimsElement.EnumerateArray())
            {
                var type = claim.TryGetProperty("typ", out var t) ? t.GetString() : null;
                var value = claim.TryGetProperty("val", out var v) ? v.GetString() : null;

                if (type is not null && value is not null)
                {
                    claims.Add((type, value));
                }
            }

            return claims;
        }
        catch (Exception ex) when (ex is FormatException or JsonException or DecoderFallbackException)
        {
            return null;
        }
    }

    private static string? FirstClaim(
        IReadOnlyList<(string Type, string Value)> claims,
        string[] claimTypes)
    {
        foreach (var claimType in claimTypes)
        {
            foreach (var (type, value) in claims)
            {
                if (string.Equals(type, claimType, StringComparison.OrdinalIgnoreCase))
                {
                    return value;
                }
            }
        }

        return null;
    }

    private static string? NullIfEmpty(string value) =>
        string.IsNullOrWhiteSpace(value) ? null : value;
}
