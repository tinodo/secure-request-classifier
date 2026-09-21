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

    /// <summary>
    /// Correlation ids are echoed into logs and into the response, so an unbounded caller-supplied
    /// string is a cheap way to bloat both. 128 characters comfortably fits a GUID or a W3C trace
    /// id and anything longer is truncated rather than rejected.
    /// </summary>
    private const int MaximumCorrelationIdLength = 128;

    // JsonSerializerDefaults.Web already implies camelCase and case-insensitive property matching.
    private static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web);

    [Function("ClassifyRequest")]
    public async Task<IActionResult> RunAsync(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "requests/classify")]
        HttpRequest request,
        CancellationToken cancellationToken)
    {
        var caller = CallerIdentityReader.Read(request);

        // Read the header first. It is the only correlation id available if the body turns out to
        // be unparseable, and it has to exist before the authorization check so a rejection can be
        // correlated too.
        var headerCorrelationId = ReadCorrelationIdHeader(request);
        var correlationId = headerCorrelationId ?? Guid.NewGuid().ToString("D");

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

        // The request contract offers correlationId in the body as well as in the header, and a
        // caller that fills it in expects to get it back. Honour it now that the body has parsed,
        // but only when no header was supplied: setting the header is the more deliberate act,
        // usually because something upstream already owns the id.
        if (headerCorrelationId is null)
        {
            var bodyCorrelationId = NormalizeCorrelationId(payload?.CorrelationId);

            if (bodyCorrelationId is not null)
            {
                correlationId = bodyCorrelationId;
            }
        }

        // Re-scope only when the body supplied an id, so everything logged from here on carries
        // the same value the caller will see echoed in the response.
        using var bodyScope = ReferenceEquals(correlationId, headerCorrelationId)
            ? null
            : logger.BeginScope(new Dictionary<string, object?> { ["CorrelationId"] = correlationId });

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

    /// <summary>
    /// Reads the correlation id from the request header, or returns null when it is absent or
    /// blank. Trimmed and capped at 128 characters so a hostile or careless caller cannot push
    /// an unbounded string through into logs and the response.
    /// </summary>
    private static string? ReadCorrelationIdHeader(HttpRequest request) =>
        NormalizeCorrelationId(request.Headers["x-correlation-id"].ToString());

    private static string? NormalizeCorrelationId(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        var trimmed = value.Trim();

        return trimmed.Length <= MaximumCorrelationIdLength
            ? trimmed
            : trimmed[..MaximumCorrelationIdLength];
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
