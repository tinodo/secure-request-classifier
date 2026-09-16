using SecureRequestClassifier.Functions.Models;

namespace SecureRequestClassifier.Functions.Services;

/// <summary>
/// Stateless input validation. Runs before any classification so that malformed
/// submissions produce a 400 with a machine-readable error map rather than a 500.
/// </summary>
public static class RequestValidator
{
    public const int MaxRequesterNameLength = 100;
    public const int MaxRequesterEmailLength = 256;
    public const int MinTitleLength = 3;
    public const int MaxTitleLength = 120;
    public const int MaxDescriptionLength = 2000;

    public static IReadOnlyDictionary<string, string[]> Validate(ClassificationRequest? request)
    {
        var errors = new Dictionary<string, string[]>(StringComparer.Ordinal);

        if (request is null)
        {
            errors["body"] = ["A JSON request body is required."];
            return errors;
        }

        Require(errors, "requesterName", request.RequesterName, MaxRequesterNameLength);
        ValidateEmail(errors, request.RequesterEmail);
        ValidateTitle(errors, request.Title);
        ValidateImpact(errors, request.Impact);
        ValidateDescription(errors, request.Description);

        // Category is deliberately NOT rejected when unknown: the service normalizes
        // unrecognised categories to "Other" and reports it as a note. It is still
        // required to be present and non-empty.
        if (string.IsNullOrWhiteSpace(request.Category))
        {
            errors["category"] =
            [
                $"A category is required. Expected one of: {string.Join(", ", RequestClassifier.SupportedCategories)}."
            ];
        }

        return errors;
    }

    private static void Require(
        Dictionary<string, string[]> errors,
        string field,
        string? value,
        int maxLength)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            errors[field] = [$"'{field}' is required."];
        }
        else if (value.Trim().Length > maxLength)
        {
            errors[field] = [$"'{field}' must be {maxLength} characters or fewer."];
        }
    }

    private static void ValidateEmail(Dictionary<string, string[]> errors, string? email)
    {
        if (string.IsNullOrWhiteSpace(email))
        {
            errors["requesterEmail"] = ["'requesterEmail' is required."];
            return;
        }

        var trimmed = email.Trim();

        if (trimmed.Length > MaxRequesterEmailLength)
        {
            errors["requesterEmail"] =
                [$"'requesterEmail' must be {MaxRequesterEmailLength} characters or fewer."];
            return;
        }

        if (!IsPlausibleEmail(trimmed))
        {
            errors["requesterEmail"] = ["'requesterEmail' must be a valid email address."];
        }
    }

    private static void ValidateTitle(Dictionary<string, string[]> errors, string? title)
    {
        if (string.IsNullOrWhiteSpace(title))
        {
            errors["title"] = ["'title' is required."];
            return;
        }

        var length = title.Trim().Length;

        if (length < MinTitleLength || length > MaxTitleLength)
        {
            errors["title"] =
                [$"'title' must be between {MinTitleLength} and {MaxTitleLength} characters."];
        }
    }

    private static void ValidateImpact(Dictionary<string, string[]> errors, string? impact)
    {
        if (string.IsNullOrWhiteSpace(impact))
        {
            errors["impact"] =
                [$"'impact' is required. Expected one of: {string.Join(", ", RequestClassifier.SupportedImpacts)}."];
            return;
        }

        if (!RequestClassifier.TryNormalizeImpact(impact, out _))
        {
            errors["impact"] =
            [
                $"'{impact.Trim()}' is not a recognised impact. Expected one of: " +
                $"{string.Join(", ", RequestClassifier.SupportedImpacts)}."
            ];
        }
    }

    private static void ValidateDescription(Dictionary<string, string[]> errors, string? description)
    {
        if (description is not null && description.Trim().Length > MaxDescriptionLength)
        {
            errors["description"] =
                [$"'description' must be {MaxDescriptionLength} characters or fewer."];
        }
    }

    /// <summary>
    /// Intentionally conservative structural check. Full RFC 5322 validation is out of
    /// scope for the demo; the authoritative identity of the caller comes from the
    /// Microsoft Entra ID token, not from this field.
    /// </summary>
    internal static bool IsPlausibleEmail(string value)
    {
        var at = value.IndexOf('@');

        if (at <= 0 || at != value.LastIndexOf('@') || at == value.Length - 1)
        {
            return false;
        }

        if (value.Any(char.IsWhiteSpace))
        {
            return false;
        }

        var domain = value[(at + 1)..];

        var dot = domain.IndexOf('.');

        return dot > 0
            && dot != domain.Length - 1
            && !domain.StartsWith('.')
            && !domain.Contains("..", StringComparison.Ordinal);
    }
}
