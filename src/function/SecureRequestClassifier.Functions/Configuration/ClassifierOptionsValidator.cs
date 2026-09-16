using Microsoft.Extensions.Options;

namespace SecureRequestClassifier.Functions.Configuration;

/// <summary>
/// Validates <see cref="ClassifierOptions"/> at host start-up so a misconfigured
/// Function App fails fast and visibly instead of failing on the first request.
/// </summary>
internal sealed class ClassifierOptionsValidator : IValidateOptions<ClassifierOptions>
{
    public ValidateOptionsResult Validate(string? name, ClassifierOptions options)
    {
        try
        {
            options.Validate();
            return ValidateOptionsResult.Success;
        }
        catch (InvalidOperationException ex)
        {
            return ValidateOptionsResult.Fail(ex.Message);
        }
    }
}
