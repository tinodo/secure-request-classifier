using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Options;
using SecureRequestClassifier.Functions.Configuration;
using SecureRequestClassifier.Functions.Models;
using SecureRequestClassifier.Functions.Services;

namespace SecureRequestClassifier.Functions.Endpoints;

/// <summary>
/// <c>POST /api/requests/classify</c>.
///
/// AuthorizationLevel is <see cref="AuthorizationLevel.Anonymous"/> on purpose: authentication
/// is enforced by App Service Authentication (Microsoft Entra ID) in front of the worker, so
/// the demo never uses a Function key. See docs/security-model.md.
/// </summary>
public sealed class ClassifyRequestFunction(
    ILogger<ClassifyRequestFunction> logger,
    RequestClassifier classifier,
    TimeProvider timeProvider,
    IOptions<ClassifierOptions> options)
{
    private readonly ClassifierOptions _options = options.Value;

    private static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true,
    };

    [Function("ClassifyRequest")]
    public async Task<IActionResult> RunAsync(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "requests/classify")]
        HttpRequest request,
        CancellationToken cancellationToken)
    {
        var caller = CallerIdentityReader.Read(request);
        var correlationId = ResolveCorrelationId(request);

        using var scope = logger.BeginScope(new Dictionary<string, object?>
        {
            ["CorrelationId"] = correlationId,
            ["CallerAppId"] = caller.AppId,
            ["CallerObjectId"] = caller.ObjectId,
        });

        if (!IsCallerAllowed(caller))
        {
            logger.LogWarning(
                "Rejected classification request from non-allow-listed application {CallerAppId}.",
                caller.AppId ?? "(none)");

            return Problem(
                StatusCodes.Status403Forbidden,
                "Caller is not authorized.",
                "The calling application is not in the configured allow-list.",
                correlationId);
        }

        ClassificationRequest? payload;

        try
        {
            payload = await JsonSerializer.DeserializeAsync<ClassificationRequest>(
                request.Body, SerializerOptions, cancellationToken);
        }
        catch (JsonException ex)
        {
            logger.LogWarning(ex, "Classification request body was not valid JSON.");

            return BadRequest(
                new Dictionary<string, string[]>
                {
                    ["body"] = ["The request body could not be parsed as JSON."],
                },
                correlationId);
        }

        var errors = RequestValidator.Validate(payload);

        if (errors.Count > 0)
        {
            logger.LogInformation(
                "Classification request rejected with {ErrorCount} validation error(s): {Fields}.",
                errors.Count,
                string.Join(", ", errors.Keys));

            return BadRequest(errors, correlationId);
        }

        var receivedAtUtc = timeProvider.GetUtcNow();

        var response = classifier.Classify(payload!, receivedAtUtc, correlationId);

        logger.LogInformation(
            "Classified {RequestId} as {Priority} for team {AssignedTeam}; response target {TargetResponseDate:u}.",
            response.RequestId,
            response.Priority,
            response.AssignedTeam,
            response.TargetResponseDate);

        return new OkObjectResult(response);
    }

    private bool IsCallerAllowed(CallerIdentity caller)
    {
        var allowList = _options.AllowedClientAppIdSet;

        if (allowList.Count == 0)
        {
            // Platform-level Easy Auth `allowedApplications` is the primary control.
            return true;
        }

        return caller.AppId is not null && allowList.Contains(caller.AppId);
    }

    private static string ResolveCorrelationId(HttpRequest request)
    {
        var header = request.Headers["x-correlation-id"].ToString();

        return string.IsNullOrWhiteSpace(header)
            ? Guid.NewGuid().ToString("D")
            : header.Trim()[..Math.Min(header.Trim().Length, 128)];
    }

    private static IActionResult BadRequest(
        IReadOnlyDictionary<string, string[]> errors,
        string correlationId)
    {
        var problem = new ValidationProblem
        {
            Errors = errors,
            CorrelationId = correlationId,
            Detail = "The submitted request did not pass validation and was not classified.",
        };

        return new ObjectResult(problem)
        {
            StatusCode = StatusCodes.Status400BadRequest,
            ContentTypes = { "application/problem+json" },
        };
    }

    private static IActionResult Problem(
        int statusCode,
        string title,
        string detail,
        string correlationId)
    {
        var problem = new ValidationProblem
        {
            Title = title,
            Detail = detail,
            Status = statusCode,
            Errors = new Dictionary<string, string[]>(StringComparer.Ordinal),
            CorrelationId = correlationId,
        };

        return new ObjectResult(problem)
        {
            StatusCode = statusCode,
            ContentTypes = { "application/problem+json" },
        };
    }
}
