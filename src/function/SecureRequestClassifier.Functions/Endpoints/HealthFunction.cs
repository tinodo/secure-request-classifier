using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Options;
using SecureRequestClassifier.Functions.Configuration;
using SecureRequestClassifier.Functions.Models;
using SecureRequestClassifier.Functions.Services;

namespace SecureRequestClassifier.Functions.Endpoints;

/// <summary>
/// <c>GET /api/health</c>.
///
/// This route is listed in the App Service Authentication <c>excludedPaths</c> so that a probe
/// from inside the virtual network can prove <em>network</em> reachability independently of
/// <em>authentication</em>. That separation is what makes "the Function App has no public
/// endpoint" demonstrable: the same probe from the public internet fails to connect at all.
/// </summary>
public sealed class HealthFunction(
    ILogger<HealthFunction> logger,
    TimeProvider timeProvider,
    IOptions<ClassifierOptions> options)
{
    private static readonly string AssemblyVersion =
        typeof(HealthFunction).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
        ?? typeof(HealthFunction).Assembly.GetName().Version?.ToString()
        ?? "unknown";

    [Function("Health")]
    public IActionResult Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "health")]
        HttpRequest request)
    {
        var caller = CallerIdentityReader.Read(request);

        logger.LogInformation(
            "Health probe received. Authenticated={Authenticated} CallerAppId={CallerAppId}",
            caller.IsAuthenticated,
            caller.AppId ?? "(none)");

        var response = new HealthResponse
        {
            Status = "Healthy",
            Service = options.Value.ServiceName,
            Version = AssemblyVersion,
            UtcNow = timeProvider.GetUtcNow(),
            Runtime = RuntimeInformation.FrameworkDescription,
            Authenticated = caller.IsAuthenticated,
            CallerAppId = caller.AppId,
        };

        return new OkObjectResult(response);
    }
}
