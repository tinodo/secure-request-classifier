using System.Reflection;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using SecureRequestClassifier.Functions.Endpoints;
using SecureRequestClassifier.Functions.Models;
using Xunit;

namespace SecureRequestClassifier.Functions.Tests.Endpoints;

public sealed class HealthFunctionTests
{
    private static HealthFunction CreateFunction() =>
        new(NullLogger<HealthFunction>.Instance,
            TimeProvider.System,
            Options.Create(TestFactory.DefaultOptions()));

    private static HttpRequest CreateRequest(params (string Name, string Value)[] headers)
    {
        var context = new DefaultHttpContext();
        context.Request.Method = HttpMethods.Get;

        foreach (var (name, value) in headers)
        {
            context.Request.Headers[name] = value;
        }

        return context.Request;
    }

    [Fact]
    public void An_unauthenticated_probe_still_succeeds()
    {
        // /api/health is excluded from App Service Authentication so a probe from inside the
        // virtual network can prove NETWORK reachability independently of authentication.
        var result = CreateFunction().Run(CreateRequest());

        var response = Assert.IsType<HealthResponse>(Assert.IsType<OkObjectResult>(result).Value);

        Assert.Equal("Healthy", response.Status);
        Assert.False(response.Authenticated);
        Assert.Null(response.CallerAppId);
    }

    [Fact]
    public void An_authenticated_probe_reports_the_calling_application()
    {
        var payload = new
        {
            auth_typ = "aad",
            claims = new[] { new { typ = "azp", val = "7ab7862c-4c57-491e-8a45-d52a7e023983" } },
        };

        var encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload)));

        var result = CreateFunction().Run(CreateRequest(("X-MS-CLIENT-PRINCIPAL", encoded)));

        var response = Assert.IsType<HealthResponse>(Assert.IsType<OkObjectResult>(result).Value);

        Assert.True(response.Authenticated);
        Assert.Equal("7ab7862c-4c57-491e-8a45-d52a7e023983", response.CallerAppId);
    }

    [Fact]
    public void The_health_document_reports_the_runtime_and_service_name()
    {
        var result = CreateFunction().Run(CreateRequest());

        var response = Assert.IsType<HealthResponse>(Assert.IsType<OkObjectResult>(result).Value);

        Assert.Contains(".NET", response.Runtime, StringComparison.Ordinal);
        Assert.Equal("Secure Request Classifier (test)", response.Service);
        Assert.False(string.IsNullOrWhiteSpace(response.Version));
    }
}

/// <summary>
/// The demo's central claim is that no Function key is used anywhere. Enforcing that with a
/// reflection test means the claim is verified on every build, not merely asserted in prose.
/// </summary>
public sealed class AuthorizationLevelTests
{
    private static IEnumerable<MethodInfo> GetTriggerMethods() =>
        typeof(ClassifyRequestFunction).Assembly
            .GetTypes()
            .SelectMany(type => type.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static))
            .Where(method => method.GetCustomAttribute<FunctionAttribute>() is not null);

    [Fact]
    public void Every_http_trigger_uses_anonymous_authorization()
    {
        var triggers = GetTriggerMethods()
            .SelectMany(method => method.GetParameters())
            .Select(parameter => parameter.GetCustomAttribute<HttpTriggerAttribute>())
            .Where(attribute => attribute is not null)
            .ToArray();

        Assert.NotEmpty(triggers);

        foreach (var trigger in triggers)
        {
            Assert.Equal(AuthorizationLevel.Anonymous, trigger!.AuthLevel);
        }
    }

    [Fact]
    public void The_expected_functions_are_registered()
    {
        var names = GetTriggerMethods()
            .Select(method => method.GetCustomAttribute<FunctionAttribute>()!.Name)
            .OrderBy(name => name, StringComparer.Ordinal)
            .ToArray();

        Assert.Equal(["ClassifyRequest", "Health"], names);
    }

    [Theory]
    [InlineData(typeof(ClassifyRequestFunction), "requests/classify")]
    [InlineData(typeof(HealthFunction), "health")]
    public void Routes_match_the_documented_contract(Type functionType, string expectedRoute)
    {
        var trigger = functionType
            .GetMethods(BindingFlags.Public | BindingFlags.Instance)
            .Where(method => method.GetCustomAttribute<FunctionAttribute>() is not null)
            .SelectMany(method => method.GetParameters())
            .Select(parameter => parameter.GetCustomAttribute<HttpTriggerAttribute>())
            .First(attribute => attribute is not null);

        Assert.Equal(expectedRoute, trigger!.Route);
    }

    [Theory]
    [InlineData(typeof(ClassifyRequestFunction), "post")]
    [InlineData(typeof(HealthFunction), "get")]
    public void Only_the_intended_http_methods_are_accepted(Type functionType, string expectedMethod)
    {
        var trigger = functionType
            .GetMethods(BindingFlags.Public | BindingFlags.Instance)
            .Where(method => method.GetCustomAttribute<FunctionAttribute>() is not null)
            .SelectMany(method => method.GetParameters())
            .Select(parameter => parameter.GetCustomAttribute<HttpTriggerAttribute>())
            .First(attribute => attribute is not null);

        Assert.Equal([expectedMethod], trigger!.Methods ?? []);
    }
}
