import Foundation

/// Errors from every `TextTransformer` provider. The name predates workflows; renaming the
/// persisted error domain would be churn with no product value.
enum TranslationError: Error, Equatable, Sendable {
    case missingConfiguration(String)
    case invalidBaseURL(String)
    case invalidResponse
    case emptyResponse
    case outputLimitReached
    case responseFiltered
    /// The endpoint reported an error partway through a streamed answer.
    case providerReportedError
    /// The endpoint sent far more than any answer, and was stopped.
    case responseTooLarge
    case cannotConnect(String)
    case timedOut
    case apiKeyRejected
    case rateLimited
    case httpStatus(Int)
    case codexCLINotFound
    case codexNotSignedIn
    case codexUsageLimit
    case codexEmptyOutput
    case codexFailed(Int)
    case codexTimedOut
    case claudeCLINotFound
    case claudeNotSignedIn
    case claudeUsageLimit
    case claudeEmptyOutput
    case claudeFailed(Int)
    case claudeTimedOut
    /// The CLI's launcher could not find its interpreter (exit 127), as with an npm install whose
    /// `node` is not where Syrup looks.
    case cliCouldNotStart(TranslationProvider)
    /// The CLI printed far more than any rewrite, and was stopped.
    case cliOutputTooLarge(TranslationProvider)
    case onDeviceUnavailable(String)
    case onDeviceGuardrail
    case onDeviceContextExceeded
}
