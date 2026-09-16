using SecureRequestClassifier.Functions.Models;
using SecureRequestClassifier.Functions.Services;
using Xunit;

namespace SecureRequestClassifier.Functions.Tests.Services;

public sealed class RequestValidatorTests
{
    private static ClassificationRequest Valid() => new()
    {
        RequesterName = "Katherine Johnson",
        RequesterEmail = "katherine@contoso.com",
        Title = "VPN drops every ten minutes",
        Category = "IT",
        Impact = "High",
        Description = "Started this morning after the update.",
    };

    [Fact]
    public void A_well_formed_request_produces_no_errors()
    {
        Assert.Empty(RequestValidator.Validate(Valid()));
    }

    [Fact]
    public void A_null_body_is_reported_rather_than_throwing()
    {
        var errors = RequestValidator.Validate(null);

        Assert.True(errors.ContainsKey("body"));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void RequesterName_is_required(string? name)
    {
        var errors = RequestValidator.Validate(Valid() with { RequesterName = name });

        Assert.True(errors.ContainsKey("requesterName"));
    }

    [Fact]
    public void RequesterName_is_length_limited()
    {
        var errors = RequestValidator.Validate(
            Valid() with { RequesterName = new string('a', RequestValidator.MaxRequesterNameLength + 1) });

        Assert.True(errors.ContainsKey("requesterName"));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("not-an-email")]
    [InlineData("missing@domain")]
    [InlineData("two@@at.com")]
    [InlineData("space in@contoso.com")]
    [InlineData("trailing@contoso.")]
    [InlineData("double@contoso..com")]
    [InlineData("@contoso.com")]
    public void RequesterEmail_must_be_structurally_plausible(string? email)
    {
        var errors = RequestValidator.Validate(Valid() with { RequesterEmail = email });

        Assert.True(errors.ContainsKey("requesterEmail"));
    }

    [Theory]
    [InlineData("a.b@contoso.com")]
    [InlineData("first.last+tag@sub.contoso.co.uk")]
    public void Realistic_addresses_are_accepted(string email)
    {
        var errors = RequestValidator.Validate(Valid() with { RequesterEmail = email });

        Assert.False(errors.ContainsKey("requesterEmail"));
    }

    [Theory]
    [InlineData("ab")]          // shorter than the minimum
    [InlineData(null)]
    [InlineData("  ")]
    public void Title_must_meet_the_minimum_length(string? title)
    {
        var errors = RequestValidator.Validate(Valid() with { Title = title });

        Assert.True(errors.ContainsKey("title"));
    }

    [Fact]
    public void Title_must_not_exceed_the_maximum_length()
    {
        var errors = RequestValidator.Validate(
            Valid() with { Title = new string('x', RequestValidator.MaxTitleLength + 1) });

        Assert.True(errors.ContainsKey("title"));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("Critical")]
    [InlineData("Severe")]
    public void Impact_must_be_one_of_the_supported_values(string? impact)
    {
        var errors = RequestValidator.Validate(Valid() with { Impact = impact });

        Assert.True(errors.ContainsKey("impact"));
        Assert.Contains("Low, Medium, High", errors["impact"][0], StringComparison.Ordinal);
    }

    [Fact]
    public void Category_is_required_but_an_unknown_value_is_not_an_error()
    {
        Assert.True(RequestValidator.Validate(Valid() with { Category = "  " })
            .ContainsKey("category"));

        // Unknown-but-present categories are normalized to Other by the classifier instead.
        Assert.False(RequestValidator.Validate(Valid() with { Category = "Catering" })
            .ContainsKey("category"));
    }

    [Fact]
    public void Description_is_optional_but_length_limited()
    {
        Assert.Empty(RequestValidator.Validate(Valid() with { Description = null }));

        Assert.True(RequestValidator
            .Validate(Valid() with { Description = new string('d', RequestValidator.MaxDescriptionLength + 1) })
            .ContainsKey("description"));
    }

    [Fact]
    public void All_failing_fields_are_reported_in_one_response()
    {
        var errors = RequestValidator.Validate(new ClassificationRequest());

        Assert.Equal(
            ["category", "impact", "requesterEmail", "requesterName", "title"],
            errors.Keys.OrderBy(k => k, StringComparer.Ordinal).ToArray());
    }
}
