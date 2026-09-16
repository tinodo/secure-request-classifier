using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.Options;
using SecureRequestClassifier.Functions.Configuration;
using SecureRequestClassifier.Functions.Services;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();

// Application Insights is wired through the Function App's managed identity
// (APPLICATIONINSIGHTS_AUTHENTICATION_STRING = Authorization=AAD). No instrumentation
// key or connection-string secret is stored anywhere in this repository.
builder.Services
    .AddApplicationInsightsTelemetryWorkerService()
    .ConfigureFunctionsApplicationInsights();

builder.Services
    .AddOptions<ClassifierOptions>()
    .Bind(builder.Configuration.GetSection(ClassifierOptions.SectionName))
    .ValidateOnStart();

builder.Services.AddSingleton<IValidateOptions<ClassifierOptions>, ClassifierOptionsValidator>();

builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<RequestClassifier>();

await builder.Build().RunAsync();