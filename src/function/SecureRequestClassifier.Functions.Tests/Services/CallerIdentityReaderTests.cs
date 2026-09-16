using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Http;
using SecureRequestClassifier.Functions.Services;
using Xunit;

namespace SecureRequestClassifier.Functions.Tests.Services;

/// <summary>
/// The function trusts App Service Authentication to validate the Microsoft Entra ID token and
/// then reads the resulting client-principal header. These tests pin that parsing, including
/// the cases where the header is absent or malformed - which must degrade to "anonymous"
/// rather than to "trusted".
/// </summary>
public sealed class CallerIdentityReaderTests
{
    private static string EncodePrincipal(params (string Type, string Value)[] claims)
    {
        var payload = new
        {
            auth_typ = "aad",
            claims = claims.Select(c => new { typ = c.Type, val = c.Value }).ToArray(),
        };

        return Convert.ToBase64String(
            Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload)));
    }

    private static HttpRequest RequestWith(params (string Name, string Value)[] headers)
    {
        var context = new DefaultHttpContext();

        foreach (var (name, value) in headers)
        {
            context.Request.Headers[name] = value;
        }

        return context.Request;
    }

    [Fact]
    public void A_request_with_no_principal_header_is_anonymous()
    {
        var identity = CallerIdentityReader.Read(RequestWith());

        Assert.False(identity.IsAuthenticated);
        Assert.Null(identity.AppId);
    }

    [Fact]
    public void A_v2_token_principal_is_read_from_the_azp_claim()
    {
        var encoded = EncodePrincipal(
            ("azp", "11111111-1111-1111-1111-111111111111"),
            ("oid", "22222222-2222-2222-2222-222222222222"),
            ("tid", "33333333-3333-3333-3333-333333333333"));

        var identity = CallerIdentityReader.Read(
            RequestWith(("X-MS-CLIENT-PRINCIPAL", encoded)));

        Assert.True(identity.IsAuthenticated);
        Assert.Equal("11111111-1111-1111-1111-111111111111", identity.AppId);
        Assert.Equal("22222222-2222-2222-2222-222222222222", identity.ObjectId);
        Assert.Equal("33333333-3333-3333-3333-333333333333", identity.TenantId);
    }

    [Fact]
    public void A_v1_token_principal_falls_back_to_the_appid_claim()
    {
        var encoded = EncodePrincipal(("appid", "44444444-4444-4444-4444-444444444444"));

        var identity = CallerIdentityReader.Read(
            RequestWith(("X-MS-CLIENT-PRINCIPAL", encoded)));

        Assert.Equal("44444444-4444-4444-4444-444444444444", identity.AppId);
    }

    [Fact]
    public void The_long_form_object_id_claim_uri_is_understood()
    {
        var encoded = EncodePrincipal(
            ("http://schemas.microsoft.com/identity/claims/objectidentifier", "abc"));

        var identity = CallerIdentityReader.Read(
            RequestWith(("X-MS-CLIENT-PRINCIPAL", encoded)));

        Assert.Equal("abc", identity.ObjectId);
    }

    [Theory]
    [InlineData("this-is-not-base64!!")]
    [InlineData("eyJ1bmNsb3NlZCI6")]
    public void A_malformed_principal_header_degrades_to_anonymous(string malformed)
    {
        var identity = CallerIdentityReader.Read(
            RequestWith(("X-MS-CLIENT-PRINCIPAL", malformed)));

        Assert.False(identity.IsAuthenticated);
    }

    [Fact]
    public void The_display_name_header_is_surfaced_for_logging()
    {
        var encoded = EncodePrincipal(("azp", "app"));

        var identity = CallerIdentityReader.Read(RequestWith(
            ("X-MS-CLIENT-PRINCIPAL", encoded),
            ("X-MS-CLIENT-PRINCIPAL-NAME", "Secure Request Classifier Flow")));

        Assert.Equal("Secure Request Classifier Flow", identity.DisplayName);
    }

    [Fact]
    public void The_principal_id_header_is_used_when_no_oid_claim_is_present()
    {
        var encoded = EncodePrincipal(("azp", "app"));

        var identity = CallerIdentityReader.Read(RequestWith(
            ("X-MS-CLIENT-PRINCIPAL", encoded),
            ("X-MS-CLIENT-PRINCIPAL-ID", "principal-id-from-header")));

        Assert.Equal("principal-id-from-header", identity.ObjectId);
    }
}
