using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using SecureRequestClassifier.Functions.Endpoints;
using SecureRequestClassifier.Functions.Models;
using Xunit;

namespace SecureRequestClassifier.Functions.Tests.Endpoints;

/// <summary>
/// Exercises the HTTP endpoint directly, including status codes and the problem+json contract
/// that Power Automate's Parse JSON action depends on.
/// </summary>
public sealed class ClassifyRequestFunctionTests
{
    private const string ValidBody = """
        {
          "requesterName": "Priya Sharma",
          "requesterEmail": "priya@contoso.com",
          "title": "Laptop will not power on after the update",
          "category": "IT",
          "impact": "High",
          "description": "Nothing happens when I press the power button."
        }
        """;

    private static ClassifyRequestFunction CreateFunction(Functions.Configuration.ClassifierOptions? options = null)
    {
        var effective = options ?? TestFactory.DefaultOptions();

        return new ClassifyRequestFunction(
            NullLogger<ClassifyRequestFunction>.Instance,
            TestFactory.CreateClassifier(effective),
            TimeProvider.System,
            Options.Create(effective));
    }

    private static HttpRequest CreateRequest(string body, params (string Name, string Value)[] headers)
    {
        var context = new DefaultHttpContext();
        context.Request.Method = HttpMethods.Post;
        context.Request.ContentType = "application/json";
        context.Request.Body = new MemoryStream(Encoding.UTF8.GetBytes(body));

        foreach (var (name, value) in headers)
        {
            context.Request.Headers[name] = value;
        }

        return context.Request;
    }

    private static string EncodePrincipal(string appId)
    {
        var payload = new
        {
            auth_typ = "aad",
            claims = new[] { new { typ = "azp", val = appId } },
        };

        return Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload)));
    }

    [Fact]
    public async Task A_valid_request_is_classified_and_returns_200()
    {
        var result = await CreateFunction().RunAsync(CreateRequest(ValidBody), CancellationToken.None);

        var ok = Assert.IsType<OkObjectResult>(result);
        var response = Assert.IsType<ClassificationResponse>(ok.Value);

        Assert.Equal("P1", response.Priority);
        Assert.Equal("Digital Workplace Support", response.AssignedTeam);
        Assert.Equal("Accepted", response.Status);
        Assert.StartsWith("SRC-", response.RequestId, StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_supplied_correlation_id_is_echoed_back()
    {
        var result = await CreateFunction()
            .RunAsync(CreateRequest(ValidBody, ("x-correlation-id", "flow-run-42")), CancellationToken.None);

        var response = Assert.IsType<ClassificationResponse>(Assert.IsType<OkObjectResult>(result).Value);

        Assert.Equal("flow-run-42", response.CorrelationId);
    }

    [Fact]
    public async Task A_missing_correlation_id_is_generated()
    {
        var result = await CreateFunction().RunAsync(CreateRequest(ValidBody), CancellationToken.None);

        var response = Assert.IsType<ClassificationResponse>(Assert.IsType<OkObjectResult>(result).Value);

        Assert.True(Guid.TryParse(response.CorrelationId, out _));
    }

    [Fact]
    public async Task A_correlation_id_in_the_body_is_echoed_back()
    {
        // The request contract advertises correlationId as a body field, which is the obvious
        // place for a Power Automate flow to put it. It used to be deserialized and then silently
        // dropped, so the caller got a random GUID back and could not tie the two together.
        var body = ValidBody.Replace(
            "\"description\"",
            "\"correlationId\": \"from-the-body\", \"description\"",
            StringComparison.Ordinal);

        var result = await CreateFunction().RunAsync(CreateRequest(body), CancellationToken.None);

        var response = Assert.IsType<ClassificationResponse>(Assert.IsType<OkObjectResult>(result).Value);

        Assert.Equal("from-the-body", response.CorrelationId);
    }

    [Fact]
    public async Task The_header_correlation_id_wins_over_the_body()
    {
        var body = ValidBody.Replace(
            "\"description\"",
            "\"correlationId\": \"from-the-body\", \"description\"",
            StringComparison.Ordinal);

        var result = await CreateFunction()
            .RunAsync(CreateRequest(body, ("x-correlation-id", "from-the-header")), CancellationToken.None);

        var response = Assert.IsType<ClassificationResponse>(Assert.IsType<OkObjectResult>(result).Value);

        Assert.Equal("from-the-header", response.CorrelationId);
    }

    [Fact]
    public async Task An_over_long_correlation_id_is_truncated()
    {
        var result = await CreateFunction()
            .RunAsync(CreateRequest(ValidBody, ("x-correlation-id", new string('x', 500))), CancellationToken.None);

        var response = Assert.IsType<ClassificationResponse>(Assert.IsType<OkObjectResult>(result).Value);

        Assert.Equal(128, response.CorrelationId.Length);
    }

    [Fact]
    public async Task A_whitespace_only_correlation_id_is_treated_as_absent()
    {
        var result = await CreateFunction()
            .RunAsync(CreateRequest(ValidBody, ("x-correlation-id", "   ")), CancellationToken.None);

        var response = Assert.IsType<ClassificationResponse>(Assert.IsType<OkObjectResult>(result).Value);

        Assert.True(Guid.TryParse(response.CorrelationId, out _));
    }

    [Fact]
    public async Task An_invalid_request_returns_400_problem_json_with_a_field_map()
    {
        const string body = """{ "requesterName": "", "impact": "Catastrophic" }""";

        var result = await CreateFunction().RunAsync(CreateRequest(body), CancellationToken.None);

        var objectResult = Assert.IsType<ObjectResult>(result);

        Assert.Equal(StatusCodes.Status400BadRequest, objectResult.StatusCode);
        Assert.Contains("application/problem+json", objectResult.ContentTypes);

        var problem = Assert.IsType<ValidationProblem>(objectResult.Value);

        Assert.Contains("requesterName", problem.Errors.Keys);
        Assert.Contains("impact", problem.Errors.Keys);
        Assert.Contains("title", problem.Errors.Keys);
    }

    [Fact]
    public async Task Malformed_json_returns_400_rather_than_500()
    {
        var result = await CreateFunction().RunAsync(CreateRequest("{ not json"), CancellationToken.None);

        var objectResult = Assert.IsType<ObjectResult>(result);

        Assert.Equal(StatusCodes.Status400BadRequest, objectResult.StatusCode);

        var problem = Assert.IsType<ValidationProblem>(objectResult.Value);
        Assert.Contains("body", problem.Errors.Keys);
    }

    [Fact]
    public async Task An_empty_body_returns_400()
    {
        var result = await CreateFunction().RunAsync(CreateRequest(string.Empty), CancellationToken.None);

        Assert.Equal(StatusCodes.Status400BadRequest, Assert.IsType<ObjectResult>(result).StatusCode);
    }

    [Fact]
    public async Task A_caller_outside_the_allow_list_is_rejected_with_403()
    {
        var options = TestFactory.DefaultOptions();
        options.AllowedClientAppIds = "11111111-1111-1111-1111-111111111111";

        var request = CreateRequest(
            ValidBody,
            ("X-MS-CLIENT-PRINCIPAL", EncodePrincipal("99999999-9999-9999-9999-999999999999")));

        var result = await CreateFunction(options).RunAsync(request, CancellationToken.None);

        var objectResult = Assert.IsType<ObjectResult>(result);

        Assert.Equal(StatusCodes.Status403Forbidden, objectResult.StatusCode);
        Assert.Contains("application/problem+json", objectResult.ContentTypes);
    }

    [Fact]
    public async Task A_caller_inside_the_allow_list_is_accepted()
    {
        const string allowed = "11111111-1111-1111-1111-111111111111";

        var options = TestFactory.DefaultOptions();
        options.AllowedClientAppIds = allowed;

        var request = CreateRequest(ValidBody, ("X-MS-CLIENT-PRINCIPAL", EncodePrincipal(allowed)));

        var result = await CreateFunction(options).RunAsync(request, CancellationToken.None);

        Assert.IsType<OkObjectResult>(result);
    }

    [Fact]
    public async Task An_empty_allow_list_defers_entirely_to_the_platform_layer()
    {
        // App Service Authentication's allowedApplications is the primary control; the
        // in-code list is optional defence in depth.
        var options = TestFactory.DefaultOptions();
        options.AllowedClientAppIds = string.Empty;

        var result = await CreateFunction(options).RunAsync(CreateRequest(ValidBody), CancellationToken.None);

        Assert.IsType<OkObjectResult>(result);
    }

    [Fact]
    public async Task An_unrecognised_category_is_normalized_rather_than_rejected()
    {
        const string body = """
            {
              "requesterName": "Sam Patel",
              "requesterEmail": "sam@contoso.com",
              "title": "Coffee machine is broken again",
              "category": "Catering",
              "impact": "Low"
            }
            """;

        var result = await CreateFunction().RunAsync(CreateRequest(body), CancellationToken.None);

        var response = Assert.IsType<ClassificationResponse>(Assert.IsType<OkObjectResult>(result).Value);

        Assert.Equal("Other", response.NormalizedCategory);
        Assert.Single(response.Notes);
    }
}
